;;; demo-init.el --- Isolated UI demonstration -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

(let* ((root (file-name-directory (directory-file-name
                                   (file-name-directory (or load-file-name buffer-file-name)))))
       (runtime (expand-file-name ".runtime/" root)))
  (setq user-emacs-directory (expand-file-name "demo/emacs/" runtime)
        load-prefer-newer t)
  (make-directory user-emacs-directory t)
  (add-to-list 'load-path root)
  (dolist (package '("compat" "vertico" "marginalia"))
    (add-to-list 'load-path (expand-file-name (concat "demo-deps/" package) runtime)))
  (require 'vertico)
  (require 'marginalia)
  (vertico-mode 1)
  (marginalia-mode 1)
  (require 'ob-multihost)
  (ob-multihost-mode 1)
  (setq multihost-inventory-file (expand-file-name "demo/inventory.json" runtime)
        multihost-state-directory (expand-file-name "demo/state/" runtime)
        multihost-worker-init-file (expand-file-name "lab/worker-init.el" runtime)
        multihost-default-timeout 20
        multihost-default-concurrency 2
        org-confirm-babel-evaluate t
        org-src-preserve-indentation t
        org-startup-folded 'showall
        inhibit-startup-screen t
        ring-bell-function #'ignore
        make-backup-files nil
        auto-save-default nil
        create-lockfiles nil
        initial-scratch-message nil)
  (load-theme 'modus-vivendi t)
  (menu-bar-mode -1)
  (when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
  (find-file (expand-file-name "demo/start.org" runtime))
  (require 'server)
  (setq server-socket-dir (expand-file-name "demo/sockets/" runtime)
        server-name "multihost-demo")
  (make-directory server-socket-dir t)
  (set-file-modes server-socket-dir #o700)
  (server-start))

;;; demo-init.el ends here
