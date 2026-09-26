;;; multihost-completion.el --- Cached asynchronous fleet completion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Multihost contributors
;; Author: Multihost contributors
;; Version: 1.1.0
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/SweatierKey/emacs-multihost
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Call `multihost-completion-setup' with a local, non-evaluating resolver
;; returning (HOST-NAME . TRAMP-DIRECTORY) pairs.  Setup opens no connection.
;; `multihost-completion-refresh' explicitly opts this buffer into remote
;; queries; subsequent CAPF calls use cached data and debounce async requests.
;; Only simple unquoted command and filename prefixes are supported.  Shell
;; operators, quotes, substitutions, escapes, and options are refused rather
;; than guessed.  Candidate insertion is shell-quoted.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'multihost-inventory)
(declare-function multihost-connection-submit "multihost-connection"
                  (directory operation payload callback &rest keys))
(declare-function multihost-connection-cancel "multihost-connection" (request))

(defgroup multihost-completion nil "Remote command and filename completion." :group 'tools)
(defcustom multihost-completion-policy 'union
  "Combine confirmed candidates by union or complete-host intersection.
Intersection is unavailable while any host is pending, failed, or truncated."
  :type '(choice (const union) (const intersection)) :group 'multihost-completion)
(defcustom multihost-completion-cache-ttl 30
  "Seconds a remote completion response remains fresh."
  :type 'number :group 'multihost-completion)
(defcustom multihost-completion-debounce 0.15
  "Idle delay before a CAPF-triggered remote query is submitted."
  :type 'number :group 'multihost-completion)
(defcustom multihost-completion-timeout 20
  "Deadline in seconds for each completion request."
  :type 'number :group 'multihost-completion)
(defcustom multihost-completion-candidate-limit 200
  "Maximum candidates returned by each host."
  :type 'integer :group 'multihost-completion)
(defcustom multihost-completion-output-limit 65536
  "Maximum candidate bytes returned by each host."
  :type 'integer :group 'multihost-completion)
(defcustom multihost-completion-cache-size 128
  "Maximum exact-prefix cache entries retained in one buffer."
  :type 'integer :group 'multihost-completion)
(defcustom multihost-completion-pending-limit 8
  "Maximum queries awaiting remote replies in one buffer, across contexts."
  :type 'integer :group 'multihost-completion)

(defvar-local multihost-completion--context-function nil)
(defvar-local multihost-completion--enabled nil)
(defvar-local multihost-completion--targets nil)
(defvar-local multihost-completion--cache nil)
(defvar-local multihost-completion--generation 0)
(defvar-local multihost-completion--edit-generation 0)
(defvar-local multihost-completion--timer nil)
(defvar-local multihost-completion--scheduled-key nil)
(defvar-local multihost-completion--active-key nil)
(defvar-local multihost-completion--requests nil)
(defvar-local multihost-completion--pending-entries nil)
(defvar-local multihost-completion--status "Remote completion is disabled; run multihost-completion-refresh")

(cl-defstruct multihost-completion--entry created targets results pending requests)

(defun multihost-completion-enabled-p ()
  "Whether this buffer has opted into asynchronous remote completion."
  multihost-completion--enabled)

(defun multihost-completion-status ()
  "Return this buffer's current remote completion status, without querying.
Interactively, show that status in the echo area."
  (interactive)
  (when (called-interactively-p 'interactive)
    (message "%s" multihost-completion--status))
  multihost-completion--status)

(defun multihost-completion-results ()
  "Return ordered per-host response plists for the active prefix, without I/O.
Each entry is (HOST-NAME . RESULT); pending hosts have :status pending.
Errors remain associated with the host that reported them."
  (when-let ((entry (and multihost-completion--active-key
                         (gethash multihost-completion--active-key multihost-completion--cache))))
    (mapcar (lambda (target)
              (cons (car target) (copy-tree (or (cdr (assoc (car target) (multihost-completion--entry-results entry)))
                                               '(:status pending)))))
            (multihost-completion--entry-targets entry))))

(defun multihost-completion--display-text (value)
  "Render VALUE as inert single-line text, escaping control characters."
  (replace-regexp-in-string
   "[[:cntrl:]]" (lambda (character) (format "\\x%02x" (aref character 0)))
   (if (stringp value) (substring-no-properties value) (format "%S" value)) t t))

(defun multihost-completion-inspect ()
  "Display a read-only snapshot of this buffer's remote completion results.
Show per-host pending states, failures, truncation, and known candidates.
This command never resolves the current context or submits a request."
  (interactive)
  (let ((source (buffer-name))
        (status (multihost-completion-status))
        (key (copy-tree multihost-completion--active-key))
        (results (multihost-completion-results))
        (buffer (get-buffer-create "*Multihost completion*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Remote completion snapshot\n\nSource: "
                (multihost-completion--display-text source) "\n"
                (multihost-completion--display-text status) "\n")
        (when key
          (insert (format "Kind: %s; prefix: %s\n" (car key)
                          (multihost-completion--display-text (cadr key)))))
        (if (not results)
            (insert "\nNo active-prefix responses are cached.\n")
          (dolist (host results)
            (let* ((result (cdr host))
                   (candidates (and (eq (plist-get result :status) 'succeeded)
                                    (plist-get result :candidates))))
              (insert (format "\n%s: %s; %d candidates%s\n"
                              (multihost-completion--display-text (car host))
                              (plist-get result :status)
                              (length candidates)
                              (if (plist-get result :truncated) "; TRUNCATED" "")))
              (when (plist-get result :error)
                (insert "  Error: " (multihost-completion--display-text (plist-get result :error)) "\n"))
              (dolist (candidate candidates)
                (insert "  " (multihost-completion--display-text candidate) "\n")))))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buffer)
    buffer))

(defun multihost-completion--cancel-timer ()
  "Cancel a deferred query in this buffer."
  (when (timerp multihost-completion--timer) (cancel-timer multihost-completion--timer))
  (setq multihost-completion--timer nil multihost-completion--scheduled-key nil))

(defun multihost-completion--edited (&rest _)
  "Invalidate deferred UI work after a buffer edit, keeping exact-key caches."
  (cl-incf multihost-completion--edit-generation)
  (setq multihost-completion--active-key nil)
  (multihost-completion--cancel-timer))

(defun multihost-completion-disable ()
  "Stop scheduling remote completions in this buffer and discard its cache."
  (interactive)
  (multihost-completion--cancel-timer)
  (cl-incf multihost-completion--generation)
  (setq multihost-completion--enabled nil)
  (let ((requests multihost-completion--requests))
    (setq multihost-completion--requests nil multihost-completion--pending-entries nil)
    (when (fboundp 'multihost-connection-cancel)
      (dolist (request requests) (ignore-errors (multihost-connection-cancel request)))))
  (remove-hook 'completion-at-point-functions #'multihost-completion-at-point t)
  (remove-hook 'after-change-functions #'multihost-completion--edited t)
  (remove-hook 'kill-buffer-hook #'multihost-completion-disable t)
  (setq multihost-completion--active-key nil
        multihost-completion--cache (make-hash-table :test #'equal)
        multihost-completion--status "Remote completion is disabled; run multihost-completion-refresh"))

(defun multihost-completion-setup (context-function &optional enabled)
  "Install cached completion using connection-free CONTEXT-FUNCTION.
The resolver returns an ordered alist of unique names and SSH/TRAMP directories
for the source at point.  It must not execute header Lisp or open connections.
Setup performs no network traffic.  Optional ENABLED carries an existing
explicit opt-in into a related source edit buffer; otherwise refresh to opt in."
  (unless (functionp context-function) (user-error "Completion context must be a resolver function"))
  (multihost-completion-disable)
  (setq-local multihost-completion--context-function context-function
              multihost-completion--targets nil multihost-completion--enabled enabled)
  (when enabled
    (setq multihost-completion--status "Remote completion is enabled; refresh or use completion at point"))
  (add-hook 'completion-at-point-functions #'multihost-completion-at-point nil t)
  (add-hook 'after-change-functions #'multihost-completion--edited nil t)
  (add-hook 'kill-buffer-hook #'multihost-completion-disable nil t))

(defun multihost-completion--context ()
  "Resolve the current ordered destinations, without connecting."
  (unless multihost-completion--context-function (user-error "Configure Multihost completion for this buffer first"))
  (let ((targets (funcall multihost-completion--context-function)) names)
    (unless (and (proper-list-p targets) targets) (user-error "Completion requires at least one host"))
    (dolist (pair targets)
      (unless (and (consp pair) (multihost-inventory--text-p (car pair)) (stringp (cdr pair)))
        (user-error "Completion resolver must return (host-name . TRAMP-directory) pairs"))
      (when (member (car pair) names) (user-error "Duplicate completion host: %s" (car pair)))
      (push (car pair) names)
      (unless (tramp-tramp-file-p (cdr pair)) (user-error "Completion destinations must be explicit TRAMP directories"))
      (multihost-inventory--remote (cdr pair)))
    (unless (equal targets multihost-completion--targets)
      (multihost-completion--cancel-timer)
      (cl-incf multihost-completion--generation)
      (setq multihost-completion--cache (make-hash-table :test #'equal)
            multihost-completion--targets
            (mapcar (lambda (pair) (cons (copy-sequence (car pair)) (copy-sequence (cdr pair)))) targets)))
    multihost-completion--targets))

(defun multihost-completion--token ()
  "Return (START END KIND PREFIX) for a simple shell token at point.
Complex shell grammar is deliberately rejected without evaluating text."
  (let* ((end (point))
         (line (buffer-substring-no-properties (line-beginning-position) end)))
    (unless (and (string-match-p "\\`[A-Za-z0-9_./:+,%=@ \t-]*\\'" line)
                 (or (eolp) (looking-at-p "[ \t]")))
      (user-error "Completion supports simple unquoted tokens; quotes, escapes, operators and expansions are unsupported"))
    (let* ((start (save-excursion (skip-chars-backward "^ \t" (line-beginning-position)) (point)))
           (prefix (buffer-substring-no-properties start end))
           (before (string-trim (buffer-substring-no-properties (line-beginning-position) start)))
           (kind (if (or (not (string-empty-p before)) (string-match-p "/" prefix)) 'file 'command)))
      (when (and (eq kind 'file) (string-prefix-p "-" prefix))
        (user-error "Option completion is unsupported; use ./ for filenames beginning with -"))
      (list start end kind prefix))))

(defun multihost-completion--fresh-entry (key)
  "Return a fresh cached entry for KEY, otherwise nil."
  (when-let ((entry (gethash key multihost-completion--cache)))
    (if (or (multihost-completion--entry-pending entry)
            (< (- (float-time) (multihost-completion--entry-created entry)) multihost-completion-cache-ttl))
        entry
      (remhash key multihost-completion--cache)
      nil)))

(defun multihost-completion--prune (&optional reserve)
  "Prune expired/old completed entries, leaving RESERVE slots if possible."
  (unless (and (integerp multihost-completion-cache-size) (> multihost-completion-cache-size 0)
               (integerp multihost-completion-pending-limit) (> multihost-completion-pending-limit 0))
    (user-error "Completion cache and pending limits must be positive integers"))
  (let ((now (float-time)) completed)
    (maphash
     (lambda (key entry)
       (unless (multihost-completion--entry-pending entry)
         (if (>= (- now (multihost-completion--entry-created entry)) multihost-completion-cache-ttl)
             (remhash key multihost-completion--cache)
           (push (cons key (multihost-completion--entry-created entry)) completed))))
     multihost-completion--cache)
    (setq completed (sort completed (lambda (a b) (< (cdr a) (cdr b)))))
    (while (and completed (> (hash-table-count multihost-completion--cache)
                            (- multihost-completion-cache-size (or reserve 0))))
      (remhash (caar completed) multihost-completion--cache)
      (setq completed (cdr completed)))))

(defun multihost-completion--counts (entry)
  "Return (READY PENDING FAILED TRUNCATED) counts for ENTRY."
  (let ((ready 0) (failed 0) (truncated 0))
    (dolist (result (multihost-completion--entry-results entry))
      (if (eq (plist-get (cdr result) :status) 'succeeded)
          (progn (cl-incf ready) (when (plist-get (cdr result) :truncated) (cl-incf truncated)))
        (cl-incf failed)))
    (list ready (length (multihost-completion--entry-pending entry)) failed truncated)))

(defun multihost-completion--describe (entry)
  "Describe ENTRY without representing incomplete results as a complete fleet."
  (pcase-let ((`(,ready ,pending ,failed ,truncated) (multihost-completion--counts entry)))
    (format "Remote completion: %d/%d replied; %d pending, %d failed, %d truncated (%s)"
            ready (length (multihost-completion--entry-targets entry)) pending failed truncated
            multihost-completion-policy)))

(defun multihost-completion--receive (buffer generation key entry name _request result)
  "Store NAME's RESULT for ENTRY if BUFFER and its routing GENERATION survive."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and multihost-completion--enabled (= generation multihost-completion--generation)
                 (eq entry (gethash key multihost-completion--cache)))
        (unless (and (memq (plist-get result :status) '(succeeded failed timed-out cancelled))
                     (or (not (eq (plist-get result :status) 'succeeded))
                         (and (proper-list-p (plist-get result :candidates))
                              (<= (length (plist-get result :candidates)) multihost-completion-candidate-limit)
                              (cl-every (lambda (candidate)
                                          (and (stringp candidate) (not (string-empty-p candidate))
                                               (string-prefix-p (cadr key) candidate)
                                               (not (string-match-p "[[:cntrl:]]" candidate))))
                                        (plist-get result :candidates)))))
          (setq result '(:status failed :error "Malformed completion reply")))
        (setf (alist-get name (multihost-completion--entry-results entry) nil nil #'equal) result
              (multihost-completion--entry-pending entry)
              (delete name (multihost-completion--entry-pending entry)))
        (unless (multihost-completion--entry-pending entry)
          (setf (multihost-completion--entry-created entry) (float-time)))
        (when (equal key multihost-completion--active-key)
          (setq multihost-completion--status (multihost-completion--describe entry)))))))

(defun multihost-completion--request (key targets)
  "Submit one asynchronous request per TARGET in KEY's context."
  (multihost-completion--prune 1)
  (when (or (>= (length multihost-completion--pending-entries) multihost-completion-pending-limit)
              (>= (hash-table-count multihost-completion--cache) multihost-completion-cache-size))
    (user-error "Remote completion is busy; wait for pending prefixes or disable completion to cancel"))
  (require 'multihost-connection)
  (let* ((entry (make-multihost-completion--entry :created (float-time) :targets targets
                                                  :pending (mapcar #'car targets)))
         (generation multihost-completion--generation)
         (buffer (current-buffer))
         (remaining (length targets)))
    (push entry multihost-completion--pending-entries)
    (puthash key entry multihost-completion--cache)
    (setq multihost-completion--status (multihost-completion--describe entry))
    (dolist (target targets)
      (let* ((receive (apply-partially #'multihost-completion--receive buffer generation key entry (car target)))
             completed
             (callback (lambda (request result)
                       (unless completed
                         (setq completed t)
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (setq multihost-completion--requests (delq request multihost-completion--requests))
                             (when (zerop (cl-decf remaining))
                               (setq multihost-completion--pending-entries
                                     (delq entry multihost-completion--pending-entries)))))
                         (funcall receive request result)))))
        (condition-case err
            (let ((request (multihost-connection-submit
                            (cdr target) 'compgen
                            (list :kind (car key) :prefix (cadr key) :limit multihost-completion-candidate-limit
                                  :max-bytes multihost-completion-output-limit)
                            callback :timeout multihost-completion-timeout)))
              (unless completed (push request multihost-completion--requests))
              (push request (multihost-completion--entry-requests entry)))
          (error (funcall callback nil (list :status 'failed :error (error-message-string err)))))))
    entry))

(defun multihost-completion--deferred (buffer generation edit-generation key)
  "Submit KEY only if BUFFER and both generations still name its current text."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq multihost-completion--timer nil multihost-completion--scheduled-key nil)
      (when (and multihost-completion--enabled (= generation multihost-completion--generation)
                 (= edit-generation multihost-completion--edit-generation))
        (condition-case err
            (let* ((targets (multihost-completion--context))
                   (token (multihost-completion--token))
                   (current-key (list (nth 2 token) (nth 3 token))))
              (when (and (= generation multihost-completion--generation) (equal key current-key)
                         (not (multihost-completion--fresh-entry key)))
                (multihost-completion--request key targets)))
          (error (setq multihost-completion--status (error-message-string err))))))))

(defun multihost-completion-refresh ()
  "Explicitly allow remote completion queries in this buffer and refresh now.
Later CAPF invocations may schedule asynchronous requests until disabled."
  (interactive)
  (let* ((targets (multihost-completion--context))
         (token (multihost-completion--token))
         (key (list (nth 2 token) (nth 3 token))))
    (multihost-completion--cancel-timer)
    (setq multihost-completion--enabled t multihost-completion--active-key key)
    (add-hook 'completion-at-point-functions #'multihost-completion-at-point nil t)
    (add-hook 'after-change-functions #'multihost-completion--edited nil t)
    (add-hook 'kill-buffer-hook #'multihost-completion-disable nil t)
    ;; Replacing the entry makes late replies from the older refresh harmless.
    (let ((entry (multihost-completion--fresh-entry key)))
      (if (and entry (multihost-completion--entry-pending entry))
          (setq multihost-completion--status (multihost-completion--describe entry))
        (multihost-completion--request key targets)))
    (when (called-interactively-p 'interactive) (message "%s" (multihost-completion-status)))))

(defun multihost-completion--candidates (entry kind)
  "Return (INSERTION . ANNOTATION) pairs for ENTRY and token KIND."
  (let* ((targets (multihost-completion--entry-targets entry))
         (results (multihost-completion--entry-results entry))
         (counts (multihost-completion--counts entry))
         (complete (and (= (car counts) (length targets)) (zerop (nth 1 counts))
                        (zerop (nth 2 counts)) (zerop (nth 3 counts))))
         (present (make-hash-table :test #'equal)))
    (unless (memq multihost-completion-policy '(union intersection)) (user-error "Unknown completion policy"))
    (unless (and (eq multihost-completion-policy 'intersection) (not complete))
      (dolist (target targets)
        (let ((result (cdr (assoc (car target) results))))
          (when (eq (plist-get result :status) 'succeeded)
            (dolist (candidate (delete-dups (copy-sequence (plist-get result :candidates))))
              (puthash candidate (append (gethash candidate present) (list (car target))) present)))))
      (let (candidates)
        (maphash
         (lambda (candidate names)
           (when (or (eq multihost-completion-policy 'union) (= (length names) (length targets)))
             (let* ((safe (if (and (eq kind 'file) (string-prefix-p "-" candidate))
                              (concat "./" candidate) candidate))
                    (insertion (shell-quote-argument safe)))
               (push (cons insertion
                           (format " [%s; %d/%d hosts%s%s%s]"
                                   (string-join names ", ") (length names) (length targets)
                                   (if (> (nth 1 counts) 0) (format "; %d pending" (nth 1 counts)) "")
                                   (if (> (nth 2 counts) 0) (format "; %d failed" (nth 2 counts)) "")
                                   (if (> (nth 3 counts) 0) (format "; %d truncated" (nth 3 counts)) ""))) candidates))))
         present)
        (sort candidates (lambda (a b) (string< (car a) (car b))))))))

(defun multihost-completion-at-point ()
  "Offer cached remote candidates and, after opt-in, debounce missing queries.
This CAPF never performs synchronous remote I/O or prompts for authentication."
  (when multihost-completion--enabled
    (condition-case err
        (let* ((_targets (multihost-completion--context))
               (_pruned (multihost-completion--prune))
               (token (multihost-completion--token))
               (key (list (nth 2 token) (nth 3 token)))
               (entry (multihost-completion--fresh-entry key)))
          (setq multihost-completion--active-key key)
          (when (and (timerp multihost-completion--timer)
                     (not (equal key multihost-completion--scheduled-key)))
            (multihost-completion--cancel-timer))
          (unless (or entry (timerp multihost-completion--timer))
            (setq multihost-completion--timer
                  (run-at-time multihost-completion-debounce nil #'multihost-completion--deferred
                               (current-buffer) multihost-completion--generation
                               multihost-completion--edit-generation key)
                  multihost-completion--scheduled-key key
                  multihost-completion--status "Remote completion query scheduled"))
          (when entry (setq multihost-completion--status (multihost-completion--describe entry)))
          (let ((candidates (and entry (multihost-completion--candidates entry (nth 2 token)))))
            ;; Even an empty/pending remote table owns this supported context.
            ;; Falling through could misrepresent local commands as remote ones.
            (list (nth 0 token) (nth 1 token) (mapcar #'car candidates)
                  :annotation-function (lambda (candidate) (cdr (assoc candidate candidates)))
                  :exclusive t)))
      (error (setq multihost-completion--status (error-message-string err)) nil))))

(provide 'multihost-completion)
;;; multihost-completion.el ends here
