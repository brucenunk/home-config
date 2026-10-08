;;; my-emacs-remote.el --- Remote access configuration -*- lexical-binding: t -*-

;;; Commentary:

;; TRAMP defaults, release-only TRAMP-RPC deployment, and remote envrc support.
;; Nix owns package installation and bundles the Linux release servers.

;;; Code:

(require 'cl-lib)

(defvar my/tramp-connection-properties nil
  "Additional TRAMP connection properties configured by host adapters.")

(defvar my/tramp-remote-paths nil
  "Additional remote executable paths configured by host adapters.")

(defvar my/tramp-rpc-managed-servers nil
  "Managed RPC servers as plists with :host, :user and :remoteBinaryPath.
Home Manager supplies these through tramp-rpc-managed-servers.json.")

(let ((file (locate-user-emacs-file "tramp-rpc-managed-servers.json")))
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (setq my/tramp-rpc-managed-servers
            (json-parse-buffer :object-type 'plist :array-type 'list
                               :null-object nil)))))

(defun my/tramp-rpc-configure-managed-servers (servers)
  "Register exact-host connection-local deployment policy for SERVERS.
Only RPC connections match; unrelated hosts retain automatic deployment."
  ;; Connection-local variables can already be buffer-local in a visited
  ;; managed file. Upstream resolves a new target in that same buffer, so a
  ;; matching default profile must clear the old host's policy before applying
  ;; the new target's more specific profile. Register it first (lowest priority).
  (when servers
    (connection-local-set-profile-variables
     'my-tramp-rpc-unmanaged
     '((tramp-rpc-deploy-never-deploy . nil)
       (tramp-rpc-deploy-remote-binary-path . nil)))
    (connection-local-set-profiles
     '(:application tramp :protocol "rpc") 'my-tramp-rpc-unmanaged))
  (dolist (server servers)
    (let* ((host (plist-get server :host))
           (user (plist-get server :user))
           (profile (intern (format "my-tramp-rpc-managed-%S" (list host user))))
           (criteria (append (list :application 'tramp :protocol "rpc"
                                   :machine host)
                             (and user (list :user user)))))
      (connection-local-set-profile-variables
       profile `((tramp-rpc-deploy-never-deploy . t)
                 (tramp-rpc-deploy-remote-binary-path
                  . ,(plist-get server :remoteBinaryPath))))
      (connection-local-set-profiles criteria profile))))

(use-package tramp
  :defer t
  :ensure nil
  :custom
  (tramp-default-method "sshx")
  (tramp-ssh-controlmaster-options
   (concat "-o ControlPath=/tmp/ssh-ControlPath-%%r@%%h:%%p "
           "-o ControlMaster=auto -o ControlPersist=yes")
   "Use ssh connection sharing")
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

(use-package tramp-rpc
  :ensure nil
  :after tramp
  :demand t
  :init
  ;; Nil source-directory disables Cargo, including download-failure fallback.
  (setq tramp-rpc-deploy-source-directory nil
        tramp-rpc-deploy-prefer-build nil
        tramp-rpc-deploy-git-build-policy 'release
        tramp-rpc-deploy-auto-deploy t
        tramp-rpc-deploy-local-cache-directory
        (expand-file-name "~/.cache/emacs/tramp-rpc-binaries"))
  :config
  (my/tramp-rpc-configure-managed-servers my/tramp-rpc-managed-servers))

(use-package envrc
  :ensure nil
  :custom
  (envrc-remote t)
  (envrc-supported-tramp-methods '("scp" "scpx" "ssh" "sshx" "rpc"))
  :config
  (add-hook 'envrc-mode-on-hook
            (lambda ()
              (when (eq envrc--status 'on)
                (setq-local process-environment
                            (cons (format "TMPDIR=%s" (temporary-file-directory))
                                  (cl-remove-if (lambda (s) (string-prefix-p "TMPDIR=" s))
                                                process-environment)))))))

(provide 'my-emacs-remote)
;;; my-emacs-remote.el ends here