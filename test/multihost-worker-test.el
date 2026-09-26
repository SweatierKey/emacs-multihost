;;; multihost-worker-test.el --- Worker regression tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'multihost-worker)

(defun multihost-worker-test--execute (language body &optional params)
  (let ((multihost-worker--allow-local-execution t))
    (multihost-execute-spec
     (list :language language :body body :params (or params '((:results . "output"))))
     temporary-file-directory)))

(ert-deftest multihost-worker-shell-failure-is-not-lisp-success ()
  (let ((result (multihost-worker-test--execute
                 "sh" "printf before; printf problem >&2; exit 7")))
    (should (eq (plist-get result :status) 'failed))
    (should (eql (plist-get result :exit-code) 7))
    (should (equal (plist-get result :stdout) "before"))
    (should (equal (plist-get result :stderr) "problem"))))

(ert-deftest multihost-worker-warning-on-stderr-does-not-mean-failure ()
  (let ((result (multihost-worker-test--execute "bash" "printf ok; printf warning >&2")))
    (should (eq (plist-get result :status) 'succeeded))
    (should (equal (plist-get result :stderr) "warning"))
    (should (eql (plist-get result :exit-code) 0))))

(ert-deftest multihost-worker-variables-use-standard-babel-escaping ()
  (let* ((value "quoted ' value; $(printf INJECTION)")
         (result (multihost-worker-test--execute
                  "sh" "printf '%s' \"$example\""
                  (list '(:results . "output") (cons :var (cons 'example value))))))
    (should (eq (plist-get result :status) 'succeeded))
    (should (equal (plist-get result :stdout) value))))

(ert-deftest multihost-worker-python-output-and-exit-status ()
  (skip-unless (executable-find "python3"))
  (let ((result (multihost-worker-test--execute
                 "python" "import sys\nprint('hello')\nsys.stderr.write('bad')\nsys.exit(9)"
                 '((:results . "output") (:python . "python3")))))
    (should (eq (plist-get result :status) 'failed))
    (should (eql (plist-get result :exit-code) 9))
    (should (equal (plist-get result :stdout) "hello\n"))
    (should (equal (plist-get result :stderr) "bad"))))

(ert-deftest multihost-worker-python-value-preserves-babel-value ()
  (skip-unless (executable-find "python3"))
  (let ((result (multihost-worker-test--execute
                 "python" "return 6 * 7"
                 '((:results . "value") (:python . "python3")))))
    (should (eq (plist-get result :status) 'succeeded))
    (should (eql (plist-get result :value) 42))))

(ert-deftest multihost-worker-python-defaults-to-python3 ()
  (skip-unless (executable-find "python3"))
  (let ((result (multihost-worker-test--execute "python" "import sys\nprint(sys.version_info.major)")))
    (should (eq (plist-get result :status) 'succeeded))
    (should (equal (plist-get result :stdout) "3\n"))))

(ert-deftest multihost-worker-refuses-unsupported-or-unsafe-semantics ()
  (dolist (params '(((:session . "shared")) ((:async . "yes"))
                    ((:file . "/tmp/out")) ((:post . "run()"))
                    ((:cache . "yes")) ((:results . "value"))
                    ((:stdin . "a")) ((:cmdline . "--x"))
                    ((:eval . "never")) ((:results . (progn (error "no"))))))
    (should-error
     (multihost-worker-validate-spec (list :language "sh" :body "true" :params params))
     :type 'user-error))
  (should-error
   (multihost-worker-validate-spec '(:language "emacs-lisp" :body "(+ 1 2)"))
   :type 'user-error))

(ert-deftest multihost-worker-never-falls-back-to-local-execution ()
  (should-error
   (multihost-execute-spec '(:language "sh" :body "true" :params nil) "/tmp/")
   :type 'user-error))

(ert-deftest multihost-worker-json-preserves-params-without-reading-code ()
  (let* ((file (make-temp-file "multihost-json-"))
         (value '(:language "bash" :body "#.(error \"never read Lisp\")"
                            :params ((:var item . "quoted") (:var count . 2)
                                     (:result-type . output) (:result-params "output" "replace")))))
    (unwind-protect
        (progn
          (multihost-worker--write-json file (multihost-worker--encode-value value))
          (should (equal value (multihost-worker--decode-value (multihost-worker--read-json file))))
          (should (= (logand (file-modes file) #o777) #o600)))
      (delete-file file))))

(ert-deftest multihost-worker-advice-is-removed-after-error ()
  (let ((multihost-worker--allow-local-execution t))
    (multihost-execute-spec '(:language "python" :body "! syntax error"
                             :params ((:results . "output") (:python . "python3"))) "/tmp/"))
  (should-not (advice-member-p #'multihost-worker--capture-eval
                              'org-babel--shell-command-on-region)))

(ert-deftest multihost-worker-connection-error-does-not-publish-input-as-output ()
  (let ((multihost-worker--captures nil))
    (with-temp-buffer
      (insert "SECRET_SOURCE_BODY")
      (should-error
       (multihost-worker--capture-eval
        (lambda (&rest _) (error "SSH authentication failed")) "sh" "missing-error-buffer")))
    (should (equal (plist-get (car multihost-worker--captures) :stdout) ""))
    (should-not (plist-get (car multihost-worker--captures) :exit-code))))

(ert-deftest multihost-worker-tramp-minus-one-preserves-keyboard-quit ()
  (let ((multihost-worker--allow-local-execution t)
        interrupted)
    (cl-letf (((symbol-function 'org-babel--shell-command-on-region)
               (lambda (&rest _) -1)))
      (condition-case nil
          (multihost-execute-spec '(:language "sh" :body "sleep 10"
                                   :params ((:results . "output"))) "/tmp/")
        (quit (setq interrupted t))))
    (should interrupted)))

(provide 'multihost-worker-test)
;;; multihost-worker-test.el ends here
