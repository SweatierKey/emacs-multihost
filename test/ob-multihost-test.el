;;; ob-multihost-test.el --- Org policy and result ownership contracts -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'ob-multihost)
(require 'ox)

(defvar ob-multihost-test--evaluated 0)

(defmacro ob-multihost-test-with-block (headers &rest body)
  "Evaluate BODY at a shell block carrying HEADERS."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert (concat "#+begin_src sh :results output " ,headers "\nprintf ok\n#+end_src\n"))
     (goto-char (point-min))
     (let ((multihost-inventory-file nil)
           (org-confirm-babel-evaluate nil))
       ,@body)))

(defun ob-multihost-test-run (id)
  "Return a completed fixture run identified by ID."
  (make-multihost-run
   :id id :state 'finished :started-at 100 :ended-at 101
   :jobs (list (make-multihost-job :id "web" :index 0 :host (make-multihost-host :name "web" :connection "web")
                                  :directory "/ssh:web:~/" :status 'succeeded :exit-code 0
                                  :stdout "expected-result" :stderr "" :started-at 100 :ended-at 101))))

(ert-deftest ob-multihost-preview-does-not-evaluate-vars-or-connect ()
  (ob-multihost-test-with-block ":hosts web db :var x=(progn (cl-incf ob-multihost-test--evaluated) 7)"
    (let ((ob-multihost-test--evaluated 0))
      (cl-letf (((symbol-function 'multihost-start) (lambda (&rest _) (ert-fail "preview started execution")))
                ((symbol-function 'process-file) (lambda (&rest _) (ert-fail "preview opened a process"))))
        (let ((plan (ob-multihost--plan)))
          (should (equal (mapcar #'multihost-host-name (plist-get plan :hosts)) '("web" "db"))))
        (save-window-excursion (multihost-org-preview))
        (should (zerop ob-multihost-test--evaluated))))))

(ert-deftest ob-multihost-preview-rejects-lisp-routing-without-eval ()
  (ob-multihost-test-with-block ":hosts (progn (cl-incf ob-multihost-test--evaluated) (list \"web\"))"
    (let ((ob-multihost-test--evaluated 0))
      (should-error (ob-multihost--plan) :type 'user-error)
      (should (zerop ob-multihost-test--evaluated)))))

(ert-deftest ob-multihost-invalid-options-fail-before-consent-or-execution ()
  (dolist (headers '(":hosts web :renderer typo" ":hosts web :concurrency 0"
                     ":hosts web :timeout 0" ":hosts web :session shared"
                     ":hosts web :dir /ssh:other:/srv/" ":hosts web :fail-fast maybe"
                     ":hosts web :execution foreground :concurrency 2"
                     ":hosts web :execution foreground :timeout 10"))
    (ob-multihost-test-with-block headers
      (cl-letf (((symbol-function 'multihost-start) (lambda (&rest _) (ert-fail "invalid plan started execution")))
                ((symbol-function 'org-babel-confirm-evaluate) (lambda (&rest _) (ert-fail "invalid plan reached consent"))))
        (should-error (multihost-org-execute) :type 'user-error)))))

(ert-deftest ob-multihost-unsupported-result-placement-rejected-before-execution ()
  (dolist (option '("silent" "append" "prepend" "none" "discard" "raw"))
    (ob-multihost-test-with-block (concat ":hosts web :results output " option)
      (cl-letf (((symbol-function 'multihost-start) (lambda (&rest _) (ert-fail "unsupported result placement executed")))
                ((symbol-function 'org-babel-confirm-evaluate) (lambda (&rest _) (ert-fail "unsupported result placement reached consent"))))
        (should-error (multihost-org-execute) :type 'user-error)))))

(ert-deftest ob-multihost-eval-never-and-denied-query-prevent-expansion ()
  (dolist (headers '(":hosts web :eval never" ":hosts web :eval no"
                     ":hosts web :eval query :var x=(progn (cl-incf ob-multihost-test--evaluated) 7)"))
    (ob-multihost-test-with-block headers
      (let ((ob-multihost-test--evaluated 0))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                  ((symbol-function 'multihost-start) (lambda (&rest _) (ert-fail "declined block started execution"))))
          (should-error (multihost-org-execute) :type 'user-error)
          (should (zerop ob-multihost-test--evaluated)))))))

(ert-deftest ob-multihost-authorized-expansion-happens-once ()
  (ob-multihost-test-with-block ":hosts web db :var x=(progn (cl-incf ob-multihost-test--evaluated) 7)"
    (let ((ob-multihost-test--evaluated 0)
          captured-spec captured-hosts)
      (cl-letf (((symbol-function 'multihost-start)
                 (lambda (spec hosts &rest _) (setq captured-spec spec captured-hosts hosts) (ob-multihost-test-run "expanded")))
                ((symbol-function 'multihost-show-run) #'identity))
        (multihost-org-execute)
        (should (= ob-multihost-test--evaluated 1))
        (should (equal (mapcar #'multihost-host-name captured-hosts) '("web" "db")))
        (should (string-match-p "7" (plist-get captured-spec :body)))
        (should-not (assq :var (plist-get captured-spec :params)))
        (should-not (assq :hosts (plist-get captured-spec :params)))))))

(ert-deftest ob-multihost-block-without-hosts-passes-through ()
  (ob-multihost-test-with-block ""
    (let (received)
      (should (eq (ob-multihost--around (lambda (&rest args) (setq received args) 'ordinary)
                                       'prefix nil '((:results . "output"))) 'ordinary))
      (should (equal received '(prefix nil ((:results . "output"))))))))

(ert-deftest ob-multihost-foreign-source-info-cannot-execute-current-body ()
  (ob-multihost-test-with-block ":hosts web"
    (let ((foreign (copy-tree (org-babel-get-src-block-info 'no-eval))))
      (setf (nth 1 foreign) "printf different-authorized-body")
      (cl-letf (((symbol-function 'multihost-start) (lambda (&rest _) (ert-fail "Executed a different body than supplied INFO")))
                ((symbol-function 'org-babel-confirm-evaluate) (lambda (&rest _) (ert-fail "Foreign source reached consent"))))
        (should-error (multihost-org-execute foreign) :type 'user-error)))))

(ert-deftest ob-multihost-export-never-broadcasts ()
  (ob-multihost-test-with-block ":hosts web"
    (let ((org-export-current-backend 'html))
      (cl-letf (((symbol-function 'multihost-org-execute) (lambda (&rest _) (ert-fail "export executed hosts"))))
        (should-error (ob-multihost--around (lambda (&rest _) (ert-fail "export reached ordinary executor")))
                      :type 'user-error)))))

(ert-deftest ob-multihost-result-insertion-replaces-one-drawer ()
  (ob-multihost-test-with-block ":hosts web"
    (let* ((info (org-babel-get-src-block-info 'no-eval))
           (marker (copy-marker (nth 5 info)))
           (fingerprint (ob-multihost--fingerprint info))
           (run (ob-multihost-test-run "complete")))
      (ob-multihost--claim marker run)
      (ob-multihost--insert-completed run marker fingerprint 'combined)
      (ob-multihost--insert-completed run marker fingerprint 'combined)
      (should (string-match-p "expected-result" (buffer-string)))
      (goto-char (point-min))
      (should (= (how-many "^#\\+RESULTS:" (point-min) (point-max)) 1)))))

(ert-deftest ob-multihost-edited-block-retains-results-outside-runbook ()
  (ob-multihost-test-with-block ":hosts web"
    (let* ((info (org-babel-get-src-block-info 'no-eval))
           (marker (copy-marker (nth 5 info)))
           (fingerprint (ob-multihost--fingerprint info))
           (run (ob-multihost-test-run "edited")))
      (ob-multihost--claim marker run)
      (search-forward "printf ok")
      (replace-match "printf changed")
      (ob-multihost--insert-completed run marker fingerprint 'combined)
      (should-not (string-match-p "expected-result" (buffer-string))))))

(ert-deftest ob-multihost-older-run-cannot-overwrite-newer-submission ()
  (ob-multihost-test-with-block ":hosts web"
    (let* ((info (org-babel-get-src-block-info 'no-eval))
           (old-marker (copy-marker (nth 5 info)))
           (new-marker (copy-marker (nth 5 info)))
           (fingerprint (ob-multihost--fingerprint info))
           (old-run (ob-multihost-test-run "old"))
           (new-run (ob-multihost-test-run "new")))
      (ob-multihost--claim old-marker old-run)
      (ob-multihost--claim new-marker new-run)
      (ob-multihost--insert-completed old-run old-marker fingerprint 'combined)
      (should-not (string-match-p "expected-result" (buffer-string)))
      (ob-multihost--insert-completed new-run new-marker fingerprint 'combined)
      (should (string-match-p "Run new" (buffer-string))))))

(ert-deftest ob-multihost-killed-source-buffer-is-harmless ()
  (let ((buffer (generate-new-buffer " *multihost-killed-test*")) marker)
    (with-current-buffer buffer (setq marker (copy-marker (point))))
    (kill-buffer buffer)
    (should-not (ob-multihost--insert-completed (ob-multihost-test-run "killed") marker "irrelevant" 'digest))))

(ert-deftest ob-multihost-foreground-command-overrides-background-settings ()
  (ob-multihost-test-with-block ":hosts web db :execution background :concurrency 8 :timeout 5"
    (let ((before (buffer-string)) captured-plan captured-spec)
      (cl-letf (((symbol-function 'ob-multihost--foreground)
                 (lambda (spec plan _callback)
                   (setq captured-spec spec captured-plan plan)
                   (ob-multihost-test-run "foreground")))
                ((symbol-function 'multihost-start) (lambda (&rest _) (ert-fail "foreground started background")))
                ((symbol-function 'multihost-show-run) #'identity))
        (multihost-org-execute-foreground)
        (should (equal (plist-get captured-plan :execution) "foreground"))
        (should (= (plist-get captured-plan :concurrency) 1))
        (should (equal (plist-get captured-spec :body) "printf ok"))
        (should (equal before (buffer-string)))))))

(ert-deftest ob-multihost-foreground-fail-fast-keeps-order ()
  (let* ((state (make-temp-file "multihost-foreground-test-" t))
         (multihost-state-directory state)
         (multihost-runs nil)
         (spec '(:language "sh" :body "false" :params ((:results . "output"))))
         (plan (list :hosts (multihost-select-hosts "web db backup") :timeout 60 :fail-fast t))
         executed)
    (unwind-protect
        (cl-letf (((symbol-function 'multihost-execute-spec)
                   (lambda (_spec directory)
                     (push directory executed)
                     '(:status failed :exit-code 7 :stdout "partial" :stderr "failure"))))
          (let ((run (ob-multihost--foreground spec plan (lambda (&rest _)))))
            (should (equal executed '("/ssh:web:~/")))
            (should (equal (mapcar #'multihost-job-status (multihost-run-jobs run)) '(failed skipped skipped)))
            (should (eq (multihost-run-state run) 'failed))
            (should (multihost-run-finished-p run))))
      (delete-directory state t))))

(ert-deftest ob-multihost-foreground-quit-marks-running-and-queued ()
  (let* ((state (make-temp-file "multihost-foreground-quit-" t))
         (multihost-state-directory state)
         (multihost-runs nil)
         (spec '(:language "sh" :body "sleep 30" :params ((:results . "output"))))
         (plan (list :hosts (multihost-select-hosts "web db") :timeout 60)))
    (unwind-protect
        (cl-letf (((symbol-function 'multihost-execute-spec) (lambda (&rest _) (signal 'quit nil))))
          (let ((run (ob-multihost--foreground spec plan (lambda (&rest _)))))
            (should (equal (mapcar #'multihost-job-status (multihost-run-jobs run)) '(cancelled cancelled)))
            (should (eq (multihost-run-state run) 'cancelled))
            (should (multihost-run-finished-p run))))
      (delete-directory state t))))

(ert-deftest ob-multihost-foreground-observer-error-does-not-break-execution ()
  (let* ((state (make-temp-file "multihost-foreground-observer-" t))
         (multihost-state-directory state)
         (multihost-runs nil)
         (spec '(:language "sh" :body "true" :params ((:results . "output"))))
         (plan (list :hosts (multihost-select-hosts "web db") :timeout 60)))
    (unwind-protect
        (cl-letf (((symbol-function 'multihost-execute-spec)
                   (lambda (&rest _) '(:status succeeded :exit-code 0 :stdout "ok" :stderr ""))))
          (let ((run (ob-multihost--foreground spec plan (lambda (&rest _) (error "Observer failed")))))
            (should (equal (mapcar #'multihost-job-status (multihost-run-jobs run)) '(succeeded succeeded)))
            (should (multihost-run-finished-p run))))
      (delete-directory state t))))

(provide 'ob-multihost-test)
;;; ob-multihost-test.el ends here
