;; -*- lexical-binding: t -*-

(setq-default backup-inhibited t
	      create-lockfiles nil
              custom-file (expand-file-name "custom.el" user-emacs-directory)
	      inhibit-startup-message t
	      make-backup-files nil
	      native-comp-async-report-warnings-errors 'silent
	      use-short-answers t)

;; Keep package.el startup activation for Nix-provided package autoloads, but
;; leave package provisioning exclusively to Nix.
(setq package-archives nil)

(menu-bar-mode -1)
(scroll-bar-mode -1)
(tool-bar-mode -1)

(when (memq window-system '(ns))
  (add-to-list 'default-frame-alist '(fullscreen . maximized))
  (add-to-list 'default-frame-alist '(ns-transparent-titlebar . t))
  (setq frame-title-format "\n"))

(setq frame-resize-pixelwise t)
