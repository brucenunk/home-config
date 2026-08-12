;;; my-emacs-ui.el --- UI and appearance configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Theme, fonts, spacious-padding, pulsar configuration.

;;; Code:

(declare-function mixed-pitch-mode "mixed-pitch" (&optional arg))

(defvar mixed-pitch-mode)

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
               'bricolage-grotesque)))))))
  :hook
  ((after-init . my/fontaine-setup-frame)
   (after-make-frame-functions . my/fontaine-setup-frame))
  :bind ("C-c F" . fontaine-set-preset)
  :config
  (setq fontaine-presets
        '((t
           :default-family "JetBrains Mono"
           :default-height 140
           :fixed-pitch-family "JetBrains Mono"
           :fixed-pitch-height 1.0
           :variable-pitch-family "Bricolage Grotesque"
           :variable-pitch-height 1.0)
          (bricolage-grotesque)
          (open-sans
           :variable-pitch-family "Open Sans"))))

(use-package mixed-pitch
  :ensure nil
  :hook (markdown-mode . mixed-pitch-mode)
  :config
  (add-to-list 'mixed-pitch-fixed-pitch-faces 'markdown-table-face)
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
  (setq lin-face 'lin-blue)
  (lin-global-mode))

(provide 'my-emacs-ui)
;;; my-emacs-ui.el ends here
