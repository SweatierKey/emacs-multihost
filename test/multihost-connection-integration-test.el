;;; multihost-connection-integration-test.el --- Persistent SSH evidence -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Opt-in tests use only tools/lab.py's two loopback SSH endpoints.  Separate
;; SSH_CONNECTION source ports identify separate SSH sessions (ControlMaster
;; is disabled by the fixture).  Timer delivery is a responsiveness proxy.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'multihost-connection)

(defun multihost-connection-test--lab ()
  "Return the explicitly enabled private lab directory."
  (unless (equal (getenv "MULTIHOST_INTEGRATION") "1")
    (ert-skip "Run the opt-in loopback SSH integration harness"))
  (let ((lab (getenv "MULTIHOST_LAB_ROOT")))
    (should (and lab (file-directory-p lab)))
    (file-name-as-directory lab)))

(defmacro multihost-connection-test--with-lab (&rest body)
  "Run BODY with isolated state and dispose of all background connections."
  (declare (indent 0) (debug t))
  `(let* ((lab (multihost-connection-test--lab))
          (default-directory lab)
          (multihost-state-directory (expand-file-name "connection-test-state" lab))
          (multihost-worker-init-file (expand-file-name "worker-init.el" lab))
          (multihost-connection-limit 4))
     (multihost-connection-reset)
     (unwind-protect (progn ,@body)
       (multihost-connection-reset))))

(defun multihost-connection-test--directory (lab role &optional alias)
  "Return ROLE's remote directory in LAB, optionally with ALIAS."
  (format "/ssh:%s:%s/" (or alias (concat "mh-lab-" role))
          (expand-file-name role lab)))

(defun multihost-connection-test--spec (body)
  "Build an expanded shell Babel specification for BODY."
  (list :language "sh" :body body
        :params '((:results . "output replace") (:result-params . ("output" "replace"))
                  (:session . "none"))))

(defun multihost-connection-test--until (predicate &optional seconds)
  "Deliver events until PREDICATE succeeds, within SECONDS."
  (let ((deadline (+ (float-time) (or seconds 25))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun multihost-connection-test--wait (request)
  "Wait for REQUEST's final result and return it."
  (multihost-connection-test--until (lambda () (multihost-request-ended-at request)))
  (multihost-request-result request))

(defun multihost-connection-test--execute (directory body &optional timeout)
  "Submit shell BODY in DIRECTORY with TIMEOUT."
  (multihost-connection-submit directory 'execute
                               (multihost-connection-test--spec body) nil
                               :timeout (or timeout 20)))

(defun multihost-connection-test--read (file)
  "Return local fixture FILE's contents."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun multihost-connection-test--write (file text &optional executable)
  "Write private fixture FILE with TEXT, optionally EXECUTABLE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text))
  (set-file-modes file (if executable #o700 #o600))
  file)

(defun multihost-connection-test--init (lab name forms)
  "Create trusted NAME worker configuration in LAB with additional FORMS."
  (let ((file (expand-file-name (concat "connection-fixtures/" name ".el") lab)))
    (multihost-connection-test--write
     file (mapconcat (lambda (form) (concat (prin1-to-string form) "\n"))
                     (cons `(load ,(expand-file-name "worker-init.el" lab) nil t) forms) ""))))

