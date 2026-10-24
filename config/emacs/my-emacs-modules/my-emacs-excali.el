;;; my-emacs-excali.el --- Native drawings with theme defaults -*- lexical-binding: t; -*-

;; Drawings store ordinary Excalidraw colours.  The current Emacs theme is used
;; only when creating a new drawing; opening or switching themes never recolours
;; an existing scene.  Automatic theme following and semantic roles are deferred.

(require 'cl-lib)
(require 'color)

(defgroup my-excali nil "Personal Excalidraw integration." :group 'multimedia)
(defcustom my/excali-directory (expand-file-name "~/work/docs/diagrams/")
  "Default directory for drawing entry points; other locations remain allowed."
  :type 'directory :group 'my-excali)

(autoload 'excali-new "excali" nil t)
(autoload 'excali-open "excali" nil t)

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
    (setf (alist-get 'strokeColor excali--current-style)
          (my/excali--hex (face-foreground 'default nil t)))
    (my/excali-set-canvas-background (face-background 'default nil t))))

(defun my/excali--setup-buffer ()
  "Install the buffer-local scene event before its document is opened."
  (add-hook 'excali-after-open-hook #'my/excali--after-open nil t))

(with-eval-after-load 'excali
  (advice-add 'excali-new :around #'my/excali--new-drawing)
  (add-hook 'excali-mode-hook #'my/excali--setup-buffer)
  ;; Browsers use CSS aliases; Pango needs the embedded family names.
  (setopt excali-font-families
          (append excali-font-families
                  (cl-remove-if (lambda (entry) (assq (car entry) excali-font-families))
                                '((6 . "Nunito ExtraLight, Nunito, sans-serif")
                                  (8 . "Comic Shanns Regular, Comic Shanns, monospace"))))))

(provide 'my-emacs-excali)
;;; my-emacs-excali.el ends here
