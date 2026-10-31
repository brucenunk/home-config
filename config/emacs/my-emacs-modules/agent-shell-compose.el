;;; agent-shell-compose.el --- Editable markup in native composers -*- lexical-binding: t -*-

;;; Commentary:
;; Markup helpers only: the viewport keeps its major mode and editing services.
;; `agent-shell-compose-insert-source-block' prompts for a language and inserts
;; a block, or wraps the active region, without submitting or converting text.
;; The selected markup is fixed for the lifetime of a viewport, including view
;; transitions.  Change `agent-shell-compose-markup' before opening a new one;
;; existing drafts are never detected, converted, or reinterpreted.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-element)
(require 'markdown-mode)

(defgroup agent-shell-compose nil
  "Editable markup in agent-shell's native viewport composer."
  :group 'applications)

(defcustom agent-shell-compose-markup 'markdown
  "Markup for new viewport composers: `org' or `markdown'.
Changing this option does not change existing viewports or convert drafts."
  :type '(choice (const org) (const markdown)))

(defcustom agent-shell-compose-language-modes nil
  "Composer-local language-to-major-mode overrides for both markup formats.
Each entry maps a block language string to a major-mode command symbol
ending in -mode.  The mode and any required grammar must be installed.
Overrides apply to highlighting and native block editing.  Other languages
retain their markup package's resolver; ordinary Org/Markdown buffers are
unaffected.  This option does not configure or attach language servers."
  :type '(alist :key-type string :value-type (symbol :tag "Major mode")))

(defvar-local agent-shell-compose--markup nil)
(put 'agent-shell-compose--markup 'permanent-local t)
(defvar-local agent-shell-compose--generation nil)
(defvar-local agent-shell-compose--org-buffer nil)
(defvar-local agent-shell-compose--org-fontified-region nil)

(defconst agent-shell-compose--org-invalid-body-regexp
  "^\\(?:[ \t]*#\\+end_src\\b\\|\\*+[ \t]\\)"
  "Raw body lines that would terminate or invalidate an Org source block.")

(defun agent-shell-compose-selected-markup (&optional buffer)
  "Return BUFFER's selected markup, or the default for a new composer."
  (with-current-buffer (or buffer (current-buffer))
    (or agent-shell-compose--markup agent-shell-compose-markup)))

(defun agent-shell-compose--org-quote (text)
  "Wrap plain TEXT in an Org quote, without converting its inline markup.
Refuse text that would break the outer quote rather than silently escaping it.
Response presentation properties must not enter the editable draft."
  (let ((quote (concat "#+begin_quote\n" (substring-no-properties text)
                       (unless (string-suffix-p "\n" text) "\n")
                       "#+end_quote")))
    (with-temp-buffer
      (let ((org-mode-hook nil) (text-mode-hook nil)
            (after-change-major-mode-hook nil)
            (org-inhibit-startup t) (org-element-cache-persistent nil))
        (org-mode))
      (insert quote)
      (goto-char (point-min))
      (let ((node (org-element-at-point)))
        (unless (and (eq (org-element-type node) 'quote-block)
                     (= (org-element-property :end node) (point-max)))
          (user-error "Response contains text that would break an Org quote block"))))
    quote))

(defun agent-shell-compose--setup-reply (setup &rest args)
  "Call native reply SETUP with ARGS, adapting only its Org quote formatter."
  (let ((text (plist-get args :quoted-text)))
    (if (and text (eq (agent-shell-compose-selected-markup) 'org))
        ;; Validate before native setup changes modes or consumes the snapshot.
        ;; The pinned upstream has no quote-format hook.  Limit the temporary
        ;; substitution to this reply's buffer and exact input, leaving native
        ;; draft restoration, attachments, positioning and Markdown untouched.
        (let ((quote (agent-shell-compose--org-quote text))
              (viewport (current-buffer))
              (block-quote (symbol-function 'agent-shell--block-quote)))
          (cl-letf (((symbol-function 'agent-shell--block-quote)
                     (lambda (input)
                       (if (and (eq (current-buffer) viewport) (eq input text))
                           quote
                         (funcall block-quote input)))))
            (apply setup args)))
      (apply setup args))))

(with-eval-after-load 'agent-shell-viewport
  (advice-add 'agent-shell-viewport--setup-reply :around
              #'agent-shell-compose--setup-reply))

(defun agent-shell-compose--fontify-markdown (beg end loudly)
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

(defun agent-shell-compose--setup-markdown ()
  "Reuse Markdown's syntax and font-lock setup, not its editing environment."
  (setq-local markdown-hide-markup nil
              markdown-fontify-code-blocks-natively t
              syntax-propertize-function #'markdown-syntax-propertize
              font-lock-fontify-region-function #'agent-shell-compose--fontify-markdown
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

(defun agent-shell-compose--kill-org-buffer ()
  "Dispose of this composer's private Org parser/fontification buffer."
  (when (buffer-live-p agent-shell-compose--org-buffer)
    (kill-buffer agent-shell-compose--org-buffer))
  (setq agent-shell-compose--org-buffer nil))

(defun agent-shell-compose--org-buffer ()
  "Return a private Org buffer containing this composer's plain draft text."
  (unless (buffer-live-p agent-shell-compose--org-buffer)
    (let ((text (save-restriction
                  (widen)
                  (buffer-substring-no-properties (point-min) (point-max))))
          (language-modes org-src-lang-modes))
      (setq agent-shell-compose--org-buffer
            (generate-new-buffer " *agent-shell-compose-org*"))
      (with-current-buffer agent-shell-compose--org-buffer
        ;; Suppress prose services and startup folding in this parser buffer.
        ;; Do NOT suppress hooks during later language fontification: those
        ;; hooks supply rainbow delimiters in Org's native source buffers.
        (let ((org-mode-hook nil) (text-mode-hook nil)
              (after-change-major-mode-hook nil)
              (org-inhibit-startup t) (org-element-cache-persistent nil))
          (org-mode))
        (setq-local org-src-lang-modes language-modes
                    font-lock-fontify-region-function #'agent-shell-compose--org-fontify-source
                    org-hide-emphasis-markers nil org-hide-leading-stars nil
                    org-hide-macro-markers nil org-hidden-keywords nil
                    org-pretty-entities nil org-link-descriptive nil
                    org-use-sub-superscripts nil org-src-fontify-natively t)
        ;; Hidden buffers (and batch Emacs) are normally skipped by Font Lock.
        ;; This parser needs change tracking even when it is never displayed.
        (setq-local font-lock-mode t)
        (font-lock-mode-internal t)
        ;; Font Lock can create this buffer with modification hooks inhibited.
        (let ((inhibit-modification-hooks nil)) (insert text)))))
  agent-shell-compose--org-buffer)

(defun agent-shell-compose--org-after-change (beg end old-length)
  "Mirror a composer edit at BEG..END replacing OLD-LENGTH characters."
  (when (buffer-live-p agent-shell-compose--org-buffer)
    (if (/= (+ (buffer-size) old-length (- beg end))
            (with-current-buffer agent-shell-compose--org-buffer (buffer-size)))
        ;; Native attachment modification hooks can remove extra characters
        ;; with hooks inhibited.  Discard this cache, never the native edit;
        ;; the next fontification reconstructs it from the current plain draft.
        (agent-shell-compose--kill-org-buffer)
      (let ((text (buffer-substring-no-properties beg end)))
        (with-current-buffer agent-shell-compose--org-buffer
          ;; Change hooks themselves run with this inhibited.  Org must see its
          ;; own edit to invalidate source blocks and its element cache.
          (let ((inhibit-modification-hooks nil))
            (delete-region beg (+ beg old-length))
            (goto-char beg)
            (insert text)))))))

(defun agent-shell-compose--org-fontify-source (beg end loudly)
  "Fontify BEG..END LOUDLY, recording Org's extended face-update range."
  (let* ((source (current-buffer))
         (unfontify font-lock-unfontify-region-function)
         (font-lock-unfontify-region-function
          (lambda (from to)
            ;; Nested language fontification must not pollute this range.
            (when (eq source (current-buffer))
              (setq agent-shell-compose--org-fontified-region
                    (if-let* ((region agent-shell-compose--org-fontified-region))
                        (cons (min from (car region)) (max to (cdr region)))
                      (cons from to))))
            (funcall unfontify from to))))
    (font-lock-default-fontify-region beg end loudly)))

(defun agent-shell-compose--unfontify-org (beg end)
  "Remove only composer faces in BEG..END and invalidate the private cache."
  (with-silent-modifications
    (remove-text-properties beg end '(face nil font-lock-face nil)))
  (agent-shell-compose--kill-org-buffer))

(defun agent-shell-compose--fontify-org (beg end _loudly)
  "Copy only fontification faces from a private Org buffer.
Org owns incremental invalidation in that buffer.  No syntax, hiding,
display, mouse, attachment, or layout properties cross this boundary."
  (let ((composer (current-buffer))
        (source (agent-shell-compose--org-buffer)))
    (with-current-buffer source
      ;; Respect JIT's visible range, extending only as Org requires for a
      ;; block delimiter edit (e.g. closing an earlier unfinished block).
      (let ((bounds (save-excursion (org-fontify-extend-region beg end 0))))
        (font-lock-ensure (car bounds) (cdr bounds)))
      ;; Always copy the requested visible range, even if Org coloured it as
      ;; a side effect of an earlier request.  Also copy any newly refontified
      ;; context beyond it, but never traverse the entire draft just to scroll.
      (let* ((updated agent-shell-compose--org-fontified-region)
             (region (cons (min beg (or (car updated) beg))
                           (max end (or (cdr updated) end)))))
        (dolist (prop '(face font-lock-face))
          (let ((pos (car region)) (end (cdr region)))
            (while (< pos end)
              (let ((next (next-single-property-change pos prop nil end))
                    (value (get-text-property pos prop)))
                (with-current-buffer composer
                  (with-silent-modifications
                    (put-text-property pos next prop value)))
                (setq pos next)))))
        (setq agent-shell-compose--org-fontified-region nil)
        ;; Org may have recoloured preceding lines (e.g. when a block closes).
        ;; Tell JIT Lock so redisplay schedules those lines as well.
        (cons 'jit-lock-bounds
              (cons (min beg (car region)) (max end (cdr region))))))))

(defun agent-shell-compose--setup-language-modes ()
  "Adapt explicit composer mode overrides to the two native resolvers."
  (setq-local markdown-code-lang-modes
              (append agent-shell-compose-language-modes markdown-code-lang-modes)
              org-src-lang-modes
              (append (mapcar (lambda (entry)
                                (cons (car entry)
                                      (intern (string-remove-suffix
                                               "-mode" (symbol-name (cdr entry))))))
                              agent-shell-compose-language-modes)
                      org-src-lang-modes)))

(defun agent-shell-compose-setup ()
  "Install the selected markup's highlighting in a native viewport editor."
  (unless agent-shell-compose--markup
    (setq agent-shell-compose--markup agent-shell-compose-markup))
  (setq agent-shell-compose--generation (list nil))
  (agent-shell-compose--setup-language-modes)
  (pcase agent-shell-compose--markup
    ('markdown (agent-shell-compose--setup-markdown))
    ('org
     (setq-local font-lock-defaults '(nil t)
                 font-lock-unfontify-region-function #'agent-shell-compose--unfontify-org
                 font-lock-fontify-region-function #'agent-shell-compose--fontify-org)
     (add-hook 'after-change-functions #'agent-shell-compose--org-after-change nil t)
     (add-hook 'change-major-mode-hook #'agent-shell-compose--kill-org-buffer nil t)
     (add-hook 'kill-buffer-hook #'agent-shell-compose--kill-org-buffer nil t))
    (_ (user-error "Unsupported composer markup: %S" agent-shell-compose--markup))))

(defun agent-shell-compose--source-block (text language markup)
  "Return TEXT in a source block for LANGUAGE and MARKUP.
Refuse Org headlines/end delimiters rather than silently escaping TEXT."
  (unless (and (stringp language) (string-match-p "\\`[^[:space:]`]*\\'" language))
    (user-error "Language must be a single name without whitespace or backticks"))
  (let ((body (concat text (unless (string-suffix-p "\n" text) "\n"))))
    (pcase markup
      ('org
       (let ((case-fold-search t))
         (when (string-match-p agent-shell-compose--org-invalid-body-regexp text)
           (user-error "Selection contains an Org heading or source-block end delimiter")))
       (concat "#+begin_src" (unless (string-empty-p language) " ")
               language "\n" body "#+end_src\n\n"))
      ('markdown
       (let ((fence (make-string
                     (1+ (cl-loop with start = 0
                                  while (string-match "`+" text start)
                                  maximize (- (match-end 0) (match-beginning 0)) into longest
                                  do (setq start (match-end 0))
                                  finally return (max 2 (or longest 0))))
                     ?`)))
         (concat fence language "\n" body fence "\n\n")))
      (_ (user-error "Unsupported composer markup: %S" markup)))))

(defun agent-shell-compose-diff-block (text markup)
  "Return TEXT in an editable diff block for MARKUP, without changing TEXT."
  (agent-shell-compose--source-block text "diff" markup))

(defun agent-shell-compose--languages ()
  "Return markup language aliases and registered file modes for completion."
  (delete-dups
   (append '("emacs-lisp" "diff")
           (mapcar #'car (if (eq (agent-shell-compose-selected-markup) 'org)
                            org-src-lang-modes markdown-code-lang-modes))
           (cl-loop for (_ . mode) in auto-mode-alist
                    when (and (symbolp mode) (fboundp mode)
                              (string-suffix-p "-mode" (symbol-name mode)))
                    collect (string-remove-suffix "-mode" (symbol-name mode))))))

(defun agent-shell-compose--unfinished-org-source-p ()
  "Ask Org whether a synthetic closing line would enclose point in source.
Parse the text before point, not the live draft or its cached parser.
This handles unfinished blocks without reimplementing Org's block grammar."
  (let* ((pos (point))
         (text (save-restriction
                 (widen)
                 ;; A future headline must not prevent the synthetic closer
                 ;; from testing the context at the actual insertion point.
                 (buffer-substring-no-properties (point-min) pos))))
    (with-temp-buffer
      (let ((org-mode-hook nil) (text-mode-hook nil)
            (after-change-major-mode-hook nil)
            (org-inhibit-startup t) (org-element-cache-persistent nil))
        (org-mode))
      (insert text "\n#+end_src\n")
      (goto-char pos)
      (when-let* ((node (org-element-lineage (org-element-context) '(src-block) t)))
        (and (<= (org-element-property :post-affiliated node) pos)
             ;; Node bounds include trailing blank lines, which are not source.
             (<= pos (progn
                       (goto-char (org-element-property :end node))
                       (skip-chars-backward " \t\r\n")
                       (point))))))))

(defun agent-shell-compose--in-source-block-p ()
  "Return non-nil inside a complete or unfinished source block."
  (or (agent-shell-compose-block-at-point)
      (save-excursion
        (pcase (agent-shell-compose-selected-markup)
          ('markdown (markdown-find-previous-block))
          ('org (agent-shell-compose--unfinished-org-source-p))))))

(defun agent-shell-compose-insert-source-block (language)
  "Insert a source block for LANGUAGE, or wrap the active region.
Use this composer's selected markup and leave point at the body start.
LANGUAGE may be empty for an untyped block or an unknown language name.
Keep selected text and its properties intact; add only block delimiters
and separating newlines.  Never submit or convert the selected text."
  (interactive
   (progn
     (unless (derived-mode-p 'agent-shell-viewport-edit-mode)
       (user-error "Not in a native agent-shell composer"))
     (list (completing-read "Language (empty for untyped): "
                            (agent-shell-compose--languages) nil nil))))
  (unless (derived-mode-p 'agent-shell-viewport-edit-mode)
    (user-error "Not in a native agent-shell composer"))
  (barf-if-buffer-read-only)
  (when (or (agent-shell-compose--in-source-block-p)
            (and (use-region-p)
                 (save-excursion
                   (goto-char (mark))
                   (agent-shell-compose--in-source-block-p))))
    (user-error "Already in a source block; close it or use C-c ' to edit it"))
  (let* ((beg (if (use-region-p) (region-beginning) (point)))
         (end (if (use-region-p) (region-end) (point)))
         (text (buffer-substring-no-properties beg end))
         (block (agent-shell-compose--source-block
                 text language (agent-shell-compose-selected-markup)))
         (prefix-end (1+ (string-match "\n" block)))
         (prefix (substring block 0 prefix-end))
         (suffix (substring block (+ prefix-end (length text))))
         (leading (save-restriction
                    (widen)
                    (if (or (= beg (point-min)) (eq (char-before beg) ?\n)) "" "\n"))))
    (when (or (get-text-property beg 'agent-shell-context-image)
              (text-property-not-all beg end 'agent-shell-context-image nil))
      (user-error "Move image attachments outside the selection before wrapping it"))
    ;; Surround in place rather than deleting/reinserting selected text: that
    ;; would strip native context properties and run attachment deletion hooks.
    (atomic-change-group
      (goto-char end) (insert suffix)
      (goto-char beg) (insert leading prefix))
    (goto-char (+ beg (length leading) (length prefix)))
    (setq deactivate-mark t)))

(defun agent-shell-compose-block-at-point ()
  "Return bounds and language of the complete source block at point.
The result is a plist with :begin, :body-begin, :body-end, :end,
:language, :markup and :invalid-body-regexp.
Incomplete blocks are not editable."
  (let ((pos (point)) (markup (agent-shell-compose-selected-markup)))
    (pcase markup
      ('org
       (with-current-buffer (agent-shell-compose--org-buffer)
         (save-excursion
           (goto-char pos)
           (let ((node (org-element-lineage (org-element-context) '(src-block) t))
                 (case-fold-search t))
             (when node
               (goto-char (org-element-property :post-affiliated node))
               (let ((beg (point)) (body-beg (line-beginning-position 2)))
                 (when (and (re-search-forward "^[ \t]*#\\+end_src[ \t]*$"
                                              (org-element-property :end node) t)
                            ;; Org's node includes :post-blank lines; those
                            ;; are outside the block for both insert and edit.
                            (<= beg pos (match-end 0)))
                   (list :begin beg :body-begin body-beg
                         :body-end (match-beginning 0) :end (match-end 0)
                         :language (org-element-property :language node)
                         :markup markup
                         :invalid-body-regexp agent-shell-compose--org-invalid-body-regexp))))))))
      ('markdown
       (font-lock-ensure)
       (when-let* ((bounds (markdown-get-enclosing-fenced-block-construct)))
         (save-excursion
           (goto-char (car bounds))
           (let* ((beg (point))
                  (language (markdown-code-block-lang))
                  (fence (and (looking-at "[ \t]*\\([`~]+\\)")
                              (match-string-no-properties 1)))
                  (body-beg (line-beginning-position 2)))
             (when fence
               (goto-char (cadr bounds))
               (list :begin beg :body-begin body-beg
                     :body-end (line-beginning-position) :end (point)
                     :language language :markup markup
                     :invalid-body-regexp (format "^[ \t]*%s\\{%d,\\}[ \t]*$"
                                             (regexp-quote (substring fence 0 1))
                                             (length fence)))))))))))

(defun agent-shell-compose-block-mode (block)
  "Return BLOCK's native language mode, or `fundamental-mode' if unknown."
  (let ((language (plist-get block :language)))
    (or (and language
             (pcase (plist-get block :markup)
               ('org (org-src-get-lang-mode-if-bound language))
               ('markdown (markdown-get-lang-mode language))))
        #'fundamental-mode)))

(provide 'agent-shell-compose)
;;; agent-shell-compose.el ends here