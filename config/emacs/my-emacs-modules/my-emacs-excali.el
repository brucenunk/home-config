;;; my-emacs-excali.el --- Native drawings with theme defaults -*- lexical-binding: t; -*-

;; Drawings store ordinary Excalidraw colours.  The current Emacs theme supplies
;; new-drawing defaults and explicit presets; opening or switching themes never
;; recolours an existing scene.  Presets are native edits, not live roles.

(require 'cl-lib)
(require 'color)
(require 'json)
(require 'seq)
(require 'use-package)

(defgroup my-excali nil "Personal Excalidraw integration." :group 'multimedia)
(defcustom my/excali-directory (expand-file-name "~/work/docs/diagrams/")
  "Default directory for drawing entry points; other locations remain allowed."
  :type 'directory :group 'my-excali)

(defcustom my/excali-palette-directory
  (expand-file-name "excali/palettes/" (or (getenv "XDG_CONFIG_HOME") "~/.config/"))
  "Directory containing theme-builder's Excalidraw palette JSON files."
  :type 'directory :group 'my-excali)

(defvar-local my/excali--current-preset nil
  "Applied creation colours and preset name, independent of later theme changes.
This snapshot is cleared by native colour overrides, not theme changes.")

(defconst my/excali--presets '(default neutral accented muted))

(defun my/excali--validate-palette (palette)
  "Return PALETTE if it has the supported schema; otherwise signal an error."
  (unless (and (listp palette) (eq (alist-get 'version palette) 1)
               (stringp (alist-get 'theme palette))
               (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'"
                               (or (alist-get 'canvas palette) ""))
               (cl-every
                (lambda (role)
                  (let ((preset (alist-get role (alist-get 'presets palette))))
                    (cl-every
                     (lambda (property)
                       (let ((value (alist-get property preset)))
                         (and (stringp value)
                              (or (and (eq property 'fill) (equal value "transparent"))
                                  (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" value)))))
                     '(stroke fill text))))
                my/excali--presets))
    (user-error "Invalid Excalidraw palette"))
  palette)

(defun my/excali--read-palette (name)
  "Read and validate palette NAME from the configured directory."
  (unless (string-match-p "\\`[a-z0-9-]+\\'" name)
    (user-error "Invalid palette name"))
  (with-temp-buffer
    (insert-file-contents (expand-file-name (concat name ".json") my/excali-palette-directory))
    (my/excali--validate-palette
     (json-parse-buffer :object-type 'alist :null-object :null :false-object :false))))

(defun my/excali--theme-palette ()
  "Read the current Emacs theme's palette."
  (let* ((theme (car custom-enabled-themes))
         (name (and theme (symbol-name theme))))
    (unless (and name (file-readable-p
                       (expand-file-name (concat name ".json") my/excali-palette-directory)))
      (user-error "No Excalidraw palette for current Emacs theme: %s" (or name "none")))
    (my/excali--read-palette name)))

(defun my/excali--rgb (color)
  "Resolve COLOR numerically without display-palette quantization."
  (mapcar (lambda (v) (/ v 65535.0))
          (color-values-from-color-spec (my/excali--hex color))))

(defun my/excali--composite-color (color background &optional opacity)
  "Composite native COLOR over opaque BACKGROUND, including OPACITY percent.
Native colours include transparent, #rgba and #rrggbbaa in addition to RGB."
  (when (and (stringp color) (string-match-p "\\`#[[:xdigit:]]\\{4\\}\\'" color))
    (setq color (concat "#" (mapconcat (lambda (c) (make-string 2 c))
                                      (substring color 1) ""))))
  (let ((alpha (/ (or opacity 100) 100.0)))
    (cond
     ((equal color "transparent") (setq color background alpha 0))
     ((and (stringp color) (string-match-p "\\`#[[:xdigit:]]\\{8\\}\\'" color))
      (setq alpha (* alpha (/ (string-to-number (substring color 7) 16) 255.0))
            color (substring color 0 7))))
    (apply #'color-rgb-to-hex
           (append (cl-mapcar (lambda (fg bg) (+ (* alpha fg) (* (- 1 alpha) bg)))
                             (my/excali--rgb color) (my/excali--rgb background))
                   '(2)))))

(defun my/excali--luminance (color)
  "Return relative luminance of COLOR for text contrast checks."
  (let ((rgb (my/excali--rgb color)))
    (cl-loop for channel in rgb for weight in '(0.2126 0.7152 0.0722)
             sum (* weight (if (<= channel 0.04045) (/ channel 12.92)
                             (expt (/ (+ channel 0.055) 1.055) 2.4))))))

(defun my/excali--text-color (preferred background)
  "Use PREFERRED on BACKGROUND when readable, otherwise black or white."
  (let* ((bg (my/excali--luminance background))
         (fg (my/excali--luminance preferred)))
    (if (>= (/ (+ (max bg fg) 0.05) (+ (min bg fg) 0.05)) 4.5)
        preferred
      (if (> bg 0.179) "#000000" "#ffffff"))))

(defun my/excali--label-background (parent)
  "Return the background painted behind a label in PARENT.
Arrow labels and unfilled shapes use the canvas.  For translucent solid
fills, composite the fill over the canvas; patterned fills use the canvas."
  (let ((canvas (my/excali--composite-color (or (excali--canvas-color) "#ffffff") "#ffffff"))
        (fill (and parent (excali--get parent 'backgroundColor))))
    (if (and parent (member (excali--get parent 'type) '("rectangle" "ellipse" "diamond"))
             (equal (excali--get parent 'fillStyle) "solid")
             (stringp fill) (not (equal fill "transparent")))
        (my/excali--composite-color fill canvas (excali--get parent 'opacity))
      canvas)))

(defun my/excali-use-preset (role)
  "Apply current-theme preset ROLE to selected elements and their bound labels.
Also set native defaults for new elements.  Only colours and fill style are
changed; geometry, line patterns and unrelated metadata are preserved.
Sticky notes and their labels are excluded; use their native styling controls.
This is an ordinary element edit, committed as one native undo step."
  (interactive
   (list (intern (completing-read "Preset: " my/excali--presets nil t))))
  (unless (derived-mode-p 'excali-mode) (user-error "Select an excali drawing first"))
  (unless (memq role my/excali--presets) (user-error "Unknown preset: %s" role))
  (let* ((palette (my/excali--theme-palette))
         (preset (alist-get role (alist-get 'presets palette)))
         (index (make-hash-table :test #'equal))
         (targets (make-hash-table :test #'eq))
         (skipped-sticky nil)
         (changed nil))
    ;; Index once: text-heavy scenes must not repeatedly scan all elements.
    (dolist (element excali--elements)
      (unless (excali--get element 'isDeleted)
        (puthash (excali--get element 'id) element index)))
    (dolist (element excali--selection)
      (unless (excali--get element 'isDeleted)
        (if (or (equal (excali--get element 'type) "stickynote")
                (equal (excali--get (gethash (excali--get element 'containerId) index) 'type)
                       "stickynote"))
            (setq skipped-sticky t)
          (puthash element t targets))))
    (dolist (element excali--elements)
      (when (and (not (excali--get element 'isDeleted))
                 (equal (excali--get element 'type) "text")
                 (gethash (gethash (excali--get element 'containerId) index) targets))
        (puthash element t targets)))
    (setf (alist-get 'strokeColor excali--current-style) (alist-get 'stroke preset)
          (alist-get 'backgroundColor excali--current-style) (alist-get 'fill preset)
          (alist-get 'fillStyle excali--current-style) "solid")
    (setq my/excali--current-preset (cons (cons 'name role) (copy-tree preset)))
    ;; Paint shapes before resolving labels against their actual new background.
    (maphash
     (lambda (element _)
       (unless (equal (excali--get element 'type) "text")
         (dolist (pair `((backgroundColor . ,(alist-get 'fill preset)) (fillStyle . "solid")
                         (strokeColor . ,(alist-get 'stroke preset))))
           (when (and (excali--style-applies-p (car pair) element)
                      (not (equal (excali--get element (car pair)) (cdr pair))))
             (excali--set-element-style element (car pair) (cdr pair))
             (setq changed t)))))
     targets)
    (maphash
     (lambda (element _)
       (when (equal (excali--get element 'type) "text")
         (let* ((parent (gethash (excali--get element 'containerId) index))
                (color (my/excali--text-color
                        (alist-get 'text preset) (my/excali--label-background parent))))
           (unless (equal color (excali--get element 'strokeColor))
             (excali--set-element-style element 'strokeColor color)
             (setq changed t)))))
     targets)
    (set-buffer-modified-p t)
    (when changed
      (excali--commit)
      (excali--render)
      (excali--sync-views))
    (when skipped-sticky
      (message "Palette presets skip sticky notes and their labels; use native styling"))))

(defun my/excali--new-text-style (element)
  "Pair newly styled text ELEMENT with its actual background.
Only an explicitly active preset affects creation; never restyle existing text."
  (when (and my/excali--current-preset (equal (excali--get element 'type) "text"))
    (let ((parent (excali--container-of element)))
      ;; Sticky notes and all their text creation stay entirely native.
      (unless (equal (excali--get parent 'type) "stickynote")
        (excali--put element 'strokeColor
                    (my/excali--text-color
                     (alist-get 'text my/excali--current-preset)
                     (my/excali--label-background parent))))))
  element)

(defun my/excali--native-style-override (property _value)
  "Let native colour/fill PROPERTY choices replace the active creation preset."
  (when (memq property '(strokeColor backgroundColor fillStyle))
    (setq my/excali--current-preset nil)))

(defun my/excali--eyedropper-override (&rest _)
  "Clear the creation preset when native eyedropper changes drawing defaults."
  (unless (and excali--selection (eq excali--tool 'select))
    (setq my/excali--current-preset nil)))

(defun my/excali--palette-color-value (color)
  "Normalize native COLOR for read-only comparisons, preserving nonzero alpha."
  (when (stringp color)
    (setq color (downcase color))
    (when (string-match-p "\\`#[[:xdigit:]]\\{3,4\\}\\'" color)
      (setq color (concat "#" (mapconcat (lambda (c) (make-string 2 c))
                                        (substring color 1) ""))))
    (when (string-match-p "\\`#[[:xdigit:]]\\{8\\}\\'" color)
      (setq color (pcase (substring color 7)
                    ("00" "transparent")
                    ("ff" (substring color 0 7))
                    (_ color))))
    (if (equal color "transparent") color
      (condition-case nil (my/excali--hex color) (error color)))))

(defun my/excali--palette-color-equal-p (actual expected)
  "Compare ACTUAL with palette colour EXPECTED without changing the scene."
  (and (stringp actual)
       (equal (my/excali--palette-color-value actual)
              (my/excali--palette-color-value expected))))

(defun my/excali--shape-presets (element palette)
  "Return presets matching ELEMENT's applicable colour and fill properties."
  (unless (member (excali--get element 'type) '("text" "stickynote"))
    (let ((properties (seq-filter (lambda (key) (excali--style-applies-p key element))
                                  '(strokeColor backgroundColor fillStyle))))
      (and properties
           (seq-filter
            (lambda (role)
              (let ((preset (alist-get role (alist-get 'presets palette))))
                (cl-every
                 (lambda (key)
                   (pcase key
                     ('fillStyle (or (my/excali--palette-color-equal-p
                                     (excali--get element 'backgroundColor) "transparent")
                                     (equal (excali--get element key) "solid")))
                     (_ (my/excali--palette-color-equal-p
                         (excali--get element key)
                         (alist-get (if (eq key 'strokeColor) 'stroke 'fill) preset)))))
                 properties)))
            my/excali--presets)))))

(defun my/excali--element-presets (element palette index)
  "Return matching presets for ELEMENT, using INDEX for bound-label context."
  (if (not (equal (excali--get element 'type) "text"))
      (my/excali--shape-presets element palette)
    (let ((parent (gethash (excali--get element 'containerId) index)))
      (unless (equal (excali--get parent 'type) "stickynote")
        (let ((background (my/excali--label-background parent))
              (parent-presets (and parent (my/excali--shape-presets parent palette))))
          (let* ((matches
                  (seq-filter
                   (lambda (role)
                     (my/excali--palette-color-equal-p
                      (excali--get element 'strokeColor)
                      (my/excali--text-color
                       (alist-get 'text (alist-get role (alist-get 'presets palette))) background)))
                   my/excali--presets))
                 (contextual (seq-filter (lambda (role) (memq role parent-presets)) matches)))
            ;; Context disambiguates identical inks, but an unselected parent
            ;; cannot veto a label's independently applied preset.
            (or contextual matches)))))))

(defun my/excali--shown-preset ()
  "Recognise only explicitly selected elements, or the native drawing defaults.
This is read-only and never reactivates a creation preset after reopening.
When colours cannot distinguish roles, prefer their declared palette order."
  (condition-case nil
      (let ((palette (my/excali--theme-palette)))
        (if (null excali--selection)
            (or (car (my/excali--shape-presets
                      `((type . "rectangle")
                        (strokeColor . ,(excali--style-value 'strokeColor))
                        (backgroundColor . ,(excali--style-value 'backgroundColor))
                        (fillStyle . ,(excali--style-value 'fillStyle))) palette))
                'custom)
          (let ((index (make-hash-table :test #'equal))
                (common my/excali--presets)
                (elements (seq-filter (lambda (element) (not (excali--get element 'isDeleted)))
                                      excali--selection)))
            ;; Index once for selected labels' context, without adding their
            ;; parents or a selected shape's unselected labels to the selection.
            (dolist (element excali--elements)
              (unless (excali--get element 'isDeleted)
                (puthash (excali--get element 'id) element index)))
            (dolist (element elements)
              (let ((matches (my/excali--element-presets element palette index)))
                (setq common (seq-filter (lambda (role) (memq role matches)) common))))
            (or (and elements (car common))
                (if (seq-some
                     (lambda (key)
                       (cdr (delete-dups
                             (mapcar
                              (lambda (element)
                                (if (eq key 'fillStyle)
                                    (if (my/excali--palette-color-equal-p
                                         (excali--get element 'backgroundColor) "transparent")
                                        "solid" (excali--get element key))
                                  (my/excali--palette-color-value (excali--get element key))))
                              (seq-filter (lambda (element) (excali--style-applies-p key element))
                                          elements)))))
                     '(strokeColor backgroundColor fillStyle))
                    'mixed 'custom)))))
    ;; Missing palettes or unsupported imported colours must not break the
    ;; styling menu. No inference is persisted or used to change colours.
    (error 'custom)))

(defun my/excali--palette-description ()
  "Describe the recognised preset with native value alignment and styling."
  (concat (format "%-14s " "Palette:")
          (propertize (capitalize (symbol-name (my/excali--shown-preset)))
                      'face 'transient-value)))

(defun my/excali--install-palette-menu ()
  "Extend the native styling transient without replacing its colour pickers."
  (transient-define-prefix my/excali-palette ()
    "Apply explicit palette presets."
    [:description my/excali--palette-description
     ("d" "Default" (lambda () (interactive) (my/excali-use-preset 'default)))
     ("n" "Neutral" (lambda () (interactive) (my/excali-use-preset 'neutral)))
     ("a" "Accented" (lambda () (interactive) (my/excali-use-preset 'accented)))
     ("m" "Muted" (lambda () (interactive) (my/excali-use-preset 'muted)))])
  (unless (ignore-errors (transient-get-suffix 'excali-style "p"))
    (transient-append-suffix 'excali-style "s"
      '("p" my/excali-palette :description my/excali--palette-description
        :transient transient--do-recurse))))

(defun my/excali--check-compatible ()
  "Require actual module and Canvas capabilities, not just a package version."
  (unless (and (>= emacs-major-version 32) (fboundp 'module-load)
               (fboundp 'canvas-refresh) (memq 'canvas image-types)
               (or (not (display-graphic-p)) (image-type-available-p 'canvas)))
    (user-error "excali-mode requires graphical Emacs 32+ with modules and Canvas")))

(defun my/excali--hex (color)
  "Normalize COLOR without rounding hex colours to the display's palette."
  (let ((rgb (and (stringp color)
                  (or (color-values-from-color-spec color) (color-values color)))))
    (unless rgb (user-error "Unknown color: %s" color))
    (apply #'color-rgb-to-hex
           (append (mapcar (lambda (v) (/ v 65535.0)) rgb) '(2)))))

(defun my/excali-set-canvas-background (color)
  "Set this drawing's canvas to COLOR; save normally to persist it.
The interactive default is the current theme's background.  Canvas/view settings
are not part of upstream's element undo history."
  (interactive
   (progn
     (unless (derived-mode-p 'excali-mode)
       (user-error "Select an excali drawing first"))
     (let* ((default (face-background 'default nil t))
            (input (read-color (format "Canvas background (default %s): " default)
                               nil t)))
       (list (if (equal input "") default input)))))
  (unless (derived-mode-p 'excali-mode) (user-error "Select an excali drawing first"))
  (let ((hex (my/excali--hex color)))
    (setf (alist-get 'viewBackgroundColor (alist-get 'appState excali--doc)) hex)
    (set-buffer-modified-p t)
    (excali--render)))

(defun my/excali--directory ()
  (let ((directory (file-name-as-directory (expand-file-name my/excali-directory))))
    (make-directory directory t)
    directory))

(defun my/excali-new ()
  "Create a drawing using the current theme and `my/excali-directory'."
  (interactive)
  (my/excali--check-compatible)
  (let ((default-directory (my/excali--directory))) (excali-new)))

(defun my/excali-open (file)
  "Open FILE, prompting in `my/excali-directory'; preserve its saved colours."
  (interactive (list (read-file-name "Drawing: " (my/excali--directory) nil t)))
  (my/excali--check-compatible)
  (excali-open file))

(defvar my/excali--creating nil)
(defun my/excali--new-drawing (function &rest args)
  "Distinguish new scenes from existing scenes imported from PNG/SVG."
  (let ((my/excali--creating t)) (apply function args)))

(defun my/excali--after-open ()
  "Initialize genuinely new drawings, never recolouring an opened/imported scene."
  (my/excali--check-compatible)
  (when my/excali--creating
    (setq default-directory (my/excali--directory))
    (let* ((theme (car custom-enabled-themes))
           (name (and theme (symbol-name theme)))
           (file (and name (expand-file-name (concat name ".json") my/excali-palette-directory))))
      (if (and file (file-readable-p file))
          (let ((palette (my/excali--read-palette name)))
            (my/excali-use-preset 'default)
            (my/excali-set-canvas-background (alist-get 'canvas palette))
            (setf (alist-get 'homeConfigPalette excali--doc)
                  `((version . 1) (initialTheme . ,name)
                    (initialPalette . ,(copy-tree palette t)))))
        ;; Non-Doric/unavailable palettes retain the small original integration.
        (setf (alist-get 'strokeColor excali--current-style)
              (my/excali--hex (face-foreground 'default nil t)))
        (my/excali-set-canvas-background (face-background 'default nil t))))))

(defun my/excali--setup-buffer ()
  "Install the buffer-local scene event before its document is opened."
  (add-hook 'excali-after-open-hook #'my/excali--after-open nil t))

(use-package excali
  :commands (excali-open excali-new)
  :config
  (my/excali--install-palette-menu)
  (advice-add 'excali--apply-current-style :filter-return #'my/excali--new-text-style)
  (advice-add 'excali-set-style :before #'my/excali--native-style-override)
  (advice-add 'excali--eyedropper-apply :before #'my/excali--eyedropper-override)
  (advice-add 'excali-new :around #'my/excali--new-drawing)
  (add-hook 'excali-mode-hook #'my/excali--setup-buffer)
  ;; Browsers use CSS aliases; Pango needs the embedded family names.
  (setopt excali-font-families
          (append excali-font-families
                  (cl-remove-if (lambda (entry) (assq (car entry) excali-font-families))
                                '((6 . "Nunito ExtraLight, Nunito, sans-serif")
                                  (8 . "Comic Shanns Regular, Comic Shanns, monospace"))))))

(use-package excali-dsl
  :mode ("\\.excalidsl\\'" . excali-dsl-mode))

(provide 'my-emacs-excali)
;;; my-emacs-excali.el ends here