(defun multihost-connection-test--ssh-init (lab name prelude &optional extra-config)
  "Create worker config NAME whose SSH wrapper runs PRELUDE in LAB.
EXTRA-CONFIG precedes the generated private SSH configuration."
  (let* ((directory (expand-file-name (concat "connection-fixtures/" name "/") lab))
         (config (expand-file-name "ssh_config" directory))
         (wrapper (expand-file-name "ssh" directory)))
    (multihost-connection-test--write
     config (concat extra-config (multihost-connection-test--read (expand-file-name "ssh_config" lab))))
    (multihost-connection-test--write
     wrapper (concat "#!/bin/sh\n" prelude "\nexec /usr/bin/ssh -F "
                     (shell-quote-argument config) " \"$@\"\n") t)
    (multihost-connection-test--init
     lab name `((setq exec-path (cons ,directory exec-path))
                (setenv "PATH" (concat ,directory ":" (getenv "PATH")))))))

(ert-deftest multihost-connection-integration-reuses-worker-ssh-and-changes-cwd ()
  "Two directories on one host reuse the same child and actual SSH session."
  (multihost-connection-test--with-lab
    (let* ((directory (multihost-connection-test--directory lab "web"))
           (subdir (expand-file-name "web/pool-cwd" lab))
           (_ (make-directory subdir t))
           (body "printf 'SSH=%s\\n' \"$SSH_CONNECTION\"; printf 'CWD=%s\\n' \"$PWD\"")
           (first (multihost-connection-test--execute directory body))
           (one (multihost-connection-test--wait first))
           (second (multihost-connection-test--execute (concat directory "pool-cwd/") body))
           (two (multihost-connection-test--wait second)))
      (should (eq (plist-get one :status) 'succeeded))
      (should (eq (plist-get two :status) 'succeeded))
      (should (eq (multihost-request-worker first) (multihost-request-worker second)))
      (should (= (plist-get one :worker-pid) (plist-get two :worker-pid)))
      (let ((ssh-one (car (split-string (plist-get one :stdout) "\n")))
            (ssh-two (car (split-string (plist-get two :stdout) "\n"))))
        (should (string-match-p "^SSH=127\\.0\\.0\\.1 [0-9]+ 127\\.0\\.0\\.1 22261$" ssh-one))
        (should (equal ssh-one ssh-two)))
      (should (string-match-p (regexp-quote (concat "CWD=" subdir)) (plist-get two :stdout)))
      (message "Persistent worker %s: cold %.3fs, reused %.3fs (no speed threshold)"
               (plist-get one :worker-pid)
               (- (multihost-request-ended-at first) (multihost-request-started-at first))
               (- (multihost-request-ended-at second) (multihost-request-started-at second))))))

(ert-deftest multihost-connection-integration-single-connection-serializes-requests ()
  "Requests submitted together cannot execute simultaneously on one worker."
  (multihost-connection-test--with-lab
    (let* ((directory (multihost-connection-test--directory lab "web"))
           (marker (expand-file-name "web/pool-order" lab))
           (_ (when (file-exists-p marker) (delete-file marker)))
           (one (multihost-connection-test--execute
                 directory "printf 'first-start\\n' >> pool-order; sleep 0.3; printf 'first-end\\n' >> pool-order"))
           (two (multihost-connection-test--execute directory "printf 'second\\n' >> pool-order")))
      (should (eq (plist-get (multihost-connection-test--wait one) :status) 'succeeded))
      (should (eq (plist-get (multihost-connection-test--wait two) :status) 'succeeded))
      (should (eq (multihost-request-worker one) (multihost-request-worker two)))
      (should (equal (multihost-connection-test--read marker) "first-start\nfirst-end\nsecond\n")))))

(ert-deftest multihost-connection-integration-slow-authentication-delivers-parent-timers ()
  "Deliberate SSH startup delay occurs outside the parent event loop."
  (multihost-connection-test--with-lab
    (let* ((started (expand-file-name "connection-fixtures/slow-start" lab))
           (ended (expand-file-name "connection-fixtures/slow-end" lab))
           (multihost-worker-init-file
            (multihost-connection-test--ssh-init
             lab "slow"
             (format "case \" $* \" in *' -G '*) ;; *) date +%%s.%%N > %s; sleep 1.2; date +%%s.%%N > %s ;; esac"
                     (shell-quote-argument started) (shell-quote-argument ended))))
           ticks
           (timer (run-at-time 0 0.02 (lambda () (push (float-time) ticks)))))
      (dolist (file (list started ended)) (when (file-exists-p file) (delete-file file)))
      (unwind-protect
          (let* ((request (multihost-connection-warmup
                           (multihost-connection-test--directory lab "web") nil :timeout 20))
                 (result (multihost-connection-test--wait request))
                 (start (string-to-number (multihost-connection-test--read started)))
                 (end (string-to-number (multihost-connection-test--read ended)))
                 (during (cl-remove-if-not (lambda (tick) (< start tick end)) ticks)))
            (should (eq (plist-get result :status) 'succeeded))
            (should (> end start))
            (should (> (length during) 1))
            (let* ((points (sort ticks #'<))
                   (gaps (cl-loop for (left right) on points while right collect (- right left))))
              (message "SSH init sleep %.3fs: %d parent ticks during delay, max observed gap %.4fs"
                       (- end start) (length during) (apply #'max gaps))))
        (cancel-timer timer)))))

(ert-deftest multihost-connection-integration-denied-auth-does-not-block-healthy-host ()
  "One real SSH authentication refusal must not hide another host's output."
  (multihost-connection-test--with-lab
    (let* ((multihost-worker-init-file
            (multihost-connection-test--ssh-init
             lab "denied" ""
             "Host mh-lab-denied\n  HostName 127.0.0.1\n  Port 22261\n  User multihost-nonexistent-fixture-user\n"))
           (denied (multihost-connection-test--execute
                    (multihost-connection-test--directory lab "web" "mh-lab-denied")
                    "printf MUST-NOT-EXECUTE"))
           (healthy (multihost-connection-test--execute
                     (multihost-connection-test--directory lab "db") "cat status.txt"))
           (failure (multihost-connection-test--wait denied))
           (success (multihost-connection-test--wait healthy)))
      (should (eq (plist-get failure :status) 'failed))
      (should (stringp (plist-get failure :error)))
      (should-not (string-match-p "MUST-NOT-EXECUTE" (or (plist-get failure :stdout) "")))
      (should (eq (plist-get success :status) 'succeeded))
      (should (string-match-p "role=db" (plist-get success :stdout))))))

(ert-deftest multihost-connection-integration-cancel-active-and-queued-without-replay ()
  "Cancel an acknowledged command and queued work, then use a new connection."
  (multihost-connection-test--with-lab
    (let* ((directory (multihost-connection-test--directory lab "web"))
           (marker (expand-file-name "web/pool-once" lab))
           (queued-marker (expand-file-name "web/pool-queued" lab)))
      (dolist (file (list marker queued-marker)) (when (file-exists-p file) (delete-file file)))
      (let* ((active (multihost-connection-test--execute
                      directory "printf 'accepted\\n' >> pool-once; sleep 8"))
             (queued (multihost-connection-test--execute directory "printf forbidden > pool-queued")))
        (multihost-connection-test--until (lambda () (file-exists-p marker)))
        (let ((old-pid (process-id (multihost-request-process active))))
          (multihost-connection-cancel queued)
          (multihost-connection-cancel active)
          (should (eq (multihost-request-status active) 'cancelled))
          (should (eq (multihost-request-status queued) 'cancelled))
          (let ((next (multihost-connection-test--wait
                       (multihost-connection-test--execute directory "cat pool-once"))))
            (should (eq (plist-get next :status) 'succeeded))
            (should-not (= old-pid (plist-get next :worker-pid)))
            (should (equal (plist-get next :stdout) "accepted\n"))
            (should-not (file-exists-p queued-marker))))))))

(defun multihost-connection-test--completion-init (lab &optional no-bash)
  "Create per-host command fixtures and optional NO-BASH execution PATH."
  (let (forms)
    (dolist (role (if no-bash '("db") '("web" "db")))
      (let* ((bin (expand-file-name (concat role "/completion-bin") lab))
             (profile (intern (concat "multihost-test-" role))))
        (make-directory bin t)
        (multihost-connection-test--write
         (expand-file-name (concat "mh-fixture-" role) bin) "#!/bin/sh\nexit 0\n" t)
        (push `(connection-local-set-profile-variables
                ',profile '((tramp-remote-path . (,bin tramp-default-remote-path)))) forms)
        (push `(connection-local-set-profiles
                '(:application tramp :protocol "ssh" :machine ,(concat "mh-lab-" role)) ',profile) forms)))
    (when no-bash
      (let ((bin (expand-file-name "connection-fixtures/no-bash-bin" lab)))
        (make-directory bin t)
        ;; Keep normal TRAMP utilities available while env cannot resolve Bash.
        ;; These are local fixture symlinks, never changes to the system PATH.
        (dolist (path (directory-files "/usr/bin" t directory-files-no-dot-files-regexp))
          (unless (member (file-name-nondirectory path) '("bash" "rbash"))
            (let ((link (expand-file-name (file-name-nondirectory path) bin)))
              (unless (file-exists-p link) (make-symbolic-link path link t)))))
        (push `(connection-local-set-profile-variables
                'multihost-test-no-bash '((tramp-remote-path . (,bin)))) forms)
        (push '(connection-local-set-profiles
                '(:application tramp :protocol "ssh" :machine "mh-lab-web") 'multihost-test-no-bash) forms)))
    (multihost-connection-test--init lab (if no-bash "no-bash" "completion") (nreverse forms))))

