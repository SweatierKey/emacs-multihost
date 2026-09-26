;;; multihost-ui-test.el --- Result and inventory UI contracts -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'multihost)
(require 'org-element)

(defun multihost-ui-test-job (name status exit stdout &optional stderr)
  "Construct a completed fixture job with NAME STATUS EXIT STDOUT STDERR."
  (make-multihost-job :id name :index 0
                      :host (make-multihost-host :name name :connection name)
                      :directory (format "/ssh:%s:~/" name)
                      :status status :exit-code exit :stdout stdout :stderr (or stderr "")
                      :started-at 100 :ended-at 101))

(defun multihost-ui-test-run (&rest jobs)
  "Construct a completed fixture run of JOBS."
  (make-multihost-run :id "ui-fixture" :jobs jobs :state 'finished :started-at 100 :ended-at 101))

(ert-deftest multihost-ui-render-preserves-failure-and-zero-exit ()
  (let* ((run (multihost-ui-test-run
               (multihost-ui-test-job "web" 'succeeded 0 "identical\n")
               (multihost-ui-test-job "db" 'failed 7 "identical\n" "failure\n")))
         (rendered (multihost-render-org run 'combined)))
    (should (string-match-p "| web | succeeded | 0 |" rendered))
    (should (string-match-p "| db | failed | 7 |" rendered))
    (should (string-match-p (regexp-quote ": [stderr]\n: failure") rendered))
    (should-not (string-match-p "exit unknown" rendered))))

(ert-deftest multihost-ui-digest-groups-complete-outcomes ()
  (let* ((run (multihost-ui-test-run
               (multihost-ui-test-job "one" 'succeeded 0 "same")
               (multihost-ui-test-job "two" 'succeeded 0 "same")
               (multihost-ui-test-job "three" 'failed 7 "same")
               (multihost-ui-test-job "four" 'succeeded 0 "same" "warning")))
         (text (multihost-render-org run 'digest)))
    (should (string-match-p "one, two · succeeded · exit 0" text))
    (should (string-match-p "three · failed · exit 7" text))
    (should (string-match-p "four · succeeded · exit 0" text))
    (should-not (string-match-p "one, two, three" text))))

(ert-deftest multihost-ui-output-cannot-inject-org-code-or-drawers ()
  (let* ((payload "good\n:END:\n#+begin_src emacs-lisp\n(error \"injected\")\n#+end_src\n* Forged heading\n\e[2J")
         (run (multihost-ui-test-run (multihost-ui-test-job "web" 'succeeded 0 payload))))
    (dolist (renderer '(digest per-host table combined))
      (with-temp-buffer
        (org-mode)
        (insert (multihost-render-org run renderer))
        (should-not (org-element-map (org-element-parse-buffer) '(src-block headline drawer) #'identity))
        (should-not (string-match-p "\e" (buffer-string)))))
    (should (string-match-p (regexp-quote "\\x1b[2J") (multihost-render-org run 'combined)))))

(ert-deftest multihost-ui-table-cells-cannot-add-columns ()
  (should (equal (multihost--cell "host|x\nrow\tmore\rfinal") "host¦x row more final")))

(ert-deftest multihost-ui-inventory-selection-keeps-inventory-order ()
  (with-temp-buffer
    (multihost-inventory-mode)
    (setq-local multihost--hosts (mapcar (lambda (name) (make-multihost-host :name name :connection name))
                                        '("web-2" "db-1" "web-1"))
                multihost--marks '("web-1" "web-2"))
    (multihost--inventory-refresh)
    (should (equal (mapcar #'multihost-host-name (multihost--selected-hosts)) '("web-2" "web-1")))
    (multihost-mark-all)
    (should (= (length (multihost--selected-hosts)) 3))
    (multihost-unmark-all)
    (should-not multihost--marks)))

(ert-deftest multihost-ui-per-host-and-combined-buffers ()
  (let* ((web (multihost-ui-test-job "web" 'succeeded 0 "WEB_ONLY"))
         (db (multihost-ui-test-job "db" 'failed 1 "DB_ONLY"))
         (run (multihost-ui-test-run web db))
         buffers)
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (push buffer buffers) buffer)))
          (let ((a (multihost--show-output run web "web"))
                (b (multihost--show-output run db "db"))
                (both (multihost--show-output run 'combined "all hosts")))
            (should-not (eq a b))
            (with-current-buffer a
              (should (string-match-p "WEB_ONLY" (buffer-string)))
              (should-not (string-match-p "DB_ONLY" (buffer-string)))
              (should buffer-read-only))
            (with-current-buffer b (should (string-match-p "DB_ONLY" (buffer-string))))
            (with-current-buffer both
              (should (string-match-p "WEB_ONLY" (buffer-string)))
              (should (string-match-p "DB_ONLY" (buffer-string))))))
      (mapc #'kill-buffer buffers))))

(ert-deftest multihost-ui-export-private-and-no-overwrite ()
  (let* ((dir (make-temp-file "multihost-export-test-" t))
         (file (expand-file-name "report.org" dir))
         (run (multihost-ui-test-run (multihost-ui-test-job "web" 'succeeded 0 "sensitive-output"))))
    (unwind-protect
        (with-temp-buffer
          (setq-local multihost--run run)
          (multihost-export file)
          (should (= (logand (file-modes file) #o777) #o600))
          (should (string-match-p "sensitive-output" (with-temp-buffer (insert-file-contents file) (buffer-string))))
          (should-error (multihost-export file) :type 'user-error)
          (should-error (multihost-export "/ssh:web:/tmp/report.org") :type 'user-error))
      (delete-directory dir t))))

(ert-deftest multihost-ui-per-host-view-shows-babel-value ()
  (let ((job (multihost-ui-test-job "python" 'succeeded 0 "")))
    (setf (multihost-job-value job) '(("check" "result") ("load" 42)))
    (with-temp-buffer
      (multihost-output-mode)
      (setq-local multihost--run (multihost-ui-test-run job) multihost--view job)
      (multihost--render-view)
      (should (string-match-p "42" (buffer-string)))
      (should (string-match-p "load" (buffer-string))))))

(ert-deftest multihost-ui-reload-retains-only-existing-marks ()
  (let* ((file (make-temp-file "multihost-inventory-reload-" nil ".json"))
         (multihost-inventory-file file))
    (unwind-protect
        (with-temp-buffer
          (multihost-inventory-mode)
          (setq-local multihost--hosts (list (make-multihost-host :name "old" :connection "old"))
                      multihost--marks '("old" "retained"))
          (with-temp-file file
            (insert "{\"version\":1,\"hosts\":[{\"name\":\"new\",\"connection\":\"new\"},{\"name\":\"retained\",\"connection\":\"retained\"}]}"))
          (multihost-reload-inventory)
          (should (equal (mapcar #'multihost-host-name multihost--hosts) '("new" "retained")))
          (should (equal multihost--marks '("retained"))))
      (delete-file file))))

(ert-deftest multihost-ui-relative-export-cannot-resolve-remotely ()
  (with-temp-buffer
    (setq-local multihost--run (multihost-ui-test-run (multihost-ui-test-job "web" 'succeeded 0 "private")))
    (let ((default-directory "/ssh:must-not-connect:/tmp/")
          (native-comp-enable-subr-trampolines nil)
          accessed)
      (cl-letf (((symbol-function 'file-exists-p) (lambda (&rest _) (setq accessed t) nil))
                ((symbol-function 'make-temp-file) (lambda (&rest _) (ert-fail "Export attempted remote file creation"))))
        (should-error (multihost-export "report.org") :type 'user-error)
        (should-not accessed)))))

(provide 'multihost-ui-test)
;;; multihost-ui-test.el ends here
