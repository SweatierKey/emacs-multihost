;;; ob-multihost.el --- Org runbooks for remote host groups -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Multihost contributors
;; Author: Multihost contributors
;; Version: 1.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Keywords: tools, processes, literate programming
;; URL: https://github.com/SweatierKey/emacs-multihost
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Enable `ob-multihost-mode', add :hosts to sh/bash/shell/python blocks, and
;; execute with C-c C-c.  M-x multihost-org-preview shows a plan without
;; connecting or evaluating header Lisp.  Explicit foreground execution
;; permits interactive TRAMP authentication, including policy-dependent MFA.

;;; Code:
(require 'org)
(require 'ob-core)
(require 'ob-shell)
(require 'ob-python)
(require 'multihost)

(declare-function multihost-completion-setup "multihost-completion" (context-function &optional enabled))
(declare-function multihost-completion-refresh "multihost-completion" ())
(declare-function multihost-completion-disable "multihost-completion" ())

(defvar-local ob-multihost--owners nil)
(defvar-local ob-multihost-last-run nil)
(defvar ob-multihost--inside nil)
(defvar ob-multihost--force-foreground nil)
(defvar-local ob-multihost-completion-enabled nil
  "Whether the operator enabled remote completion for this buffer.")
(defvar-local ob-multihost--completion-cache nil)
(defconst ob-multihost--headers
  '(:hosts :exclude :renderer :concurrency :timeout :fail-fast :execution))

(defun ob-multihost--number (params key default integerp)
  "Read positive PARAMS KEY, falling back to DEFAULT.
Require an integer when INTEGERP is non-nil; never evaluate header code."
  (let* ((raw (or (cdr (assq key params)) default))
         (value (cond ((numberp raw) raw)
                      ((and (stringp raw)
                            (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" raw))
                       (string-to-number raw)))))
    (unless (and value (> value 0) (or (not integerp) (integerp value)))
      (user-error "%s must be a positive %s" key (if integerp "integer" "number")))
    value))

(defun ob-multihost--boolean (params key)
  "Read a literal yes/no PARAMS KEY."
  (let ((value (cdr (assq key params))))
    (cond ((member value '(nil "no" "nil")) nil)
          ((member value '(t "yes" "t")) t)
          (t (user-error "%s must be yes or no" key)))))

(defun ob-multihost--fingerprint (info)
  "Return a digest of source INFO independent of its buffer position."
  (secure-hash 'sha256 (prin1-to-string (cl-subseq info 0 5))))

(defun ob-multihost--plan (&optional info)
  "Build a data-only, connection-free plan from unevaluated INFO."
  (setq info (or info (org-babel-get-src-block-info 'no-eval)))
  (unless info (user-error "Point is not in an Org source block"))
  (let* ((info info)
         (params (nth 2 info))
         (hostspec (cdr (assq :hosts params)))
         (renderer (or (cdr (assq :renderer params)) "digest"))
         (execution (if ob-multihost--force-foreground "foreground"
                      (or (cdr (assq :execution params)) "background")))
         (concurrency (ob-multihost--number params :concurrency multihost-default-concurrency t))
         (timeout (ob-multihost--number params :timeout multihost-default-timeout nil))
         (fail-fast (ob-multihost--boolean params :fail-fast))
         (directory (cdr (assq :dir params)))
         (hosts (multihost-select-hosts hostspec (multihost-current-inventory)
                                       (cdr (assq :exclude params)))))
    (unless (member renderer '("digest" "per-host" "table" "combined"))
      (user-error "Renderer must be digest, per-host, table or combined"))
    (unless (member execution '("background" "foreground"))
      (user-error ":execution must be background or foreground"))
    (when-let ((results (cdr (assq :results params))))
      (unless (and (stringp results)
                   (cl-every (lambda (word) (member word '("output" "value" "replace")))
                             (split-string results)))
        (user-error "Use :results output/value replace and :renderer for presentation")))
    (when (and (not ob-multihost--force-foreground)
               (equal execution "foreground") (assq :concurrency params)
               (/= concurrency 1))
      (user-error "Foreground execution is serial; use :concurrency 1"))
    (when (and (not ob-multihost--force-foreground)
               (equal execution "foreground") (assq :timeout params))
      (user-error "Foreground execution has no hard deadline; omit :timeout or use background"))
    (when (and directory (not (stringp directory)))
      (user-error ":dir must be a literal remote-local directory"))
    (dolist (host hosts) (multihost-host-directory host directory))
    ;; Validate non-expanding fields before any :var/noweb evaluation occurs.
    (multihost-worker-validate-spec
     (list :language (car info) :body (nth 1 info)
           :params (assq-delete-all :var (copy-tree params))))
    (list :info info :hosts hosts :renderer (intern renderer) :execution execution
          :concurrency (if (equal execution "foreground") 1 concurrency)
          :timeout timeout :fail-fast fail-fast :directory directory)))

;;;###autoload
(defun multihost-org-preview ()
  "Show targets and source without connecting or evaluating header Lisp."
  (interactive)
  (let* ((plan (ob-multihost--plan))
         (info (plist-get plan :info)))
    (with-help-window "*Multihost plan*"
      (princ (format "%s · %s · concurrency %d · %s\n\n"
                     (car info) (plist-get plan :execution) (plist-get plan :concurrency)
                     (if (equal (plist-get plan :execution) "foreground") "C-g interrupts"
                       (format "%.0fs deadline per host" (plist-get plan :timeout)))))
      (princ "Targets in dispatch order:\n")
      (dolist (host (plist-get plan :hosts))
        (princ (format "  %s  %s\n" (multihost-host-name host)
                       (multihost-host-directory host (plist-get plan :directory)))))
      (princ "\nSource (variables/noweb are expanded only after execution approval):\n\n")
      (princ (nth 1 info)))))

(defun ob-multihost--resolved-spec (plan)
  "Expand the authorized source described by PLAN exactly once."
  (let* ((original (plist-get plan :info))
         (info (org-babel-get-src-block-info))
         (params (copy-tree (nth 2 info)))
         (language (car info))
         (body (org-babel-expand-src-block nil (copy-tree info)))
         (owned (append ob-multihost--headers
                        '(:dir :var :noweb :prologue :epilogue :comments :no-expand))))
    ;; Data-only routing must not change when Org resolves unrelated variables.
    (dolist (key (append ob-multihost--headers '(:dir)))
      (unless (equal (cdr (assq key (nth 2 original))) (cdr (assq key params)))
        (user-error "Header %s changed during evaluation; use literal routing parameters" key)))
    (setq params (cl-remove-if (lambda (entry) (memq (car entry) owned)) params))
    (list :language language :body body :params params
          :directory (plist-get plan :directory)
          :execution (plist-get plan :execution)
          :source (or buffer-file-name (buffer-name)))))

(defun ob-multihost--notify (callback run job)
  "Notify CALLBACK about RUN/JOB without breaking execution on UI errors."
  (condition-case err (funcall callback run job)
    (error (message "Multihost display callback: %s" (error-message-string err)))))

(defun ob-multihost--claim (marker run)
  "Assign the block at MARKER to RUN; supersede older submissions."
  (setq ob-multihost--owners
        (cl-remove-if (lambda (entry)
                        (or (not (marker-buffer (car entry)))
                            (= (marker-position (car entry)) (marker-position marker))))
                      ob-multihost--owners))
  (push (cons marker (multihost-run-id run)) ob-multihost--owners))

(defun ob-multihost--insert-completed (run marker fingerprint renderer)
  "Insert completed RUN only if MARKER still names its unmodified source.
FINGERPRINT detects edits; RENDERER selects the result presentation."
  (when (buffer-live-p (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (when (equal (cdr (assoc marker ob-multihost--owners)) (multihost-run-id run))
        (save-excursion
          (goto-char marker)
          (let ((current (org-babel-get-src-block-info 'no-eval)))
            (if (and current (equal fingerprint (ob-multihost--fingerprint current)))
                (let ((ob-multihost--inside t))
                  (org-babel-insert-result (multihost-render-org run renderer)
                                          '("drawer" "replace") current))
              (message "Multihost: source changed; results retained in run %s"
                       (multihost-run-id run)))))))))

(defun ob-multihost--foreground (spec plan callback)
  "Execute SPEC and PLAN serially in the current Emacs, notifying CALLBACK."
  (let ((run (multihost-create-run spec (plist-get plan :hosts)
                                   :concurrency 1 :timeout (plist-get plan :timeout)
                                   :fail-fast (plist-get plan :fail-fast) :callback callback))
        failed interrupted)
    (setf (multihost-run-state run) 'running)
    (condition-case nil
        (dolist (job (multihost-run-jobs run))
          (if (and failed (plist-get plan :fail-fast))
              (setf (multihost-job-status job) 'skipped
                    (multihost-job-error job) "Skipped after an earlier failure")
            (setf (multihost-job-status job) 'running
                  (multihost-job-started-at job) (float-time))
            (message "Multihost foreground: %s" (multihost--job-label job))
            (ob-multihost--notify callback run job)
            (let ((result
                   (condition-case err
                       (multihost-execute-spec spec (multihost-job-directory job))
                     (error (list :status 'failed :error (error-message-string err)
                                  :stdout "" :stderr "")))))
              (setf (multihost-job-status job) (plist-get result :status)
                    (multihost-job-exit-code job) (plist-get result :exit-code)
                    (multihost-job-stdout job) (plist-get result :stdout)
                    (multihost-job-stderr job) (plist-get result :stderr)
                    (multihost-job-value job) (plist-get result :value)
                    (multihost-job-error job) (plist-get result :error)
                    (multihost-job-ended-at job) (float-time))
              (unless (eq (multihost-job-status job) 'succeeded) (setq failed t))))
          (multihost-save-run run))
      (quit (setq interrupted t)))
    (when interrupted
      (dolist (job (multihost-run-jobs run))
        (when (memq (multihost-job-status job) '(queued running))
          (setf (multihost-job-status job) 'cancelled
                (multihost-job-ended-at job) (float-time)
                (multihost-job-error job) "Foreground run interrupted; verify remote process state"))))
    (setf (multihost-run-queue run) nil
          (multihost-run-cancelled run) interrupted
          (multihost-run-ended-at run) (float-time)
          (multihost-run-state run) (cond (interrupted 'cancelled) (failed 'failed) (t 'succeeded)))
    (multihost-save-run run)
    (ob-multihost--notify callback run nil)
    run))

;;;###autoload
(defun multihost-org-execute (&optional supplied-info)
  "Execute the current :hosts block, preserving Org evaluation policy.
SUPPLIED-INFO is unevaluated source info supplied by the Org integration."
  (interactive)
  (let* ((plan (ob-multihost--plan supplied-info))
         (info (plist-get plan :info)))
    (when supplied-info
      (let ((current (org-babel-get-src-block-info 'no-eval)))
        (unless (and current
                     (equal (cl-subseq info 0 2) (cl-subseq current 0 2))
                     (equal (nth 4 info) (nth 4 current)))
          (user-error "Execute the Multihost source block at point; indirect Babel calls are not supported"))))
    (unless (org-babel-confirm-evaluate info)
      (user-error "Org evaluation policy declined this block"))
    (let* ((marker (copy-marker (nth 5 info)))
           ;; Org may reorder params while merging call arguments.  Compare
           ;; the actual source representation with itself at completion.
           (fingerprint (ob-multihost--fingerprint (org-babel-get-src-block-info 'no-eval)))
           (renderer (plist-get plan :renderer))
           (spec (ob-multihost--resolved-spec plan))
           (insert-scheduled nil)
           (callback
            (lambda (run job)
              (multihost-notify run job)
              (when (and (multihost-run-finished-p run)
                         (multihost-run-ended-at run) (not insert-scheduled))
                (setq insert-scheduled t)
                (run-at-time 0 nil #'ob-multihost--insert-completed
                             run marker fingerprint renderer))))
           (run
            (if (equal (plist-get plan :execution) "foreground")
                (ob-multihost--foreground spec plan callback)
              (multihost-start spec (plist-get plan :hosts)
                               :concurrency (plist-get plan :concurrency)
                               :timeout (plist-get plan :timeout)
                               :fail-fast (plist-get plan :fail-fast) :callback callback))))
      (setq ob-multihost-last-run run)
      (ob-multihost--claim marker run)
      (multihost-show-run run)
      run)))

;;;###autoload
(defun multihost-org-execute-foreground ()
  "Execute the current block serially with interactive TRAMP authentication.
This uses the current Emacs connection state.  There is no background
deadline; C-g interrupts.  Remote termination still depends on transport."
  (interactive)
  (let ((ob-multihost--force-foreground t))
    (multihost-org-execute)))

(defun ob-multihost--around (original &rest args)
  "Route :hosts blocks to Multihost; otherwise call ORIGINAL with ARGS."
  (if ob-multihost--inside (apply original args)
    (let* ((info (or (nth 1 args) (org-babel-get-src-block-info 'no-eval)))
           (params (org-babel-merge-params (nth 2 info) (nth 2 args))))
      (if (assq :hosts params)
          (progn
            (when (bound-and-true-p org-export-current-backend)
              (user-error "Multihost runs are explicit; execute before exporting"))
            (setq info (copy-tree info))
            (setf (nth 2 info) params)
            (multihost-org-execute info))
        (apply original args)))))

(defun ob-multihost--completion-info ()
  "Read unevaluated source headers in Org or its current source edit buffer."
  (cond
   ((org-src-edit-buffer-p)
    (let ((marker org-src--beg-marker))
      (unless (and (markerp marker) (marker-buffer marker))
        (user-error "The source runbook is no longer available"))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (org-babel-get-src-block-info 'no-eval)))))
   ((derived-mode-p 'org-mode) (org-babel-get-src-block-info 'no-eval))
   (t (user-error "Use completion inside an Org shell block or its C-c ' edit buffer"))))

(defun ob-multihost--completion-context ()
  "Resolve literal shell block targets without evaluating source or connecting.
Keep the editor's own directory unchanged.  Cache validated inventory contents
until routing headers or the local inventory's modification metadata change."
  (let* ((info (ob-multihost--completion-info))
         (params (nth 2 info))
         (hostspec (cdr (assq :hosts params)))
         (exclude (cdr (assq :exclude params)))
         (directory (cdr (assq :dir params)))
         (inventory-file (and multihost-inventory-file
                              (expand-file-name multihost-inventory-file))))
    (unless (and info (member (car info) '("sh" "bash" "shell")) hostspec)
      (user-error "Remote completion requires a shell source block with literal :hosts"))
    (when (and inventory-file (file-remote-p inventory-file))
      (user-error "Completion inventories must be local files"))
    (when (and directory (not (stringp directory)))
      (user-error ":dir must be a literal directory"))
    (let* ((attributes (and inventory-file (file-attributes inventory-file)))
           (key (list (car info) hostspec exclude directory inventory-file
                      (and attributes (file-attribute-modification-time attributes))
                      (and attributes (file-attribute-size attributes))))
           (cached ob-multihost--completion-cache))
      (unless (equal key (car cached))
        (let ((hosts (multihost-select-hosts
                      hostspec (and inventory-file (multihost-inventory-load inventory-file)) exclude)))
          (setq cached
                (cons key (mapcar (lambda (host)
                                   (cons (multihost-host-name host)
                                         (multihost-host-directory host directory))) hosts))
                ob-multihost--completion-cache cached)))
      (cdr cached))))

;;;###autoload
(defun multihost-org-completion-enable ()
  "Enable asynchronous remote completion for this Org shell editing buffer.
Use the literal :hosts and :dir headers, with no evaluation of the block.
This explicit command requests remote candidates; later M-TAB calls use the
cache and schedule debounced refreshes.  Candidate annotations show host scope."
  (interactive)
  (ob-multihost--completion-context)
  (require 'multihost-completion)
  (multihost-completion-setup #'ob-multihost--completion-context t)
  (setq-local ob-multihost-completion-enabled t)
  (multihost-completion-refresh))

;;;###autoload
(defun multihost-org-completion-disable ()
  "Stop remote completion and its pending requests in this buffer."
  (interactive)
  (setq ob-multihost-completion-enabled nil
        ob-multihost--completion-cache nil)
  (when (featurep 'multihost-completion) (multihost-completion-disable)))

(defun ob-multihost--completion-edit-buffer ()
  "Inherit explicit completion opt-in when opening a source edit buffer.
Setting up the CAPF does not initiate remote traffic."
  (when (and (org-src-edit-buffer-p)
             (buffer-local-value 'ob-multihost-completion-enabled (org-src-source-buffer)))
    (require 'multihost-completion)
    (setq-local ob-multihost-completion-enabled t)
    (multihost-completion-setup #'ob-multihost--completion-context t)))

;;;###autoload
(define-minor-mode ob-multihost-mode
  "Enable :hosts on supported Org Babel blocks globally.
Blocks without :hosts retain normal Org behavior.  Execution during
export is rejected; run the block explicitly before exporting results."
  :global t :group 'multihost
  (if ob-multihost-mode
      (progn
        (advice-add 'org-babel-execute-src-block :around #'ob-multihost--around)
        (add-hook 'org-src-mode-hook #'ob-multihost--completion-edit-buffer))
    (advice-remove 'org-babel-execute-src-block #'ob-multihost--around)
    (remove-hook 'org-src-mode-hook #'ob-multihost--completion-edit-buffer)))

(provide 'ob-multihost)
;;; ob-multihost.el ends here
