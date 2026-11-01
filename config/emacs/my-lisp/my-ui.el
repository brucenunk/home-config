;;; my-ui.el --- Appearance and mode line helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/viewport-prompt-variable-pitch
;;   - my/refresh-mixed-pitch-mode
;;   - my/doric-theme-preload
;;   - my/auto-dark-select-themes
;;   - my/fontaine-setup-frame
;;   - my/fontaine-preview-presets
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
(require 'button)

(declare-function mixed-pitch-mode "mixed-pitch" (&optional arg))
(declare-function fontaine-set-preset "fontaine" (preset))

(defvar fontaine-presets)
(defvar fontaine-preset-history)

(defvar mixed-pitch-mode)

(defvar vc-mode)

(defvar display-time-string)

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
  "Refresh mixed-pitch-mode in all buffers where it's active.
Do nothing before mixed-pitch has loaded."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (bound-and-true-p mixed-pitch-mode)
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
             'iosevka-fixed-ss14-jetbrains-mono)))))))

(defun my/ui--fontaine-preview-families (preset)
  "Resolve PRESET's default, fixed-pitch and prose families.
Match Fontaine's single named inheritance layer, followed by the t
preset (or generic families when t is absent).  Explicit nil values
mask inherited values, just as they do in Fontaine.  A face without
a configured family uses its current family."
  (let* ((own (alist-get preset fontaine-presets))
         (properties
          (append own
                  (alist-get (plist-get own :inherit) fontaine-presets)
                  (or (alist-get t fontaine-presets)
                      '(:default-family "Monospace"
                        :fixed-pitch-family "Monospace"
                        :variable-pitch-family "Sans"))))
         (default (or (plist-get properties :default-family)
                      (face-attribute 'default :family nil t))))
    (list default
          (or (plist-get properties :fixed-pitch-family) default)
          (or (plist-get properties :variable-pitch-family)
              (face-attribute 'variable-pitch :family nil t)))))

(defun my/ui--fontaine-preview-apply (button)
  "Apply BUTTON's Fontaine preset without leaving the specimen buffer."
  (let ((preset (button-get button 'my/ui-preset)))
    ;; Fontaine persists prompt history, not `fontaine-current-preset'.
    ;; Buttons bypass the prompt, so record the choice before its save hook.
    (add-to-history 'fontaine-preset-history (symbol-name preset))
    (fontaine-set-preset preset)))

(define-derived-mode my/ui--fontaine-preview-mode special-mode "Fontaine Preview"
  "Compare Fontaine families independently of the active preset."
  (button-mode 1)
  (setq-local revert-buffer-function #'my/ui--fontaine-preview-render)
  (setq-local truncate-lines t)
  ;; These are explicit specimens, not prose following the active preset.
  (setq-local face-remapping-alist nil))

(defun my/ui--fontaine-preview-render (&rest _)
  "Render current Fontaine presets; also serve as the revert function."
  (require 'fontaine)
  (let ((inhibit-read-only t)
        (position (point))
        ;; Query once per explicit refresh, not once per sample or redisplay.
        (available (mapcar #'downcase (font-family-list))))
    (erase-buffer)
    (insert "FONTAINE PRESETS\n\n"
            "TAB: next preset button; RET: apply; g: refresh; q: return.\n"
            "Uniform 13pt, normal-width samples in regular, italic and bold.\n"
            "Preset sizes and style-face overrides are not simulated.\n"
            "Missing families are flagged, not rendered using a fallback.\n\n")
    (dolist (preset fontaine-presets)
      (unless (eq (car preset) t)
        (let ((families (my/ui--fontaine-preview-families (car preset))))
          (insert-text-button (symbol-name (car preset))
                              'my/ui-preset (car preset)
                              'action #'my/ui--fontaine-preview-apply
                              'follow-link t)
          (insert (format "\nDefault family: %s\n" (car families)))
          (dolist (entry (list (cons "Fixed pitch" (cadr families))
                              (cons "Variable pitch" (caddr families))))
            (let* ((family (cdr entry))
                   (present (or (member (downcase family) available)
                                ;; Fontconfig aliases need not be enumerated.
                                (member (downcase family)
                                        '("monospace" "sans" "sans-serif" "serif")))))
              (insert (format "%s: %s%s\n" (car entry) family
                              (if present "" " [NOT AVAILABLE]")))
              (when present
                (dolist (style '(regular italic bold))
                  (insert
                   (propertize
                    (format "  %-7s a ag gq il1 IIl| 0OQ 0123456789 {} [] () -> => !=\n"
                            style)
                    'face (list :family family :height 130 :width 'normal
                                :weight (if (eq style 'bold) 'bold 'normal)
                                :slant (if (eq style 'italic) 'italic 'normal))))))))
          (insert "\n"))))
    (goto-char (min position (point-max)))
    (set-buffer-modified-p nil)))

;;;###autoload
(defun my/fontaine-preview-presets ()
  "Show a specimen buffer generated from `fontaine-presets'.
Resolve named inheritance and shared defaults without changing the
active preset.  Show fixed-pitch and variable-pitch families at a
uniform size, width and set of styles, flagging unavailable families.
Use RET on a preset button to apply it, g to refresh, and q to quit.
This is generated rich text: saving it as plain text loses its faces
and buttons.  Run this command again to recreate it."
  (interactive)
  (require 'fontaine)
  (unless (display-graphic-p)
    (user-error "Font specimens require a graphical Emacs frame"))
  (let ((buffer (get-buffer-create "*Fontaine presets*")))
    (with-current-buffer buffer
      (unless (eq major-mode 'my/ui--fontaine-preview-mode)
        (unless (and (= (buffer-size) 0) (not buffer-file-name))
          (user-error "Buffer %s is already in use" (buffer-name)))
        (my/ui--fontaine-preview-mode))
      (my/ui--fontaine-preview-render))
    (pop-to-buffer buffer)))

(defvar-local my/writeroom-saved-text-scale nil
  "Text scaling state to restore when leaving Writeroom.
Stored as (MODE AMOUNT), or nil outside the writing view.")

(defvar-local my/ui--writeroom-scaled-p nil
  "Whether Writeroom's extra text scaling is currently applied.")

(defun my/ui--writeroom-scale-restore ()
  "Restore the saved text scale without discarding the writing baseline."
  (setq text-scale-mode-amount (cadr my/writeroom-saved-text-scale))
  (text-scale-mode (if (car my/writeroom-saved-text-scale) 1 -1)))

(defun my/ui--writeroom-scale-update ()
  "Update writing scale for ordinary windows in the selected frame.
This buffer-local window hook runs with a displaying window selected.
Text scaling is buffer-local; two windows showing this buffer still
count as a split.  Cross-frame coordination is intentionally unsupported."
  (when my/writeroom-saved-text-scale
    (let ((enlarge (= (length (window-list nil 'nomini)) 1)))
      (unless (eq enlarge my/ui--writeroom-scaled-p)
        (setq my/ui--writeroom-scaled-p enlarge)
        (if enlarge
            (text-scale-set
             (1+ (if (car my/writeroom-saved-text-scale)
                     (cadr my/writeroom-saved-text-scale)
                   0)))
          (my/ui--writeroom-scale-restore))))))

;;;###autoload
(defun my/writeroom-text-scale (arg)
  "For positive ARG, enlarge writing text only in a single-window layout.
Otherwise restore the original buffer-local scale and stop tracking layouts."
  (if (> arg 0)
      (progn
        (unless my/writeroom-saved-text-scale
          (setq my/writeroom-saved-text-scale
                (list text-scale-mode text-scale-mode-amount)))
        (add-hook 'window-configuration-change-hook
                  #'my/ui--writeroom-scale-update nil t)
        (my/ui--writeroom-scale-update))
    (remove-hook 'window-configuration-change-hook
                 #'my/ui--writeroom-scale-update t)
    (when my/writeroom-saved-text-scale
      (my/ui--writeroom-scale-restore)
      (setq my/writeroom-saved-text-scale nil
            my/ui--writeroom-scaled-p nil))))

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