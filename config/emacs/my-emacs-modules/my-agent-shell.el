;;; my-agent-shell.el --- Agent shell configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Use Pi with agent-shell's viewport interface.
;; Map remote project paths through TRAMP; keep artifacts outside projects.
;; Nix provides the Emacs packages and the pi-acp adapter.

;;; Code:

(defvar my/agent-shell-directory
  (expand-file-name "~/work/agent-shell/" "/")
  "Local artifact root on the machine running Emacs.")

(defun my/agent-shell--dot-subdir (subdir)
  "Return local artifact path for SUBDIR without creating it.
Use an explicit local root even when the current directory is remote."
  (expand-file-name subdir my/agent-shell-directory))

(defvar my/agent-shell-transcript-directory
  (my/agent-shell--dot-subdir "transcripts/")
  "Local transcript root on the machine running Emacs.")

(defun my/agent-shell--transcript-file-path ()
  "Return a timestamped, randomized Markdown path under the local root.
Do not create files or directories; agent-shell writes its normal header.
Random names separate same-second sessions; skip existing Markdown paths."
  (let ((prefix (expand-file-name (format-time-string "%F-%H-%M-%S-")
                                  my/agent-shell-transcript-directory))
        path)
    (while (or (null path) (file-exists-p path) (file-symlink-p path))
      (setq path (concat (make-temp-name prefix) ".md")))
    path))

(use-package agent-shell
  :ensure nil
  :bind (:map agent-shell-viewport-edit-mode-map
              ("C-c C-y" . agent-shell-send-clipboard-image))
  :custom
  (agent-shell-dot-subdir-function #'my/agent-shell--dot-subdir)
  (agent-shell-transcript-file-path-function #'my/agent-shell--transcript-file-path)
  (agent-shell-preferred-agent-config 'pi)
  (agent-shell-prefer-viewport-interaction t)
  :config
  ;; Keep Linux clipboard-first: the upstream direct default uses X11 import.
  (when (eq system-type 'darwin)
    (define-key agent-shell-viewport-edit-mode-map (kbd "C-c C-s")
                #'agent-shell-send-screenshot)))

(use-package agent-shell-tramp
  :ensure nil
  :after agent-shell
  :config
  ;; The pinned TRAMP mode replaces the public transcript customization when
  ;; enabled.  Reassert our policy *after* it runs, including later toggles;
  ;; leave its path resolver in place for remote ACP/file operations.
  (add-hook 'agent-shell-tramp-mode-hook
            (lambda ()
              (setq agent-shell-transcript-file-path-function #'my/agent-shell--transcript-file-path)))
  (agent-shell-tramp-mode 1))

(defun my/agent-shell-gc-protect-in-flight-p (buffer)
  "Protect BUFFER while busy or waiting for permission/elicitation input.
If status cannot be determined, leave the session alone."
  (condition-case nil
      (memq (agent-shell-status :shell-buffer buffer) '(busy blocked))
    (error t)))

(defun my/agent-shell-gc-protect-queued-input-p (buffer)
  "Protect BUFFER while it holds unsent queued prompts."
  (map-elt (buffer-local-value 'agent-shell--state buffer) :pending-prompts))

(defun my/agent-shell-gc-protect-viewport-draft-p (buffer)
  "Protect BUFFER when its viewport holds an unsent draft.
Include drafts saved while peeking at a response in view mode."
  (when-let* ((viewport (agent-shell-viewport--buffer
                        :shell-buffer buffer :existing-only t)))
    (with-current-buffer viewport
      (or (and (derived-mode-p 'agent-shell-viewport-edit-mode)
               (not (string-empty-p (string-trim (buffer-string)))))
          (not (string-empty-p
                (string-trim (or (map-elt agent-shell-viewport--compose-snapshot
                                        :content)
                                 ""))))))))

(use-package agent-shell-gc
  :ensure nil
  :after agent-shell
  :custom
  (agent-shell-gc-idle-session-ttl (* 4 24 60 60))
  ;; Leave worktrees and branches intact: the pinned GC's worktree resolver
  ;; does not support our RPC and bare-source layouts.
  (agent-shell-gc-idle-worktree-ttl nil)
  (agent-shell-gc-delete-worktree-branch nil)
  (agent-shell-gc-dry-run nil)
  ;; Visibility alone does not protect an abandoned conversation.  Native
  ;; busy protection excludes blocked sessions; native draft protection only
  ;; checks the shell, not its viewport.
  (agent-shell-gc-session-protect-functions
   '(my/agent-shell-gc-protect-in-flight-p
     my/agent-shell-gc-protect-queued-input-p
     agent-shell-gc-protect-pending-input-p
     my/agent-shell-gc-protect-viewport-draft-p
     agent-shell-gc-protect-kept-p))
  :config
  (agent-shell-gc-mode 1))

(provide 'my-agent-shell)
;;; my-agent-shell.el ends here
