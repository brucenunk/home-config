;;; my-remote.el --- Remote connection helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/tramp-rpc-configure-managed-servers

;;   - my/tramp-rpc-load-managed-servers

;;   - my/envrc-local-tempdir

;;; Code:

(require 'cl-lib)

(defvar my/tramp-connection-properties nil
  "Additional TRAMP connection properties configured by host adapters.")

(defvar my/tramp-remote-paths nil
  "Additional remote executable paths configured by host adapters.")

(defvar my/tramp-rpc-managed-servers nil
  "Managed RPC servers as plists with :host, :user and :remoteBinaryPath.
Home Manager supplies these through tramp-rpc-managed-servers.json.")

;;;###autoload
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

;;;###autoload
(defun my/tramp-rpc-load-managed-servers ()
  "Read the Home Manager generated managed-server inventory."
  (let ((file (locate-user-emacs-file "tramp-rpc-managed-servers.json")))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (setq my/tramp-rpc-managed-servers
              (json-parse-buffer :object-type 'plist :array-type 'list
                                 :null-object nil))))))

;;;###autoload
(defun my/envrc-local-tempdir ()
  "Use the effective temporary directory after envrc enables a buffer."
  (when (eq envrc--status 'on)
    (setq-local process-environment
                (cons (format "TMPDIR=%s" (temporary-file-directory))
                      (cl-remove-if (lambda (s) (string-prefix-p "TMPDIR=" s))
                                    process-environment)))))

(provide 'my-remote)
;;; my-remote.el ends here