;;; multihost-inventory.el --- Ordered SSH inventories for Multihost -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Multihost contributors
;; Author: Multihost contributors
;; URL: https://github.com/SweatierKey/emacs-multihost
;; Version: 1.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: processes, tools
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Inventories are JSON data.  Loading and selecting hosts never evaluates
;; Lisp and never tests network connectivity.  SSH configuration and TRAMP
;; own credentials, routing, and host key verification.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tramp)

(define-error 'multihost-inventory-error "Invalid Multihost inventory" 'user-error)

(cl-defstruct multihost-host
  "An inventory endpoint, independent of execution state."
  name connection groups description)

(defconst multihost-inventory--ssh-methods '("ssh" "sshx" "scp" "scpx" "sftp")
  "TRAMP methods allowed to establish an SSH endpoint.")

(defun multihost-inventory--fail (format-string &rest args)
  "Signal an inventory error using FORMAT-STRING and ARGS."
  (signal 'multihost-inventory-error (list (apply #'format format-string args))))

(defun multihost-inventory--text-p (value)
  "Whether VALUE is a nonempty string without control characters."
  (and (stringp value) (not (string-empty-p value))
       (not (string-match-p "[[:cntrl:]]" value))))

(defun multihost-inventory--name-p (name)
  "Whether NAME is an unambiguous inventory name or SSH alias."
  (let ((case-fold-search nil))
    (and (stringp name)
         (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_.-]*\\'" name))))

(defun multihost-inventory--localname-p (name)
  "Whether NAME is an absolute or home-relative remote directory."
  (and (multihost-inventory--text-p name)
       (string-match-p "\\`[/~]" name)))

(defun multihost-inventory--remote (connection)
  "Return a validated remote directory for CONNECTION, without I/O.
CONNECTION is an SSH alias or an explicit TRAMP name.  Privilege methods
are allowed only after an explicit SSH hop.  Preserve the original hop
text: some TRAMP constructors otherwise move it into global proxy state."
  (unless (multihost-inventory--text-p connection)
    (multihost-inventory--fail "Connection must be a nonempty string without control characters"))
  (let* ((path (if (multihost-inventory--name-p connection)
                   (format "/ssh:%s:~/" connection)
                 connection))
         (vec (condition-case err
                  (and (string-prefix-p "/" path)
                       (tramp-tramp-file-p path)
                       (tramp-dissect-file-name path t))
                (error (multihost-inventory--fail "Invalid connection %S: %s"
                                                        connection (error-message-string err)))))
         ssh-seen)
    (unless vec
      (multihost-inventory--fail "Use an SSH alias or a complete TRAMP directory: %S" connection))
    (dolist (part (append
                  (mapcar (lambda (hop)
                            (condition-case err
                                (tramp-dissect-file-name (concat "/" hop ":") t)
                              (error (multihost-inventory--fail "Invalid SSH hop: %s"
                                                                      (error-message-string err)))))
                          (split-string (or (tramp-file-name-hop vec) "") "|" t))
                  (list vec)))
      (unless (multihost-inventory--text-p (tramp-file-name-host part))
        (multihost-inventory--fail "Every connection hop must have an explicit host"))
      (when (string-prefix-p "-" (tramp-file-name-host part))
        (multihost-inventory--fail "Connection hosts cannot begin with an option prefix"))
      (let ((port (tramp-file-name-port part)))
        (when (and port (not (and (string-match-p "\\`[0-9]+\\'" port)
                                 (<= 1 (string-to-number port) 65535))))
          (multihost-inventory--fail "Connection port must be between 1 and 65535")))
      (let ((method (tramp-file-name-method part)))
        (cond
         ((member method multihost-inventory--ssh-methods) (setq ssh-seen t))
         ((and ssh-seen (member method '("sudo" "doas"))))
         (t (multihost-inventory--fail "Unsupported or local-only TRAMP method: %s" method)))))
    (let ((localname (tramp-file-name-localname vec)))
      (unless (or (string-empty-p localname)
                  (multihost-inventory--localname-p localname))
        (multihost-inventory--fail "Remote directory must be absolute or begin with ~: %S" localname))
      (if (string-empty-p localname) (concat path "~/") path))))

(defun multihost-inventory--object (object allowed context)
  "Check JSON OBJECT keys against ALLOWED, reporting CONTEXT on failure."
  (unless (and (listp object) (cl-every #'consp object))
    (multihost-inventory--fail "%s must be a JSON object" context))
  (let (seen)
    (dolist (pair object)
      (let ((key (car pair)))
        (unless (member key allowed)
          (multihost-inventory--fail "Unknown %s field: %s" context key))
        (when (member key seen)
          (multihost-inventory--fail "Duplicate %s field: %s" context key))
        (push key seen)))))

(defun multihost-inventory-load (file)
  "Read FILE as a version 1 JSON inventory and return an ordered host list.
Reject unknown fields, duplicate names, and unsupported connections.
No Lisp is evaluated and no connection is opened.  Inventory files contain
connection names, groups and descriptions, never stored passwords."
  (unless (and (stringp file) (not (tramp-tramp-file-p file))
               (or (file-name-absolute-p file)
                   (not (tramp-tramp-file-p default-directory))))
    (multihost-inventory--fail "Inventory must be a local JSON file"))
  ;; Resolve ~ locally even when called from a remote Dired buffer.
  (setq file (expand-file-name file (if (file-name-absolute-p file) "/" default-directory)))
  (let* ((json-object-type 'alist)
         (json-array-type 'vector)
         (json-key-type 'string)
         (json-null :json-null)
         (json-false :json-false)
         (data (condition-case err
                   (with-temp-buffer
                     (insert-file-contents file)
                     (goto-char (point-min))
                     (prog1 (json-read)
                       (skip-chars-forward " \t\r\n")
                       (unless (eobp) (multihost-inventory--fail "Trailing data after inventory JSON"))))
                 (error (multihost-inventory--fail "Cannot read inventory %s: %s"
                                                         file (error-message-string err)))))
         names hosts)
    (multihost-inventory--object data '("version" "hosts") "inventory")
    (unless (equal (cdr (assoc "version" data)) 1)
      (multihost-inventory--fail "Inventory version must be 1"))
    (let ((entries (cdr (assoc "hosts" data))))
      (unless (and (vectorp entries) (> (length entries) 0))
        (multihost-inventory--fail "Inventory hosts must be a nonempty JSON array"))
      (seq-doseq (entry entries)
        (multihost-inventory--object entry '("name" "connection" "groups" "description") "host")
        (let ((name (cdr (assoc "name" entry)))
              (connection (cdr (assoc "connection" entry)))
              (groups (cdr (assoc "groups" entry)))
              (description (cdr (assoc "description" entry))))
          (unless (multihost-inventory--name-p name)
            (multihost-inventory--fail "Host name must match [A-Za-z0-9][A-Za-z0-9_.-]*: %S" name))
          (when (member name names)
            (multihost-inventory--fail "Duplicate host name: %s" name))
          (when (assoc "groups" entry)
            (unless (and (vectorp groups)
                         (cl-every #'multihost-inventory--name-p (append groups nil)))
              (multihost-inventory--fail "Groups for %s must be an array of names" name)))
          (when (assoc "description" entry)
            (unless (and (stringp description)
                         (not (string-match-p "[[:cntrl:]]" description)))
              (multihost-inventory--fail "Description for %s must be a string without control characters" name)))
          (multihost-inventory--remote connection)
          (push name names)
          (push (make-multihost-host :name name :connection connection
                                    :groups (delete-dups (append groups nil))
                                    :description description) hosts))))
    (nreverse hosts)))

(defun multihost-inventory--tokens (spec)
  "Normalize already evaluated SPEC into selector strings, never evaluating it."
  (cond
   ((null spec) nil)
   ((stringp spec)
    (when (string-match-p "[\000-\010\013\014\016-\037\177]" spec)
      (multihost-inventory--fail "Control character in selector"))
    (split-string spec "[ \t\r\n]+" t))
   ((vectorp spec) (apply #'append (mapcar #'multihost-inventory--tokens (append spec nil))))
   ((and (listp spec) (proper-list-p spec))
    (apply #'append (mapcar #'multihost-inventory--tokens spec)))
   (t (multihost-inventory--fail "Host selectors must be strings, lists, or vectors: %S" spec))))

(defun multihost-inventory--copy-host (host)
  "Return an independent snapshot of HOST."
  (make-multihost-host
   :name (copy-sequence (multihost-host-name host))
   :connection (copy-sequence (multihost-host-connection host))
   :groups (mapcar #'copy-sequence (multihost-host-groups host))
   :description (when (multihost-host-description host)
                  (copy-sequence (multihost-host-description host)))))

(defun multihost-inventory--match (selector inventory)
  "Resolve SELECTOR against INVENTORY, or signal a useful error."
  (let ((matches
         (cond
          ((and (null inventory) (string-prefix-p "/" selector))
           (multihost-inventory--remote selector)
           (list (make-multihost-host :name selector :connection selector)))
          ((string-prefix-p "@" selector)
           (unless inventory (multihost-inventory--fail "Group selectors require an inventory"))
           (cl-remove-if-not (lambda (host) (member (substring selector 1)
                                                   (multihost-host-groups host))) inventory))
          ((string-match-p "[*?[]" selector)
           (unless inventory (multihost-inventory--fail "Glob selectors require an inventory"))
           (let ((regexp (wildcard-to-regexp selector))
                 (case-fold-search nil))
             (cl-remove-if-not (lambda (host) (string-match-p regexp (multihost-host-name host))) inventory)))
          (inventory
           (let ((host (cl-find selector inventory :key #'multihost-host-name :test #'equal)))
             (when host (list host))))
          (t
           (multihost-inventory--remote selector)
           (list (make-multihost-host :name selector :connection selector))))))
    (unless matches (multihost-inventory--fail "Selector matches no hosts: %s" selector))
    matches))

(defun multihost-select-hosts (spec &optional inventory exclude)
  "Resolve SPEC to independent ordered host snapshots.
SPEC accepts strings, lists, or vectors already evaluated by Org.  Literal
names, @groups, and host-name globs expand left to right.  An inventory's
order is preserved inside each expansion; repeated hosts are kept once at
their first position.  !selector tokens and EXCLUDE apply globally after
inclusion.  Unknown selectors and empty selections are errors.
Without INVENTORY, only literal SSH aliases or full TRAMP names are valid."
  (let ((tokens (multihost-inventory--tokens spec))
        (exclusions (multihost-inventory--tokens exclude))
        selected names)
    (dolist (token tokens)
      (if (string-prefix-p "!" token)
          (push (substring token 1) exclusions)
        (dolist (host (multihost-inventory--match token inventory))
          (unless (member (multihost-host-name host) names)
            (push (multihost-host-name host) names)
            (push host selected)))))
    (dolist (token exclusions)
      (let ((excluded (mapcar #'multihost-host-name
                             (multihost-inventory--match
                              (string-remove-prefix "!" token) inventory))))
        (setq selected (cl-remove-if (lambda (host) (member (multihost-host-name host) excluded)) selected))))
    (unless selected (multihost-inventory--fail "Select at least one host"))
    (mapcar #'multihost-inventory--copy-host (nreverse selected))))

(defun multihost-host-directory (host &optional dir)
  "Return HOST's validated remote working directory, optionally overriding DIR.
DIR must be an absolute or home-relative path on the target host.  Remote
DIR values are rejected as ambiguous: put complete TRAMP routing in the
inventory connection.  Preserve user, port, method, and every explicit hop."
  (unless (multihost-host-p host)
    (multihost-inventory--fail "Expected a multihost-host endpoint"))
  (let* ((path (multihost-inventory--remote (multihost-host-connection host)))
         (localname (tramp-file-name-localname (tramp-dissect-file-name path t))))
    (when dir
      (unless (and (multihost-inventory--localname-p dir)
                   (not (tramp-tramp-file-p dir)))
        (multihost-inventory--fail ":dir must be a target-local absolute or ~ path; configure remote routing in the inventory"))
      (setq path (concat (substring path 0 (- (length path) (length localname))) dir)))
    (if (string-suffix-p "/" path) path (concat path "/"))))

(provide 'multihost-inventory)
;;; multihost-inventory.el ends here
