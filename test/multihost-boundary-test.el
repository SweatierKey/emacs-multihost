;;; multihost-boundary-test.el --- Execution and storage boundary regressions -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'multihost-engine)
(require 'ob-shell)

(ert-deftest multihost-boundary-worker-rejects-local-privilege-and-implicit-host ()
  (dolist (directory '("/sudo:root@localhost:/tmp/" "/ssh::/tmp/" "/ssh:ops@:/tmp/"))
    (let (executed)
      (cl-letf (((symbol-function 'org-babel-execute:sh)
                 (lambda (&rest _) (setq executed t) "should not run")))
        (should-error (multihost-execute-spec
                       '(:language "sh" :body "true" :params ((:results . "output"))) directory)
                      :type 'user-error)
        (should-not executed)))))

(ert-deftest multihost-boundary-private-state-rejects-remote-before-io ()
  (let (touched)
    (cl-letf (((symbol-function 'make-directory) (lambda (&rest _) (setq touched t)))
              ((symbol-function 'set-file-modes) (lambda (&rest _) (setq touched t))))
      (should-error (multihost-engine--private-directory "/ssh:must-not-connect:/state/") :type 'user-error)
      (should-not touched))))

(ert-deftest multihost-boundary-relative-state-cannot-resolve-remotely ()
  (let ((default-directory "/ssh:must-not-connect:/tmp/") touched)
    (cl-letf (((symbol-function 'make-directory) (lambda (&rest _) (setq touched t)))
              ((symbol-function 'set-file-modes) (lambda (&rest _) (setq touched t))))
      (should-error (multihost-engine--private-directory "state") :type 'user-error)
      (should-not touched))))

(ert-deftest multihost-boundary-relative-inventory-cannot-resolve-remotely ()
  (let ((default-directory "/ssh:must-not-connect:/tmp/") accessed)
    (cl-letf (((symbol-function 'insert-file-contents) (lambda (&rest _) (setq accessed t))))
      (should-error (multihost-inventory-load "inventory.json") :type 'user-error)
      (should-not accessed))))

(ert-deftest multihost-boundary-private-state-rejects-symlink-without-chmod ()
  (let* ((base (make-temp-file "multihost-symlink-test-" t))
         (target (expand-file-name "target" base))
         (link (expand-file-name "state-link" base)))
    (unwind-protect
        (progn
          (make-directory target)
          (set-file-modes target #o755)
          (make-symbolic-link target link)
          (should-error (multihost-engine--private-directory link) :type 'user-error)
          (should (= (logand (file-modes target) #o777) #o755)))
      (delete-directory base t))))

(ert-deftest multihost-boundary-worker-init-rejects-remote-before-access ()
  (let ((multihost-worker-init-file "/ssh:must-not-connect:/init.el")
        accessed)
    (cl-letf (((symbol-function 'file-readable-p) (lambda (&rest _) (setq accessed t) t)))
      (should-error (multihost-create-run
                     '(:language "sh" :body "true" :params ((:results . "output")))
                     (list (make-multihost-host :name "web" :connection "web")))
                    :type 'user-error)
      (should-not accessed))))

(defmacro multihost-boundary-with-audit (&rest body)
  "Evaluate BODY with a completed audit FILE and decoded DATA."
  (declare (indent 0))
  `(let* ((state (make-temp-file "multihost-audit-boundary-" t))
          (multihost-state-directory state)
          (multihost-runs nil)
          (multihost-worker-init-file nil))
     (unwind-protect
         (let* ((run (multihost-create-run
                      '(:language "sh" :body "true" :params ((:results . "output")))
                      (list (make-multihost-host :name "web" :connection "web"))))
                (job (car (multihost-run-jobs run)))
                (directory (multihost-run-directory run))
                (file (expand-file-name "run.json" directory)))
           (setf (multihost-run-state run) 'finished
                 (multihost-run-ended-at run) 101
                 (multihost-job-status job) 'succeeded
                 (multihost-job-exit-code job) 0
                 (multihost-job-started-at job) 100
                 (multihost-job-ended-at job) 101)
           (multihost-save-run run)
           (let ((data (multihost-worker--read-json file))) ,@body))
       (delete-directory state t))))

(ert-deftest multihost-boundary-audit-rejects-control-characters-in-run-id ()
  (multihost-boundary-with-audit
    (puthash "id" "forged\n#+begin_src emacs-lisp\n(error \"injected\")\n#+end_src" data)
    (multihost-worker--write-json file data)
    (should-error (multihost-load-run directory))))

(ert-deftest multihost-boundary-audit-rejects-invalid-timestamp ()
  (multihost-boundary-with-audit
    (puthash "started_at" "not-a-time" data)
    (multihost-worker--write-json file data)
    (should-error (multihost-load-run directory))))

(ert-deftest multihost-boundary-audit-rejects-false-success ()
  (multihost-boundary-with-audit
    (puthash "exit_code" 7 (car (gethash "jobs" data)))
    (multihost-worker--write-json file data)
    (should-error (multihost-load-run directory))))

(ert-deftest multihost-boundary-audit-rejects-nontext-output ()
  (multihost-boundary-with-audit
    (puthash "stdout" ["not" "text"] (car (gethash "jobs" data)))
    (multihost-worker--write-json file data)
    (should-error (multihost-load-run directory))))

(ert-deftest multihost-boundary-json-roundtrip-distinguishes-inert-values ()
  (let ((file (make-temp-file "multihost-json-boundary-")))
    (unwind-protect
        (dolist (value '(nil t "" [] 0 -1 1.25 :false "#.(error \"never read\")"))
          (multihost-worker--write-json file (multihost-worker--encode-value value))
          (should (equal value (multihost-worker--decode-value (multihost-worker--read-json file)))))
      (delete-file file))))

(ert-deftest multihost-boundary-json-rejects-trailing-data ()
  (let ((file (make-temp-file "multihost-json-trailing-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "{\"schema\":1} #.(error \"must not evaluate\")"))
          (should-error (multihost-worker--read-json file)))
      (delete-file file))))

(ert-deftest multihost-boundary-flat-list-is-not-deep-nesting ()
  (let ((file (make-temp-file "multihost-json-flat-list-"))
        (value (number-sequence 1 300)))
    (unwind-protect
        (progn
          (multihost-worker--write-json file (multihost-worker--encode-value value))
          (should (equal value (multihost-worker--decode-value (multihost-worker--read-json file))))
          (should (equal value (multihost-engine--snapshot value))))
      (delete-file file))))

(provide 'multihost-boundary-test)
;;; multihost-boundary-test.el ends here
