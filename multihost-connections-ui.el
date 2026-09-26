;;; multihost-connections-ui.el --- Inspect and prepare TRAMP connections -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; These views only read parent-side state.  Warm-up is explicit and runs in
;; the same asynchronous connection pool as execution and remote completion.

;;; Code:
(require 'multihost)
(require 'multihost-connection)

(defvar-local multihost-connections--timer nil)
(defvar-local multihost-connections--warmups nil)

(defun multihost-connections-refresh ()
  "Refresh the connection table without performing remote I/O."
  (interactive)
  (setq tabulated-list-entries
        (mapcar
         (lambda (row)
           (list (plist-get row :directory)
                 (vector (multihost--cell (plist-get row :directory))
                         (format "%s" (plist-get row :state))
                         (format "%s" (or (plist-get row :pid) "—"))
                         (format "%s" (or (plist-get row :queued) 0))
                         (format "%s" (or (plist-get row :completed) 0)))))
         (multihost-connection-snapshots)))
  (tabulated-list-print t))

(defun multihost-connections-close ()
  "Close the connection at point and cancel its outstanding requests."
  (interactive)
  (let ((directory (tabulated-list-get-id)))
    (unless directory (user-error "No connection at point"))
    (multihost-connection-reset directory)
    (multihost-connections-refresh)
    (message "Connection closed; verify any interrupted remote operation before retrying")))

(defun multihost-connections--stop-timer ()
  "Stop this view's refresh timer."
  (when (timerp multihost-connections--timer)
    (cancel-timer multihost-connections--timer))
  (setq multihost-connections--timer nil))

(defvar multihost-connections-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "g") #'multihost-connections-refresh)
    (define-key map (kbd "k") #'multihost-connections-close)
    map))

(define-derived-mode multihost-connections-mode tabulated-list-mode "Multihost-Connections"
  "Inspect persistent TRAMP workers.  g refreshes, k closes one connection."
  (setq tabulated-list-format [("Connection" 60 t) ("State" 14 t)
                               ("Worker PID" 12 nil) ("Queued" 8 nil) ("Completed" 10 nil)]
        header-line-format " g refresh · k close connection and cancel its requests · q quit")
  (tabulated-list-init-header)
  (add-hook 'kill-buffer-hook #'multihost-connections--stop-timer nil t)
  (add-hook 'change-major-mode-hook #'multihost-connections--stop-timer nil t))

;;;###autoload
(defun multihost-connections ()
  "Display existing pooled connections without starting any connection."
  (interactive)
  (let ((buffer (get-buffer-create "*Multihost connections*")))
    (with-current-buffer buffer
      (multihost-connections-mode)
      (multihost-connections-refresh)
      (setq multihost-connections--timer
            (run-at-time
             0.5 0.5
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (get-buffer-window buffer t)
                     (multihost-connections-refresh))))))))
    (pop-to-buffer buffer)))

(defun multihost-connections--refresh-warmups ()
  "Render current warm-up outcomes, including failures."
  (setq tabulated-list-entries
        (mapcar
         (lambda (row)
           (list (plist-get row :directory)
                 (vector (plist-get row :name)
                         (symbol-name (plist-get row :status))
                         (if (plist-get row :elapsed)
                             (format "%.3f" (plist-get row :elapsed)) "—")
                         (multihost--cell
                          (or (plist-get row :error) (plist-get row :directory))))))
         multihost-connections--warmups))
  (tabulated-list-print t))

(define-derived-mode multihost-warmup-mode tabulated-list-mode "Multihost-Connect"
  "Show asynchronous initialization results for selected hosts."
  (setq tabulated-list-format [("Host" 24 nil) ("Status" 14 nil)
                               ("Seconds" 10 nil) ("Connection / error" 60 nil)]
        header-line-format " Initialization runs outside this editor · M-x multihost-connections to inspect or close")
  (tabulated-list-init-header))

;;;###autoload
(defun multihost-warm-connections ()
  "Initialize selected inventory hosts asynchronously and retain connections."
  (interactive)
  (let* ((hosts (multihost--selected-hosts))
         (buffer (generate-new-buffer "*Multihost connect*"))
         (rows (mapcar (lambda (host)
                         (list :name (multihost-host-name host)
                               :directory (multihost-host-directory host)
                               :status 'pending :error nil :elapsed nil)) hosts)))
    (with-current-buffer buffer
      (multihost-warmup-mode)
      (setq-local multihost-connections--warmups rows)
      (multihost-connections--refresh-warmups))
    (pop-to-buffer buffer)
    (dolist (row rows)
      (let* ((started (float-time))
             (callback
              (lambda (_request result)
                (setf (plist-get row :status) (plist-get result :status)
                      (plist-get row :error) (plist-get result :error)
                      (plist-get row :elapsed) (- (float-time) started))
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (multihost-connections--refresh-warmups))))))
        (condition-case err
            (multihost-connection-warmup (plist-get row :directory) callback
                                        :timeout multihost-default-timeout)
          (error (funcall callback nil (list :status 'failed :error (error-message-string err)))))))))

(provide 'multihost-connections-ui)
;;; multihost-connections-ui.el ends here
