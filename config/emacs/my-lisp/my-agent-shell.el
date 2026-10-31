;;; my-agent-shell.el --- Agent shell helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/agent-shell-insert-reference
;;   - my/agent-shell-register-reference-actions
;;   - my/agent-shell-quote-region
;;   - my/agent-shell-gc-protect-in-flight-p
;;   - my/agent-shell-gc-protect-queued-input-p
;;   - my/agent-shell-gc-protect-viewport-draft-p

;;   - my/agent-shell-restore-transcript-policy

;;; Code:

(require 'cl-lib)

;;;###autoload
(defun my/agent-shell-insert-reference ()
  "Insert one Consult file or grep candidate into the originating composer.
Use this Embark action from `consult-fd' or `consult-ripgrep'.  The
search must exit first so Consult restores the composer and its point.
Grep locations are whole-file mentions followed by a line hint."
  (interactive)
  (user-error "Use this action through Embark in a Consult file or grep search"))

(cl-defun my/agent-shell--reference-action
    (&key type target orig-target quit &allow-other-keys)
  "Handle Embark TARGET of TYPE after Consult exits when QUIT is non-nil."
  (unless (and quit (memq embark--command '(consult-fd consult-ripgrep)))
    (user-error "Start a Consult file or grep search from a composer; exit on action"))
  (unless (derived-mode-p 'agent-shell-viewport-edit-mode)
    (user-error "The search must originate in an editable agent-shell composer"))
  (when (file-remote-p default-directory)
    (user-error "Remote agent references are not supported"))
  (let* ((search-directory default-directory)
         (shell (agent-shell-viewport--shell-buffer))
         (cwd (and (buffer-live-p shell)
                   (with-current-buffer shell
                     ;; Embark dynamically binds the search directory.  Do not
                     ;; let that replace the shell's actual working directory.
                     (let ((default-directory
                            (buffer-local-value 'default-directory shell)))
                       (agent-shell-cwd)))))
         (file (pcase type
                 ;; Embark's generic file transformer substitutes environment
                 ;; variables.  Consult results are literal filenames instead.
                 ('file (substring-no-properties (or orig-target target)))
                 ('consult-grep (get-text-property 0 'consult--group target))
                 (_ (user-error "Select one Consult file or grep candidate"))))
         line)
    (unless cwd (user-error "The originating agent-shell no longer exists"))
    (unless (and (stringp file) (not (string-empty-p file)))
      (user-error "Candidate has no file path"))
    (when (eq type 'consult-grep)
      ;; Consult stores the filename separately, avoiding ambiguity in paths
      ;; containing colons.  Keep the original candidate's text properties.
      (unless (string-match "\\`[:-]\\([0-9]+\\)[:-]"
                            (substring target (length file)))
        (user-error "Candidate has no line location"))
      (setq line (string-to-number (match-string 1 (substring target (length file)))))
      (unless (> line 0) (user-error "Candidate has an invalid line location")))
    (when (or (file-remote-p cwd) (file-remote-p file))
      (user-error "Remote agent references are not supported"))
    (let* ((absolute (expand-file-name
                      ;; Consult strips ./ from results.  Restore it for
                      ;; relative paths so literal ~/ names stay literal.
                      (if (string-prefix-p "/" file) file (concat "./" file))
                      search-directory))
           (path (file-relative-name absolute cwd)))
      ;; Mention resolution uses expand-file-name, where a leading tilde
      ;; denotes a home directory rather than a literal project path.
      (when (string-prefix-p "~" path)
        (setq path (concat "./" path)))
      ;; Native quoting cannot represent embedded quotes or newlines safely.
      (when (string-match-p "[\"\n\r]" path)
        (user-error "This filename cannot be represented as a native agent mention"))
      (atomic-change-group
        (unless (or (bobp) (memq (char-before) '(?\s ?\t ?\n)))
          (insert " "))
        (insert (agent-shell--file-mention path)
                (if line (format " (line %d)" line) ""))
        (unless (or (eobp) (memq (char-after) '(?\s ?\t ?\n)))
          (insert " "))))))

;;;###autoload
(defun my/agent-shell-register-reference-actions ()
  "Register composer reference actions after Embark and Consult load.
Called by the single `embark-consult' declaration in completion configuration."
  (defvar my/agent-shell-reference-map
    (let ((map (make-sparse-keymap)))
      (set-keymap-parent map embark-general-map)
      (define-key map (kbd "@") #'my/agent-shell-insert-reference)
      map)
    "Embark actions for Consult grep candidates.")
  (define-key embark-file-map (kbd "@") #'my/agent-shell-insert-reference)
  (setf (alist-get 'consult-grep embark-keymap-alist)
        '(my/agent-shell-reference-map))
  ;; Receive the original propertized candidate, not read-string's stripped
  ;; injected copy.  Embark restores the search's original window before this
  ;; hook runs; no session selection or window manipulation is needed here.
  (setf (alist-get 'my/agent-shell-insert-reference embark-around-action-hooks)
        '(my/agent-shell--reference-action)))

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

;;;###autoload
(defun my/agent-shell-quote-region (&optional pick-shell)
  "Insert the active region as a diff block into an editable prompt.
Use the destination composer's explicitly selected markup.  Use the most
recently accessed shell in the current project, or offer the native
existing-shell chooser when none exists.  With prefix PICK-SHELL,
always offer the chooser.  Never start a shell or submit."
  (interactive "P")
  (unless (use-region-p)
    (user-error "No region selected"))
  ;; Capture before session selection can change the current buffer or region.
  (let ((text (buffer-substring-no-properties (region-beginning) (region-end))))
    (require 'agent-shell)
    (let* ((shell (or (unless pick-shell (car (agent-shell-project-buffers)))
                      (agent-shell--read-shell-buffer :prompt "Quote region to shell: ")))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell :existing-only t))
           (markup (agent-shell-compose-selected-markup (or viewport shell)))
           (insertion (agent-shell-insert
                       :text (agent-shell-compose-diff-block text markup)
                       :shell-buffer shell :submit nil)))
      ;; Native viewport append preserves drafts but leaves point unchanged.
      (when insertion
        (with-current-buffer (map-elt insertion :buffer)
          (goto-char (map-elt insertion :end)))))))

;;;###autoload
(defun my/agent-shell-gc-protect-in-flight-p (buffer)
  "Protect BUFFER while busy or waiting for permission/elicitation input.
If status cannot be determined, leave the session alone."
  (condition-case nil
      (memq (agent-shell-status :shell-buffer buffer) '(busy blocked))
    (error t)))

;;;###autoload
(defun my/agent-shell-gc-protect-queued-input-p (buffer)
  "Protect BUFFER while it holds unsent queued prompts."
  (map-elt (buffer-local-value 'agent-shell--state buffer) :pending-prompts))

;;;###autoload
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

;;;###autoload
(defun my/agent-shell-restore-transcript-policy ()
  "Restore local transcripts after enabling or toggling TRAMP integration."
  (setq agent-shell-transcript-file-path-function #'my/agent-shell--transcript-file-path))

(provide 'my-agent-shell)
;;; my-agent-shell.el ends here