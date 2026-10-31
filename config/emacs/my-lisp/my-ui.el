;;; my-ui.el --- Appearance and mode line helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/agent-shell-header-no-underline
;;   - my/viewport-prompt-variable-pitch
;;   - my/refresh-mixed-pitch-mode
;;   - my/doric-theme-preload
;;   - my/auto-dark-select-themes
;;   - my/fontaine-setup-frame
;;   - my/writeroom-text-scale
;;   - my/writeroom-visual-line
;;   - my/modeline-status
;;   - my/modeline-buffer-name
;;   - my/modeline-details-p
;;   - my/modeline-context
;;   - my/modeline-diagnostics
;;   - my/modeline-info

;;; Code:

(require 'face-remap)

(declare-function mixed-pitch-mode "mixed-pitch" (&optional arg))

(defvar mixed-pitch-mode)

(defvar vc-mode)

(defvar display-time-string)

(defvar-local my/agent-shell-header-face-cookies nil
  "Remapping cookies for agent-shell header underlines.")

;;;###autoload
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

(defvar-local my/viewport-prompt-face-cookie nil
  "Remapping cookie for the echoed viewport prompt.")

;;;###autoload
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

;;;###autoload
(defun my/refresh-mixed-pitch-mode ()
  "Refresh mixed-pitch-mode in all buffers where it's active."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when mixed-pitch-mode
        (mixed-pitch-mode -1)
        (mixed-pitch-mode 1)))))

;;;###autoload
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

(defun my/auto-dark--read-doric-theme (prompt themes current)
  "Read an available Doric theme from THEMES with PROMPT and CURRENT default."
  (let* ((available (custom-available-themes))
         (candidates
          (sort (mapcar #'symbol-name
                        (seq-filter (lambda (theme) (memq theme available))
                                    themes))
                #'string-lessp))
         (default (and current (symbol-name current))))
    (intern
     (completing-read
      (format-prompt prompt default)
      (lambda (string pred action)
        (if (eq action 'metadata)
            '(metadata (category . theme)
                       (display-sort-function . identity)
                       (cycle-sort-function . identity))
          (complete-with-action action candidates string pred)))
      nil t nil nil default))))

;;;###autoload
(defun my/auto-dark-select-themes ()
  "Select one light and one dark Doric theme for this session only.
Prompt light first, defaulting to the current selections.  Update
`auto-dark-themes' only after both prompts complete, and let its setter
apply the current OS appearance when `auto-dark-mode' is enabled.
Subsequent automatic appearance changes use the selected themes."
  (interactive)
  (let* ((light (my/auto-dark--read-doric-theme
                 "Light Doric theme" doric-themes-light-themes
                 (car (cadr auto-dark-themes))))
         (dark (my/auto-dark--read-doric-theme
                "Dark Doric theme" doric-themes-dark-themes
                (caar auto-dark-themes))))
    ;; Register new Doric definitions before auto-dark's setter preloads them.
    (mapc #'my/doric-theme-preload (list light dark))
    (setopt auto-dark-themes (list (list dark) (list light)))))

;;;###autoload
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

(defvar-local my/writeroom-saved-text-scale nil
  "Text scaling state to restore when leaving Writeroom.
Stored as (MODE AMOUNT), or nil outside the writing view.")

;;;###autoload
(defun my/writeroom-text-scale (arg)
  "Enlarge writing text locally for positive ARG; otherwise restore it."
  (if (> arg 0)
      (unless my/writeroom-saved-text-scale
        (setq my/writeroom-saved-text-scale
              (list text-scale-mode text-scale-mode-amount))
        (text-scale-set (1+ (if text-scale-mode text-scale-mode-amount 0))))
    (when my/writeroom-saved-text-scale
      (setq text-scale-mode-amount (cadr my/writeroom-saved-text-scale))
      (text-scale-mode (if (car my/writeroom-saved-text-scale) 1 -1))
      (setq my/writeroom-saved-text-scale nil))))

(defvar-local my/writeroom-saved-visual-line nil
  "Visual-line state on entering Writeroom, wrapped in a list.")

;;;###autoload
(defun my/writeroom-visual-line (arg)
  "Enable wrapping for positive ARG; restore its prior state otherwise."
  (if (> arg 0)
      (progn
        (unless my/writeroom-saved-visual-line
          (setq my/writeroom-saved-visual-line (list visual-line-mode)))
        (visual-line-mode 1))
    (when my/writeroom-saved-visual-line
      (visual-line-mode (if (car my/writeroom-saved-visual-line) 1 -1))
      (setq my/writeroom-saved-visual-line nil))))

;;;###autoload
(defun my/modeline-status ()
  "Return a quiet read-only marker and exceptional editing states."
  (concat
   (when buffer-read-only
     (propertize " RO " 'face 'shadow 'help-echo "Read-only buffer"))
   (when (file-remote-p default-directory) " Remote ")
   (when (buffer-narrowed-p) " Narrow ")
   (when defining-kbd-macro " Recording ")))

;;;###autoload
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

;;;###autoload
(defun my/modeline-details-p (minimum-width)
  "Whether secondary details fit in the active window at MINIMUM-WIDTH."
  (and (mode-line-window-selected-p)
       (>= (- (window-total-width) (string-width (my/modeline-status)))
           minimum-width)))

;;;###autoload
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

;;;###autoload
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

;;;###autoload
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

(provide 'my-ui)
;;; my-ui.el ends here