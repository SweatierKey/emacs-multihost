;;; multihost-connection.el --- Persistent isolated TRAMP workers -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/SweatierKey/emacs-multihost

;;; Commentary:
;; This pool never connects from the editor process.  Every worker owns its
;; TRAMP shell and caches; one operation at a time runs in each worker.
;; Cancellation and timeouts retire active workers without replaying work.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'multihost-inventory)
(require 'multihost-worker)

(defgroup multihost nil "Organized remote administration with Org." :group 'tools)
(defcustom multihost-state-directory (expand-file-name "multihost" user-emacs-directory)
  "Private directory for run metadata and worker files." :type 'directory :group 'multihost)
(defcustom multihost-worker-init-file nil
  "Explicitly trusted local configuration loaded once in each worker."
  :type '(choice (const nil) file) :group 'multihost)
(defcustom multihost-worker-program (expand-file-name invocation-name invocation-directory)
  "Emacs executable used for isolated workers." :type 'file :group 'multihost)
(defcustom multihost-connection-limit 4
  "Maximum total persistent worker processes, across all runs and operations."
  :type 'natnum :group 'multihost)
(defcustom multihost-connection-idle-timeout 300
  "Seconds to retain an idle worker and its in-memory TRAMP connection."
  :type 'number :group 'multihost)
(defconst multihost-connection--library-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))
(defconst multihost-connection--terminal '(succeeded failed timed-out cancelled))
(defvar multihost-connection--workers nil)
(defvar multihost-connection--queue nil)
(defvar multihost-connection--counter 0)
(defvar multihost-connection--pumping nil)
(defvar multihost-connection--pump-timer nil)

(cl-defstruct multihost-request
  id directory operation payload callback timeout key init-file
  (status 'queued) result process worker timer submitted-at started-at ended-at)
(cl-defstruct multihost-connection-worker
  id key directory storage process request (state 'starting) pending
  started-at last-used idle-timer (completed 0))

(defun multihost-connection--hash-file (file)
  "Return a content fingerprint of local FILE."
  (let ((default-directory "/"))
    (with-temp-buffer (insert-file-contents-literally file) (secure-hash 'sha256 (current-buffer)))))

(defun multihost-connection--prefix (directory)
  "Return DIRECTORY's complete textual TRAMP prefix without proxy side effects."
  (multihost-inventory--remote directory)
  (unless (tramp-tramp-file-p directory) (user-error "An explicit TRAMP directory is required"))
  (let ((localname (tramp-file-name-localname (tramp-dissect-file-name directory t))))
    (substring-no-properties directory 0 (- (length directory) (length localname)))))

(defun multihost-connection--local-path (file label)
  "Resolve local FILE for LABEL without consulting remote file handlers."
  (unless (stringp file) (user-error "%s must be a local path" label))
  (when (or (or (tramp-tramp-file-p file) (file-remote-p file))
            (and (not (file-name-absolute-p file))
                 (or (tramp-tramp-file-p default-directory) (file-remote-p default-directory))))
    (user-error "%s must use an explicit local path" label))
  (expand-file-name file (if (file-name-absolute-p file) "/" default-directory)))

(defun multihost-connection--key (directory)
  "Return the full remote identity and explicit configuration for DIRECTORY."
  (let* ((prefix (multihost-connection--prefix directory))
         (state (multihost-connection--local-path multihost-state-directory "Worker state"))
         (init (and multihost-worker-init-file
                    (multihost-connection--local-path multihost-worker-init-file "Worker init")))
         (program-path (multihost-connection--local-path multihost-worker-program "Worker executable"))
         (program (if (file-name-directory multihost-worker-program) program-path
                    (let ((default-directory "/")
                          (exec-path (cl-remove-if (lambda (path) (and path (file-remote-p path))) exec-path)))
                      (or (executable-find multihost-worker-program) program-path)))))
    (let ((default-directory "/"))
      (when (and init (not (file-readable-p init))) (user-error "Worker init is not readable")))
    (list prefix program init
          (and init (multihost-connection--hash-file init))
          ;; A source update must not silently keep executing an older worker.
          (mapcar (lambda (name)
                    (let ((file (expand-file-name name multihost-connection--library-directory))
                          (default-directory "/"))
                      (and (file-exists-p file) (multihost-connection--hash-file file))))
                  '("multihost-worker.el" "multihost-compgen.el")) state)))

(defun multihost-connection--private-directory (directory)
  "Create local DIRECTORY without following a final symbolic link."
  (setq directory (multihost-connection--local-path directory "Worker state"))
  (when (file-remote-p directory) (user-error "Worker state must be local"))
  (let ((default-directory "/"))
    (when (file-symlink-p (directory-file-name directory))
      (user-error "Worker state must not be a symbolic link"))
    (make-directory directory t)
    (set-file-modes directory #o700))
  directory)

(defun multihost-connection--schedule ()
  "Schedule dispatch without reentering callbacks or process sentinels."
  (unless (timerp multihost-connection--pump-timer)
    (setq multihost-connection--pump-timer (run-at-time 0 nil #'multihost-connection--pump))))

(cl-defun multihost-connection-submit (directory operation payload callback &key (timeout 60))
  "Queue OPERATION with inert PAYLOAD in remote DIRECTORY.
Return a `multihost-request'.  CALLBACK receives (REQUEST RESULT) exactly
once.  TIMEOUT includes queueing, authentication, and execution.  No failed
or interrupted operation is automatically replayed."
  (unless (and (integerp multihost-connection-limit) (> multihost-connection-limit 0))
    (user-error "Connection limit must be a positive integer"))
  (unless (and (numberp timeout) (> timeout 0)) (user-error "Timeout must be positive"))
  (unless (symbolp operation) (user-error "Operation must be a symbol"))
  (let* ((key (multihost-connection--key directory))
         ;; Encoding and decoding through JSON makes strings independent too.
         (snapshot (multihost-worker--decode-value
                    (json-parse-string
                     (json-encode (multihost-worker--encode-value payload))
                     :object-type 'hash-table :array-type 'list :null-object nil :false-object :false)))
         (request (make-multihost-request
                   :id (format "%s-%d" (emacs-pid) (cl-incf multihost-connection--counter))
                   :directory (substring-no-properties directory) :operation operation
                   :payload snapshot :callback callback :timeout timeout :key key
                   :init-file (nth 2 key) :submitted-at (float-time))))
    (setf (multihost-request-timer request)
          (run-at-time timeout nil #'multihost-connection--timeout request))
    (setq multihost-connection--queue (nconc multihost-connection--queue (list request)))
    (multihost-connection--schedule)
    request))

(defun multihost-connection--request-file (worker kind)
  "Return WORKER's file for protocol KIND."
  (expand-file-name (concat kind ".json") (multihost-connection-worker-storage worker)))

(defun multihost-connection--send (worker)
  "Send WORKER's assigned request after its startup handshake."
  (let ((request (multihost-connection-worker-request worker))
        (default-directory "/"))
    (when (and request (eq (multihost-request-status request) 'running))
      (multihost-worker--write-json
       (multihost-connection--request-file worker "request")
       `(("schema" . ,multihost-worker-protocol-version)
         ("id" . ,(multihost-request-id request))
         ("directory" . ,(multihost-request-directory request))
         ("operation" . ,(symbol-name (multihost-request-operation request)))
         ("payload" . ,(multihost-worker--encode-value (multihost-request-payload request)))))
      (setf (multihost-connection-worker-state worker) 'busy)
      (process-send-string
       (multihost-connection-worker-process worker)
       (concat (json-encode `(("request" . ,(multihost-connection--request-file worker "request"))
                              ("result" . ,(multihost-connection--request-file worker "result")))) "\n")))))

(defun multihost-connection--assign (worker request)
  "Reserve WORKER exclusively for REQUEST."
  (when (timerp (multihost-connection-worker-idle-timer worker))
    (cancel-timer (multihost-connection-worker-idle-timer worker)))
  (setf (multihost-connection-worker-idle-timer worker) nil
        (multihost-connection-worker-request worker) request
        (multihost-request-worker request) worker
        (multihost-request-process request) (multihost-connection-worker-process worker)
        (multihost-request-status request) 'running
        (multihost-request-started-at request) (float-time))
  (unless (eq (multihost-connection-worker-state worker) 'starting)
    (multihost-connection--send worker)))

(defun multihost-connection--validate-configuration (request)
  "Ensure REQUEST still names the exact trusted init that was approved."
  (let* ((key (multihost-request-key request)) (init (nth 2 key)))
    (when (and init (not (equal (nth 3 key) (multihost-connection--hash-file init))))
      (user-error "Worker init changed while this request was queued; submit it again"))))

(defun multihost-connection--start-worker (request)
  "Start a fresh private worker and reserve it for REQUEST."
  (let* ((default-directory "/")
         (base (multihost-connection--private-directory (nth 5 (multihost-request-key request))))
         (pool (multihost-connection--private-directory (expand-file-name "connections" base)))
         (storage (make-temp-file (expand-file-name "worker-" pool) t))
         (worker (make-multihost-connection-worker
                  :id (file-name-nondirectory storage) :key (multihost-request-key request)
                  :directory (car (multihost-request-key request)) :storage storage
                  :started-at (float-time) :last-used (float-time)))
         (bootstrap (expand-file-name "bootstrap.json" storage))
         (default-directory storage))
    (set-file-modes storage #o700)
    (push worker multihost-connection--workers)
    (multihost-connection--assign worker request)
    (condition-case err
        (progn
          (multihost-worker--write-json
           bootstrap `(("schema" . ,multihost-worker-protocol-version)
                       ("id" . ,(multihost-connection-worker-id worker))
                       ("storage" . ,storage) ("init" . ,(multihost-request-init-file request))
                       ("init_sha256" . ,(nth 3 (multihost-request-key request)))))
          (let ((process
                 (make-process
                  :name (concat "multihost-" (multihost-connection-worker-id worker))
                  :buffer (generate-new-buffer " *multihost-connection-log*")
                  :connection-type 'pipe :coding 'utf-8-unix :noquery t
                  :command (list (nth 1 (multihost-request-key request)) "--quick" "--batch"
                                 "--eval" "(setq load-prefer-newer t)"
                                 "-L" multihost-connection--library-directory
                                 "-l" (expand-file-name "multihost-worker.el" multihost-connection--library-directory)
                                 "--funcall" "multihost-worker-daemon-main" bootstrap)
                  :filter (lambda (process output) (multihost-connection--filter worker process output))
                  :sentinel (lambda (process event) (multihost-connection--sentinel worker process event)))))
            (setf (multihost-connection-worker-process worker) process
                  (multihost-request-process request) process)))
      (error (multihost-connection--finish request
                                           (list :status 'failed :stdout "" :stderr "" :error (error-message-string err)) nil))))
  request)

(defun multihost-connection--pump ()
  "Dispatch queued requests subject to per-connection and global limits."
  (setq multihost-connection--pump-timer nil)
  (unless multihost-connection--pumping
    (let ((multihost-connection--pumping t)
          (pending multihost-connection--queue) remaining)
      (setq multihost-connection--queue nil)
      (dolist (request pending)
        (when (eq (multihost-request-status request) 'queued)
          (let* ((key (multihost-request-key request))
                 (matching (cl-find key multihost-connection--workers
                                    :key #'multihost-connection-worker-key :test #'equal))
                 (idle (cl-find 'idle multihost-connection--workers
                                :key #'multihost-connection-worker-state)))
            (condition-case err
                (progn
                  (multihost-connection--validate-configuration request)
                  (cond
                 ((and matching (eq (multihost-connection-worker-state matching) 'idle))
                  (multihost-connection--assign matching request))
                 (matching (push request remaining))
                 (t
                  (when (and (>= (length multihost-connection--workers) multihost-connection-limit) idle)
                    (multihost-connection--retire
                     (car (sort (cl-remove-if-not
                                 (lambda (worker) (eq (multihost-connection-worker-state worker) 'idle))
                                 (copy-sequence multihost-connection--workers))
                                (lambda (a b) (< (multihost-connection-worker-last-used a)
                                                 (multihost-connection-worker-last-used b)))))))
                  (if (< (length multihost-connection--workers) multihost-connection-limit)
                      (multihost-connection--start-worker request)
                    (push request remaining)))))
              (error (multihost-connection--finish request
                                                   (list :status 'failed :stdout "" :stderr "" :error (error-message-string err)) nil))))))
      (setq multihost-connection--queue (nconc (nreverse remaining) multihost-connection--queue)))))

(defun multihost-connection--filter (worker process output)
  "Parse bounded RPC notifications and retain bounded diagnostics."
  (unless (eq (multihost-connection-worker-state worker) 'dead)
    (let* ((all (concat (multihost-connection-worker-pending worker) output))
           (lines (split-string all "\n")))
      (setf (multihost-connection-worker-pending worker) (car (last lines)))
      (when (> (length (multihost-connection-worker-pending worker)) 65536)
        (setf (multihost-connection-worker-pending worker) "")
        (multihost-connection--broken worker "Worker protocol line exceeds limit"))
      (dolist (line (butlast lines))
        (when (> (length line) 65536)
          (multihost-connection--broken worker "Worker protocol line exceeds limit"))
        (unless (eq (multihost-connection-worker-state worker) 'dead)
          (if (string-prefix-p "MULTIHOST-RPC/1 " line)
            (condition-case err
                (multihost-connection--message
                 worker (json-parse-string (substring line 16) :object-type 'hash-table
                                            :array-type 'list :null-object nil :false-object :false))
              (error (multihost-connection--broken worker (error-message-string err))))
          (when (buffer-live-p (process-buffer process))
            (with-current-buffer (process-buffer process)
              (goto-char (point-max)) (insert line "\n")
              (when (> (buffer-size) 65536) (delete-region (point-min) (- (point-max) 65536)))))))))))

(defun multihost-connection--message (worker message)
  "Accept one validated MESSAGE from WORKER."
  (unless (equal (gethash "worker" message) (multihost-connection-worker-id worker))
    (error "Worker identity mismatch"))
  (pcase (gethash "kind" message)
    ("ready"
     (unless (eq (multihost-connection-worker-state worker) 'starting) (error "Unexpected ready message"))
     (multihost-connection--send worker))
    ("result"
     (let* ((default-directory "/")
            (request (multihost-connection-worker-request worker))
            (response (multihost-worker--read-json (multihost-connection--request-file worker "result")))
            (result (multihost-worker--decode-value (gethash "result" response))))
       (unless (and request (equal (gethash "id" message) (multihost-request-id request))
                    (equal (gethash "id" response) (multihost-request-id request))
                    (eql (gethash "schema" response) multihost-worker-protocol-version)
                    (memq (plist-get result :status) '(succeeded failed)))
         (error "Invalid worker result protocol"))
       (multihost-connection--finish request result (plist-get result :reusable))))
    (_ (error "Unknown worker notification"))))

(defun multihost-connection--broken (worker reason)
  "Fail WORKER's active request with REASON without replay."
  (if-let ((request (multihost-connection-worker-request worker)))
      (multihost-connection--finish request (list :status 'failed :stdout "" :stderr "" :error reason) nil)
    (multihost-connection--retire worker)))

(defun multihost-connection--sentinel (worker process _event)
  "Handle unexpected PROCESS termination in WORKER."
  (when (and (not (eq (multihost-connection-worker-state worker) 'dead))
             (memq (process-status process) '(exit signal failed)))
    (let ((diagnostics (when (buffer-live-p (process-buffer process))
                         (with-current-buffer (process-buffer process) (buffer-string)))))
      (multihost-connection--broken
       worker (format "Worker exited %s: %s" (process-exit-status process) (or diagnostics ""))))))

(defun multihost-connection--cleanup (function)
  "Attempt one local cleanup FUNCTION without preventing other cleanup steps."
  (let ((default-directory "/"))
    (condition-case err (progn (funcall function) t)
      ((error quit) (message "Multihost cleanup: %s" (error-message-string err)) nil))))

(defun multihost-connection--retire (worker)
  "Dispose of inactive WORKER and its private protocol files, best effort."
  (unless (eq (multihost-connection-worker-state worker) 'dead)
    (setf (multihost-connection-worker-state worker) 'dead)
    (setq multihost-connection--workers (delq worker multihost-connection--workers))
    (when (timerp (multihost-connection-worker-idle-timer worker))
      (cancel-timer (multihost-connection-worker-idle-timer worker)))
    (when-let ((process (multihost-connection-worker-process worker)))
      (multihost-connection--cleanup (lambda () (when (process-live-p process) (delete-process process))))
      (multihost-connection--cleanup
       (lambda () (when (buffer-live-p (process-buffer process)) (kill-buffer (process-buffer process))))))
    (multihost-connection--cleanup
     (lambda () (when (file-directory-p (multihost-connection-worker-storage worker))
                  (delete-directory (multihost-connection-worker-storage worker) t))))
    (multihost-connection--schedule)))

(defun multihost-connection--expire (worker)
  "Expire WORKER only while idle."
  (when (eq (multihost-connection-worker-state worker) 'idle)
    (multihost-connection--retire worker)))

(defun multihost-connection--finish (request result reusable)
  "Finalize REQUEST exactly once with RESULT, optionally retaining its worker."
  (unless (memq (multihost-request-status request) multihost-connection--terminal)
    (setf (multihost-request-status request) (plist-get result :status)
          (multihost-request-result request) result
          (multihost-request-ended-at request) (float-time))
    (when (timerp (multihost-request-timer request)) (cancel-timer (multihost-request-timer request)))
    (setf (multihost-request-timer request) nil)
    (setq multihost-connection--queue (delq request multihost-connection--queue))
    (unwind-protect
        (when-let ((worker (multihost-request-worker request)))
          (setf (multihost-connection-worker-request worker) nil)
          (dolist (kind '("request" "result"))
            (unless (multihost-connection--cleanup
                     (lambda () (let ((file (multihost-connection--request-file worker kind)))
                                  (when (file-exists-p file) (delete-file file)))))
              (setq reusable nil)))
          (if (and reusable (process-live-p (multihost-connection-worker-process worker)))
              (progn
                (setf (multihost-connection-worker-state worker) 'idle
                      (multihost-connection-worker-last-used worker) (float-time))
                (cl-incf (multihost-connection-worker-completed worker))
                (setf (multihost-connection-worker-idle-timer worker)
                      (run-at-time multihost-connection-idle-timeout nil #'multihost-connection--expire worker)))
            (multihost-connection--retire worker)))
      ;; File-system errors must never strand the engine waiting for a callback.
      (when (multihost-request-callback request)
        (condition-case err (funcall (multihost-request-callback request) request result)
          ((error quit) (message "Multihost request callback: %s" (error-message-string err)))))
      (multihost-connection--schedule))))

(defun multihost-connection--timeout (request)
  "Expire REQUEST and invalidate an active worker without replay."
  (multihost-connection--finish request
                               '(:status timed-out :stdout "" :stderr "" :error "Request deadline exceeded; remote termination is not guaranteed") nil))

(defun multihost-connection-cancel (request)
  "Cancel REQUEST exactly once; active workers are discarded."
  (multihost-connection--finish request
                               '(:status cancelled :stdout "" :stderr "" :error "Cancelled locally; remote termination is not guaranteed") nil))

(defun multihost-connection-reset (&optional directory)
  "Cancel pending and active requests and retire workers for DIRECTORY.
When DIRECTORY is nil, reset the entire pool.  No request is replayed."
  (let ((prefix (and directory (multihost-connection--prefix directory))))
    (dolist (request (copy-sequence multihost-connection--queue))
      (when (or (null prefix) (equal prefix (car (multihost-request-key request))))
        (multihost-connection-cancel request)))
    (dolist (worker (copy-sequence multihost-connection--workers))
      (when (or (null prefix) (equal prefix (car (multihost-connection-worker-key worker))))
        (if (multihost-connection-worker-request worker)
            (multihost-connection-cancel (multihost-connection-worker-request worker))
          (multihost-connection--retire worker))))))

(cl-defun multihost-connection-warmup (directory callback &key (timeout 60))
  "Initialize DIRECTORY's background TRAMP connection, reporting to CALLBACK."
  (multihost-connection-submit directory 'warmup nil callback :timeout timeout))

(defun multihost-connection-snapshots ()
  "Return safe metadata snapshots, without payloads or credentials."
  (mapcar
   (lambda (worker)
     (list :key (secure-hash 'sha256 (prin1-to-string (multihost-connection-worker-key worker)))
           :directory (multihost-connection-worker-directory worker)
           :state (multihost-connection-worker-state worker)
           :pid (when (multihost-connection-worker-process worker)
                  (process-id (multihost-connection-worker-process worker)))
           :queued (cl-count (multihost-connection-worker-key worker) multihost-connection--queue
                             :key #'multihost-request-key :test #'equal)
           :completed (multihost-connection-worker-completed worker)
           :started-at (multihost-connection-worker-started-at worker)
           :last-used (multihost-connection-worker-last-used worker)))
   multihost-connection--workers))

(add-hook 'kill-emacs-hook #'multihost-connection-reset)
(provide 'multihost-connection)
;;; multihost-connection.el ends here
