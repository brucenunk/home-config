;;; my-agent-shell-header.el --- Compact agent header -*- lexical-binding: t -*-

;;; Commentary:
;; Layout for agent-shell's pinned header model.  Redisplay does no Git I/O.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'svg)
(require 'subr-x)

(defface my/agent-shell-header-model
  '((t :inherit default :weight medium))
  "Model name in the agent header."
  :group 'agent-shell)

(defvar-local my/agent-shell-header--identity-cache nil)
(defvar-local my/agent-shell-header--render-cache nil)

(defun my/agent-shell-header--git (&rest args)
  "Return successful Git ARGS output, or nil."
  (with-temp-buffer
    (when (eq 0 (apply #'process-file "git" nil (list t nil) nil args))
      (string-trim (buffer-string)))))

(defun my/agent-shell-header--identity (model)
  "Add repository and branch identity to MODEL outside redisplay.
Cache briefly because viewport updates can rebuild models frequently."
  (let ((directory (agent-shell-cwd)))
    (unless (and (equal directory (nth 0 my/agent-shell-header--identity-cache))
                 (< (- (float-time) (or (nth 1 my/agent-shell-header--identity-cache) 0)) 5))
      (let* ((default-directory directory)
             (identity
              (condition-case nil
                  ;; Presentation must never establish a TRAMP connection.
                  (when-let* (((not (file-remote-p directory)))
                              (common (my/agent-shell-header--git
                                      "rev-parse" "--git-common-dir")))
                    (let* ((common (directory-file-name (expand-file-name common)))
                           (name (file-name-nondirectory common))
                           ;; The checkout can be called main/ rather than
                           ;; the repository name.  Reading origin is local
                           ;; Git config access, not a network operation.
                           (origin (my/agent-shell-header--git "remote" "get-url" "origin"))
                           (origin-name (and origin (car (last (split-string
                                                               (directory-file-name origin)
                                                               "[:/]" t)))))
                           (repo (if origin-name
                                     (string-remove-suffix ".git" origin-name)
                                   (if (member name '(".git" ".bare" "master.git"))
                                     (file-name-nondirectory
                                      (directory-file-name (file-name-directory common)))
                                     (string-remove-suffix ".git" name))))
                           (branch (my/agent-shell-header--git
                                    "symbolic-ref" "--quiet" "--short" "HEAD")))
                      (cons repo (or branch
                                     (when-let* ((sha (my/agent-shell-header--git
                                                      "rev-parse" "--short" "HEAD")))
                                       (concat "detached@" sha))))))
                (error nil))))
        (setq my/agent-shell-header--identity-cache
              (list directory (float-time) identity))))
    (append `((:my-repository . ,(or (car (nth 2 my/agent-shell-header--identity-cache))
                                   (map-elt model :project-name)))
              (:my-branch . ,(cdr (nth 2 my/agent-shell-header--identity-cache)))
              (:my-menu . ,(when (derived-mode-p 'agent-shell-mode)
                             (agent-shell--mode-line-combined-menu))))
            model)))

(defun my/agent-shell-header--context-face (face)
  "Translate upstream context FACE without changing its thresholds."
  (pcase face
    ('agent-shell-success 'shadow)
    ('agent-shell-warning 'warning)
    ('agent-shell-error 'error)
    (_ face)))

(defun my/agent-shell-header--fields (model)
  "Return the two logical rows of styled text for MODEL."
  (let* ((thought (map-elt model :thought-level-name))
         (thought (and thought (replace-regexp-in-string
                                "\\`[Tt]hinking: *" "" thought)))
         (mode (map-elt model :mode-name))
         (mode (and mode (replace-regexp-in-string "\\`[Tt]hinking: *" "" mode)))
         (context (map-elt model :context-indicator))
         (status (map-elt model :status))
         (busy-frame (map-elt model :busy-indicator-frame))
         (activity (cond
                    ((and status (string-match-p "queue" status)) "queue")
                    ((or busy-frame
                         (equal status "Busy")) "busy"))))
    (list
     (delq nil (list (cons (or (map-elt model :buffer-name) "Agent") 'default)
                     (when-let* ((name (map-elt model :model-name)))
                       (cons name 'my/agent-shell-header-model))
                     (when thought (cons thought 'shadow))
                     (when (and mode (not (equal (downcase mode) (downcase (or thought "")))))
                       (cons mode 'shadow))))
     (delq nil (list (cons (or (map-elt model :my-repository)
                              (map-elt model :project-name) "") 'shadow)
                     (when-let* ((branch (map-elt model :my-branch)))
                       (cons branch 'font-lock-constant-face))))
     (when context
       ;; The detailed indicator is escaped for mode-line interpretation.
       (cons (replace-regexp-in-string "%%" "%" context)
             (or (get-text-property 0 'face context) 'shadow)))
     (when activity
       (cons (concat activity (or busy-frame "")) 'font-lock-keyword-face)))))

(defun my/agent-shell-header--layout (fields width measure)
  "Lay out FIELDS within WIDTH using MEASURE for text widths.
Return (TEXT FACE X ROW) runs.  Split even individual long fields rather
than clipping repository or model names.  Context and activity are
right-aligned on their respective rows, wrapping when needed."
  (let ((x 0) (row 0) runs)
    (cl-labels
        ((emit (text face)
           ;; Keep each row as a shaped text run, not separate codepoints.
           ;; In particular, never strand combining marks on the next row.
           (let ((chunk ""))
             (dolist (glyph (string-glyph-split text))
               (when (and (> (+ x (funcall measure (concat chunk glyph))) width)
                          (or (> x 0) (not (string-empty-p chunk))))
                 (unless (string-empty-p chunk)
                   (push (list chunk face x row) runs))
                 (setq chunk "" x 0 row (1+ row)))
               (setq chunk (concat chunk glyph)))
             (unless (string-empty-p chunk)
               (push (list chunk face x row) runs)
               (setq x (+ x (funcall measure chunk))))))
         (right-field (entry)
           (when entry
             (let ((size (funcall measure (car entry))))
               (when (> (+ x (funcall measure "  ") size) width)
                 (setq x 0 row (1+ row)))
               (setq x (max x (- width size)))
               (emit (car entry) (cdr entry)))))
         (fields-row (entries)
           (let ((first t))
             (dolist (entry entries)
               (unless first
                 (if (> (+ x (funcall measure (concat " · " (car entry)))) width)
                     (setq x 0 row (1+ row))
                   (emit " · " 'shadow)))
               (emit (car entry) (cdr entry))
               (setq first nil)))))
      (fields-row (nth 0 fields))
      (right-field (nth 2 fields))
      (setq x 0 row (1+ row))
      (fields-row (nth 1 fields))
      (right-field (nth 3 fields)))
    (nreverse runs)))

(defun my/agent-shell-header--svg (model width &optional bottom-padding)
  "Build the compact SVG for MODEL at pixel WIDTH with BOTTOM-PADDING."
  (let* ((fields (my/agent-shell-header--fields model))
         (size (map-elt model :font-size))
         (stride (max (map-elt model :font-height) (ceiling (* size 1.4))))
         (padding 6)
         (width (max 1 (- width (* 2 padding))))
         ;; A small allowance covers differences between Emacs and librsvg
         ;; font metrics, particularly fallback glyphs in model names.
         (measure (lambda (s) (* 1.08 (string-pixel-width s))))
         (runs (my/agent-shell-header--layout fields width measure))
         (rows (1+ (apply #'max 0 (mapcar (lambda (run) (nth 3 run)) runs))))
         (svg (svg-create (+ width (* 2 padding))
                          (+ (* rows stride) (* 2 padding) (or bottom-padding 0)))))
    (dolist (run runs)
      (pcase-let ((`(,text ,face ,x ,row) run))
        (svg-text svg text :x (+ padding x) :y (+ padding size (* row stride))
                  :font-family (face-attribute 'default :family)
                  :font-size size
                  :font-weight (if (eq face 'my/agent-shell-header-model) "500" "400")
                  :fill (agent-shell--svg-fill-color face))))
    svg))

(defun my/agent-shell-header--display (model)
  "Render MODEL for the window being redisplayed, using a bounded cache."
  (let* ((window (selected-window))
         (frame (window-frame window))
         (font (face-attribute 'default :font frame))
         (font-size (and (fontp font) (font-get font :size)))
         ;; Models can outlive font changes and be shared across frames.
         ;; Measure and draw with the target frame's current metrics.
         (model (append `((:font-height . ,(frame-char-height frame))
                          (:font-size . ,(if (and (numberp font-size) (> font-size 0))
                                             font-size (frame-char-height frame))))
                        model))
         (width (window-body-width window t))
         (fields (my/agent-shell-header--fields model))
         (graphic (and (eq agent-shell-header-style 'graphical)
                       (display-graphic-p) (image-type-available-p 'svg)))
         (gap (max 8 (round (* 0.4 (frame-char-height frame)))))
         (native-face (if (and (not (mode-line-window-selected-p))
                               (facep 'header-line-inactive))
                          'header-line-inactive 'header-line))
         (underline (face-attribute native-face :underline frame t))
         (underline (unless (memq underline '(nil unspecified))
                      (plist-put (cond ((listp underline) (copy-sequence underline))
                                       ((stringp underline) (list :color underline))
                                       (t (list :color (face-foreground native-face frame t))))
                                 :position gap)))
         (key (list fields graphic underline (map-elt model :my-menu)
                    (when-let* ((context (map-elt model :context-indicator)))
                      (get-text-property 0 'help-echo context))
                    width (map-elt model :font-size)
                    (map-elt model :font-height) (frame-char-height)
                    (mapcar (lambda (face) (face-foreground face nil t))
                            '(default shadow my/agent-shell-header-model
                              font-lock-constant-face font-lock-keyword-face warning error))
                    (face-attribute 'default :family))))
    (or (cdr (assoc key my/agent-shell-header--render-cache))
        (let* ((text (if graphic
                         (propertize " " 'display
                                     (svg-image (my/agent-shell-header--svg model width gap)
                                                :ascent 'center))
                       (replace-regexp-in-string
                        "%" "%%"
                        (mapconcat
                         (lambda (entry) (propertize (car entry) 'face (cdr entry)))
                         (delq nil (append (nth 0 fields) (list (nth 2 fields))
                                           (nth 1 fields) (list (nth 3 fields))))
                         " · ")))))
          (when graphic
            ;; The trailing fill must share the separator's raised position.
            (setq text (propertize
                        (concat text (propertize " " 'display
                                                 '(space :align-to (+ right right-fringe right-margin))))
                        ;; Keep the native separator above the blank footer.
                        'face (list :underline underline))))
          (setq text (propertize text
                                 'help-echo (concat
                                             (when-let* ((context (map-elt model :context-indicator))
                                                         (usage (get-text-property 0 'help-echo context)))
                                               (concat usage "\n\n"))
                                             "Agent settings (model, thinking and mode)")
                                 'mouse-face 'mode-line-highlight
                                 'local-map (let ((map (make-sparse-keymap)))
                                              (define-key map [header-line down-mouse-1] #'ignore)
                                              (define-key map [header-line mouse-1]
                                                          (map-elt model :my-menu))
                                              map)))
          (push (cons key text) my/agent-shell-header--render-cache)
          ;; Keep native animation frames reusable in split windows too.
          (when (> (length my/agent-shell-header--render-cache) 32)
            (setcdr (nthcdr 31 my/agent-shell-header--render-cache) nil))
          text))))

(defun my/agent-shell-header--render (original model)
  "Replace ORIGINAL renderer for MODEL when a header is enabled."
  (if (memq agent-shell-header-style '(nil none))
      (funcall original model)
    ;; Evaluated per window: a shared buffer can have two different widths.
    `(:eval (my/agent-shell-header--display ',model))))

(defun my/agent-shell-header-setup ()
  "Install the compact header after agent-shell loads."
  (advice-add 'agent-shell--make-header-model :filter-return #'my/agent-shell-header--identity)
  (advice-add 'agent-shell--context-usage-face :filter-return #'my/agent-shell-header--context-face)
  (advice-add 'agent-shell--render-header-model :around #'my/agent-shell-header--render))

(provide 'my-agent-shell-header)
;;; my-agent-shell-header.el ends here