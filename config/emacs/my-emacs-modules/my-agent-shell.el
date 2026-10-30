;;; my-agent-shell.el --- Agent shell configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Use Pi with agent-shell's viewport interface.
;; Map remote project paths through TRAMP; keep artifacts outside projects.
;; Nix provides the Emacs packages and the pi-acp adapter.

;;; Code:

(require 'cl-lib)

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

(defun my/agent-shell-compose-fontify (beg end loudly)
  "Apply Markdown faces between BEG and END without presentation changes.
LOUDLY is passed to Font Lock.  Preserve native viewport/attachment
properties and discard Markdown's hiding, display and mouse controls."
  (let ((composer (current-buffer)) original start)
    ;; Capture the *extended* region immediately before Font Lock clears it.
    ;; Only faces and parser metadata should change in a prompt composer.
    (let ((font-lock-unfontify-region-function
           (lambda (from to)
             ;; Native code highlighting also fontifies scratch buffers.
             (when (eq (current-buffer) composer)
               (setq start from
                     original (buffer-substring from to)))
             (font-lock-default-unfontify-region from to))))
      (unwind-protect
          (font-lock-default-fontify-region beg end loudly)
        (when original
          (with-silent-modifications
            (dolist (prop '(composition display invisible rear-nonsticky
                           keymap help-echo mouse-face))
              (let ((pos 0) (length (length original)))
                (while (< pos length)
                  (let ((next (next-single-property-change pos prop original length)))
                    (put-text-property (+ start pos) (+ start next) prop
                                       (get-text-property pos prop original))
                    (setq pos next)))))))))))

(defun my/agent-shell-compose-markdown ()
  "Fontify Markdown without replacing the native viewport editor.
Reuse the pinned `markdown-mode' syntax and font-lock setup only; do
not install its keymap, indentation, completion, or rendering modes."
  (require 'markdown-mode)
  (setq-local markdown-hide-markup nil
              markdown-fontify-code-blocks-natively t
              syntax-propertize-function #'markdown-syntax-propertize
              font-lock-fontify-region-function #'my/agent-shell-compose-fontify
              font-lock-defaults
              '(markdown-mode-font-lock-keywords
                nil nil nil nil
                (font-lock-multiline . t)
                (font-lock-syntactic-face-function . markdown-syntactic-face)))
  (add-hook 'syntax-propertize-extend-region-functions
            #'markdown-syntax-propertize-extend-region nil t)
  (add-hook 'jit-lock-after-change-extend-region-functions
            #'markdown-font-lock-extend-region-function t t)
  (add-hook 'font-lock-extend-region-functions
            #'markdown-font-lock-extend-region t t)
  (remove-from-invisibility-spec 'markdown-markup)
  (syntax-propertize (point-max)))

(add-hook 'agent-shell-viewport-edit-mode-hook #'my/agent-shell-compose-markdown)

(defun my/agent-shell-quote-region (&optional pick-shell)
  "Insert the active region as fenced diff into an editable prompt.
Use the most recently accessed shell in the current project, or offer
the native existing-shell chooser when none exists.  With prefix
PICK-SHELL, always offer the chooser.  Never start a shell or submit."
  (interactive "P")
  (unless (use-region-p)
    (user-error "No region selected"))
  ;; Capture before session selection can change the current buffer or region.
  (let* ((text (buffer-substring-no-properties (region-beginning) (region-end)))
         ;; A selection may itself contain fences.  Use a longer delimiter
         ;; than any run in the selection, preserving its exact characters.
         (fence (make-string
                 (1+ (cl-loop with start = 0
                              while (string-match "`+" text start)
                              maximize (- (match-end 0) (match-beginning 0)) into longest
                              do (setq start (match-end 0))
                              finally return (max 2 (or longest 0))))
                 ?`)))
    (require 'agent-shell)
    (let* ((shell (or (unless pick-shell (car (agent-shell-project-buffers)))
                      (agent-shell--read-shell-buffer :prompt "Quote region to shell: ")))
           (insertion (agent-shell-insert
                       :text (concat fence "diff\n" text
                                     (unless (string-suffix-p "\n" text) "\n")
                                     fence "\n\n")
                       :shell-buffer shell :submit nil)))
      ;; Native viewport append preserves drafts but leaves point unchanged.
      (when insertion
        (with-current-buffer (map-elt insertion :buffer)
          (goto-char (map-elt insertion :end)))))))

(with-eval-after-load 'magit-diff
  (define-key magit-diff-mode-map (kbd "C-c r") #'my/agent-shell-quote-region))

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
  (require 'my-agent-shell-notifications)
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
