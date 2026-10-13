;;; my-agent-shell.el --- Agent shell configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Use Pi with agent-shell's viewport interface.
;; Map remote project paths through TRAMP and keep remote transcripts local.
;; Nix provides the Emacs packages and the pi-acp adapter.

;;; Code:

(use-package agent-shell
  :ensure nil
  :custom
  (agent-shell-preferred-agent-config 'pi)
  (agent-shell-prefer-viewport-interaction t))

(use-package agent-shell-tramp
  :ensure nil
  :after agent-shell
  :config
  (agent-shell-tramp-mode 1))

(provide 'my-agent-shell)
;;; my-agent-shell.el ends here
