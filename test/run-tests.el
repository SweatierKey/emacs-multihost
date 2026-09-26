;;; run-tests.el --- Batch test entry point -*- lexical-binding: t; -*-
(require 'ert)
(setq load-prefer-newer t)
(let ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (dolist (file (directory-files directory t "-test\\.el\\'"))
    (unless (string-match-p "integration-test\\.el\\'" file)
      (load file nil t))))
(ert-run-tests-batch-and-exit)
