;;; multihost-compgen.el --- Inert remote Bash completion queries -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Multihost contributors
;; Author: Multihost contributors
;; Version: 1.1.0
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/SweatierKey/emacs-multihost
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A connection worker invokes a fixed Bash program with positional data.
;; This is command-name and filename completion, not programmable Bash
;; completion.  Editor text is never evaluated as shell code.  Candidate
;; count and output bytes are bounded on the target before transfer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'multihost-inventory)

(defvar multihost-compgen--allow-local-execution nil
  "Internal unit-test binding; production queries require SSH destinations.")

(defconst multihost-compgen--script
  "LC_ALL=C; export LC_ALL
kind=$1; prefix=$2; limit=$3; maxbytes=$4
count=0; bytes=0
while IFS= read -r candidate; do
  [[ $candidate == \"$prefix\"* ]] || continue
  [[ $candidate != *[[:cntrl:]]* ]] || continue
  if [[ $kind == file ]]; then
    [[ -e $candidate || -L $candidate ]] || continue
    if [[ -d $candidate && $candidate != */ ]]; then candidate+=/; fi
  fi
  size=${#candidate}
  if (( count >= limit || bytes + size + 2 > maxbytes )); then
    printf 'T\\0'; exit 0
  fi
  printf 'C%s\\0' \"$candidate\"
  (( count += 1, bytes += size + 2 ))
done < <(if [[ $kind == command ]]; then compgen -c -- \"$prefix\"; else compgen -f -- \"$prefix\"; fi)
printf 'E\\0'
"
  "Fixed shell program.  Output records are C<candidate>, T or E, NUL-delimited.")

(defun multihost-compgen-execute (payload directory)
  "Return completion candidates for inert PAYLOAD in remote DIRECTORY.
PAYLOAD is a plist with :kind (command or file), :prefix (literal string),
:limit (default 200), and :max-bytes (default 65536).  Return :status,
:candidates, :truncated and :error.  Missing Bash, transport errors and
malformed replies are failures, not authoritative empty candidate lists.
Filenames containing control characters are outside this completion contract."
  (condition-case err
      (let* ((kind (plist-get payload :kind))
             (prefix (plist-get payload :prefix))
             (limit (or (plist-get payload :limit) 200))
             (maxbytes (or (plist-get payload :max-bytes) 65536)))
        (unless (memq kind '(command file)) (user-error "Completion kind must be command or file"))
        (unless (and (stringp prefix) (<= (string-bytes prefix) 4096)
                     (not (string-match-p "[[:cntrl:]]" prefix)))
          (user-error "Completion prefix must be a literal string without control characters, at most 4096 bytes"))
        (unless (and (integerp limit) (<= 1 limit 1000)
                     (integerp maxbytes) (<= 128 maxbytes 262144))
          (user-error "Completion limits must be 1..1000 candidates and 128..262144 bytes"))
        (unless multihost-compgen--allow-local-execution
          (multihost-inventory--remote directory))
        (let ((default-directory directory)
              (stderr (make-temp-file (expand-file-name "multihost-compgen-" temporary-file-directory))))
          (unwind-protect
              (with-temp-buffer
                (let ((code (process-file "env" nil (list (current-buffer) stderr) nil
                                          "-u" "BASH_ENV" "-u" "ENV" "bash" "--noprofile" "--norc"
                                          "-c" multihost-compgen--script "--"
                                          (symbol-name kind) prefix (number-to-string limit)
                                          (number-to-string maxbytes))))
                  (unless (eql code 0)
                    (error "Remote Bash completion failed (exit %s): %s" code
                           (with-temp-buffer
                             (insert-file-contents stderr nil 0 4096)
                             (string-trim (buffer-string)))))
                  (when (> (string-bytes (buffer-string)) (+ maxbytes 2))
                    (error "Remote completion exceeded the output limit"))
                  (let* ((records (split-string (buffer-string) "\0"))
                         (final (nth (- (length records) 2) records))
                         (items (butlast records 2)))
                    (unless (and (>= (length records) 2) (equal (car (last records)) "")
                                 (member final '("E" "T")) (<= (length items) limit)
                                 (cl-every (lambda (record)
                                             (and (string-prefix-p "C" record)
                                                  (> (length record) 1)
                                                  (string-prefix-p prefix (substring record 1))
                                                  (not (string-match-p "[[:cntrl:]]" record)))) items))
                      (error "Malformed remote completion response"))
                    (list :status 'succeeded
                          :candidates (delete-dups (mapcar (lambda (record) (substring record 1)) items))
                          :truncated (equal final "T") :error nil))))
            (when (file-exists-p stderr) (delete-file stderr)))))
    (error (list :status 'failed :candidates nil :truncated nil :error (error-message-string err)))))

(provide 'multihost-compgen)
;;; multihost-compgen.el ends here
