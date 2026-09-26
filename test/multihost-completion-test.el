;;; multihost-completion-test.el --- Safe remote completion contracts -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'multihost-completion)
(require 'multihost-compgen)
(require 'multihost-connection)

(defmacro multihost-completion-test--buffer (text &rest body)
  "Evaluate BODY in a configured TEXT buffer with a fake async connection pool."
  (declare (indent 1))
  `(let ((requests nil) (cancelled nil)
         (targets '(("web" . "/ssh:web:/srv/") ("db" . "/ssh:db:/srv/")))
         (multihost-completion-debounce 60))
     (cl-letf (((symbol-function 'multihost-connection-submit)
                (lambda (directory operation payload callback &rest _)
                  (let ((request (list :id (make-symbol "request") :directory directory
                                       :operation operation :payload payload :callback callback)))
                    (setq requests (append requests (list request)))
                    request)))
               ((symbol-function 'multihost-connection-cancel)
                (lambda (request) (push request cancelled))))
       (with-temp-buffer
         (insert ,text)
         (multihost-completion-setup (lambda () targets))
         ,@body))))

(defun multihost-completion-test--reply (request &rest result)
  "Deliver RESULT from the fake REQUEST."
  (funcall (plist-get request :callback) request result))

(ert-deftest multihost-completion-explicit-opt-in-and-pending-dedup ()
  (multihost-completion-test--buffer "sys"
    (should-not (multihost-completion-enabled-p))
    (should-not (multihost-completion-at-point))
    (should-not requests)
    (cl-letf (((symbol-function 'process-file) (lambda (&rest _) (ert-fail "CAPF used synchronous remote I/O"))))
      (multihost-completion-refresh)
      (should (= (length requests) 2))
      (dotimes (_ 4)
        (let ((capf (multihost-completion-at-point)))
          (should-not (nth 2 capf))
          (should (eq (plist-get (nthcdr 3 capf) :exclusive) t))))
      (let ((multihost-completion-cache-ttl 0))
        (multihost-completion-refresh)
        (multihost-completion-at-point)
        (should (= (length requests) 2))))))

(ert-deftest multihost-completion-inherited-opt-in-opens-no-connection ()
  (multihost-completion-test--buffer "sys"
    (multihost-completion-setup (lambda () targets) t)
    (should (multihost-completion-enabled-p))
    (should-not requests)
    (multihost-completion-at-point)
    (should-not requests)
    (should (timerp multihost-completion--timer))))

(ert-deftest multihost-completion-inspect-is-a-pure-per-host-snapshot ()
  (multihost-completion-test--buffer "sys"
    (setq targets (append targets '(("cache" . "/ssh:cache:/srv/"))))
    (multihost-completion-refresh)
    (multihost-completion-test--reply (nth 0 requests) :status 'succeeded :candidates '("systemctl") :truncated t)
    (multihost-completion-test--reply (nth 1 requests) :status 'failed :error "Bash unavailable\n\033[31m")
    (let ((original (current-buffer)) snapshot)
      (unwind-protect
          (cl-letf (((symbol-function 'multihost-connection-submit)
                     (lambda (&rest _) (ert-fail "Inspection submitted remote work")))
                    ((symbol-function 'process-file)
                     (lambda (&rest _) (ert-fail "Inspection queried a process")))
                    ((symbol-function 'display-buffer) #'ignore))
            (setq multihost-completion--context-function
                  (lambda () (ert-fail "Inspection resolved the current context")))
            (should (commandp 'multihost-completion-status))
            (should (string-match-p "1 pending, 1 failed, 1 truncated" (multihost-completion-status)))
            (setq snapshot (multihost-completion-inspect))
            (should (eq original (current-buffer)))
            (with-current-buffer snapshot
              (should (derived-mode-p 'special-mode))
              (should buffer-read-only)
              (should (string-match-p "web: succeeded; 1 candidates; TRUNCATED" (buffer-string)))
              (should (string-match-p "cache: pending" (buffer-string)))
              (should (string-match-p "db: failed" (buffer-string)))
              (should (string-match-p "systemctl" (buffer-string)))
              (should (string-match-p (regexp-quote "Bash unavailable\\x0a\\x1b[31m") (buffer-string)))
              (should-not (string-match-p "\033" (buffer-string)))))
        (when (buffer-live-p snapshot) (kill-buffer snapshot))))))

(ert-deftest multihost-completion-routing-changes-preserve-global-backpressure ()
  (multihost-completion-test--buffer "sys"
    (let ((multihost-completion-pending-limit 2))
      (multihost-completion-refresh)
      (setq targets '(("third" . "/ssh:third:/srv/")))
      (multihost-completion-refresh)
      (setq targets '(("fourth" . "/ssh:fourth:/srv/")))
      (should-error (multihost-completion-refresh) :type 'user-error)
      (should (= (length requests) 3))
      (should (= (length multihost-completion--pending-entries) 2))
      (should-not cancelled)
      ;; One old-generation reply cannot release a still-active fleet query.
      (multihost-completion-test--reply (nth 0 requests) :status 'succeeded :candidates '("sysctl"))
      (should-error (multihost-completion-refresh) :type 'user-error)
      (multihost-completion-test--reply (nth 1 requests) :status 'failed :error "Unavailable")
      (should (= (length multihost-completion--pending-entries) 1))
      (multihost-completion-refresh)
      (should (= (length requests) 4))
      (should-not (nth 2 (multihost-completion-at-point)))
      (should-not cancelled)
      (multihost-completion-disable)
      (should-not multihost-completion--pending-entries)
      (should (= (length cancelled) 2)))))

(ert-deftest multihost-completion-union-retains-host-origins-and-errors ()
  (multihost-completion-test--buffer "sys"
    (multihost-completion-refresh)
    (multihost-completion-test--reply (nth 0 requests) :status 'succeeded :candidates '("systemctl" "sysctl") :truncated nil)
    (multihost-completion-test--reply (nth 1 requests) :status 'failed :error "Bash is unavailable")
    (let* ((capf (multihost-completion-at-point))
           (annotate (plist-get (nthcdr 3 capf) :annotation-function)))
      (should (equal (nth 2 capf) '("sysctl" "systemctl")))
      (should (string-match-p "web; 1/2 hosts; 1 failed" (funcall annotate "systemctl")))
      (should (equal (plist-get (cdr (assoc "db" (multihost-completion-results))) :error) "Bash is unavailable")))))

(ert-deftest multihost-completion-intersection-requires-all-complete-hosts ()
  (multihost-completion-test--buffer "sys"
    (let ((multihost-completion-policy 'intersection))
      (multihost-completion-refresh)
      (multihost-completion-test--reply (nth 0 requests) :status 'succeeded :candidates '("systemctl" "sysctl") :truncated nil)
      (should-not (nth 2 (multihost-completion-at-point)))
      (multihost-completion-test--reply (nth 1 requests) :status 'succeeded :candidates '("systemctl" "sysfoo") :truncated nil)
      (should (equal (nth 2 (multihost-completion-at-point)) '("systemctl")))
      (multihost-completion-refresh)
      (multihost-completion-test--reply (nth 2 requests) :status 'succeeded :candidates '("systemctl") :truncated nil)
      (multihost-completion-test--reply (nth 3 requests) :status 'succeeded :candidates '("systemctl") :truncated t)
      (should-not (nth 2 (multihost-completion-at-point)))
      (should (string-match-p "1 truncated" (multihost-completion-status))))))

(ert-deftest multihost-completion-debounce-edits-and-stale-prefix-results ()
  (multihost-completion-test--buffer "sys"
    (multihost-completion-refresh)
    (insert "tem")
    (let ((generation multihost-completion--generation)
          (edit-generation multihost-completion--edit-generation))
      (multihost-completion-at-point)
      (should (timerp multihost-completion--timer))
      (insert "c")
      (should-not multihost-completion--timer)
      (multihost-completion--deferred (current-buffer) generation edit-generation '(command "system"))
      (should (= (length requests) 2)))
    (multihost-completion-test--reply (nth 0 requests) :status 'succeeded :candidates '("sysctl") :truncated nil)
    (multihost-completion-test--reply (nth 1 requests) :status 'succeeded :candidates '("sysctl") :truncated nil)
    (should-not (nth 2 (multihost-completion-at-point)))
    (should (equal multihost-completion--active-key '(command "systemc")))))

(ert-deftest multihost-completion-routing-change-rejects-late-replies ()
  (multihost-completion-test--buffer "sys"
    (multihost-completion-refresh)
    (setq targets '(("other" . "/ssh:other:/srv/")))
    (multihost-completion-at-point)
    (multihost-completion-test--reply (car requests) :status 'succeeded :candidates '("systemctl") :truncated nil)
    (should-not (nth 2 (multihost-completion-at-point)))
    (multihost-completion-disable)
    (should (= (length cancelled) 1))
    (should-not (memq #'multihost-completion-at-point completion-at-point-functions))
    (should-not multihost-completion--timer)))

(ert-deftest multihost-completion-killed-buffer-ignores-late-replies ()
  (let ((buffer (generate-new-buffer " *multihost-completion-killed*")) request callback cancelled)
    (cl-letf (((symbol-function 'multihost-connection-submit)
               (lambda (_directory _operation _payload cb &rest _) (setq request 'pending callback cb) request))
              ((symbol-function 'multihost-connection-cancel) (lambda (req) (setq cancelled req))))
      (with-current-buffer buffer
        (insert "sys")
        (multihost-completion-setup (lambda () '(("web" . "/ssh:web:/"))))
        (multihost-completion-refresh))
      (kill-buffer buffer)
      (should (eq cancelled 'pending))
      (should-not (funcall callback request '(:status succeeded :candidates ("systemctl")))))))

(ert-deftest multihost-completion-rejects-complex-context-without-traffic ()
  (dolist (text '("cat $(touch marker)" "cat 'file" "cat \"file" "cat file\\ name"
                  "cat a; rm" "cat /tmp/*" "echo x | gre" "cat -f" "cat ~/"))
    (multihost-completion-test--buffer text
      (should-error (multihost-completion-refresh) :type 'user-error)
      (should-not requests))))

(ert-deftest multihost-completion-token-boundaries-and-filename-kind ()
  (dolist (case '(("sys" command "sys") ("  sys" command "sys")
                  ("cat /var/lo" file "/var/lo") ("/usr/bi" file "/usr/bi")
                  ("cat " file "") ("printf ok\nsys" command "sys")))
    (with-temp-buffer
      (insert (car case))
      (let ((token (multihost-completion--token)))
        (should (eq (nth 2 token) (nth 1 case)))
        (should (equal (nth 3 token) (nth 2 case)))))))

(ert-deftest multihost-completion-filename-insertion-is-shell-quoted ()
  (multihost-completion-test--buffer "cat fi"
    (multihost-completion-refresh)
    (let ((name "file with spaces;$(printf should-not-run)'end"))
      (dolist (request requests)
        (multihost-completion-test--reply request :status 'succeeded :candidates (list name) :truncated nil))
      (let ((insertion (car (nth 2 (multihost-completion-at-point)))))
        (with-temp-buffer
          (should (zerop (call-process "bash" nil t nil "--noprofile" "--norc" "-c" (concat "printf '%s' " insertion))))
          (should (equal (buffer-string) name)))))))

(ert-deftest multihost-completion-leading-dash-file-is-an-operand ()
  (multihost-completion-test--buffer "cat "
    (multihost-completion-refresh)
    (dolist (request requests)
      (multihost-completion-test--reply request :status 'succeeded :candidates '("-rf") :truncated nil))
    (should (equal (nth 2 (multihost-completion-at-point)) '("./-rf")))))

(ert-deftest multihost-completion-cache-ttl-and-size-are-bounded ()
  (multihost-completion-test--buffer "sys"
    (let ((multihost-completion-cache-size 2) (multihost-completion-cache-ttl 30))
      (dolist (n '(1 2 3))
        (puthash (list 'command (number-to-string n))
                 (make-multihost-completion--entry :created (+ (float-time) n) :targets targets)
                 multihost-completion--cache))
      (multihost-completion--prune)
      (should (= (hash-table-count multihost-completion--cache) 2))
      (should-not (gethash '(command "1") multihost-completion--cache))
      (maphash (lambda (_key entry) (setf (multihost-completion--entry-created entry) (- (float-time) 31)))
               multihost-completion--cache)
      (multihost-completion--prune)
      (should (zerop (hash-table-count multihost-completion--cache))))))

(ert-deftest multihost-completion-backpressure-does-not-cancel-active-workers ()
  (multihost-completion-test--buffer "sys"
    (let ((multihost-completion-pending-limit 1))
      (multihost-completion-refresh)
      (insert "t")
      (should-error (multihost-completion-refresh) :type 'user-error)
      (should (= (length requests) 2))
      (should-not cancelled))))

(ert-deftest multihost-completion-malformed-host-response-is-not-authoritative ()
  (multihost-completion-test--buffer "sys"
    (multihost-completion-refresh)
    (multihost-completion-test--reply (car requests) :status 'succeeded :candidates '("sys\nmalicious"))
    (should (eq (plist-get (cdar (multihost-completion-results)) :status) 'failed))
    (should-not (nth 2 (multihost-completion-at-point)))))

(ert-deftest multihost-compgen-local-fixture-commands-and-files ()
  (skip-unless (executable-find "bash"))
  (let* ((directory (make-temp-file "multihost-compgen-fixture-" t))
         (default-directory (file-name-as-directory directory))
         (multihost-compgen--allow-local-execution t)
         (process-environment (cons (concat "PATH=" directory ":" (getenv "PATH")) process-environment)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "mh-fixture-command" directory) (insert "#!/bin/sh\nexit 0\n"))
          (set-file-modes (expand-file-name "mh-fixture-command" directory) #o700)
          (with-temp-file (expand-file-name "file with spaces" directory) (insert "fixture"))
          (make-directory (expand-file-name "file-dir" directory))
          (let ((commands (multihost-compgen-execute '(:kind command :prefix "mh-fixture-") default-directory))
                (files (multihost-compgen-execute '(:kind file :prefix "file") default-directory)))
            (should (eq (plist-get commands :status) 'succeeded))
            (should (member "mh-fixture-command" (plist-get commands :candidates)))
            (should (equal (sort (plist-get files :candidates) #'string<) '("file with spaces" "file-dir/")))))
      (delete-directory directory t))))

(ert-deftest multihost-compgen-prefix-is-data-never-shell-code ()
  (let* ((directory (make-temp-file "multihost-compgen-inert-" t))
         (marker (expand-file-name "MUST_NOT_EXIST" directory))
         (multihost-compgen--allow-local-execution t))
    (unwind-protect
        (dolist (prefix (list (concat "$(touch " marker ")") (concat "`; touch " marker "`")))
          (let ((result (multihost-compgen-execute (list :kind 'file :prefix prefix) (file-name-as-directory directory))))
            (should (eq (plist-get result :status) 'succeeded))
            (should-not (plist-get result :candidates))
            (should-not (file-exists-p marker))))
      (delete-directory directory t))))

(ert-deftest multihost-compgen-output-is-bounded-and-truncation-explicit ()
  (let* ((directory (make-temp-file "multihost-compgen-bounded-" t))
         (multihost-compgen--allow-local-execution t))
    (unwind-protect
        (progn
          (dotimes (n 8) (with-temp-file (expand-file-name (format "item-%d" n) directory) (insert "fixture")))
          (let ((result (multihost-compgen-execute '(:kind file :prefix "item" :limit 3) (file-name-as-directory directory))))
            (should (eq (plist-get result :status) 'succeeded))
            (should (= (length (plist-get result :candidates)) 3))
            (should (plist-get result :truncated))))
      (delete-directory directory t))))

(ert-deftest multihost-compgen-rejects-local-routing-and-invalid-data ()
  (should (eq (plist-get (multihost-compgen-execute '(:kind file :prefix "x") "/tmp/") :status) 'failed))
  (should (eq (plist-get (multihost-compgen-execute '(:kind file :prefix "x") "/sudo:root@localhost:/") :status) 'failed))
  (dolist (payload '((:kind eval :prefix "x") (:kind file :prefix "bad\n")
                      (:kind file :prefix "x" :limit 100000) (:kind file :prefix "x" :max-bytes 99999999)))
    (should (eq (plist-get (multihost-compgen-execute payload "/ssh:web:/") :status) 'failed))))

(ert-deftest multihost-compgen-absence-is-failure-not-empty-success ()
  (let ((multihost-compgen--allow-local-execution t))
    (cl-letf (((symbol-function 'process-file) (lambda (&rest _) 127)))
      (let ((result (multihost-compgen-execute '(:kind command :prefix "sys") temporary-file-directory)))
        (should (eq (plist-get result :status) 'failed))
        (should (string-match-p "127" (plist-get result :error)))))))

(provide 'multihost-completion-test)
;;; multihost-completion-test.el ends here
