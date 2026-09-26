;;; multihost-integration-test.el --- Real loopback SSH tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run through tools/test-integration.sh.  These endpoints are normal SSHD
;; processes with separate ports/directories, but share one host and kernel.
;; No real inventory, personal credentials, or production servers are used.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'multihost-inventory)
(require 'multihost-engine)

(defvar multihost-integration--runs nil)

(defun multihost-integration--lab ()
  "Return the private fixture root, or skip outside the explicit lab."
  (unless (equal (getenv "MULTIHOST_INTEGRATION") "1")
    (ert-skip "Run tools/test-integration.sh to enable the private SSH lab"))
  (let ((directory (getenv "MULTIHOST_LAB_ROOT")))
    (should (and directory (file-directory-p directory)))
    (file-name-as-directory directory)))

(defmacro multihost-integration--with-lab (&rest body)
  "Execute BODY with isolated worker configuration and guaranteed cleanup."
  (declare (indent 0) (debug t))
  `(let* ((lab (multihost-integration--lab))
          (default-directory lab)
          (multihost-worker-init-file (expand-file-name "worker-init.el" lab))
          (multihost-integration--runs nil))
     (unwind-protect (progn ,@body)
       (dolist (run multihost-integration--runs)
         (unless (multihost-run-finished-p run)
           (multihost-cancel run))))))

(defun multihost-integration--host (role &optional explicit)
  "Return lab ROLE; EXPLICIT requests user and port instead of an alias."
  (let* ((lab (multihost-integration--lab))
         (port (if (equal role "web") 22261 22262))
         (prefix (if explicit
                     (format "/ssh:%s@127.0.0.1#%d:" (user-login-name) port)
                   (format "/ssh:mh-lab-%s:" role))))
    (make-multihost-host :name role
                         :connection (concat prefix (expand-file-name role lab) "/")
                         :groups '("lab"))))

(defun multihost-integration--spec (body &optional directory language)
  "Build an already expanded Babel specification for BODY."
  (list :language (or language "sh") :body body :directory directory
        :params '((:results . "output replace") (:result-params . ("output" "replace"))
                  (:session . "none"))))

(defun multihost-integration--start (body hosts &rest options)
  "Start BODY on HOSTS with engine OPTIONS and remember it for cleanup."
  (let ((run (apply #'multihost-start (multihost-integration--spec body)
                    hosts options)))
    (push run multihost-integration--runs)
    run))

(defun multihost-integration--wait (run &optional seconds)
  "Wait up to SECONDS for RUN without blocking Emacs timers."
  (let ((deadline (+ (float-time) (or seconds 25))))
    (while (and (not (multihost-run-finished-p run))
                (< (float-time) deadline))
      (accept-process-output nil 0.03))
    (should (multihost-run-finished-p run))
    run))

(defun multihost-integration--stamp (job label)
  "Read remote nanosecond timestamp LABEL from JOB output."
  (let ((text (multihost-job-stdout job)))
    (should (string-match (concat "^" label "=\\([0-9]+\\)$") text))
    (string-to-number (match-string 1 text))))

(defconst multihost-integration--clock-body
  "printf 'START=%s\\n' \"$(date +%s%N)\"\nsleep 1.2\nprintf 'END=%s\\n' \"$(date +%s%N)\"\ncat status.txt\n")

(ert-deftest multihost-integration-exit-code-and-output ()
  "Babel's returned Lisp value must not conceal a remote exit failure."
  (multihost-integration--with-lab
    (let* ((run (multihost-integration--start
                 "printf 'real-stdout\\n'; printf 'real-stderr\\n' >&2; exit 7"
                 (list (multihost-integration--host "web")) :timeout 15))
           (job (car (multihost-run-jobs (multihost-integration--wait run)))))
      (should (eq (multihost-job-status job) 'failed))
      (should (= (multihost-job-exit-code job) 7))
      (should (string-match-p "real-stdout" (multihost-job-stdout job)))
      (should (string-match-p "real-stderr" (multihost-job-stderr job))))))

(ert-deftest multihost-integration-parallel-overlap-and-responsive-parent ()
  "Measure overlap on the remote endpoints while parent timers continue."
  (multihost-integration--with-lab
    (let* ((ticks 0)
           (timer (run-at-time 0 0.04 (lambda () (cl-incf ticks)))))
      (unwind-protect
          (let* ((run (multihost-integration--start
                       multihost-integration--clock-body
                       (list (multihost-integration--host "web")
                             (multihost-integration--host "db"))
                       :concurrency 2 :timeout 15))
                 (jobs (multihost-run-jobs (multihost-integration--wait run))))
            (should (cl-every (lambda (job) (eq (multihost-job-status job) 'succeeded)) jobs))
            (should (< (apply #'max (mapcar (lambda (job) (multihost-integration--stamp job "START")) jobs))
                       (apply #'min (mapcar (lambda (job) (multihost-integration--stamp job "END")) jobs))))
            (should (> ticks 10))
            (message "Remote overlap %.3fs; parent timer ticks %d"
                     (/ (- (apply #'min (mapcar (lambda (job) (multihost-integration--stamp job "END")) jobs))
                           (apply #'max (mapcar (lambda (job) (multihost-integration--stamp job "START")) jobs)))
                        1000000000.0)
                     ticks)
            (should (string-match-p "role=web" (multihost-job-stdout (car jobs))))
            (should (string-match-p "role=db" (multihost-job-stdout (cadr jobs)))))
        (cancel-timer timer)))))

(ert-deftest multihost-integration-serial-preserves-selection-order ()
  "The reversed host selection must execute without overlap in that order."
  (multihost-integration--with-lab
    (let* ((run (multihost-integration--start
                 multihost-integration--clock-body
                 (list (multihost-integration--host "db")
                       (multihost-integration--host "web"))
                 :concurrency 1 :timeout 15))
           (jobs (multihost-run-jobs (multihost-integration--wait run))))
      (should (cl-every (lambda (job) (eq (multihost-job-status job) 'succeeded)) jobs))
      (should (equal (mapcar (lambda (job) (multihost-host-name (multihost-job-host job))) jobs)
                     '("db" "web")))
      (should (<= (multihost-integration--stamp (car jobs) "END")
                  (multihost-integration--stamp (cadr jobs) "START")))
      (message "Serial remote order db -> web; gap %.3fs"
               (/ (- (multihost-integration--stamp (cadr jobs) "START")
                     (multihost-integration--stamp (car jobs) "END"))
                  1000000000.0)))))

(ert-deftest multihost-integration-python-backend-runs-remotely ()
  "The second supported Babel interpreter also executes through TRAMP."
  (multihost-integration--with-lab
    (let* ((spec (multihost-integration--spec
                  "import os\nprint('PYTHON_SSH=' + os.environ['SSH_CONNECTION'])\nprint(open('status.txt').read().strip())"
                  nil "python"))
           (_ (push '(:python . "python3") (plist-get spec :params)))
           (run (multihost-start spec (list (multihost-integration--host "db")) :timeout 15))
           (_ (push run multihost-integration--runs))
           (job (car (multihost-run-jobs (multihost-integration--wait run)))))
      (should (eq (multihost-job-status job) 'succeeded))
      (should (= (multihost-job-exit-code job) 0))
      (should (string-match-p "PYTHON_SSH=127\\.0\\.0\\.1 [0-9]+ 127\\.0\\.0\\.1 22262"
                              (multihost-job-stdout job)))
      (should (string-match-p "role=db" (multihost-job-stdout job))))))

(ert-deftest multihost-integration-fail-fast-skips-queued-host ()
  (multihost-integration--with-lab
    (let ((marker (expand-file-name "db/fail-fast-started" lab)))
      (when (file-exists-p marker) (delete-file marker))
      (let* ((run (multihost-integration--start
                   "if grep -q role=web status.txt; then exit 7; fi\nprintf started > fail-fast-started"
                   (list (multihost-integration--host "web")
                         (multihost-integration--host "db"))
                   :concurrency 1 :fail-fast t :timeout 15))
             (jobs (multihost-run-jobs (multihost-integration--wait run))))
        (should (eq (multihost-job-status (car jobs)) 'failed))
        (should (eq (multihost-job-status (cadr jobs)) 'skipped))
        (should-not (multihost-job-started-at (cadr jobs)))
        (should-not (file-exists-p marker))))))

(ert-deftest multihost-integration-retry-failed-only ()
  (multihost-integration--with-lab
    (with-temp-file (expand-file-name "web/retry-state" lab) (insert "fail\n"))
    (with-temp-file (expand-file-name "db/retry-state" lab) (insert "pass\n"))
    (let* ((run (multihost-integration--start
                 "cat status.txt\nif grep -q fail retry-state; then exit 7; fi\nprintf recovered"
                 (list (multihost-integration--host "web")
                       (multihost-integration--host "db"))
                 :concurrency 2 :timeout 15))
           (jobs (multihost-run-jobs (multihost-integration--wait run))))
      (should (equal (mapcar #'multihost-job-status jobs) '(failed succeeded)))
      (with-temp-file (expand-file-name "web/retry-state" lab) (insert "pass\n"))
      (let* ((retry (multihost-retry-failed run))
             (_ (push retry multihost-integration--runs))
             (retried (multihost-run-jobs (multihost-integration--wait retry))))
        (should (= (length retried) 1))
        (should (equal (multihost-host-name (multihost-job-host (car retried))) "web"))
        (should (eq (multihost-job-status (car retried)) 'succeeded))
        (should (eq (multihost-job-status (car jobs)) 'failed))))))

(ert-deftest multihost-integration-timeout-without-queued-execution ()
  (multihost-integration--with-lab
    (let ((marker (expand-file-name "db/timeout-started" lab)))
      (when (file-exists-p marker) (delete-file marker))
      (let* ((began (float-time))
             (run (multihost-integration--start
                   "if grep -q role=db status.txt; then printf started > timeout-started; fi\nsleep 5"
                   (list (multihost-integration--host "web")
                         (multihost-integration--host "db"))
                   :concurrency 1 :timeout 1.5 :fail-fast t))
             (jobs (multihost-run-jobs (multihost-integration--wait run 8))))
        (should (eq (multihost-job-status (car jobs)) 'timed-out))
        (should (eq (multihost-job-status (cadr jobs)) 'skipped))
        (should (< (- (float-time) began) 6))
        (should-not (file-exists-p marker))))))

(ert-deftest multihost-integration-cancel-without-queued-execution ()
  (multihost-integration--with-lab
    (let ((marker (expand-file-name "db/cancel-started" lab)))
      (when (file-exists-p marker) (delete-file marker))
      (let ((run (multihost-integration--start
                  "if grep -q role=db status.txt; then printf started > cancel-started; fi\nsleep 5"
                  (list (multihost-integration--host "web")
                        (multihost-integration--host "db"))
                  :concurrency 1 :timeout 15)))
        (accept-process-output nil 0.2)
        (multihost-cancel run)
        (multihost-integration--wait run 5)
        (should (cl-every (lambda (job) (memq (multihost-job-status job) '(cancelled skipped)))
                          (multihost-run-jobs run)))
        (should-not (multihost-job-started-at (cadr (multihost-run-jobs run))))
        (should-not (file-exists-p marker))))))

(ert-deftest multihost-integration-explicit-user-port-cwd-no-local-fallback ()
  "The command must run through SSH in the requested remote directory."
  (multihost-integration--with-lab
    (let* ((run (multihost-integration--start
                 "printf 'CWD=%s\\n' \"$(pwd)\"\nprintf 'SSH=%s\\n' \"$SSH_CONNECTION\"\ncat status.txt"
                 (list (multihost-integration--host "web" t)) :timeout 15))
           (job (car (multihost-run-jobs (multihost-integration--wait run))))
           (output (multihost-job-stdout job)))
      (should (eq (multihost-job-status job) 'succeeded))
      (should (string-match-p (regexp-quote (concat "CWD=" (expand-file-name "web" lab))) output))
      (should (string-match-p "SSH=127\\.0\\.0\\.1 [0-9]+ 127\\.0\\.0\\.1 22261" output))
      (should (string-prefix-p (format "/ssh:%s@127.0.0.1#22261:" (user-login-name))
                               (multihost-job-directory job))))))

(ert-deftest multihost-integration-invalid-directory-fails-remotely ()
  (multihost-integration--with-lab
    (let* ((host (multihost-integration--host "web"))
           (_ (setf (multihost-host-connection host)
                    (concat (multihost-host-connection host) "does-not-exist/")))
           (run (multihost-integration--start "printf 'UNEXPECTED-LOCAL-FALLBACK'"
                                               (list host) :timeout 15))
           (job (car (multihost-run-jobs (multihost-integration--wait run)))))
      (should (eq (multihost-job-status job) 'failed))
      (should-not (string-match-p "UNEXPECTED-LOCAL-FALLBACK" (multihost-job-stdout job))))))

(provide 'multihost-integration-test)
;;; multihost-integration-test.el ends here
