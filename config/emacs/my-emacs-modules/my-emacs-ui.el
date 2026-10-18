;;; my-emacs-ui.el --- UI and appearance configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Theme, fonts, a quiet mode line, spacious-padding, and pulsar configuration.

;;; Code:

(require 'face-remap)

(declare-function mixed-pitch-mode "mixed-pitch" (&optional arg))

(defvar mixed-pitch-mode)
(defvar vc-mode)
(defvar display-time-string)

(defvar-local my/agent-shell-header-face-cookies nil
  "Remapping cookies for agent-shell header underlines.")

(defun my/agent-shell-header-no-underline ()
  "Suppress face underlines beneath agent-shell headers locally."
  (mapc #'face-remap-remove-relative my/agent-shell-header-face-cookies)
  (setq my/agent-shell-header-face-cookies nil)
  (when (derived-mode-p 'agent-shell-mode
                        'agent-shell-viewport-view-mode
                        'agent-shell-viewport-edit-mode)
    (dolist (face '(header-line header-line-inactive))
      (when (facep face)
        (push (face-remap-add-relative face :underline nil)
              my/agent-shell-header-face-cookies)))))

(add-hook 'agent-shell-mode-hook #'my/agent-shell-header-no-underline)
(add-hook 'agent-shell-viewport-view-mode-hook #'my/agent-shell-header-no-underline)
(add-hook 'agent-shell-viewport-edit-mode-hook #'my/agent-shell-header-no-underline)

(defvar-local my/viewport-prompt-face-cookie nil
  "Remapping cookie for the echoed viewport prompt.")

(defun my/viewport-prompt-variable-pitch ()
  "Let viewport prompts follow prose without changing documentation faces."
  (when my/viewport-prompt-face-cookie
    (face-remap-remove-relative my/viewport-prompt-face-cookie)
    (setq my/viewport-prompt-face-cookie nil))
  (when (and mixed-pitch-mode
             (derived-mode-p 'agent-shell-viewport-view-mode))
    ;; Override only the family inherited from mixed-pitch's doc-face remap.
    ;; Keep the prompt's original colour/slant, and recompute on font refresh.
    (setq my/viewport-prompt-face-cookie
          (face-remap-add-relative
           'agent-shell-viewport-prompt
           :family (face-attribute 'variable-pitch :family)))))

(defun my/refresh-mixed-pitch-mode ()
  "Refresh mixed-pitch-mode in all buffers where it's active."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when mixed-pitch-mode
        (mixed-pitch-mode -1)
        (mixed-pitch-mode 1)))))

;; https://github.com/protesilaos/doric-themes
(use-package doric-themes
  :ensure nil
  :demand t
  :preface
  (defun my/doric-theme-preload (theme)
    "Load Doric THEME definitions without enabling the theme.

Requiring `doric-themes' only loads the package library, not each individual
theme definition.  `auto-dark' preloads `auto-dark-themes' with `load-theme',
but the first such call for a Doric theme can fail with an `Unknown theme'
error.  Evaluate the theme's package source once and retry to register it."
    (condition-case err
        (load-theme theme :no-confirm :no-enable)
      (error
       (let* ((library (locate-library "doric-themes"))
              (source (and library
                           (expand-file-name
                            (format "%s-theme.el" theme)
                            (file-name-directory library)))))
         (if (and source (file-exists-p source))
             (progn
               (load source nil t)
               (load-theme theme :no-confirm :no-enable))
           (signal (car err) (cdr err)))))))
  :config
  (mapc #'my/doric-theme-preload '(doric-obsidian doric-marble)))

;; https://github.com/LionyxML/auto-dark-emacs
(use-package auto-dark
  :ensure nil
  :demand t
  :after doric-themes
  :custom
  (auto-dark-themes '((doric-obsidian) (doric-marble)))
  :config
  (auto-dark-mode 1))

;; https://github.com/protesilaos/spacious-padding
(use-package spacious-padding
  :ensure nil
  :hook (after-init . spacious-padding-mode)
  :custom
  (spacious-padding-subtle-frame-lines
      '( :mode-line-active spacious-padding-line-active
         :mode-line-inactive spacious-padding-line-inactive
         :header-line-active spacious-padding-line-active
         :header-line-inactive spacious-padding-line-inactive)))
;; https://github.com/protesilaos/fontaine
(use-package fontaine
  :ensure nil
  :preface
  (defun my/fontaine-setup-frame (&optional frame)
    "Enable Fontaine only for graphical FRAMEs."
    (let ((frame (or frame (selected-frame))))
      (when (display-graphic-p frame)
        (with-selected-frame frame
          (fontaine-mode 1)
          (let ((preset (fontaine-restore-latest-preset)))
            (fontaine-set-preset
             (if (assq preset fontaine-presets)
                 preset
               'aporetic-serif-mono)))))))
  :hook
  ((after-init . my/fontaine-setup-frame)
   (after-make-frame-functions . my/fontaine-setup-frame))
  :bind ("C-c F" . fontaine-set-preset)
  :config
  (setq fontaine-presets
        '((t
           :default-family "Aporetic Serif Mono"
           :default-height 130
           :fixed-pitch-family "Aporetic Serif Mono"
           :fixed-pitch-height 1.0
           :variable-pitch-family "Bricolage Grotesque"
           :variable-pitch-height 1.0)
          (aporetic-serif-mono)
          (aporetic-sans-mono
           :default-family "Aporetic Sans Mono"
           :fixed-pitch-family "Aporetic Sans Mono")
          (open-sans
           :variable-pitch-family "Open Sans"))))

(use-package mixed-pitch
  :ensure nil
  :hook ((markdown-mode . mixed-pitch-mode)
         (agent-shell-viewport-view-mode . mixed-pitch-mode)
         (agent-shell-viewport-edit-mode . mixed-pitch-mode))
  :config
  ;; The renderer's base faces also cover source labels, syntax-highlighted
  ;; bodies, and table headers/borders through inheritance.  Remap them only
  ;; in mixed-pitch buffers; ordinary shell buffers keep their own font.
  ;; Compose has no Markdown faces: raw draft code/tables stay variable-pitch.
  (dolist (face '(markdown-table-face
                  agent-shell-markdown-inline-code
                  agent-shell-markdown-source-block
                  agent-shell-markdown-table))
    (add-to-list 'mixed-pitch-fixed-pitch-faces face))
  (add-hook 'mixed-pitch-mode-hook #'my/viewport-prompt-variable-pitch)
  (add-hook 'fontaine-set-preset-hook #'my/refresh-mixed-pitch-mode))

(use-package pulsar
  :ensure nil
  :custom
  (pulsar-highlight-face 'pulsar-generic)
  :config
  (pulsar-global-mode))

(use-package lin
  :ensure nil
  :config
  ;; Keep Doric's bg-accent selection colour.
  (setq lin-face 'hl-line)
  (lin-global-mode))

;; Inspired by Prot's custom mode line.  Keep the native VC, Flymake, and
;; process constructs rather than running queries or subprocesses on redisplay.
;; Spacious padding supplies the subtle frame lines; faces inherit Doric's
;; semantic colours so theme changes need no palette-copying hooks.
(defun my/modeline-status ()
  "Return a quiet read-only marker and exceptional editing states."
  (concat
   (when buffer-read-only
     (propertize " RO " 'face 'shadow 'help-echo "Read-only buffer"))
   (when (file-remote-p default-directory) " Remote ")
   (when (buffer-narrowed-p) " Narrow ")
   (when defining-kbd-macro " Recording ")))

(defun my/modeline-buffer-name ()
  "Identify the buffer, leaving room for state markers and the clock.
Use the window being redisplayed, not the globally selected window."
  (let* ((width (window-total-width))
         (details (format-mode-line (list (my/modeline-context)
                                         (my/modeline-info))))
         (budget (max 4 (min (/ width 2)
                            (- width (string-width (my/modeline-status))
                               (string-width details) 4))))
         (face (if (mode-line-window-selected-p) 'mode-line-buffer-id 'shadow)))
    ;; Eval results are mode-line constructs too: quote literal percent signs.
    (propertize (string-replace "%" "%%"
                                (truncate-string-to-width
                                 (buffer-name) budget nil nil "…"))
                'face (if (and buffer-file-name (buffer-modified-p))
                          (list 'italic face)
                        face)
                'help-echo (or buffer-file-name (buffer-name))
                'mouse-face 'mode-line-highlight
                'local-map mode-line-buffer-identification-keymap)))

(defun my/modeline-details-p (minimum-width)
  "Whether secondary details fit in the active window at MINIMUM-WIDTH."
  (and (mode-line-window-selected-p)
       (>= (- (window-total-width) (string-width (my/modeline-status)))
           minimum-width)))

(defun my/modeline-context ()
  "Return separated mode, process, and VC details for this window.
Reserve space for the clock and buffer identity before shortening VC text."
  (let* ((mode (when (my/modeline-details-p 70)
                 (truncate-string-to-width
                  (if (eq major-mode 'emacs-lisp-mode)
                      "Emacs Lisp"
                    (format-mode-line 'mode-name))
                  (/ (window-total-width) 3) nil nil "…")))
         (branch (when (and vc-mode (my/modeline-details-p 70))
                   (string-trim (format-mode-line 'vc-mode))))
         (branch-width
          (- (window-total-width)
             (string-width (my/modeline-status))
             (min (string-width (buffer-name)) (/ (window-total-width) 3))
             (string-width (format-mode-line (my/modeline-info)))
             (string-width (format-mode-line 'mode-line-process))
             (if mode (+ 5 (string-width mode)) 0)
             ;; Leading/branch spacing plus room for alignment and padding.
             10)))
    (list
     ""
     (when mode (list "  ·  " (string-replace "%" "%%" mode)))
     ;; Process status remains visible even when secondary details are hidden.
     'mode-line-process
     (when (and branch (not (string-empty-p branch)) (> branch-width 8))
       (list "  ·  "
             (string-replace "%" "%%"
                             (truncate-string-to-width branch branch-width
                                                       nil nil "…")))))))

(defun my/modeline-diagnostics ()
  "Label non-zero native Flymake counters, retaining their faces and actions."
  (when (bound-and-true-p flymake-mode)
    (let ((exception (string-trim (format-mode-line 'flymake-mode-line-exception)))
          fields)
      (unless (string-empty-p exception) (push exception fields))
      (dolist (entry '((flymake-mode-line-error-counter . "error")
                       (flymake-mode-line-warning-counter . "warning")
                       (flymake-mode-line-note-counter . "info")))
        (let* ((counter (string-trim (format-mode-line (car entry))))
               (count (string-to-number counter)))
          (when (> count 0)
            (push (apply #'propertize
                         (format "%s %s%s" counter (cdr entry)
                                 (if (or (= count 1) (string= (cdr entry) "info"))
                                     "" "s"))
                         (text-properties-at 0 counter))
                  fields))))
      (string-join (nreverse fields) ", "))))

(defun my/modeline-info ()
  "Return separated native diagnostics and clock, only in the active window."
  (when (mode-line-window-selected-p)
    (let ((diagnostics
           (when (my/modeline-details-p 80)
             (my/modeline-diagnostics))))
      (list
       ""
       (when (and diagnostics (not (string-empty-p (string-trim diagnostics))))
         (list (string-replace "%" "%%" diagnostics) "  ·  "))
       display-time-string " "))))

(setq mode-line-right-align-edge 'right-margin)
(setq-default
 mode-line-format
 '("%e" " "
   (:eval (my/modeline-status))
   " " (:eval (my/modeline-buffer-name))
   (:eval (my/modeline-context))
   mode-line-format-right-align
   (:eval (my/modeline-info))))

;; Native minute-aligned updates; no separate timer or redisplay-time I/O.
(use-package time
  :ensure nil
  :demand t
  :custom
  (display-time-format "%-I:%M %P")
  (display-time-interval 60)
  (display-time-default-load-average nil)
  (display-time-mail-function #'ignore)
  :config
  (display-time-mode 1))

(provide 'my-emacs-ui)
;;; my-emacs-ui.el ends here
