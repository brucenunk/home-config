;;; my-agent-shell-tests.el --- Isolated agent-shell policy tests -*- lexical-binding: t -*-

;;; Commentary:
;; No daemon, live agents, remote connections or user worktrees are used.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'markdown-mode)
(require 'rainbow-delimiters)
;; Match configured language hooks before native Markdown creates its cached
;; language buffers.  No other programming-mode services run in this suite.
(add-hook 'prog-mode-hook #'rainbow-delimiters-mode)
(add-hook 'emacs-lisp-mode-hook #'rainbow-delimiters-mode)
(require 'agent-shell-gc)
;; Load policy without starting global tracking outside a disposable fixture.
(cl-letf (((symbol-function 'agent-shell-gc-mode) #'ignore))
  (require 'my-agent-shell))

(defvar my/agent-shell-test--buffers nil)

(defmacro my/agent-shell-test--isolated (&rest body)
  "Run BODY with isolated GC state and a disposable filesystem root."
  (declare (indent 0))
  `(let* ((root (make-temp-file "agent-gc-policy-" t))
          (default-directory (file-name-as-directory root))
          (user-emacs-directory default-directory)
          (my/agent-shell-directory (expand-file-name "artifacts/" root))
          (my/agent-shell-transcript-directory (expand-file-name "transcripts/" root))
          (agent-shell-gc-store-file (expand-file-name "gc/state.eld" root))
          (agent-shell-gc--sessions (make-hash-table :test 'equal))
          (agent-shell-gc--worktrees (make-hash-table :test 'equal))
          (agent-shell-gc--worktree-cache (make-hash-table :test 'equal))
          (agent-shell-gc--store-loaded nil)
          (agent-shell-gc--timer nil)
          (agent-shell-gc--save-timer nil)
          (agent-shell-gc--last-tick nil)
          (agent-shell-gc--grace-until 0)
          (agent-shell-gc-notify-function #'ignore)
          (agent-shell-gc-mode nil)
          (my/agent-shell-test--buffers nil))
     (unwind-protect
         (progn ,@body)
       (agent-shell-gc-mode -1)
       (dolist (buffer my/agent-shell-test--buffers)
         (when (buffer-live-p buffer)
           (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))
       (when (timerp agent-shell-gc--save-timer)
         (cancel-timer agent-shell-gc--save-timer))
       (delete-directory root t))))

(defun my/agent-shell-test--shell ()
  "Start a native Pi shell, replacing only ACP bootstrapping."
  (let ((agent-shell-pi-acp-command (list (executable-find "git")))
        (agent-shell-show-welcome-message nil)
        (agent-shell-show-busy-indicator nil)
        (agent-shell-session-strategy 'new))
    (cl-letf (((symbol-function 'agent-shell--handle) #'ignore))
      (let* ((shell (agent-shell-start :config (agent-shell-pi-make-agent-config)))
             (viewport (agent-shell-viewport--buffer :shell-buffer shell)))
        (push shell my/agent-shell-test--buffers)
        (when viewport (push viewport my/agent-shell-test--buffers))
        (with-current-buffer shell
          (setf (map-elt agent-shell--state :session)
                (list (cons :id (buffer-name shell))))
          (agent-shell--emit-event :event 'init-finished)
          (agent-shell--append-transcript :text "Fixture session\n"
                                          :file-path agent-shell--transcript-file))
        shell))))

(defun my/agent-shell-test--expire (shell)
  "Give SHELL activity older than the configured session TTL."
  (with-current-buffer shell
    (setq agent-shell-gc--activity
          (- (float-time) agent-shell-gc-idle-session-ttl 60))))

(defun my/agent-shell-test--git (dir &rest args)
  "Run Git ARGS in fixture DIR, failing on errors."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (error "Fixture git %S failed: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun my/agent-shell-test--repo (root &optional bare)
  "Create a source and linked task worktree beneath ROOT.
When BARE is non-nil, use a bare source like the supported launcher layout."
  (let ((main (expand-file-name "main" root))
        (task (expand-file-name "task" root)))
    (make-directory main)
    (my/agent-shell-test--git main "init" "-q" "-b" "main")
    (my/agent-shell-test--git main "config" "user.name" "GC Test")
    (my/agent-shell-test--git main "config" "user.email" "gc@example.invalid")
    (my/agent-shell-test--git main "config" "commit.gpgsign" "false")
    (my/agent-shell-test--git main "commit" "-qm" "Initial" "--allow-empty")
    (when bare
      (let ((source (expand-file-name "master.git" root)))
        (my/agent-shell-test--git root "clone" "--bare" main source)
        (setq main source)))
    (my/agent-shell-test--git main "worktree" "add" "-qb" "task" task)
    (list main task)))

(defconst my/agent-shell-test--png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")
  "Synthetic one-pixel PNG; never uses screen or clipboard contents.")

(defun my/agent-shell-test--write-png (path)
  "Write the synthetic PNG to PATH."
  (let ((coding-system-for-write 'binary))
    (write-region my/agent-shell-test--png nil path nil 'silent)))

(defmacro my/agent-shell-test--region (text &rest body)
  "Run BODY with TEXT selected in a disposable source buffer."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     (push-mark (point-max) t t)
     (let ((transient-mark-mode t)) ,@body)))

(defun my/agent-shell-test--faces-at (text)
  "Return faces at the beginning of TEXT, leaving point after it."
  (goto-char (point-min))
  (search-forward text)
  (let ((faces (get-text-property (- (point) (length text)) 'face)))
    (if (listp faces) faces (list faces))))

(ert-deftest my/agent-shell-compose-markdown-faces-and-visible-markup ()
  (let ((markdown-hide-markup t))
    (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
      (with-temp-buffer
        (agent-shell-viewport-edit-mode)
        (let ((draft (concat "# Heading\n\nProse with `identifier` and **bold**.\n\n"
                             "```elisp\n(let ((x \"hello\")) x)\n```\n\n"
                             "```diff\n@@ -1 +1 @@\n-old\n+new\n```\n\n"
                             "```unknown-language\nunknown body\n```\n\n"
                             "```\nuntyped body\n```\n")))
          (insert draft)
          (set-buffer-modified-p nil)
          (font-lock-ensure)
          (should-not (buffer-modified-p))
          (should (equal (buffer-substring-no-properties (point-min) (point-max)) draft))
          (should (memq 'markdown-inline-code-face (my/agent-shell-test--faces-at "identifier")))
          (should (memq 'font-lock-keyword-face (my/agent-shell-test--faces-at "let")))
          (should (memq 'font-lock-string-face (my/agent-shell-test--faces-at "hello")))
          (should (memq 'rainbow-delimiters-depth-1-face
                        (my/agent-shell-test--faces-at "(let")))
          (dolist (pair '(("@@ -1" . diff-hunk-header)
                          ("old\n" . diff-removed) ("new\n" . diff-added)
                          ("unknown body" . markdown-code-face)
                          ("untyped body" . markdown-code-face)))
            (should (memq (cdr pair) (my/agent-shell-test--faces-at (car pair)))))
          (dotimes (offset (buffer-size))
            (should-not (invisible-p (1+ offset)))
            (should-not (get-text-property (1+ offset) 'invisible))
            (should-not (get-text-property (1+ offset) 'display)))
          (should-not markdown-hide-markup))))))

(ert-deftest my/agent-shell-compose-markdown-incremental-fences ()
  (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
    (with-temp-buffer
      (agent-shell-viewport-edit-mode)
      ;; Batch Emacs leaves font-lock-mode disabled.  Install the interactive
      ;; change tracking so these edits exercise actual JIT invalidation.
      (setq font-lock-mode t)
      (font-lock-mode-internal t)
      (insert "Before.\n\n```elisp\n(message \"first\")\n")
      (font-lock-ensure)
      ;; Native Markdown waits for a closing fence before language colouring.
      (should-not (memq 'font-lock-string-face (my/agent-shell-test--faces-at "first")))
      ;; Continue an unfinished block, then close it and add prose.
      (goto-char (point-max))
      (let ((start (point)))
        (insert "(message \"second\")\n```\n\nAfter.\n")
        (font-lock-ensure start (point-max)))
      (should (memq 'font-lock-string-face (my/agent-shell-test--faces-at "second")))
      (should-not (memq 'markdown-code-face (my/agent-shell-test--faces-at "After")))
      ;; Only request the edited region: installed extension hooks must
      ;; invalidate the rest of the block, not a test's full-buffer flush.
      (goto-char (point-min))
      (search-forward "elisp")
      (replace-match "diff")
      (font-lock-ensure (- (point) 4) (point))
      (should-not (memq 'font-lock-string-face (my/agent-shell-test--faces-at "first")))
      (goto-char (point-min))
      (search-forward "```diff\n")
      (replace-match "")
      (font-lock-ensure (point) (1+ (point)))
      (should-not (memq 'markdown-code-face (my/agent-shell-test--faces-at "first")))
      ;; An unfinished fence must remain editable.  Reclosing it must leave
      ;; following prose outside the block; native incomplete-block colours
      ;; can depend on whether the block was previously closed.
      (erase-buffer)
      (insert "```elisp\n(message \"inside\")\n```\n\n(message \"outside\")\n")
      (font-lock-ensure)
      (goto-char (point-min))
      (forward-line 2)
      (delete-region (point) (line-beginning-position 2))
      (font-lock-ensure (point) (1+ (point)))
      (insert "```\n")
      (font-lock-ensure (- (point) 4) (point))
      (should-not (memq 'font-lock-string-face (my/agent-shell-test--faces-at "outside"))))))

(ert-deftest my/agent-shell-compose-fontification-preserves-native-layout ()
  (my/agent-shell-test--isolated
    (let* ((agent-shell-header-style 'text)
           (shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell)))
      (with-current-buffer viewport
        (agent-shell-viewport--initialize)
        (should (get-text-property (point-min) 'cursor-intangible))
        (font-lock-ensure)
        (should (equal (get-text-property (point-min) 'rear-nonsticky)
                       '(cursor-intangible)))
        (goto-char (point-max))
        (insert "Editable draft")
        (should-not (get-text-property (1- (point)) 'cursor-intangible))))))

(ert-deftest my/agent-shell-compose-fontification-preserves-attachment-properties ()
  (my/agent-shell-test--isolated
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell)))
      (with-current-buffer viewport
        (insert "```elisp\n(message \"hello\")\n```\n\n")
        ;; Use the real native image/link constructor with a display object
        ;; independent of graphical image support in the batch test runner.
        (cl-letf (((symbol-function 'agent-shell--load-image)
                   (lambda (&rest _) '(image :type png :data "fixture"))))
          (insert (agent-shell--get-files-context :files '("/fixture/image.png"))))
        (let ((original (buffer-string)))
          (dotimes (_ 2)
            (font-lock-flush)
            (font-lock-ensure)
            (dotimes (offset (length original))
              (dolist (prop '(composition display invisible rear-nonsticky keymap
                             help-echo mouse-face pointer modification-hooks
                             agent-shell-context-image))
                (should (equal (get-text-property (1+ offset) prop)
                               (get-text-property offset prop original)))))))))))

(ert-deftest my/agent-shell-compose-fontification-does-not-hide-submitted-fences ()
  (my/agent-shell-test--isolated
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell))
           (draft "Explain `code`.\n\n```elisp\n(message \"hello\")\n```")
           sent)
      (with-current-buffer viewport
        (insert draft)
        (font-lock-ensure)
        (cl-letf (((symbol-function 'agent-shell-viewport--busy-p) (lambda (&rest _) nil))
                  ((symbol-function 'agent-shell--insert-to-shell-buffer)
                   (lambda (&rest args) (setq sent args))))
          ;; Exercise the real default submit/view transition and prompt echo,
          ;; stubbing only the final shell transport boundary.
          (let ((agent-shell-viewport-dismiss-on-send nil))
            (agent-shell-viewport-compose-send)))
        (should (equal (plist-get sent :text) draft))
        (should (plist-get sent :submit))
        (should (eq major-mode 'agent-shell-viewport-view-mode))
        (goto-char (point-min))
        (search-forward "```elisp")
        (should-not (invisible-p (1- (point))))
        (dotimes (offset (length draft))
          (should-not (get-text-property offset 'invisible (plist-get sent :text))))))))

(ert-deftest my/agent-shell-compose-markdown-draft-view-round-trip ()
  (my/agent-shell-test--isolated
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell))
           (draft "Keep `inline`.\n\n```elisp\n(message \"draft\")\n```\n"))
      (with-current-buffer viewport
        (insert draft)
        (goto-char 8)
        (font-lock-ensure)
        ;; Keep native snapshot/restore paths; supply only a history item.
        (cl-letf (((symbol-function 'shell-maker-history-position)
                   (lambda () '((:current . 1) (:total . 1))))
                  ((symbol-function 'agent-shell-goto-last-interaction) #'ignore)
                  ((symbol-function 'agent-shell-interaction-at-point)
                   (lambda () '((:prompt . "Question") (:response . "Response")))))
          (agent-shell-viewport-compose-peek-last))
        (should (eq major-mode 'agent-shell-viewport-view-mode))
        (should-not (local-variable-p 'markdown-fontify-code-blocks-natively))
        (should-not (eq syntax-propertize-function #'markdown-syntax-propertize))
        (should-not (memq #'markdown-font-lock-extend-region font-lock-extend-region-functions))
        (save-window-excursion
          (agent-shell-viewport--show-buffer :shell-buffer shell :edit t))
        (should (eq major-mode 'agent-shell-viewport-edit-mode))
        ;; Native restore currently prefixes a newline to snapshots.
        (should (equal (string-trim-left (buffer-substring-no-properties
                                         (point-min) (point-max)) "\n") draft))
        (should (= (point) 8))
        (font-lock-ensure)
        (should (memq 'markdown-inline-code-face (my/agent-shell-test--faces-at "inline")))
        (should-not agent-shell-viewport--compose-snapshot)))))

(ert-deftest my/agent-shell-compose-markdown-send-and-queue ()
  (my/agent-shell-test--isolated
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell))
           (draft "Explain `code`.\n\n```elisp\n(message \"hello\")\n```"))
      (dolist (busy '(nil t))
        (let (sent queued)
          (with-current-buffer viewport
            (agent-shell-viewport-edit-mode)
            (insert draft)
            (font-lock-ensure)
            (cl-letf (((symbol-function 'agent-shell-viewport--busy-p) (lambda (&rest _) busy))
                      ((symbol-function 'agent-shell--insert-to-shell-buffer)
                       (lambda (&rest args) (setq sent args)))
                      ((symbol-function 'agent-shell--busy-submit)
                       (lambda (&rest args) (setq queued args))))
              (agent-shell-viewport-compose-send t))
            (should (equal (plist-get (if busy queued sent) (if busy :prompt :text)) draft))
            (should-not (if busy sent queued))
            (unless busy (should (plist-get sent :submit)))
            (should (eq major-mode 'agent-shell-viewport-edit-mode))
            (should (string-empty-p (string-trim (buffer-string))))))))))

(ert-deftest my/agent-shell-quote-exact-text-and-editable-draft ()
  (my/agent-shell-test--isolated
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell)))
      (cl-letf (((symbol-function 'agent-shell-project-buffers) (lambda () (list shell)))
                ((symbol-function 'agent-shell--send-request)
                 (lambda (&rest _) (ert-fail "Quote submitted a prompt"))))
        (dolist (text '("-  old\n+  new" "  partial  " "a\n\nb\n" "\tλ\n> nested"
                        "```\n````"))
          (with-current-buffer viewport
            (agent-shell-viewport-edit-mode)
            (erase-buffer)
            (insert "Existing draft"))
          (save-window-excursion
            ;; Select only the interior; neither surrounding text nor face
            ;; properties should become part of the quote.
            (with-temp-buffer
              (insert "BEFORE" (propertize text 'face 'bold) "AFTER")
              (goto-char (+ (point-min) 6))
              (push-mark (+ (point) (length text)) t t)
              (let ((transient-mark-mode t))
                (call-interactively #'my/agent-shell-quote-region)))
            (with-current-buffer viewport
              (should (derived-mode-p 'agent-shell-viewport-edit-mode))
              (should (equal (buffer-substring-no-properties (point-min) (point-max))
                             (let ((fence (if (string-match-p "````" text) "`````" "```")))
                               (concat "Existing draft\n\n" fence "diff\n" text
                                       (unless (string-suffix-p "\n" text) "\n")
                                       fence "\n\n"))))
              (should (= (point) (point-max)))
              (insert "Explain this change.")
              (should (string-suffix-p "\n\nExplain this change." (buffer-string))))))))))

(ert-deftest my/agent-shell-quote-fontifies-as-diff ()
  (my/agent-shell-test--isolated
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell)))
      (cl-letf (((symbol-function 'agent-shell-project-buffers) (lambda () (list shell))))
        (save-window-excursion
          (my/agent-shell-test--region "@@ -1 +1 @@\n-old\n+new"
            (my/agent-shell-quote-region))))
      (with-current-buffer viewport
        (font-lock-ensure)
        (should (memq 'diff-removed (my/agent-shell-test--faces-at "old")))
        (should (memq 'diff-added (my/agent-shell-test--faces-at "new")))))))

(ert-deftest my/agent-shell-quote-restores-view-mode-draft-while-busy ()
  (my/agent-shell-test--isolated
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell)))
      (with-current-buffer viewport
        (agent-shell-viewport-view-mode)
        (setq agent-shell-viewport--compose-snapshot
              '((:content . "Saved draft") (:location . 3))))
      (cl-letf (((symbol-function 'agent-shell-project-buffers) (lambda () (list shell)))
                ((symbol-function 'agent-shell-viewport--busy-p) (lambda () t))
                ((symbol-function 'agent-shell--send-request)
                 (lambda (&rest _) (ert-fail "Quote submitted while busy"))))
        (save-window-excursion
          (my/agent-shell-test--region "+ change"
            (my/agent-shell-quote-region)))
        (with-current-buffer viewport
          (should (derived-mode-p 'agent-shell-viewport-edit-mode))
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "\nSaved draft\n\n```diff\n+ change\n```\n\n"))
          (should (= (point) (point-max)))
          (should-not agent-shell-viewport--compose-snapshot))))))

(ert-deftest my/agent-shell-quote-routes-to-worktree-or-chosen-session ()
  (my/agent-shell-test--isolated
    (pcase-let* ((`(,main ,task) (my/agent-shell-test--repo root))
                 (default-directory (file-name-as-directory main))
                 (other (my/agent-shell-test--shell))
                 (default-directory (file-name-as-directory task))
                 (local (my/agent-shell-test--shell))
                 (selected nil)
                 (inserted nil))
      (cl-letf (((symbol-function 'agent-shell-insert)
                 (lambda (&rest args) (setq inserted (plist-get args :shell-buffer)) nil))
                ((symbol-function 'completing-read)
                 (lambda (_prompt candidates &rest _)
                   (setq selected t)
                   (seq-find (lambda (name)
                               (string-prefix-p "main " name))
                             (all-completions "" candidates)))))
        (my/agent-shell-test--region "change"
          (my/agent-shell-quote-region)
          (should (eq inserted local))
          (should-not selected)
          (my/agent-shell-quote-region t)
          (should selected)
          (should (eq inserted other))
          (setq selected nil inserted nil)
          (let ((default-directory (file-name-as-directory root)))
            (my/agent-shell-quote-region))
          (should selected)
          (should (eq inserted other)))))))

(ert-deftest my/agent-shell-quote-errors-and-cancellation-do-not-insert ()
  (my/agent-shell-test--isolated
    (cl-letf (((symbol-function 'agent-shell-insert)
               (lambda (&rest _) (ert-fail "Unexpected insertion"))))
      (with-temp-buffer
        (should-error (my/agent-shell-quote-region) :type 'user-error))
      (my/agent-shell-test--region "change"
        ;; No existing session: the chooser must error, not create one.
        (cl-letf (((symbol-function 'agent-shell--start)
                   (lambda (&rest _) (ert-fail "Quote started a session"))))
          (should-error (my/agent-shell-quote-region) :type 'user-error)
          (should-error (my/agent-shell-quote-region t) :type 'user-error)))
      (let* ((shell (my/agent-shell-test--shell))
             (viewport (agent-shell-viewport--buffer :shell-buffer shell)))
        (with-current-buffer viewport (insert "Keep draft"))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (signal 'quit nil))))
          (my/agent-shell-test--region "change"
            (should (eq (condition-case nil
                            (my/agent-shell-quote-region t)
                          (quit 'cancelled))
                        'cancelled))
            (should (equal (buffer-string) "change"))
            (should (use-region-p))))
        (with-current-buffer viewport (should (equal (buffer-string) "Keep draft")))))))

(ert-deftest my/agent-shell-quote-diff-only-binding ()
  ;; The minimal Nix agent-shell check does not include Magit; exercise the
  ;; real maps when running with the full configured Emacs package set.
  (skip-unless (require 'magit-diff nil t))
  (should (eq (lookup-key magit-diff-mode-map (kbd "C-c r"))
              #'my/agent-shell-quote-region))
  (should (eq (lookup-key magit-diff-mode-map (kbd "r")) #'magit-rebase))
  (should-not (eq (lookup-key magit-mode-map (kbd "C-c r"))
                  #'my/agent-shell-quote-region)))

(ert-deftest my/agent-shell-artifact-paths-and-bindings ()
  (my/agent-shell-test--isolated
    (should (eq agent-shell-dot-subdir-function #'my/agent-shell--dot-subdir))
    (should (equal (lookup-key agent-shell-viewport-edit-mode-map (kbd "C-c C-y"))
                   #'agent-shell-send-clipboard-image))
    (should (eq (lookup-key agent-shell-viewport-edit-mode-map (kbd "C-c C-s"))
                (when (eq system-type 'darwin) #'agent-shell-send-screenshot)))
    (when (eq system-type 'darwin)
      (should (equal agent-shell-screenshot-command '("/usr/sbin/screencapture" "-i"))))
    (dolist (cwd (list root "/rpc:user@fixture.invalid:/srv/repo/"))
      (let ((default-directory cwd))
        (should (equal (funcall agent-shell-dot-subdir-function "screenshots")
                       (expand-file-name "screenshots" my/agent-shell-directory)))
        (should-not (file-remote-p (my/agent-shell--transcript-file-path)))))
    (should-not (file-exists-p my/agent-shell-directory))
    (should-not (file-exists-p my/agent-shell-transcript-directory))))

(ert-deftest my/agent-shell-attachments-preserve-draft-and-clean-worktree ()
  (my/agent-shell-test--isolated
    (pcase-let* ((`(,source ,task) (my/agent-shell-test--repo root))
                 (default-directory (file-name-as-directory task))
                 (exclude (expand-file-name ".git/info/exclude" source))
                 (before (with-temp-buffer (insert-file-contents exclude) (buffer-string)))
                 (shell (my/agent-shell-test--shell))
                 (viewport (agent-shell-viewport--buffer :shell-buffer shell))
                 (real-call-process (symbol-function 'call-process))
                 (real-executable-find (symbol-function 'executable-find)))
      (cl-letf (((symbol-function 'window-system) (lambda (&optional _) 'fixture))
                ((symbol-function 'executable-find)
                 (lambda (name &rest args)
                   (cond ((equal name "pngpaste") "/fixture/pngpaste")
                         ((member name '("wl-paste" "xclip" "powershell")) nil)
                         (t (apply real-executable-find name args)))))
                ((symbol-function 'call-process)
                 (lambda (program &rest args)
                   (if (equal (file-name-nondirectory program) "git")
                       (apply real-call-process program args)
                     (should (member program '("pngpaste" "/usr/sbin/screencapture")))
                     (my/agent-shell-test--write-png (car (last args)))
                     0)))
                ((symbol-function 'agent-shell--display-buffer) #'ignore)
                ((symbol-function 'agent-shell--send-request)
                 (lambda (&rest _) (ert-fail "Attachment submitted a prompt"))))
        (with-current-buffer viewport
          (agent-shell-viewport-edit-mode)
          (erase-buffer)
          (insert "Existing draft")
          (agent-shell-send-clipboard-image)
          (let ((agent-shell-screenshot-command '("/usr/sbin/screencapture" "-i")))
            (agent-shell-send-screenshot))
          (should (derived-mode-p 'agent-shell-viewport-edit-mode))
          (should (string-prefix-p "Existing draft" (buffer-string)))
          (should (= 2 (length (agent-shell--parse-file-mentions (buffer-string)))))
          ;; Still editable; no submission was needed to append more text.
          (goto-char (point-max))
          (insert "\nPlease explain this image.")
          (dolist (mention (agent-shell--parse-file-mentions (buffer-string)))
            (let ((path (map-elt mention :path)))
              (should (file-in-directory-p path my/agent-shell-directory))
              (should-not (file-remote-p path)))))
        (should (equal "" (my/agent-shell-test--git task "status" "--porcelain" "--untracked-files=all")))
        (should-not (file-exists-p (expand-file-name ".agent-shell" task)))
        (should (equal before (with-temp-buffer (insert-file-contents exclude) (buffer-string))))))))

(ert-deftest my/agent-shell-attachment-failures-leave-draft-intact ()
  (my/agent-shell-test--isolated
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell))
           (agent-shell-screenshot-command '("fixture-capture")))
      (cl-letf (((symbol-function 'window-system) (lambda (&optional _) 'fixture))
                ((symbol-function 'agent-shell--send-request)
                 (lambda (&rest _) (ert-fail "Failure submitted a prompt"))))
        (with-current-buffer viewport
          (agent-shell-viewport-edit-mode)
          (erase-buffer)
          (insert "Keep this draft")
          ;; Nonzero capture, cancellation with no output, and empty output.
          (dolist (result '(failure cancelled empty))
            (cl-letf (((symbol-function 'call-process)
                       (lambda (_program &rest args)
                         (when (eq result 'empty)
                           (write-region "" nil (car (last args)) nil 'silent))
                         (if (eq result 'failure) 1 0))))
              (should-error (agent-shell-send-screenshot))
              (should (equal "Keep this draft" (buffer-string)))))
          ;; Missing tool, tool error (including non-image clipboard), and empty PNG.
          (dolist (result '(missing failure empty))
            (cl-letf (((symbol-function 'executable-find)
                       (lambda (name &rest _)
                         (when (and (not (eq result 'missing)) (equal name "pngpaste"))
                           "/fixture/pngpaste")))
                      ((symbol-function 'call-process)
                       (lambda (_program &rest args)
                         (when (eq result 'empty)
                           (write-region "" nil (car (last args)) nil 'silent))
                         (if (eq result 'failure) 1 0))))
              (should-error (agent-shell-send-clipboard-image))
              (should (equal "Keep this draft" (buffer-string))))))))))

(ert-deftest my/agent-shell-wayland-handler-writes-fixture-bytes ()
  (my/agent-shell-test--isolated
    (let ((destination (agent-shell--dot-subdir "screenshots")))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name &rest _) (when (equal name "wl-paste") "/fixture/wl-paste")))
                ((symbol-function 'call-process)
                 (lambda (program infile output _display &rest args)
                   (should (equal program "wl-paste"))
                   (should-not infile)
                   (should (equal output '(t nil)))
                   (should (equal args '("--type" "image/png")))
                   (insert my/agent-shell-test--png)
                   0)))
        (let ((path (agent-shell--save-clipboard-image :destination-dir destination)))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally path)
            (should (equal my/agent-shell-test--png (buffer-string)))))))))

(ert-deftest my/agent-shell-local-images-embed-bytes-for-local-and-rpc-agents ()
  (my/agent-shell-test--isolated
    (let ((image (expand-file-name "fixture.png" root)))
      (my/agent-shell-test--write-png image)
      (dolist (cwd (list root "/rpc:user@fixture.invalid:/srv/repo/"))
        (let ((agent-shell-cwd-function (lambda () cwd))
              (agent-shell--state '((:prompt-capabilities . ((:image . t))))))
          (cl-letf (((symbol-function 'tramp-maybe-open-connection)
                     (lambda (&rest _) (ert-fail "Image encoding attempted a remote connection"))))
            (let* ((blocks (agent-shell--build-content-blocks
                            (concat "Explain " (agent-shell--file-mention image))))
                   (block (seq-find (lambda (item) (equal (map-elt item 'type) "image")) blocks)))
              (should block)
              (should (equal (map-elt block 'mimeType) "image/png"))
              (should (equal (base64-decode-string (map-elt block 'data)) my/agent-shell-test--png))
              ;; Optional fixture artifact for the installed Pi ACP translator check.
              (when-let* ((output (getenv "MY_AGENT_SHELL_IMAGE_BLOCKS")))
                (with-temp-file output
                  (insert (json-encode (vconcat blocks))))))))))))

(ert-deftest my/agent-shell-gc-configured-mode-and-settings ()
  (my/agent-shell-test--isolated
    ;; Exercise the actual :config enablement, not a mocked mode call.
    (load "my-agent-shell" nil t)
    (should agent-shell-gc-mode)
    (should (timerp agent-shell-gc--timer))
    (should (agent-shell-gc--in-grace-p))
    (should (= agent-shell-gc-idle-session-ttl (* 4 86400)))
    (should-not agent-shell-gc-idle-worktree-ttl)
    (should (= agent-shell-gc-poll-interval 60))
    (should (= agent-shell-gc-grace 300))
    (should-not agent-shell-gc-delete-worktree-branch)
    (should-not agent-shell-gc-dry-run)
    (should (equal agent-shell-gc-session-protect-functions
                   '(my/agent-shell-gc-protect-in-flight-p
                     my/agent-shell-gc-protect-queued-input-p
                     agent-shell-gc-protect-pending-input-p
                     my/agent-shell-gc-protect-viewport-draft-p
                     agent-shell-gc-protect-kept-p)))
    (should (eq agent-shell-preferred-agent-config 'pi))
    (should agent-shell-prefer-viewport-interaction)
    (should agent-shell-tramp-mode)
    (should (eq agent-shell-transcript-file-path-function
                #'my/agent-shell--transcript-file-path))))

(ert-deftest my/agent-shell-gc-protects-busy-blocked-and-unknown-status ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let ((shell (my/agent-shell-test--shell)))
      (my/agent-shell-test--expire shell)
      ;; Use the pinned public status implementation, including its busy guard.
      (dolist (blocked '(nil permission elicitation))
        (cl-letf (((symbol-function 'shell-maker-busy) (lambda () t))
                  ((symbol-function 'agent-shell--permission-pending-p)
                   (lambda (&rest _) (eq blocked 'permission)))
                  ((symbol-function 'agent-shell-elicitation--pending-p)
                   (lambda (&rest _) (eq blocked 'elicitation))))
          (should (eq (agent-shell-status :shell-buffer shell)
                      (if blocked 'blocked 'busy)))
          (agent-shell-gc--sweep-sessions)
          (should (buffer-live-p shell))))
      (cl-letf (((symbol-function 'agent-shell-status)
                 (lambda (&rest _) (error "Unknown status"))))
        (agent-shell-gc--sweep-sessions)
        (should (buffer-live-p shell))))))

(ert-deftest my/agent-shell-gc-ready-session-with-queued-input-is-protected ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let ((shell (my/agent-shell-test--shell)))
      (my/agent-shell-test--expire shell)
      (with-current-buffer shell
        (setf (map-elt agent-shell--state :pending-prompts) '("Unsent queued prompt")))
      (should (eq (agent-shell-status :shell-buffer shell) 'ready))
      (should (eq (agent-shell-gc--protected-by shell)
                  #'my/agent-shell-gc-protect-queued-input-p))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell))
      (with-current-buffer shell
        (setf (map-elt agent-shell--state :pending-prompts) nil))
      (agent-shell-gc--sweep-sessions)
      (should-not (buffer-live-p shell)))))

(ert-deftest my/agent-shell-gc-drafts-pin-and-viewport-activity ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell :existing-only t)))
      (should (buffer-live-p viewport))
      (my/agent-shell-test--expire shell)
      (with-current-buffer viewport (insert "Unsent draft"))
      (should (my/agent-shell-gc-protect-viewport-draft-p shell))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell))
      ;; A draft stashed while viewing output is still work worth keeping.
      (with-current-buffer viewport
        (setq agent-shell-viewport--compose-snapshot '((:content . "Saved draft")))
        (agent-shell-viewport-view-mode))
      (should (my/agent-shell-gc-protect-viewport-draft-p shell))
      (with-current-buffer viewport
        (setq agent-shell-viewport--compose-snapshot nil)
        (agent-shell-viewport-edit-mode)
        (insert "  \n"))
      (should-not (my/agent-shell-gc-protect-viewport-draft-p shell))
      (with-current-buffer shell
        (goto-char (point-max))
        (insert "Shell draft"))
      (should (agent-shell-gc-protect-pending-input-p shell))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell))
      (with-current-buffer shell
        (delete-region (marker-position (cdr comint-last-prompt)) (point-max)))
      (with-current-buffer viewport (agent-shell-gc-toggle-keep))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell))
      (with-current-buffer viewport
        (agent-shell-gc-toggle-keep)
        (run-hooks 'post-command-hook))
      (should (< (agent-shell-gc--idle shell) 5))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell)))))

(ert-deftest my/agent-shell-gc-closes-visible-session-process-and-viewport-only ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell :existing-only t))
           (client (acp-make-client :command "cat" :context-buffer shell))
           (process (make-process :name "gc-fixture-client" :command '("cat") :noquery t))
           (transcript (with-current-buffer shell agent-shell--transcript-file))
           (saved-session (expand-file-name "saved-session.json" root)))
      (setf (map-elt client :process) process)
      (with-current-buffer shell
        (setf (map-elt agent-shell--state :client) client)
        (should-not agent-shell--pending-directory-cleanup)
        (agent-shell--append-transcript :text "Keep transcript\n" :file-path transcript))
      (write-region "Persisted agent session" nil saved-session)
      (save-window-excursion
        ;; Visible shell and viewport are both eligible after the TTL.
        (dolist (buffer (list shell viewport))
          (set-window-buffer (selected-window) buffer)
          (should (get-buffer-window buffer))
          (should-not (agent-shell-gc--protected-by shell)))
        (my/agent-shell-test--expire shell)
        (should (process-live-p process))
        (agent-shell-gc-now))
      (should-not (buffer-live-p shell))
      (should-not (buffer-live-p viewport))
      (should-not (process-live-p process))
      (should (file-exists-p transcript))
      (should (equal (with-temp-buffer (insert-file-contents saved-session) (buffer-string))
                     "Persisted agent session"))
      (should (file-directory-p root)))))

(ert-deftest my/agent-shell-gc-native-temporary-directory-cleanup ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let ((shell (my/agent-shell-test--shell))
          (temporary-session (expand-file-name "temporary-session" root)))
      (make-directory temporary-session)
      ;; Only agent-shell's explicit temporary-session marker causes this.
      (with-current-buffer shell
        (setq agent-shell--pending-directory-cleanup temporary-session))
      (my/agent-shell-test--expire shell)
      (agent-shell-gc--sweep-sessions)
      (should-not (file-exists-p temporary-session))
      (should (file-directory-p root)))))

(ert-deftest my/agent-shell-gc-session-cleanup-preserves-worktree-and-branch ()
  (dolist (bare '(nil t))
    (my/agent-shell-test--isolated
      (pcase-let* ((`(,source ,task) (my/agent-shell-test--repo root bare))
                   (default-directory (file-name-as-directory task)))
        (agent-shell-gc-mode 1)
        (let* ((shell (my/agent-shell-test--shell))
               (transcript (buffer-local-value 'agent-shell--transcript-file shell)))
          ;; Seed an ancient entry too: even tracked worktrees cannot be removed.
          (puthash (agent-shell-gc--normalize-dir task)
                   (list (cons :last-activity 0) (cons :repo source)
                         (cons :branch "task") (cons :origin 'session))
                   agent-shell-gc--worktrees)
          (my/agent-shell-test--expire shell)
          (cl-letf (((symbol-function 'agent-shell-gc--collect-worktree)
                     (lambda (&rest _) (ert-fail "Worktree collection is disabled"))))
            (agent-shell-gc-now))
          (should-not (buffer-live-p shell))
          (should (file-exists-p (expand-file-name ".git" task)))
          (should (file-directory-p source))
          (should (equal (my/agent-shell-test--git source "branch" "--format=%(refname:short)"
                                                 "--list" "task") "task"))
          (should (file-exists-p transcript)))))))

(ert-deftest my/agent-shell-gc-session-cleanup-with-rpc-cwd ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let* ((shell (my/agent-shell-test--shell))
           (transcript (buffer-local-value 'agent-shell--transcript-file shell))
           (remote "/rpc:gc-fixture.invalid:/srv/task/")
           (lookups 0))
      (with-current-buffer shell (setq default-directory remote))
      (my/agent-shell-test--expire shell)
      ;; Worktree resolution is unsupported and deletion disabled.  Simulate
      ;; its nil result at that boundary, without touching a remote filesystem.
      (cl-letf (((symbol-function 'agent-shell-gc--worktree-info)
                 (lambda (dir)
                   (should (equal dir remote))
                   (cl-incf lookups)
                   nil)))
        (agent-shell-gc-now))
      (should (> lookups 0))
      (should-not (buffer-live-p shell))
      (should (file-exists-p transcript)))))

(ert-deftest my/agent-shell-gc-rpc-stat-connection-error-preserves-tracking ()
  (require 'tramp-rpc)
  (my/agent-shell-test--isolated
    (let ((remote "/rpc:gc-fixture.invalid:/srv/task")
          (remote-file-name-inhibit-cache t)
          (calls 0))
      (puthash remote '((:last-activity . 1)) agent-shell-gc--worktrees)
      ;; Exercise pinned RPC's real file-directory-p/stat error conversion.
      ;; Replace only the transport, never connect to a host.
      (cl-letf (((symbol-function 'tramp-rpc--call)
                 (lambda (&rest _)
                   (cl-incf calls)
                   (signal 'file-error '("GC fixture connection unavailable")))))
        (should-error (agent-shell-gc--prune) :type 'file-error))
      (should (> calls 0))
      (should (gethash remote agent-shell-gc--worktrees)))))

(ert-deftest my/agent-shell-gc-unavailable-directory-tracking-is-best-effort ()
  (my/agent-shell-test--isolated
    (let ((remote "/rpc:offline.invalid:/srv/task"))
      (puthash remote '((:last-activity . 1)) agent-shell-gc--worktrees)
      ;; A signalled connection failure aborts pruning without dropping state.
      (cl-letf (((symbol-function 'file-directory-p)
                 (lambda (_) (signal 'file-error '("Connection unavailable")))))
        (should-error (agent-shell-gc--prune) :type 'file-error))
      (should (gethash remote agent-shell-gc--worktrees))
      ;; Accepted upstream limitation: a nil probe is interpreted as absence.
      ;; This test does not assert that real RPC connection errors return nil.
      (cl-letf (((symbol-function 'file-directory-p) (lambda (_) nil)))
        (agent-shell-gc--prune))
      (should-not (gethash remote agent-shell-gc--worktrees)))))

(provide 'my-agent-shell-tests)
;;; my-agent-shell-tests.el ends here