(ert-deftest multihost-connection-integration-compgen-host-specific-files-programs ()
  "Completion uses each SSH host's working directory and configured PATH."
  (multihost-connection-test--with-lab
    (let ((multihost-worker-init-file (multihost-connection-test--completion-init lab)))
      (dolist (role '("web" "db"))
        (multihost-connection-test--write (expand-file-name (format "%s/mh-data-%s" role role) lab) "fixture\n"))
      (dolist (kind '(command file))
        (let* ((prefix (if (eq kind 'command) "mh-fixture-" "mh-data-"))
               (requests (mapcar
                          (lambda (role)
                            (multihost-connection-submit
                             (multihost-connection-test--directory lab role)
                             'compgen (list :kind kind :prefix prefix) nil :timeout 20))
                          '("web" "db"))))
          (cl-mapc
           (lambda (request role)
             (let ((result (multihost-connection-test--wait request)))
               (should (eq (plist-get result :status) 'succeeded))
               (should (equal (plist-get result :candidates) (list (concat prefix role))))))
           requests '("web" "db"))))
      (let* ((marker (expand-file-name "web/completion-injection" lab))
             (_ (when (file-exists-p marker) (delete-file marker)))
             (result (multihost-connection-test--wait
                      (multihost-connection-submit
                       (multihost-connection-test--directory lab "web") 'compgen
                       '(:kind file :prefix "$(touch completion-injection)") nil :timeout 20))))
        (should (eq (plist-get result :status) 'succeeded))
        (should-not (plist-get result :candidates))
        (should-not (file-exists-p marker))))))

(ert-deftest multihost-connection-integration-compgen-missing-bash-is-explicit-error ()
  "A real remote PATH without Bash returns an error, not an empty success."
  (multihost-connection-test--with-lab
    (let* ((multihost-worker-init-file (multihost-connection-test--completion-init lab t))
           (result (multihost-connection-test--wait
                    (multihost-connection-submit
                     (multihost-connection-test--directory lab "web") 'compgen
                     '(:kind command :prefix "ls") nil :timeout 20))))
      (should (eq (plist-get result :status) 'failed))
      (should (string-match-p "127" (plist-get result :error)))
      (should-not (plist-get result :candidates)))))

(provide 'multihost-connection-integration-test)
;;; multihost-connection-integration-test.el ends here
