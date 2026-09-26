;;; multihost.el --- Organized remote operations in Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Multihost contributors
;; Author: Multihost contributors
;; Version: 1.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Keywords: processes, tools, unix
;; URL: https://github.com/SweatierKey/emacs-multihost
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Inventory, run dashboard and result views for Org/Babel/TRAMP operations.
;; M-x multihost opens an inventory.  M-x multihost-runs opens run history.
;; Enable `ob-multihost-mode' to use :hosts on ordinary Org source blocks.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'json)
(require 'multihost-inventory)
(require 'multihost-engine)

(autoload 'multihost-connections "multihost-connections-ui" nil t)
(autoload 'multihost-warm-connections "multihost-connections-ui" nil t)

(defcustom multihost-inventory-file nil
  "JSON inventory file, or nil to use literal SSH aliases in Org blocks."
  :type '(choice (const nil) file) :group 'multihost)
(defcustom multihost-default-concurrency 4
  "Maximum simultaneous background jobs in a run."
  :type 'natnum :group 'multihost)
(defcustom multihost-default-timeout 60
  "Background job deadline in seconds, including connection setup."
  :type 'number :group 'multihost)

(defvar multihost--known-runs nil "Runs displayed by this editor session.")
(defvar-local multihost--run nil)
(defvar-local multihost--hosts nil)
(defvar-local multihost--marks nil)
(defvar-local multihost--view nil)
(defvar-local multihost--refresh-timer nil)

(defun multihost-current-inventory ()
  "Read the configured inventory afresh, or return nil."
  (when multihost-inventory-file
    (multihost-inventory-load multihost-inventory-file)))

(defun multihost--plain (value)
  "Return VALUE with terminal control characters made visible."
  (replace-regexp-in-string
   "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]"
   (lambda (s) (format "\\x%02x" (aref s 0)))
   (format "%s" (or value "")) t t))

(defun multihost--cell (value)
  "Format VALUE as one safe Org table cell."
  (replace-regexp-in-string
   "|" "¦" (replace-regexp-in-string "[\n\r\t]+" " " (multihost--plain value)) t t))

(defun multihost--duration (job)
  "Return elapsed seconds for JOB."
  (if-let ((start (multihost-job-started-at job)))
      (- (or (multihost-job-ended-at job) (float-time)) start)
    0))

(defun multihost--job-label (job)
  "Return display name for JOB."
  (multihost-host-name (multihost-job-host job)))

(defun multihost--verbatim (text)
  "Render TEXT as fixed-width Org text without executable markup."
  (mapconcat (lambda (line) (concat ": " line))
             (split-string (multihost--plain text) "\n") "\n"))

(defun multihost--job-body (job)
  "Return readable, Org-safe output for JOB."
  (concat (multihost--verbatim (multihost-job-stdout job))
          (unless (string-empty-p (or (multihost-job-stderr job) ""))
            (concat "\n: [stderr]\n" (multihost--verbatim (multihost-job-stderr job))))
          (when (multihost-job-error job)
            (concat "\n: [error]\n" (multihost--verbatim (multihost-job-error job))))
          (when (and (multihost-job-value job)
                     (string-empty-p (or (multihost-job-stdout job) "")))
            (concat "\n: [value]\n" (multihost--verbatim (format "%S" (multihost-job-value job)))))))

(defun multihost-render-org (run &optional renderer)
  "Render RUN as Org-safe text using RENDERER.
RENDERER is digest, per-host, table or combined."
  (let* ((renderer (or renderer 'digest))
         (jobs (multihost-run-jobs run))
         (summary (format "Run %s · %s · %d hosts\n"
                          (multihost-run-id run) (multihost-run-state run) (length jobs)))
         (table (concat
                 "| Host | Status | Exit | Seconds |\n|------+--------+------+---------|\n"
                 (mapconcat
                  (lambda (job)
                    (format "| %s | %s | %s | %.3f |"
                            (multihost--cell (multihost--job-label job))
                            (multihost-job-status job)
                            (or (multihost-job-exit-code job) "unknown")
                            (multihost--duration job))) jobs "\n")))
         (full (lambda ()
                 (mapconcat
                  (lambda (job)
                    (format "%s · %s · exit %s\n%s"
                            (multihost--cell (multihost--job-label job))
                            (multihost-job-status job)
                            (or (multihost-job-exit-code job) "unknown")
                            (multihost--job-body job))) jobs "\n\n"))))
    (concat
     summary "\n"
     (pcase renderer
       ('table table)
       ('per-host (funcall full))
       ('combined (concat table "\n\n" (funcall full)))
       ('digest
        (let (groups)
          (dolist (job jobs)
            (let* ((key (list (multihost-job-status job) (multihost-job-exit-code job)
                              (multihost--job-body job)))
                   (entry (assoc key groups)))
              (if entry (setcdr entry (append (cdr entry) (list (multihost--job-label job))))
                (setq groups (append groups (list (list key (multihost--job-label job))))))))
          (mapconcat
           (lambda (group)
             (format "%s · %s · exit %s\n%s"
                     (mapconcat #'multihost--cell (cdr group) ", ")
                     (caar group) (or (cadar group) "unknown") (nth 2 (car group))))
           groups "\n\n")))
       (_ (user-error "Unknown renderer: %s" renderer))))))

(defun multihost--job-entries (run)
  "Build dashboard rows for RUN."
  (mapcar
   (lambda (job)
     (list job (vector (number-to-string (1+ (multihost-job-index job)))
                       (multihost--job-label job)
                       (if (and (eq (multihost-job-status job) 'running)
                                (multihost-request-p (multihost-job-request job))
                                (eq (multihost-request-status (multihost-job-request job)) 'queued))
                           "waiting-pool"
                         (symbol-name (multihost-job-status job)))
                       (format "%s" (or (multihost-job-exit-code job) "—"))
                       (format "%.2f" (multihost--duration job))
                       (multihost--plain (multihost-job-directory job)))))
   (multihost-run-jobs run)))

(defun multihost-refresh ()
  "Refresh the current Multihost view."
  (interactive)
  (pcase major-mode
    ('multihost-run-mode
     (setq tabulated-list-entries (multihost--job-entries multihost--run)
           header-line-format
           (format " %s | %s | RET output · a all · d digest · c cancel · r retry failures · e export"
                   (multihost-run-id multihost--run) (multihost-run-state multihost--run)))
     (tabulated-list-print t))
    ('multihost-history-mode
     (setq tabulated-list-entries
           (mapcar (lambda (run)
                     (list run (vector (multihost-run-id run)
                                       (symbol-name (multihost-run-state run))
                                       (number-to-string (length (multihost-run-jobs run)))
                                       (format-time-string "%F %T" (multihost-run-started-at run)))))
                   multihost--known-runs))
     (tabulated-list-print t))
    ('multihost-output-mode (multihost--render-view))))

(defun multihost-notify (run &optional _job)
  "Refresh existing views when RUN changes.  Suitable as engine callback."
  (cl-pushnew run multihost--known-runs :test #'eq)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (eq multihost--run run)
                 (memq major-mode '(multihost-run-mode multihost-output-mode)))
        (multihost-refresh))))
  (when (multihost-run-finished-p run)
    (message "Multihost %s: %s" (multihost-run-id run) (multihost-run-state run))))

(defvar multihost-run-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'multihost-show-job)
    (define-key map (kbd "g") #'multihost-refresh)
    (define-key map (kbd "a") #'multihost-show-combined)
    (define-key map (kbd "d") #'multihost-show-digest)
    (define-key map (kbd "c") #'multihost-cancel-run)
    (define-key map (kbd "r") #'multihost-retry-run)
    (define-key map (kbd "e") #'multihost-export)
    map))

(define-derived-mode multihost-run-mode tabulated-list-mode "Multihost-Run"
  "Inspect an ordered set of remote jobs."
  (setq tabulated-list-format [("#" 4 nil) ("Host" 24 t) ("Status" 12 t)
                               ("Exit" 8 nil) ("Seconds" 9 nil) ("Directory" 45 t)]
        tabulated-list-padding 1)
  (tabulated-list-init-header)
  (add-hook 'kill-buffer-hook #'multihost--stop-refresh-timer nil t)
  (add-hook 'change-major-mode-hook #'multihost--stop-refresh-timer nil t))

(defun multihost--stop-refresh-timer ()
  "Stop this dashboard's parent-side refresh timer."
  (when (timerp multihost--refresh-timer) (cancel-timer multihost--refresh-timer))
  (setq multihost--refresh-timer nil))

(defun multihost--refresh-running (buffer)
  "Refresh visible BUFFER from local state until its run finishes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (get-buffer-window buffer t) (multihost-refresh))
      (when (multihost-run-finished-p multihost--run)
        (multihost--stop-refresh-timer)))))

(defun multihost-show-run (run)
  "Display RUN without changing its execution order."
  (cl-pushnew run multihost--known-runs :test #'eq)
  (let ((buffer (get-buffer-create (format "*Multihost %s*" (multihost-run-id run)))))
    (with-current-buffer buffer
      (multihost-run-mode)
      (setq-local multihost--run run)
      (multihost-refresh)
      (unless (multihost-run-finished-p run)
        (setq multihost--refresh-timer
              (run-at-time 0.25 0.25 #'multihost--refresh-running buffer))))
    (pop-to-buffer buffer)))

(defun multihost-cancel-run ()
  "Cancel queued work and stop local workers of the current run."
  (interactive)
  (unless multihost--run (user-error "No run in this buffer"))
  (multihost-cancel multihost--run)
  (multihost-refresh))

(defun multihost-retry-run ()
  "Create a new run for unsuccessful jobs of the current run."
  (interactive)
  (unless multihost--run (user-error "No run in this buffer"))
  (let* ((original multihost--run)
         (spec (multihost-run-spec original)))
    (unless (plist-get spec :body)
      (user-error "Archived runs contain no executable body; reopen the source runbook"))
    (if (equal (plist-get spec :execution) "foreground")
        (let ((hosts (cl-loop for job in (multihost-run-jobs original)
                              when (memq (multihost-job-status job) '(failed timed-out cancelled))
                              collect (multihost-job-host job))))
          (unless hosts (user-error "No failed, timed out, or cancelled hosts to retry"))
          (require 'ob-multihost)
          (multihost-show-run
           (ob-multihost--foreground
            spec (list :hosts hosts :timeout (multihost-run-timeout original)
                       :fail-fast (multihost-run-fail-fast original)) #'multihost-notify)))
      (multihost-show-run (multihost-retry-failed original)))))

(declare-function ob-multihost--foreground "ob-multihost" (spec plan callback))

(defvar multihost-output-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'multihost-refresh)
    (define-key map (kbd "e") #'multihost-export)
    map))
(define-derived-mode multihost-output-mode special-mode "Multihost-Output"
  "Read immutable job results; refresh while other hosts finish.")

(defun multihost--render-view ()
  "Update this output buffer from its run and view selection."
  (let ((inhibit-read-only t)
        (position (point)))
    (erase-buffer)
    (if (multihost-job-p multihost--view)
        (let ((job multihost--view))
          (insert (format "%s\n%s\nStatus: %s  Exit: %s  Duration: %.3fs\n\nSTDOUT\n%s\n\nSTDERR\n%s\n"
                          (multihost--job-label job) (multihost-job-directory job)
                          (multihost-job-status job) (or (multihost-job-exit-code job) "unknown")
                          (multihost--duration job)
                          (multihost--plain (multihost-job-stdout job))
                          (multihost--plain (multihost-job-stderr job))))
          (when (multihost-job-error job)
            (insert "\nERROR\n" (multihost--plain (multihost-job-error job)) "\n"))
          (when (and (multihost-job-value job)
                     (string-empty-p (or (multihost-job-stdout job) "")))
            (insert "\nVALUE\n" (multihost--plain (format "%S" (multihost-job-value job))) "\n")))
      (insert (multihost-render-org multihost--run multihost--view)))
    (goto-char (min position (point-max)))))

(defun multihost--show-output (run view label)
  "Show VIEW of RUN with LABEL in a separate buffer."
  (let ((buffer (get-buffer-create (format "*Multihost %s / %s*" (multihost-run-id run) label))))
    (with-current-buffer buffer
      (multihost-output-mode)
      (setq-local multihost--run run multihost--view view)
      (multihost--render-view))
    (pop-to-buffer buffer)))

(defun multihost-show-job ()
  "Open the host at point in its own output buffer."
  (interactive)
  (let ((job (tabulated-list-get-id)))
    (unless (multihost-job-p job) (user-error "Select a host row"))
    (multihost--show-output multihost--run job (multihost--job-label job))))

(defun multihost-show-combined ()
  "Show every host's output in one buffer."
  (interactive)
  (multihost--show-output multihost--run 'combined "all hosts"))

(defun multihost-show-digest ()
  "Group hosts with identical status and output."
  (interactive)
  (multihost--show-output multihost--run 'digest "digest"))

(defun multihost-export (file)
  "Export current run as an Org report to FILE, with private permissions."
  (interactive (list (read-file-name "Export Org report: " nil nil nil "multihost-results.org")))
  (unless multihost--run (user-error "No run in this buffer"))
  (setq file (expand-file-name file))
  (when (file-remote-p file) (user-error "Choose a local export path"))
  (when (file-exists-p file) (user-error "Export already exists: %s" file))
  (let ((run multihost--run)
        (temporary (make-temp-file (expand-file-name ".multihost-export-" (file-name-directory (expand-file-name file))))))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (with-temp-file temporary
            (insert "#+title: Multihost run " (multihost-run-id run) "\n\n"
                    (multihost-render-org run 'combined) "\n"))
          (rename-file temporary file nil))
      (when (file-exists-p temporary) (delete-file temporary))))
  (message "Exported %s" file))

(defvar multihost-history-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'multihost-history-open)
    (define-key map (kbd "g") #'multihost-refresh)
    map))
(define-derived-mode multihost-history-mode tabulated-list-mode "Multihost-History"
  "List runs in this Emacs session."
  (setq tabulated-list-format [("Run" 34 t) ("State" 13 t) ("Hosts" 8 t) ("Started" 20 t)])
  (tabulated-list-init-header))
(defun multihost-history-open ()
  "Open the run at point."
  (interactive)
  (let ((run (tabulated-list-get-id)))
    (unless (multihost-run-p run) (user-error "Select a run row"))
    (multihost-show-run run)))

;;;###autoload
(defun multihost-runs ()
  "Display run history."
  (interactive)
  (let ((directory (expand-file-name "runs" multihost-state-directory)))
    (when (file-directory-p directory)
      (dolist (path (directory-files directory t directory-files-no-dot-files-regexp))
        (when (and (file-directory-p path)
                   (file-exists-p (expand-file-name "run.json" path))
                   (not (cl-find (file-name-nondirectory path) multihost--known-runs
                                 :key #'multihost-run-id :test #'equal)))
          (condition-case err
              (push (multihost-load-run path) multihost--known-runs)
            (error (message "Multihost: cannot read history %s: %s" path (error-message-string err))))))))
  (setq multihost--known-runs
        (sort multihost--known-runs (lambda (a b) (> (multihost-run-started-at a) (multihost-run-started-at b)))))
  (pop-to-buffer (get-buffer-create "*Multihost runs*"))
  (multihost-history-mode)
  (multihost-refresh))

(defun multihost--inventory-refresh ()
  "Refresh rows and marks of the inventory buffer."
  (setq tabulated-list-entries
        (mapcar (lambda (host)
                  (list (multihost-host-name host)
                        (vector (if (member (multihost-host-name host) multihost--marks) "*" "")
                                (multihost-host-name host)
                                (string-join (multihost-host-groups host) ", ")
                                (multihost-host-connection host)
                                (or (multihost-host-description host) "")))) multihost--hosts))
  (tabulated-list-print t))

(defun multihost-reload-inventory ()
  "Reload the inventory file, preserving marks for hosts that still exist."
  (interactive)
  (setq multihost--hosts (multihost-current-inventory)
        multihost--marks
        (cl-intersection multihost--marks (mapcar #'multihost-host-name multihost--hosts)
                         :test #'equal))
  (multihost--inventory-refresh))

(defun multihost-mark ()
  "Mark the inventory host at point."
  (interactive)
  (when-let ((id (tabulated-list-get-id)))
    (cl-pushnew id multihost--marks :test #'equal)
    (multihost--inventory-refresh)
    (forward-line)))
(defun multihost-unmark ()
  "Unmark the inventory host at point."
  (interactive)
  (setq multihost--marks (delete (tabulated-list-get-id) multihost--marks))
  (multihost--inventory-refresh))
(defun multihost-mark-all ()
  "Mark all inventory hosts."
  (interactive)
  (setq multihost--marks (mapcar #'multihost-host-name multihost--hosts))
  (multihost--inventory-refresh))
(defun multihost-unmark-all ()
  "Clear every inventory mark."
  (interactive)
  (setq multihost--marks nil)
  (multihost--inventory-refresh))

(defun multihost--selected-hosts ()
  "Return marked hosts in inventory order, or the host at point."
  (let ((names (or multihost--marks (list (tabulated-list-get-id)))))
    (unless (car names) (user-error "Select or mark at least one host"))
    (cl-remove-if-not (lambda (host) (member (multihost-host-name host) names)) multihost--hosts)))

(defun multihost-run-command (command serial)
  "Run shell COMMAND on selected hosts; with prefix SERIAL run one at a time."
  (interactive (list (read-shell-command "Command on selected hosts: ") current-prefix-arg))
  (when (string-empty-p (string-trim command)) (user-error "Empty command"))
  (let ((hosts (multihost--selected-hosts)))
    (multihost-show-run
     (multihost-start (list :language "sh" :body command
                           :params '((:results . "output") (:session . "none"))
                           :source "inventory command") hosts
                     :concurrency (if serial 1 multihost-default-concurrency)
                     :timeout multihost-default-timeout :callback #'multihost-notify))))

(defun multihost-dired ()
  "Visit the selected host's directory using ordinary TRAMP."
  (interactive)
  (let ((host (car (multihost--selected-hosts))))
    (dired (multihost-host-directory host))))

(defun multihost-shell ()
  "Open an ordinary interactive shell on the selected host."
  (interactive)
  (require 'shell)
  (let* ((host (car (multihost--selected-hosts)))
         (default-directory (multihost-host-directory host)))
    (shell (generate-new-buffer-name (format "*Multihost shell %s*" (multihost-host-name host))))))

(defun multihost-check-connection ()
  "Check the selected host interactively through TRAMP.
Show remote user, hostname and directory.  This does not establish that
isolated background workers can reuse the authentication."
  (interactive)
  (let* ((host (car (multihost--selected-hosts)))
         (directory (multihost-host-directory host))
         (buffer (get-buffer-create (format "*Multihost connection %s*" (multihost-host-name host))))
         (status (with-current-buffer buffer
                   (setq-local default-directory directory)
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (process-file "sh" nil t nil "-c" "id -un; hostname; pwd")))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\nConnection check exit: %s\n" status)))
      (special-mode))
    (pop-to-buffer buffer)))

(defvar multihost-inventory-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (dolist (pair '(("m" . multihost-mark) ("u" . multihost-unmark)
                    ("T" . multihost-mark-all) ("U" . multihost-unmark-all)
                    ("x" . multihost-run-command) ("d" . multihost-dired)
                    ("s" . multihost-shell) ("h" . multihost-runs)
                    ("w" . multihost-warm-connections) ("C" . multihost-connections)
                    ("g" . multihost-reload-inventory) ("v" . multihost-check-connection)))
      (define-key map (kbd (car pair)) (cdr pair)))
    map))
(define-derived-mode multihost-inventory-mode tabulated-list-mode "Multihost"
  "Select hosts: m/u mark, T/U all/none, x command, C-u x serial, s shell, d files."
  (setq tabulated-list-format [("" 1 nil) ("Host" 24 t) ("Groups" 22 t)
                               ("Connection" 42 t) ("Description" 30 t)]
        header-line-format " m/u mark · T/U all/none · x command · w connect · C connections · s shell · d files · h runs")
  (tabulated-list-init-header))

;;;###autoload
(defun multihost (&optional file)
  "Open inventory FILE, or `multihost-inventory-file'."
  (interactive)
  (let* ((file (or file multihost-inventory-file
                   (read-file-name "Multihost inventory JSON: " nil nil t)))
         (hosts (multihost-inventory-load file)))
    (setq multihost-inventory-file (expand-file-name file))
    (pop-to-buffer (get-buffer-create "*Multihost inventory*"))
    (multihost-inventory-mode)
    (setq-local multihost--hosts hosts multihost--marks nil)
    (multihost--inventory-refresh)))

(provide 'multihost)
;;; multihost.el ends here
