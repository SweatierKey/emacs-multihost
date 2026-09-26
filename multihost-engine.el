;;; multihost-engine.el --- Bounded asynchronous fleet execution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/SweatierKey/emacs-multihost

;;; Commentary:
;; Each host gets an isolated batch Emacs using the ordinary Babel backend.
;; The parent schedules jobs and remains responsive during remote execution.
;; Cancellation stops observation and the worker; it cannot guarantee that
;; remote processes have stopped after a broken SSH connection.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'multihost-inventory)
(require 'multihost-worker)

(defgroup multihost nil "Organized remote administration with Org." :group 'tools)
(defcustom multihost-state-directory (expand-file-name "multihost" user-emacs-directory)
  "Private directory for run metadata and results."
  :type 'directory :group 'multihost)
(defcustom multihost-worker-init-file nil
  "Optional trusted Lisp file loaded by each isolated worker.
Use this explicitly for TRAMP or authentication configuration.  Workers
never load the ordinary Emacs init file automatically."
  :type '(choice (const nil) file) :group 'multihost)
(defcustom multihost-worker-program
  (expand-file-name invocation-name invocation-directory)
  "Emacs executable used for isolated workers."
  :type 'file :group 'multihost)
(defconst multihost-engine--library-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))
(defconst multihost-engine--terminal-states
  '(succeeded failed timed-out cancelled skipped))
(defvar multihost-runs nil "Runs in this Emacs session, newest first.")

(cl-defstruct multihost-job
  id index host directory (status 'queued) started-at ended-at exit-code
  (stdout "") (stderr "") value error process timer)
(cl-defstruct multihost-run
  id jobs queue concurrency timeout fail-fast cancelled directory spec callback
  started-at ended-at (state 'ready))

(defun multihost-engine--private-directory (directory)
  "Create DIRECTORY and restrict its permissions."
  (setq directory (expand-file-name directory))
  (when (file-remote-p directory) (user-error "Multihost state must use a local directory"))
  (when (file-symlink-p (directory-file-name directory))
    (user-error "Multihost state directories must not be symbolic links: %s" directory))
  (make-directory directory t)
  (set-file-modes directory #o700)
  directory)

(defun multihost-engine--snapshot (value &optional depth)
  "Copy inert VALUE deeply, including mutable strings, with bounded DEPTH."
  (let ((depth (or depth 0)))
    (when (> depth 100) (user-error "Execution specification is nested too deeply"))
    (cond ((stringp value) (substring-no-properties value))
          ((and (consp value) (proper-list-p value))
           (mapcar (lambda (item) (multihost-engine--snapshot item (1+ depth))) value))
          ((consp value) (cons (multihost-engine--snapshot (car value) (1+ depth))
                               (multihost-engine--snapshot (cdr value) (1+ depth))))
          ((vectorp value) (vconcat (mapcar (lambda (item)
                                             (multihost-engine--snapshot item (1+ depth))) value)))
          ((or (null value) (symbolp value) (numberp value)) value)
          (t (user-error "Execution specifications must contain inert data")))))

(defun multihost-run-finished-p (run)
  "Return non-nil when every job in RUN has reached a terminal state."
  (cl-every (lambda (job) (memq (multihost-job-status job)
                              multihost-engine--terminal-states))
            (multihost-run-jobs run)))

(defun multihost-engine--notify (run job)
  "Notify the observer of RUN about JOB without breaking scheduling."
  (when (multihost-run-callback run)
    (condition-case err
        (funcall (multihost-run-callback run) run job)
      (error (message "Multihost observer error: %s" (error-message-string err))))))

(defun multihost-engine--job-record (job)
  "Return persistent data for JOB, excluding runtime objects."
  `(("id" . ,(multihost-job-id job))
    ("index" . ,(multihost-job-index job))
    ("host" . (("name" . ,(multihost-host-name (multihost-job-host job)))
                ("connection" . ,(multihost-host-connection (multihost-job-host job)))
                ("groups" . ,(vconcat (multihost-host-groups (multihost-job-host job))))
                ("description" . ,(multihost-host-description (multihost-job-host job)))))
    ("directory" . ,(multihost-job-directory job))
    ("status" . ,(symbol-name (multihost-job-status job)))
    ("started_at" . ,(multihost-job-started-at job))
    ("ended_at" . ,(multihost-job-ended-at job))
    ("exit_code" . ,(multihost-job-exit-code job))
    ("stdout" . ,(multihost-job-stdout job))
    ("stderr" . ,(multihost-job-stderr job))
    ("value" . ,(multihost-worker--encode-value (multihost-job-value job)))
    ("error" . ,(multihost-job-error job))))

(defun multihost-save-run (run)
  "Persist RUN atomically with private permissions.
The audit stores a body hash, never source code or resolved parameters.
Output may itself contain sensitive data and is stored only locally."
  (let* ((spec (multihost-run-spec run))
         (body (plist-get spec :body)))
    (multihost-worker--write-json
     (expand-file-name "run.json" (multihost-run-directory run))
     `(("schema" . 1) ("id" . ,(multihost-run-id run))
       ("state" . ,(symbol-name (multihost-run-state run)))
       ("started_at" . ,(multihost-run-started-at run))
       ("ended_at" . ,(multihost-run-ended-at run))
       ("concurrency" . ,(multihost-run-concurrency run))
       ("timeout" . ,(multihost-run-timeout run))
       ("fail_fast" . ,(if (multihost-run-fail-fast run) t :false))
       ("spec" . (("language" . ,(plist-get spec :language))
                   ("execution" . ,(plist-get spec :execution))
                   ("source" . ,(plist-get spec :source))
                   ("directory" . ,(plist-get spec :directory))
                   ("body_sha256" . ,(if body (secure-hash 'sha256 body)
                                       (plist-get spec :body-sha256)))))
       ("jobs" . ,(vconcat (mapcar #'multihost-engine--job-record
                                   (multihost-run-jobs run))))))))

(cl-defun multihost-create-run (spec hosts &key (concurrency 4) (timeout 60)
                                    fail-fast callback)
  "Create and persist a RUN for SPEC and ordered HOSTS, without execution.
CONCURRENCY is a positive integer.  TIMEOUT is seconds per host, including
connection setup.  FAIL-FAST skips queued hosts after the first failure.
CALLBACK is called with the run and the changed job, or nil."
  (multihost-worker-validate-spec spec)
  (unless (and (integerp concurrency) (> concurrency 0))
    (user-error "Concurrency must be a positive integer"))
  (unless (and (numberp timeout) (> timeout 0))
    (user-error "Timeout must be a positive number of seconds"))
  (unless (and (listp hosts) hosts (cl-every #'multihost-host-p hosts))
    (user-error "Select at least one valid host"))
  (when (and multihost-worker-init-file
             (file-remote-p (expand-file-name multihost-worker-init-file)))
    (user-error "Worker init must be an explicitly trusted local file"))
  (when (and multihost-worker-init-file
             (not (file-readable-p multihost-worker-init-file)))
    (user-error "Worker init file is not readable"))
  ;; Resolve all directories before creating state or starting any worker.
  (let* ((spec (multihost-engine--snapshot spec))
         (hosts (mapcar #'multihost-inventory--copy-host hosts))
         (directories (mapcar (lambda (host)
                                (multihost-host-directory host (plist-get spec :directory)))
                              hosts))
         (_state (multihost-engine--private-directory multihost-state-directory))
         (base (multihost-engine--private-directory
                (expand-file-name "runs" multihost-state-directory)))
         (directory (make-temp-file
                     (expand-file-name (format-time-string "%Y%m%dT%H%M%S-") base) t))
         (id (file-name-nondirectory directory))
         (jobs (cl-loop for host in hosts for remote in directories for index from 0
                        collect (make-multihost-job
                                 :id (format "%s-%04d" id index) :index index
                                 :host host :directory remote)))
         (run (make-multihost-run
               :id id :jobs jobs :queue (copy-sequence jobs)
               :concurrency concurrency :timeout timeout :fail-fast fail-fast
               :directory directory :spec spec :callback callback
               :started-at (float-time))))
    (set-file-modes directory #o700)
    (multihost-save-run run)
    (push run multihost-runs)
    run))

(cl-defun multihost-start (spec hosts &key (concurrency 4) (timeout 60)
                               fail-fast callback)
  "Start SPEC on ordered HOSTS and immediately return the run.
See `multihost-create-run' for CONCURRENCY, TIMEOUT, FAIL-FAST and CALLBACK."
  (let ((run (multihost-create-run spec hosts :concurrency concurrency :timeout timeout
                                   :fail-fast fail-fast :callback callback)))
    (setf (multihost-run-state run) 'running)
    ;; A zero-delay timer lets callers install their UI before notifications.
    (run-at-time 0 nil #'multihost-engine--pump run)
    run))

(defun multihost-engine--job-file (run job extension)
  "Return a private file in RUN for JOB and EXTENSION."
  (expand-file-name (format "%04d.%s" (multihost-job-index job) extension)
                    (multihost-run-directory run)))

(defun multihost-engine--diagnostic-filter (process output)
  "Keep only the last 64 KiB of worker PROCESS diagnostic OUTPUT."
  (when-let* ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert output)
          (when (> (buffer-size) 65536)
            (delete-region (point-min) (- (point-max) 65536))))))))

(defun multihost-engine--launch (run job)
  "Launch the isolated worker for JOB in RUN."
  (let* ((request (multihost-engine--job-file run job "request.json"))
         (result (multihost-engine--job-file run job "result.json"))
         (buffer (generate-new-buffer (format " *multihost-worker-%s*" (multihost-job-id job))))
         (default-directory (multihost-run-directory run)))
    (setf (multihost-job-status job) 'running
          (multihost-job-started-at job) (float-time))
    (condition-case err
        (progn
          (multihost-worker--write-json
           request `(("schema" . ,multihost-worker-protocol-version)
                     ("id" . ,(multihost-job-id job))
                     ("directory" . ,(multihost-job-directory job))
                     ("init" . ,(and multihost-worker-init-file
                                      (expand-file-name multihost-worker-init-file)))
                     ("spec" . ,(multihost-worker--encode-value (multihost-run-spec run)))))
          (let ((process
                 (make-process
                  :name (format "multihost-%s" (multihost-job-id job))
                  :buffer buffer :noquery t :connection-type 'pipe
                  :coding 'utf-8-unix
                  :command (list multihost-worker-program "--quick" "--batch"
                                 "-L" multihost-engine--library-directory
                                 "-l" (expand-file-name "multihost-worker.el"
                                                        multihost-engine--library-directory)
                                 "--funcall" "multihost-worker-main" request result)
                  :filter #'multihost-engine--diagnostic-filter
                  :sentinel (lambda (process event)
                              (multihost-engine--sentinel run job process event)))))
            (setf (multihost-job-process job) process
                  (multihost-job-timer job)
                  (run-at-time (multihost-run-timeout run) nil
                               #'multihost-engine--timeout run job))))
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (multihost-engine--finish run job 'failed :error (error-message-string err))))
    (multihost-engine--notify run job)))

(defun multihost-engine--pump (run)
  "Fill available execution slots in RUN."
  (unless (multihost-run-cancelled run)
    (let ((running (cl-count 'running (multihost-run-jobs run)
                             :key #'multihost-job-status)))
      (while (and (multihost-run-queue run)
                  (< running (multihost-run-concurrency run)))
        (let ((job (pop (multihost-run-queue run))))
          (when (eq (multihost-job-status job) 'queued)
            (multihost-engine--launch run job)
            (when (eq (multihost-job-status job) 'running) (cl-incf running)))))))
  (when (multihost-run-finished-p run)
    (unless (multihost-run-ended-at run)
      (setf (multihost-run-ended-at run) (float-time)
            (multihost-run-state run) (if (multihost-run-cancelled run) 'cancelled 'finished))
      (multihost-engine--notify run nil)))
  (multihost-save-run run))

(defun multihost-engine--diagnostics (job)
  "Return the bounded diagnostic log for JOB."
  (let* ((process (multihost-job-process job))
         (buffer (and process (process-buffer process))))
    (if (buffer-live-p buffer) (with-current-buffer buffer (buffer-string)) "")))

(defun multihost-engine--sentinel (run job process _event)
  "Collect worker PROCESS completion for JOB in RUN."
  (when (and (memq (process-status process) '(exit signal failed))
             (eq (multihost-job-status job) 'running))
    (condition-case err
        (progn
          (unless (and (eq (process-status process) 'exit)
                       (zerop (process-exit-status process)))
            (error "Worker exited %s: %s" (process-exit-status process)
                   (string-trim (multihost-engine--diagnostics job))))
          (let* ((file (multihost-engine--job-file run job "result.json"))
                 (response (multihost-worker--read-json file))
                 (result (multihost-worker--decode-value (gethash "result" response))))
            (unless (and (eql (gethash "schema" response) multihost-worker-protocol-version)
                         (equal (gethash "id" response) (multihost-job-id job))
                         (memq (plist-get result :status) '(succeeded failed))
                         (stringp (plist-get result :stdout))
                         (stringp (plist-get result :stderr))
                         (or (not (eq (plist-get result :status) 'succeeded))
                             (eql (plist-get result :exit-code) 0)))
              (error "Invalid worker response protocol"))
            (apply #'multihost-engine--finish run job (plist-get result :status)
                   (cl-loop for (key value) on result by #'cddr
                            unless (eq key :status) append (list key value)))))
      (error (multihost-engine--finish run job 'failed :error (error-message-string err))))))

(cl-defun multihost-engine--finish (run job status &key exit-code stdout stderr value error)
  "Finalize JOB in RUN exactly once with STATUS and its outcome fields."
  (unless (memq (multihost-job-status job) multihost-engine--terminal-states)
    ;; Mark terminal before stopping the process: its sentinel may reenter.
    (setf (multihost-job-status job) status
          (multihost-job-ended-at job) (float-time)
          (multihost-job-exit-code job) exit-code
          (multihost-job-stdout job) (or stdout "")
          (multihost-job-stderr job) (or stderr "")
          (multihost-job-value job) value
          (multihost-job-error job) error)
    (when (timerp (multihost-job-timer job)) (cancel-timer (multihost-job-timer job)))
    (setf (multihost-job-timer job) nil)
    (when-let* ((process (multihost-job-process job)))
      (when (process-live-p process) (delete-process process))
      (when-let* ((buffer (process-buffer process)))
        (when (buffer-live-p buffer)
          ;; Private diagnostics are deliberately bounded and never displayed
          ;; in the Org document automatically.
          (let ((file (multihost-engine--job-file run job "worker.log")))
            (let ((temporary (make-temp-file (concat file ".tmp-"))))
              (unwind-protect
                  (progn
                    (set-file-modes temporary #o600)
                    (with-current-buffer buffer
                      (write-region (point-min) (point-max) temporary nil 'silent))
                    (rename-file temporary file t))
                (when (file-exists-p temporary) (delete-file temporary)))))
          (kill-buffer buffer))))
    (dolist (extension '("request.json" "result.json"))
      (let ((file (multihost-engine--job-file run job extension)))
        (when (file-exists-p file) (delete-file file))))
    (when (and (multihost-run-fail-fast run) (memq status '(failed timed-out)))
      (dolist (pending (multihost-run-queue run))
        (when (eq (multihost-job-status pending) 'queued)
          (setf (multihost-job-status pending) 'skipped
                (multihost-job-ended-at pending) (float-time)
                (multihost-job-error pending) "Skipped by fail-fast after an earlier failure")
          (multihost-engine--notify run pending)))
      (setf (multihost-run-queue run) nil))
    (multihost-save-run run)
    (multihost-engine--notify run job)
    ;; Avoid recursively launching jobs from a sentinel or failed spawn.
    (run-at-time 0 nil #'multihost-engine--pump run)))

(defun multihost-engine--timeout (run job)
  "Expire JOB in RUN if it is still running."
  (when (eq (multihost-job-status job) 'running)
    (multihost-engine--finish
     run job 'timed-out
     :error (format "Host deadline exceeded (%s s); remote termination is not guaranteed"
                    (multihost-run-timeout run)))))

(defun multihost-cancel-job (run job)
  "Cancel JOB belonging to RUN; remote termination is not guaranteed."
  (unless (memq job (multihost-run-jobs run)) (user-error "Job does not belong to this run"))
  (multihost-engine--finish run job 'cancelled
                            :error "Cancelled locally; remote termination is not guaranteed"))

(defun multihost-cancel (run)
  "Cancel queued and active work in RUN; do not promise remote termination."
  (setf (multihost-run-cancelled run) t
        (multihost-run-queue run) nil)
  (dolist (job (multihost-run-jobs run)) (multihost-cancel-job run job))
  (multihost-engine--pump run)
  run)

(defun multihost-retry-failed (run)
  "Create a new run for failed, timed out, or cancelled hosts in RUN.
The original ordered inventory and in-memory block snapshot are reused.
This never retries successful hosts or silently reruns an archived body."
  (unless (plist-get (multihost-run-spec run) :body)
    (user-error "Archived runs contain no executable body; reopen the source runbook"))
  (let ((hosts (cl-loop for job in (multihost-run-jobs run)
                        when (memq (multihost-job-status job) '(failed timed-out cancelled))
                        collect (multihost-job-host job))))
    (unless hosts (user-error "No failed, timed out, or cancelled hosts to retry"))
    (multihost-start (multihost-run-spec run) hosts
                     :concurrency (multihost-run-concurrency run)
                     :timeout (multihost-run-timeout run)
                     :fail-fast (multihost-run-fail-fast run)
                     :callback (multihost-run-callback run))))

(defun multihost-load-run (directory)
  "Load the audit in DIRECTORY without evaluating saved code.
Unfinished jobs from an earlier Emacs session are reported as interrupted.
An archive deliberately contains no executable body for automatic retry."
  (setq directory (expand-file-name directory))
  (when (file-remote-p directory) (user-error "Run archives must be local"))
  (let* ((data (multihost-worker--read-json (expand-file-name "run.json" directory)))
         (_valid (multihost-engine--validate-audit data))
         (saved-spec (gethash "spec" data))
         (run (make-multihost-run
               :id (gethash "id" data) :directory directory
               :concurrency (gethash "concurrency" data) :timeout (gethash "timeout" data)
               :fail-fast (eq (gethash "fail_fast" data) t)
               :started-at (gethash "started_at" data) :ended-at (gethash "ended_at" data)
               :state (if (equal (gethash "state" data) "cancelled") 'cancelled 'finished)
               :cancelled (equal (gethash "state" data) "cancelled")
               :spec (list :language (gethash "language" saved-spec)
                           :execution (gethash "execution" saved-spec)
                           :source (gethash "source" saved-spec)
                           :directory (gethash "directory" saved-spec)
                           :body-sha256 (gethash "body_sha256" saved-spec)))))
    (unless (and (eql (gethash "schema" data) 1) (stringp (multihost-run-id run)))
      (error "Invalid multihost run archive"))
    (setf (multihost-run-jobs run)
          (mapcar
           (lambda (record)
             (let* ((host (gethash "host" record))
                    (status (intern (gethash "status" record)))
                    (interrupted (not (memq status multihost-engine--terminal-states))))
               (make-multihost-job
                :id (gethash "id" record) :index (gethash "index" record)
                :host (make-multihost-host
                       :name (gethash "name" host) :connection (gethash "connection" host)
                       :groups (gethash "groups" host) :description (gethash "description" host))
                :directory (gethash "directory" record)
                :status (if interrupted 'failed status)
                :started-at (gethash "started_at" record) :ended-at (gethash "ended_at" record)
                :exit-code (gethash "exit_code" record)
                :stdout (or (gethash "stdout" record) "") :stderr (or (gethash "stderr" record) "")
                :value (multihost-worker--decode-value (gethash "value" record))
                :error (if interrupted "Interrupted: the earlier Emacs session did not record completion"
                         (gethash "error" record)))))
           (gethash "jobs" data)))
    (cl-pushnew run multihost-runs :key #'multihost-run-id :test #'equal)
    run))

(defun multihost-engine--validate-audit (data)
  "Validate decoded audit DATA before constructing any displayable objects."
  (unless (hash-table-p data) (error "Run archive must be a JSON object"))
  (let ((id (gethash "id" data))
        (spec (gethash "spec" data))
        (jobs (gethash "jobs" data))
        ids indexes)
    (unless (and (eql (gethash "schema" data) 1)
                 (stringp id) (string-match-p "\\`[A-Za-z0-9_-]+\\'" id)
                 (<= (length id) 128)
                 (numberp (gethash "started_at" data))
                 (or (null (gethash "ended_at" data)) (numberp (gethash "ended_at" data)))
                 (integerp (gethash "concurrency" data)) (> (gethash "concurrency" data) 0)
                 (numberp (gethash "timeout" data)) (> (gethash "timeout" data) 0)
                 (member (gethash "state" data) '("ready" "running" "finished" "cancelled" "succeeded" "failed"))
                 (hash-table-p spec)
                 (member (gethash "language" spec) multihost-worker-supported-languages)
                 (member (gethash "execution" spec) '(nil "background" "foreground"))
                 (listp jobs) jobs)
      (error "Invalid multihost run metadata"))
    (dolist (job jobs)
      (unless (hash-table-p job) (error "Invalid archived job"))
      (let ((host (gethash "host" job))
            (index (gethash "index" job))
            (job-id (gethash "id" job))
            (status (gethash "status" job))
            (code (gethash "exit_code" job)))
        (unless (and (integerp index) (>= index 0)
                     (equal job-id (format "%s-%04d" id index))
                     (not (member job-id ids)) (not (member index indexes))
                     (member status '("queued" "running" "succeeded" "failed" "timed-out" "cancelled" "skipped"))
                     (or (null code) (integerp code) (stringp code))
                     (or (not (equal status "succeeded")) (eql code 0))
                     (or (null (gethash "started_at" job)) (numberp (gethash "started_at" job)))
                     (or (null (gethash "ended_at" job)) (numberp (gethash "ended_at" job)))
                     (stringp (gethash "stdout" job)) (stringp (gethash "stderr" job))
                     (or (null (gethash "error" job)) (stringp (gethash "error" job)))
                     (hash-table-p host)
                     (or (multihost-inventory--name-p (gethash "name" host))
                         ;; Without an inventory, an explicit TRAMP selector
                         ;; is also its display name.  Validate the connection
                         ;; below and allow only that exact spelling here.
                         (and (stringp (gethash "name" host))
                              (equal (gethash "name" host) (gethash "connection" host))
                              (file-remote-p (gethash "connection" host))))
                     (listp (gethash "groups" host))
                     (cl-every #'multihost-inventory--name-p (gethash "groups" host))
                     (or (null (gethash "description" host)) (stringp (gethash "description" host))))
          (error "Invalid multihost job metadata"))
        (multihost-inventory--remote (gethash "connection" host))
        (unless (and (stringp (gethash "directory" job)) (file-remote-p (gethash "directory" job)))
          (error "Archived job directory must be remote"))
        (multihost-inventory--remote (gethash "directory" job))
        (push job-id ids)
        (push index indexes))))
  t)

(provide 'multihost-engine)
;;; multihost-engine.el ends here
