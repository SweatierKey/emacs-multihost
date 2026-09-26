;;; multihost-worker.el --- Isolated Org Babel execution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/SweatierKey/emacs-multihost

;;; Commentary:
;; A worker runs one already-expanded Babel block.  JSON transports data,
;; never executable Lisp.  Only explicitly supported non-session backends
;; are accepted; an ordinary successful Lisp return is not an exit status.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'ob-core)
(require 'ob-eval)
(require 'subr-x)
(require 'multihost-inventory)

(defconst multihost-worker-protocol-version 1)
(defconst multihost-worker-supported-languages '("sh" "bash" "shell" "python"))
(defvar multihost-worker--captures nil)
(defvar multihost-worker--allow-local-execution nil
  "Internal test binding; production entry points require a remote directory.")

(defun multihost-worker--encode-value (value &optional depth)
  "Encode inert Lisp VALUE as JSON-compatible data, preserving its type."
  (let ((depth (or depth 0)))
    (when (> depth 100) (error "Worker data nesting limit exceeded"))
    (cond ((or (null value) (eq value t) (stringp value) (numberp value)) value)
          ((symbolp value) `(("type" . "symbol") ("name" . ,(symbol-name value))))
          ((and (consp value) (proper-list-p value))
           `(("type" . "list")
             ("items" . ,(vconcat
                           (mapcar (lambda (item) (multihost-worker--encode-value item (1+ depth)))
                                   value)))))
          ((consp value)
           `(("type" . "cons")
             ("car" . ,(multihost-worker--encode-value (car value) (1+ depth)))
             ("cdr" . ,(multihost-worker--encode-value (cdr value) (1+ depth)))))
          ((vectorp value)
           `(("type" . "vector")
             ("items" . ,(vconcat
                           (mapcar (lambda (item) (multihost-worker--encode-value item (1+ depth)))
                                   value)))))
          (t (error "Cannot transport value of type %s" (type-of value))))))

(defun multihost-worker--decode-value (value &optional depth)
  "Decode inert JSON VALUE, limiting nesting to DEPTH."
  (let ((depth (or depth 0)))
    (when (> depth 100) (error "Worker data nesting limit exceeded"))
    (cond
     ((or (null value) (eq value t) (stringp value) (numberp value)) value)
     ((hash-table-p value)
      (pcase (gethash "type" value)
        ("symbol"
         (let ((name (gethash "name" value)))
           (unless (and (stringp name) (< (length name) 1024))
             (error "Invalid symbol data"))
           (intern name)))
        ("cons"
         (cons (multihost-worker--decode-value (gethash "car" value) (1+ depth))
               (multihost-worker--decode-value (gethash "cdr" value) (1+ depth))))
        ("list"
         (mapcar (lambda (item) (multihost-worker--decode-value item (1+ depth)))
                 (gethash "items" value)))
        ("vector"
         (vconcat (mapcar (lambda (item)
                           (multihost-worker--decode-value item (1+ depth)))
                         (gethash "items" value))))
        (_ (error "Invalid worker value tag"))))
     (t (error "Invalid worker value")))))

(defun multihost-worker--write-json (file object)
  "Atomically write JSON OBJECT to private FILE."
  (let ((temporary (make-temp-file (concat file ".tmp-"))))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (with-temp-file temporary
            (set-buffer-file-coding-system 'utf-8-unix)
            (let ((json-null nil) (json-false :false))
              (insert (json-encode object))))
          (rename-file temporary file t)
          (set-file-modes file #o600))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun multihost-worker--read-json (file)
  "Read JSON FILE without evaluating Lisp or visiting file variables."
  (when (> (file-attribute-size (file-attributes file)) (* 64 1024 1024))
    (error "Worker protocol file exceeds 64 MiB"))
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (prog1 (json-parse-buffer :object-type 'hash-table :array-type 'list
                              :null-object nil :false-object :false)
      (skip-chars-forward " \t\r\n")
      (unless (eobp) (error "Trailing data after worker JSON")))))

(defun multihost-worker-validate-spec (spec)
  "Validate execution SPEC before starting any host."
  (let* ((language (plist-get spec :language))
         (params (plist-get spec :params))
         (results (cdr (assq :results params))))
    (unless (member language multihost-worker-supported-languages)
      (user-error "Supported languages: %s" (string-join multihost-worker-supported-languages ", ")))
    (unless (stringp (plist-get spec :body)) (user-error "Block body must be a string"))
    (unless (and (listp params) (cl-every #'consp params))
      (user-error "Block parameters must be an Org Babel alist"))
    (unless (or (null results) (stringp results))
      (user-error "The :results header must be a literal string"))
    (dolist (entry params)
      (unless (keywordp (car entry)) (user-error "Invalid parameter key"))
      (when (and (eq (car entry) :var) (not (consp (cdr entry))))
        (user-error "Resolve Babel variables before scheduling execution")))
    (dolist (key '(:file :post :stdin :cmdline))
      (when (cdr (assq key params))
        (user-error "%s is not supported for isolated multihost execution" key)))
    (dolist (key '(:cache :async))
      (unless (member (cdr (assq key params)) '(nil "no" "nil"))
        (user-error "%s must be no for multihost execution" key)))
    (unless (member (cdr (assq :session params)) '(nil "none"))
      (user-error "Multihost requires :session none"))
    (when (member (cdr (assq :eval params)) '("no" "never"))
      (user-error "This block disables evaluation with :eval"))
    (when (and (member language '("sh" "bash" "shell"))
               (or (eq (cdr (assq :result-type params)) 'value)
                   (member "value" (cdr (assq :result-params params)))
                   (and results (member "value" (split-string results)))))
      (user-error "Shell blocks require :results output for reliable exit status"))
    t))

(defun multihost-worker--capture-eval (original command error-buffer)
  "Call ORIGINAL with COMMAND and ERROR-BUFFER, recording the real result."
  (let (status)
    (unwind-protect
        (setq status (funcall original command error-buffer))
      ;; Before process-file runs, this buffer still contains the input
      ;; script.  A connection failure must never publish that as output.
      (push (list :exit-code status :stdout (if status (buffer-string) "")
                  :stderr (if (and status (get-buffer error-buffer))
                              (with-current-buffer error-buffer (buffer-string))
                            ""))
            multihost-worker--captures))
    status))

(defun multihost-execute-spec (spec directory)
  "Synchronously execute resolved SPEC in DIRECTORY using standard Babel.
Return a plist with :status, :exit-code, :stdout, :stderr, :value and :error.
This function supports interactive TRAMP authentication in the calling
Emacs; workers call the same function in a separate batch Emacs.  It does
not insert results, evaluate header Lisp, or expand document references."
  (multihost-worker-validate-spec spec)
  (unless (and (stringp directory)
               (or multihost-worker--allow-local-execution (file-remote-p directory)))
    (user-error "Multihost execution requires an explicit TRAMP remote directory"))
  (unless multihost-worker--allow-local-execution
    (multihost-inventory--remote directory))
  (let* ((language (plist-get spec :language))
         (params (copy-tree (plist-get spec :params)))
         (default-directory (file-name-as-directory directory))
         (multihost-worker--captures nil)
         value error-message exit-code)
    (require (if (equal language "python") 'ob-python 'ob-shell))
    (when (and (equal language "python") (not (assq :python params)))
      (push '(:python . "python3") params))
    (unless (assq :results params)
      (push '(:results . "output") params))
    (setq params (org-babel-process-params params))
    (setf (alist-get :dir params) directory
          (alist-get :session params) "none"
          (alist-get :noweb params) "no")
    (unwind-protect
        (progn
          (advice-add 'org-babel--shell-command-on-region :around
                      #'multihost-worker--capture-eval)
          (condition-case err
              (with-temp-buffer
                (org-mode)
                (setq value (funcall (intern (concat "org-babel-execute:" language))
                                     (plist-get spec :body) params)))
            (error (setq error-message (error-message-string err)))))
      (advice-remove 'org-babel--shell-command-on-region #'multihost-worker--capture-eval))
    (setq multihost-worker--captures (nreverse multihost-worker--captures))
    (let ((failed-capture
           (cl-find-if (lambda (capture)
                         (let ((code (plist-get capture :exit-code)))
                           (not (and (integerp code) (zerop code)))))
                       multihost-worker--captures)))
      (setq exit-code
            (if failed-capture (plist-get failed-capture :exit-code)
              (and multihost-worker--captures
                   (plist-get (car (last multihost-worker--captures)) :exit-code)))))
    (unless (or error-message multihost-worker--captures)
      (setq error-message "Backend did not report a process exit status"))
    ;; TRAMP's synchronous process-file handler turns a keyboard quit into
    ;; -1.  Preserve the user's request to stop the whole foreground run.
    (when (eql exit-code -1) (signal 'quit nil))
    (list :status (if (and (not error-message) (integerp exit-code) (zerop exit-code))
                      'succeeded 'failed)
          :exit-code exit-code
          :stdout (mapconcat (lambda (capture) (plist-get capture :stdout))
                             multihost-worker--captures "")
          :stderr (mapconcat (lambda (capture) (plist-get capture :stderr))
                             multihost-worker--captures "")
          :value value :error error-message)))

(defun multihost-worker-main ()
  "Run one private JSON request from `command-line-args-left'."
  (let* ((request-file (pop command-line-args-left))
         (result-file (pop command-line-args-left))
         (request (multihost-worker--read-json request-file))
         (id (gethash "id" request))
         result)
    (unless (and (eql (gethash "schema" request) multihost-worker-protocol-version)
                 (stringp id))
      (error "Invalid worker request protocol"))
    (condition-case err
        (progn
          (when-let* ((init (gethash "init" request)))
            (load init nil 'nomessage 'nosuffix))
          (setq result
                (multihost-execute-spec
                 (multihost-worker--decode-value (gethash "spec" request))
                 (gethash "directory" request))))
      (error (setq result (list :status 'failed :exit-code nil :stdout "" :stderr ""
                               :value nil :error (error-message-string err)))))
    (multihost-worker--write-json
     result-file
     `(("schema" . ,multihost-worker-protocol-version)
       ("id" . ,id)
       ("result" . ,(multihost-worker--encode-value result))))))

(provide 'multihost-worker)
;;; multihost-worker.el ends here
