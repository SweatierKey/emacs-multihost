;;; multihost-engine-test.el --- Scheduler and persistence tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'multihost-engine)

(defmacro multihost-engine-test--isolated (&rest body)
  (declare (indent 0) (debug t))
  `(let ((multihost-state-directory (make-temp-file "multihost-engine-test-" t))
         (multihost-runs nil)
         (multihost-worker-init-file nil))
     (unwind-protect (progn ,@body)
       (dolist (run multihost-runs)
         (unless (multihost-run-finished-p run) (multihost-cancel run)))
       (sleep-for 0.03)
       (delete-directory multihost-state-directory t))))

(defun multihost-engine-test--hosts (&optional count)
  (cl-loop for index below (or count 3)
           collect (make-multihost-host :name (format "host%d" index)
                                       :connection (format "host%d" index))))

(defun multihost-engine-test--spec ()
  '(:language "sh" :body "printf ULTRA_SECRET_BODY" :params ((:results . "output"))
              :source "test-runbook.org"))

(defun multihost-engine-test--wait (run)
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (multihost-run-finished-p run)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (multihost-run-finished-p run))
    (sleep-for 0.03)))

(ert-deftest multihost-engine-serial-is-ordered-and-waits-for-completion ()
  (multihost-engine-test--isolated
    (let (started finished overlap run)
      (cl-letf (((symbol-function 'multihost-engine--launch)
                 (lambda (current job)
                   (when (> (cl-count 'running (multihost-run-jobs current)
                                     :key #'multihost-job-status) 0)
                     (setq overlap t))
                   (push (multihost-job-index job) started)
                   (setf (multihost-job-status job) 'running)
                   (run-at-time 0.015 nil
                                (lambda ()
                                  (push (multihost-job-index job) finished)
                                  (multihost-engine--finish current job 'succeeded :exit-code 0))))))
        (setq run (multihost-start (multihost-engine-test--spec)
                                   (multihost-engine-test--hosts) :concurrency 1))
        (multihost-engine-test--wait run))
      (should-not overlap)
      (should (equal (nreverse started) '(0 1 2)))
      (should (equal (nreverse finished) '(0 1 2)))
      (should (eq (multihost-run-state run) 'finished)))))

(ert-deftest multihost-engine-concurrency-is-bounded-and-refills-slots ()
  (multihost-engine-test--isolated
    (let ((peak 0) started finished)
      (cl-letf (((symbol-function 'multihost-engine--launch)
                 (lambda (run job)
                   (setf (multihost-job-status job) 'running)
                   (push (multihost-job-index job) started)
                   (setq peak (max peak (cl-count 'running (multihost-run-jobs run)
                                                 :key #'multihost-job-status)))
                   (run-at-time (if (zerop (multihost-job-index job)) 0.09 0.015) nil
                                (lambda ()
                                  (push (multihost-job-index job) finished)
                                  (multihost-engine--finish run job 'succeeded :exit-code 0))))))
        (multihost-engine-test--wait
         (multihost-start (multihost-engine-test--spec)
                          (multihost-engine-test--hosts) :concurrency 2)))
      (should (= peak 2))
      (should (equal (nreverse started) '(0 1 2)))
      (should (equal (nreverse finished) '(1 2 0))))))

(ert-deftest multihost-engine-fail-fast-preserves-already-running-jobs ()
  (multihost-engine-test--isolated
    (cl-letf (((symbol-function 'multihost-engine--launch)
               (lambda (run job)
                 (setf (multihost-job-status job) 'running)
                 (run-at-time (if (zerop (multihost-job-index job)) 0.01 0.04) nil
                              (lambda ()
                                (multihost-engine--finish
                                 run job (if (zerop (multihost-job-index job)) 'failed 'succeeded)
                                 :exit-code (if (zerop (multihost-job-index job)) 7 0)))))))
      (let ((run (multihost-start (multihost-engine-test--spec)
                                  (multihost-engine-test--hosts 4)
                                  :concurrency 2 :fail-fast t)))
        (multihost-engine-test--wait run)
        (should (equal (mapcar #'multihost-job-status (multihost-run-jobs run))
                       '(failed succeeded skipped skipped)))))))

(ert-deftest multihost-engine-cancel-before-first-tick-does-not-launch ()
  (multihost-engine-test--isolated
    (let ((run (multihost-start (multihost-engine-test--spec) (multihost-engine-test--hosts))))
      (cl-letf (((symbol-function 'multihost-engine--launch)
                 (lambda (&rest _) (ert-fail "Cancelled run launched a worker"))))
        (multihost-cancel run)
        (sleep-for 0.03))
      (should (equal (mapcar #'multihost-job-status (multihost-run-jobs run))
                     '(cancelled cancelled cancelled)))
      (should (eq (multihost-run-state run) 'cancelled)))))

(ert-deftest multihost-engine-finalization-is-idempotent ()
  (multihost-engine-test--isolated
    (let* ((run (multihost-create-run (multihost-engine-test--spec)
                                     (multihost-engine-test--hosts 1)))
           (job (car (multihost-run-jobs run))))
      (multihost-engine--finish run job 'timed-out :error "deadline")
      (multihost-engine--finish run job 'succeeded :exit-code 0 :stdout "late output")
      (should (eq (multihost-job-status job) 'timed-out))
      (should (equal (multihost-job-error job) "deadline"))
      (should (equal (multihost-job-stdout job) "")))))

(ert-deftest multihost-engine-worker-start-failure-does-not-hang ()
  (multihost-engine-test--isolated
    (let* ((multihost-worker-program "/nonexistent/multihost-emacs")
           (run (multihost-start (multihost-engine-test--spec)
                                 (multihost-engine-test--hosts 1))))
      (multihost-engine-test--wait run)
      (should (eq (multihost-job-status (car (multihost-run-jobs run))) 'failed))
      (should-not (file-exists-p (multihost-engine--job-file run (car (multihost-run-jobs run))
                                                              "request.json"))))))

(ert-deftest multihost-engine-worker-crash-is-distinct-from-command-exit ()
  (multihost-engine-test--isolated
    (let* ((multihost-worker-program "/bin/false")
           (run (multihost-start (multihost-engine-test--spec)
                                 (multihost-engine-test--hosts 1))))
      (multihost-engine-test--wait run)
      (let ((job (car (multihost-run-jobs run))))
        (should (eq (multihost-job-status job) 'failed))
        (should-not (multihost-job-exit-code job))
        (should (string-match-p "Worker exited" (multihost-job-error job)))))))

(ert-deftest multihost-engine-private-audit-excludes-code-and-marks-interruption ()
  (multihost-engine-test--isolated
    (let* ((run (multihost-create-run (multihost-engine-test--spec)
                                     (multihost-engine-test--hosts 1)))
           (directory (multihost-run-directory run))
           (file (expand-file-name "run.json" directory)))
      (should (= (logand (file-modes directory) #o777) #o700))
      (should (= (logand (file-modes file) #o777) #o600))
      (with-temp-buffer
        (insert-file-contents file)
        (should-not (search-forward "ULTRA_SECRET_BODY" nil t)))
      (let* ((reloaded (multihost-load-run directory))
             (job (car (multihost-run-jobs reloaded))))
        (should (eq (multihost-job-status job) 'failed))
        (should (string-match-p "Interrupted" (multihost-job-error job)))
        (should-not (plist-get (multihost-run-spec reloaded) :body))
        (should-error (multihost-retry-failed reloaded) :type 'user-error)))))

(ert-deftest multihost-engine-retry-only-failed-hosts-in-original-order ()
  (multihost-engine-test--isolated
    (let* ((run (multihost-create-run (multihost-engine-test--spec)
                                     (multihost-engine-test--hosts 4)))
           captured)
      (cl-mapc (lambda (job status) (setf (multihost-job-status job) status))
               (multihost-run-jobs run) '(failed succeeded timed-out skipped))
      (cl-letf (((symbol-function 'multihost-start)
                 (lambda (_spec hosts &rest _)
                   (setq captured (mapcar #'multihost-host-name hosts)) 'new-run)))
        (should (eq (multihost-retry-failed run) 'new-run)))
      (should (equal captured '("host0" "host2"))))))

(ert-deftest multihost-engine-observer-errors-do-not-corrupt-results ()
  (multihost-engine-test--isolated
    (let* ((run (multihost-create-run
                 (multihost-engine-test--spec) (multihost-engine-test--hosts 1)
                 :callback (lambda (&rest _) (error "broken UI"))))
           (job (car (multihost-run-jobs run))))
      (multihost-engine--finish run job 'succeeded :exit-code 0 :stdout "preserved")
      (multihost-engine-test--wait run)
      (should (equal (multihost-job-stdout job) "preserved")))))

(ert-deftest multihost-engine-rejects-wrong-id-and-false-success-protocol ()
  (multihost-engine-test--isolated
    (dolist (fault '(wrong-id false-success malformed-json))
      (let* ((run (multihost-create-run (multihost-engine-test--spec)
                                       (multihost-engine-test--hosts 1)))
             (job (car (multihost-run-jobs run)))
             (file (multihost-engine--job-file run job "result.json"))
             (process (make-process :name "multihost-protocol-test" :noquery t
                                    :buffer (generate-new-buffer " *multihost-protocol-test*")
                                    :command '("/bin/true") :sentinel #'ignore)))
        (while (process-live-p process) (accept-process-output process 0.01))
        (setf (multihost-job-status job) 'running (multihost-job-process job) process)
        (if (eq fault 'malformed-json)
            (with-temp-file file (insert "{invalid JSON"))
          (multihost-worker--write-json
           file `(("schema" . 1)
                  ("id" . ,(if (eq fault 'wrong-id) "different-job" (multihost-job-id job)))
                  ("result" . ,(multihost-worker--encode-value
                                (list :status 'succeeded
                                      :exit-code (unless (eq fault 'false-success) 0)
                                      :stdout "output" :stderr ""))))))
        (multihost-engine--sentinel run job process "finished")
        (should (eq (multihost-job-status job) 'failed))
        (should-not (multihost-job-exit-code job))
        (should-not (file-exists-p file))))))

(ert-deftest multihost-engine-timeout-stops-worker-and-ignores-late-sentinel ()
  (multihost-engine-test--isolated
    (let* ((run (multihost-create-run (multihost-engine-test--spec)
                                     (multihost-engine-test--hosts 1)))
           (job (car (multihost-run-jobs run)))
           (process (make-process :name "multihost-timeout-test" :noquery t
                                  :command '("sleep" "10") :sentinel #'ignore)))
      (setf (multihost-job-status job) 'running (multihost-job-process job) process)
      (multihost-engine--timeout run job)
      (should (eq (multihost-job-status job) 'timed-out))
      (should-not (process-live-p process))
      (multihost-engine--sentinel run job process "killed")
      (should (eq (multihost-job-status job) 'timed-out)))))

(ert-deftest multihost-engine-freezes-mutable-source-and-inventory-strings ()
  (multihost-engine-test--isolated
    (let* ((name (copy-sequence "web"))
           (connection (copy-sequence "ssh-web"))
           (group (copy-sequence "production"))
           (body (copy-sequence "printf original"))
           (value (copy-sequence "original"))
           (host (make-multihost-host :name name :connection connection :groups (list group)))
           (spec (list :language "sh" :body body
                       :params (list '(:results . "output") (cons :var (cons 'value value)))))
           (run (multihost-create-run spec (list host)))
           (saved-host (multihost-job-host (car (multihost-run-jobs run)))))
      (aset name 0 ?X)
      (aset connection 0 ?X)
      (aset group 0 ?X)
      (aset body 0 ?X)
      (aset value 0 ?X)
      (setf (multihost-host-groups host) nil)
      (should (equal (multihost-host-name saved-host) "web"))
      (should (equal (multihost-host-connection saved-host) "ssh-web"))
      (should (equal (multihost-host-groups saved-host) '("production")))
      (should (equal (plist-get (multihost-run-spec run) :body) "printf original"))
      (should (equal (cddr (assq :var (plist-get (multihost-run-spec run) :params))) "original")))))

(ert-deftest multihost-engine-literal-tramp-selector-audit-roundtrip ()
  (multihost-engine-test--isolated
    (let* ((selector "/ssh:ops@web#2222:/srv/checks/")
           (hosts (multihost-select-hosts selector nil))
           (run (multihost-create-run (multihost-engine-test--spec) hosts))
           (job (car (multihost-run-jobs run))))
      (setf (multihost-job-status job) 'succeeded
            (multihost-job-exit-code job) 0
            (multihost-job-stdout job) "healthy\n"
            (multihost-run-state run) 'finished
            (multihost-run-ended-at run) (float-time))
      (multihost-save-run run)
      (let* ((reloaded (multihost-load-run (multihost-run-directory run)))
             (saved-job (car (multihost-run-jobs reloaded))))
        (should (equal (multihost-host-name (multihost-job-host saved-job)) selector))
        (should (equal (multihost-host-connection (multihost-job-host saved-job)) selector))
        (should (eq (multihost-job-status saved-job) 'succeeded))
        (should (equal (multihost-job-stdout saved-job) "healthy\n"))))))

(provide 'multihost-engine-test)
;;; multihost-engine-test.el ends here
