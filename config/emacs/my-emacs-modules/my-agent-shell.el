;;; my-agent-shell.el --- Agent shell configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Use Pi with agent-shell's viewport interface.
;; Map remote project paths through TRAMP; keep all transcripts outside projects.
;; Nix provides the Emacs packages and the pi-acp adapter.

;;; Code:

(defvar my/agent-shell-transcript-directory
  (expand-file-name "~/work/agent-shell-transcripts/" "/")
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
  :custom
  (agent-shell-transcript-file-path-function #'my/agent-shell--transcript-file-path)
  (agent-shell-preferred-agent-config 'pi)
  (agent-shell-prefer-viewport-interaction t))

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

(provide 'my-agent-shell)
;;; my-agent-shell.el ends here
