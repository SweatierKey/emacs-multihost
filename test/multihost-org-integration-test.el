;;; multihost-org-integration-test.el --- Org runbooks over real SSH -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'multihost-integration-test)
(require 'ob-multihost)

(defun multihost-org-integration--wait-results (run source)
  "Wait for RUN finalization and its actual results insertion in SOURCE.
Job completion, run finalization, and Org insertion are separate events;
one fixed sleep does not establish that all three have been processed."
  (let ((deadline (+ (float-time) 10))
        (ready (lambda ()
                 (and (multihost-run-ended-at run)
                      (with-current-buffer source
                        (save-excursion
                          (goto-char (point-min))
                          (search-forward "#+RESULTS:" nil t))))))
        (polls 0))
    (while (and (not (funcall ready)) (< (float-time) deadline))
      (cl-incf polls)
      (accept-process-output nil 0.03))
    (message "Org result event observed: polls=%d state=%s inserted=%s"
             polls (multihost-run-state run) (and (funcall ready) t))
    (should (funcall ready))))

(defmacro multihost-org-integration--with-runbook (text &rest body)
  "Visit lab runbook TEXT and run BODY with standard Org integration."
  (declare (indent 1) (debug t))
  `(multihost-integration--with-lab
     (let ((org-confirm-babel-evaluate nil)
           (multihost-default-timeout 15)
           (multihost-state-directory (expand-file-name "org-integration-state" lab))
           (multihost--known-runs nil)
           (multihost-runs nil)
           (previous-mode ob-multihost-mode))
       (unwind-protect
           (cl-letf (((symbol-function 'multihost-current-inventory)
                      (lambda () (list (multihost-integration--host "web")
                                       (multihost-integration--host "db")))))
             (ob-multihost-mode 1)
             (with-temp-buffer
               (org-mode)
               (insert ,text)
               (goto-char (point-min))
               (search-forward "#+begin_src sh :hosts")
               (beginning-of-line)
               ,@body))
         (ob-multihost-mode (if previous-mode 1 -1))))))

(ert-deftest multihost-org-integration-background-vars-noweb-and-final-results ()
  "Expand variables and noweb once, execute twice remotely, insert final state."
  (multihost-org-integration--with-runbook
      (concat "#+name: shared-check\n#+begin_src sh\nprintf 'NOWEB=expanded\\n'\n#+end_src\n\n"
              "#+begin_src sh :hosts web db :concurrency 2 :timeout 15 :results output :noweb yes :var greeting=\"quoted value\"\n"
              "printf 'VALUE=%s\\n' \"$greeting\"\n<<shared-check>>\ncat status.txt\n#+end_src\n")
    (let* ((source (current-buffer))
           (run (org-babel-execute-src-block)))
      (push run multihost-integration--runs)
      (multihost-integration--wait run)
      (multihost-org-integration--wait-results run source)
      (let ((jobs (multihost-run-jobs run)))
        (should (equal (mapcar #'multihost-job-status jobs) '(succeeded succeeded)))
        (dolist (job jobs)
          (should (string-match-p "VALUE=quoted value\nNOWEB=expanded\nrole="
                                  (multihost-job-stdout job)))))
      (with-current-buffer source
        (goto-char (point-min))
        (should (search-forward "#+RESULTS:" nil t))
        (should (search-forward "· finished · 2 hosts" nil t))
        (should-not (search-forward "· running ·" nil t))))))

(ert-deftest multihost-org-integration-foreground-real-ssh-two-hosts ()
  "Use the editor's TRAMP session serially and produce normal Org results."
  (multihost-org-integration--with-runbook
      (concat "#+begin_src sh :hosts db web :execution foreground :concurrency 1 :results output\n"
              "printf 'SSH=%s\\n' \"$SSH_CONNECTION\"\ncat status.txt\n#+end_src\n")
    (let* ((source (current-buffer))
           (run (org-babel-execute-src-block))
           (jobs (multihost-run-jobs run)))
      (push run multihost-integration--runs)
      (multihost-org-integration--wait-results run source)
      (should (multihost-run-finished-p run))
      (should (equal (mapcar #'multihost-job-status jobs) '(succeeded succeeded)))
      (should (equal (mapcar (lambda (job) (multihost-host-name (multihost-job-host job))) jobs)
                     '("db" "web")))
      (should (cl-every (lambda (job) (null (multihost-job-process job))) jobs))
      (should (<= (multihost-job-ended-at (car jobs)) (multihost-job-started-at (cadr jobs))))
      (should (string-match-p "SSH=127\\.0\\.0\\.1.*22262" (multihost-job-stdout (car jobs))))
      (should (string-match-p "role=web" (multihost-job-stdout (cadr jobs))))
      (with-current-buffer source
        (goto-char (point-min))
        (should (search-forward "#+RESULTS:" nil t))))))

(ert-deftest multihost-org-integration-foreground-failure-keeps-per-host-status ()
  "A failed foreground check may continue, preserving both outcomes."
  (multihost-org-integration--with-runbook
      (concat "#+begin_src sh :hosts web db :execution foreground :concurrency 1 :results output\n"
              "cat status.txt\nif grep -q role=web status.txt; then printf failed >&2; exit 7; fi\nprintf healthy\n#+end_src\n")
    (let* ((run (org-babel-execute-src-block))
           (jobs (multihost-run-jobs run)))
      (push run multihost-integration--runs)
      (should (equal (mapcar #'multihost-job-status jobs) '(failed succeeded)))
      (should (eql (multihost-job-exit-code (car jobs)) 7))
      (should (equal (multihost-job-stderr (car jobs)) "failed"))
      (should (string-match-p "healthy" (multihost-job-stdout (cadr jobs)))))))

(provide 'multihost-org-integration-test)
;;; multihost-org-integration-test.el ends here
