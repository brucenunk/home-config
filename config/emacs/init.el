;; -*- lexical-binding: t -*-

;; ============================================================================
;; Configuration Structure
;; ============================================================================
;;
;; This configuration follows the structure from protesilaos/dotfiles:
;;
;; - my-lisp/        Custom Elisp libraries (pure functions)
;;                   my-repo.el, my-git.el, my-worktree.el, my-task.el,
;;                   my-agent.el
;;
;; - my-emacs-modules/  Package configuration (use-package, keybindings)
;;                      my-emacs-ui.el, my-emacs-completion.el, my-emacs-editing.el,
;;                      my-emacs-denote.el
;;
;; Package Management:
;; - Nix provides Emacs, external packages, and tree-sitter grammars (see
;;   flake-modules/features/emacs.nix)
;; - use-package configures packages without installing them at runtime

(require 'cl-lib)

(declare-function eglot-format-buffer "eglot" ())
(declare-function eglot-managed-p "eglot" ())
(declare-function my/task-list-maybe-refresh-overlays "my-task-list" ())
(declare-function server-running-p "server" (&optional name))

(defvar eshell-scroll-to-bottom-on-input)
(defvar forge-add-default-sections)
(defvar forge-add-pullreq-refspec)

;; ============================================================================
;; Load Path Setup
;; ============================================================================

(mapc (lambda (dir)
        (add-to-list 'load-path (locate-user-emacs-file dir)))
      '("my-lisp" "my-emacs-modules"))

;; ============================================================================
;; Core Modules
;; ============================================================================

(require 'my-repo)
(require 'my-emacs-ui)
(require 'my-emacs-completion)
(require 'my-emacs-editing)
(require 'my-emacs-dictation)

;; ============================================================================
;; Startup Hooks
;; ============================================================================

;; ============================================================================
;; Languages & LSP
;; ============================================================================

;; Tree-sitter parser grammars are installed declaratively by Nix in
;; flake-modules/features/emacs.nix. Keep that curated grammar list aligned with the
;; tree-sitter-backed modes and language tooling configured here.
(use-package treesit
  :ensure nil)

(use-package eglot
  :ensure nil
  :preface
  ;; Keep this allowlist in sync with language servers installed by Nix.
  ;; Avoid a broad `prog-mode' hook: it makes Eglot noisy for modes without
  ;; a configured/available server.
  (defvar my/eglot-mode-server-executables
    '((bash-ts-mode . "bash-language-server")
      (go-ts-mode . "gopls")
      (jsonnet-mode . "jsonnet-language-server")
      (nix-ts-mode . "nixd")
      (python-mode . "pylsp")
      (python-ts-mode . "pylsp")
      (rego-mode . "regal")
      (terraform-mode . "terraform-ls")
      (yaml-mode . "yaml-language-server"))
    "Language server executables for modes where Eglot should auto-start.")
  (defun my/eglot-before-save-hook ()
    "Format buffer before save"
    (when (eglot-managed-p)
      (add-hook 'before-save-hook #'eglot-format-buffer t t)))
  (defun my/eglot-ensure-if-server-available ()
    "Start Eglot when the current mode has an available language server."
    (when-let ((server-executable (alist-get major-mode my/eglot-mode-server-executables)))
      (when (executable-find server-executable t)
        (eglot-ensure))))
  :hook
  (eglot-managed-mode . my/eglot-before-save-hook)
  ((bash-ts-mode go-ts-mode jsonnet-mode nix-ts-mode python-mode python-ts-mode
    rego-mode terraform-mode yaml-mode) . my/eglot-ensure-if-server-available)
  :custom
  (eglot-events-buffer-config '(:size 0) "Disable the events buffer")
  (eglot-connect-timeout 120 "Longer for servers like `gopls' to boot over TRAMP")
  (eglot-confirm-server-initiated-edits nil "Don't ask for confirmation")
  (eglot-autoshutdown t "Shutdown server when last managed buffer is killed")
  (eglot-sync-connect nil "Never block LSP connection attempts")
  (eglot-send-changes-idle-time 0.2 "Send data to the server faster"))

(use-package jsonnet-mode
  :ensure nil
  :after eglot
  :config
  (setq-default eglot-workspace-configuration
                '(:formatting (:StringStyle "double")))
  (add-to-list 'eglot-server-programs
	       `(jsonnet-mode . ("jsonnet-language-server" :initializationOptions
                                 (:enable_lint_diagnostics t
                                  :formatting (:StringStyle "double")
                                  :show_docstring_in_completion t)))))

(use-package nix-ts-mode
  :ensure nil
  :mode "\\.nix\\'")

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(nix-ts-mode . ("nixd" :initializationOptions
                                (:formatting (:command ["nixfmt"]))))))

(use-package python
  :ensure nil
  :after eglot
  :init
  (setq-default eglot-workspace-configuration
        (plist-put eglot-workspace-configuration
                   ':pylsp '(:plugins (:ruff (:enabled t :formatEnabled t))))))

(use-package rego-mode
  :ensure nil
  :after eglot
  :config
  (add-to-list 'eglot-server-programs
               '(rego-mode . ("regal" "language-server"))))

(use-package terraform-mode
  :ensure nil
  :after eglot
  :custom
  (terraform-format-on-save t)
  :config
  (add-to-list 'eglot-server-programs `(terraform-mode . ("terraform-ls" "serve"))))

(use-package yaml-mode
  :ensure nil
  :after eglot
  :config
  (unless (assq 'yaml-mode eglot-server-programs)
    (add-to-list 'eglot-server-programs
                 '(yaml-mode . ("yaml-language-server" "--stdio")))))

(use-package emacs
  :ensure nil
  :config
  (add-to-list 'auto-mode-alist
	       '("\\.go\\'" . go-ts-mode))
  (setq major-mode-remap-alist
	'((sh-mode . bash-ts-mode))))

;; ============================================================================
;; Remote Access & Shell
;; ============================================================================

(defvar my/tramp-connection-properties nil
  "Additional TRAMP connection properties configured by host adapters.")

(defvar my/tramp-remote-paths nil
  "Additional remote executable paths configured by host adapters.")

(use-package tramp
  :defer t
  :ensure nil
  :custom
  (tramp-default-method "sshx")
  (tramp-ssh-controlmaster-options (concat
  "-o ControlPath=/tmp/ssh-ControlPath-%%r@%%h:%%p "
  "-o ControlMaster=auto -o ControlPersist=yes") "Use ssh connection sharing")
  :config
  (dolist (property my/tramp-connection-properties)
    (add-to-list 'tramp-connection-properties property))
  (add-to-list 'backup-directory-alist
               (cons tramp-file-name-regexp nil))
  (dolist (path my/tramp-remote-paths)
    (add-to-list 'tramp-remote-path path))
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path)
  (setq remote-file-name-inhibit-locks t)
  (setq remote-file-name-inhibit-cache nil)
  (setq remote-file-name-inhibit-delete-by-moving-to-trash t)
  (setq tramp-verbose 2))

(use-package dired
  :ensure nil
  :hook ((dired-mode . dired-hide-details-mode)
         (dired-mode . auto-revert-mode))
  :config
  (setq delete-by-moving-to-trash t)
  (setq dired-dwim-target t)
  (setq dired-recursive-copies 'always)
  (setq dired-recursive-deletes 'always))

(use-package exec-path-from-shell
  :ensure nil
  :preface
  (defun my/exec-path-from-shell-initialize-deferred ()
    "Initialize shell PATH after startup when GUI or daemon sessions need it."
    (when (or (display-graphic-p) (daemonp))
      (run-with-idle-timer
       1 nil
       (lambda ()
         (exec-path-from-shell-initialize)))))
  :hook (emacs-startup . my/exec-path-from-shell-initialize-deferred))

(use-package flymake
  :ensure nil
  :hook emacs-lisp-mode)

;; ============================================================================
;; VCS & Projects
;; ============================================================================

(use-package envrc
  :ensure nil
  :custom
  (envrc-remote t)
  (envrc-supported-tramp-methods '(scp scpx ssh sshx))
  :config
  (add-hook 'envrc-mode-on-hook
            (lambda ()
              (when (eq envrc--status 'on)
                (setq-local process-environment
                            (cons (format "TMPDIR=%s" (temporary-file-directory))
                                  (cl-remove-if (lambda (s) (string-prefix-p "TMPDIR=" s))
                                                process-environment)))))))

(use-package magit
  :ensure nil
  :bind
  (("C-c f" . magit-file-dispatch)
   ("C-c g" . magit-dispatch))
  :hook (magit-mode . visual-line-mode)
  :init
  (setq forge-add-default-sections nil
        forge-add-pullreq-refspec nil))

(use-package forge
  :ensure nil
  :after magit)

(use-package project
  :ensure nil
  :after magit)

(use-package eshell
  :defer t
  :ensure nil
  :config
  (add-to-list 'eshell-modules-list 'eshell-tramp)
  (setq eshell-scroll-to-bottom-on-input t))

(use-package ghostel
  :ensure nil
  :commands (ghostel ghostel-mode ghostel-project ghostel-other)
  :custom
  (ghostel-shell (let ((fish (expand-file-name ".nix-profile/bin/fish"
                                               (or (getenv "HOME") "~"))))
                   (if (file-executable-p fish)
                       fish
                     shell-file-name)))
  (ghostel-kill-buffer-on-exit nil)
  (ghostel-max-scrollback (* 20 1024 1024))
  (ghostel-enable-osc52 t)
  :config
  (with-eval-after-load 'project
    (add-to-list 'project-switch-commands '(ghostel-project "Ghostel") t)))

(with-eval-after-load 'eshell
  (when (locate-library "ghostel-eshell")
    (with-demoted-errors "ghostel-eshell setup failed: %S"
      (require 'ghostel-eshell)
      (when (fboundp 'ghostel-eshell-visual-command-mode)
        (ghostel-eshell-visual-command-mode 1)))))

(use-package wgrep
  :defer t
  :ensure nil)

(use-package ediff
  :defer t
  :ensure nil
  :custom
  (ediff-window-setup-function #'ediff-setup-windows-plain))

(use-package bazel
  :defer t
  :ensure nil
  :custom
  (bazel-buildifier-before-save t))

;; Bazel manifest builds.
(add-to-list 'safe-local-variable-values
        '(compile-command . (format "cd %s && bazelisk run //manifests:render"
                                    (locate-dominating-file
                                     default-directory ".dir-locals.el"))))

(use-package server
  :ensure nil
  :config
  (unless (server-running-p)
    (server-start)))

;; ============================================================================
;; Domain Modules (task workflow)
;; ============================================================================

(require 'my-emacs-denote)

;; ============================================================================
;; Custom File
;; ============================================================================

(when (and custom-file (file-exists-p custom-file))
  (load custom-file))
