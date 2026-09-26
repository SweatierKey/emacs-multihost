;;; multihost-editor-test.el --- Connection and Org completion integration -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'ob-multihost)
(require 'multihost-connections-ui)
(require 'multihost-completion)

(ert-deftest multihost-editor-dashboard-distinguishes-pool-waiting-from-execution ()
  (let* ((request (make-multihost-request :status 'queued))
         (job (make-multihost-job :index 0 :status 'running :request request
                                  :directory "/ssh:web:/" :started-at (float-time)
                                  :host (make-multihost-host :name "web")))
         (run (make-multihost-run :jobs (list job))))
    (should (equal (aref (cadar (multihost--job-entries run)) 2) "waiting-pool"))
    (setf (multihost-request-status request) 'running)
    (should (equal (aref (cadar (multihost--job-entries run)) 2) "running"))))

(ert-deftest multihost-editor-completion-context-is-data-only-and-ordered ()
  (let ((multihost-inventory-file nil))
    (with-temp-buffer
      (org-mode)
      (insert "#+begin_src sh :hosts db web :dir /etc :var x=(error \"DO-NOT-EVALUATE\")\ncat conf\n#+end_src\n")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'process-file) (lambda (&rest _) (ert-fail "Remote I/O in context resolver"))))
        (should (equal (ob-multihost--completion-context)
                       '(("db" . "/ssh:db:/etc/") ("web" . "/ssh:web:/etc/"))))))))

(ert-deftest multihost-editor-completion-routing-changes-invalidate-context ()
  (let ((multihost-inventory-file nil))
    (with-temp-buffer
      (org-mode)
      (insert "#+begin_src sh :hosts db :dir /etc\ncat conf\n#+end_src\n")
      (goto-char (point-min))
      (should (equal (caar (ob-multihost--completion-context)) "db"))
      (search-forward "db")
      (replace-match "web")
      (should (equal (ob-multihost--completion-context) '(("web" . "/ssh:web:/etc/")))))))

(ert-deftest multihost-editor-source-edit-resolves-parent-hosts-without-remote-directory ()
  (let ((multihost-inventory-file nil)
        (default-directory temporary-file-directory))
    (save-window-excursion
      (with-temp-buffer
        (org-mode)
        (insert "#+begin_src sh :hosts web db :dir /srv\ncat conf\n#+end_src\n")
        (goto-char (point-min))
        (forward-line)
        (org-edit-src-code)
        (unwind-protect
            (progn
              (should (derived-mode-p 'sh-mode))
              (should-not (file-remote-p default-directory))
              (should (equal (ob-multihost--completion-context)
                             '(("web" . "/ssh:web:/srv/") ("db" . "/ssh:db:/srv/")))))
          (org-edit-src-exit))))))

(ert-deftest multihost-editor-completion-rejects-remote-inventory-before-reading ()
  (let ((multihost-inventory-file "/ssh:must-not-connect:/inventory.json"))
    (with-temp-buffer
      (org-mode)
      (insert "#+begin_src sh :hosts web\ncat conf\n#+end_src\n")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'file-attributes)
                 (lambda (&rest _) (ert-fail "Read remote inventory attributes"))))
        (should-error (ob-multihost--completion-context) :type 'user-error)))))

(ert-deftest multihost-editor-explicit-opt-in-inherits-without-querying-on-edit ()
  (let ((multihost-inventory-file nil)
        (was-enabled ob-multihost-mode)
        submitted cancelled)
    (unwind-protect
        (cl-letf (((symbol-function 'multihost-connection-submit)
                   (lambda (directory _operation _payload _callback &rest _)
                     (push directory submitted)
                     directory))
                  ((symbol-function 'multihost-connection-cancel)
                   (lambda (request) (push request cancelled))))
          (ob-multihost-mode 1)
          (save-window-excursion
            (with-temp-buffer
              (org-mode)
              (insert "#+begin_src sh :hosts web db\ncat conf\n#+end_src\n")
              (goto-char (point-min))
              (forward-line)
              (end-of-line)
              (should-not (multihost-completion-enabled-p))
              (multihost-org-completion-enable)
              (should (multihost-completion-enabled-p))
              (should (equal (reverse submitted) '("/ssh:web:~/" "/ssh:db:~/")))
              (org-edit-src-code)
              (unwind-protect
                  (progn
                    (should (derived-mode-p 'sh-mode))
                    (should (multihost-completion-enabled-p))
                    (should (= (length submitted) 2))
                    (should-not (file-remote-p default-directory))
                    (multihost-org-completion-disable)
                    (should-not (memq #'multihost-completion-at-point completion-at-point-functions)))
                (org-edit-src-exit))
              ;; The source edit buffer has its own opt-in and cache.
              (should (multihost-completion-enabled-p))
              (multihost-org-completion-disable)
              (should (= (length cancelled) 2))
              (should-not (multihost-completion-enabled-p)))))
      (ob-multihost-mode (if was-enabled 1 -1)))))

(ert-deftest multihost-editor-connections-view-does-not-initiate-connections ()
  (with-temp-buffer
    (multihost-connections-mode)
    (cl-letf (((symbol-function 'multihost-connection-snapshots)
               (lambda () '((:directory "/ssh:db:/" :state idle :pid 123 :completed 2 :queued 0))))
              ((symbol-function 'multihost-connection-submit)
               (lambda (&rest _) (ert-fail "View submitted remote work"))))
      (multihost-connections-refresh)
      (should (string-match-p "/ssh:db:/" (buffer-string)))
      (should (string-match-p "idle" (buffer-string))))))

(ert-deftest multihost-editor-close-connection-targets-only-row-at-point ()
  (with-temp-buffer
    (multihost-connections-mode)
    (let (closed)
      (cl-letf (((symbol-function 'multihost-connection-snapshots)
                 (lambda () '((:directory "/ssh:db:/" :state busy :pid 123))))
                ((symbol-function 'multihost-connection-reset) (lambda (directory) (setq closed directory))))
        (multihost-connections-refresh)
        (goto-char (point-min))
        (multihost-connections-close)
        (should (equal closed "/ssh:db:/"))))))

(provide 'multihost-editor-test)
;;; multihost-editor-test.el ends here
