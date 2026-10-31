;;; my-languages.el --- Language tooling helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/eglot-before-save-hook
;;   - my/eglot-ensure-if-server-available

;;; Code:

(require 'cl-lib)

(defvar my/eglot-mode-server-executables nil
  "Language server executables for automatic Eglot startup.")

;;;###autoload
(defun my/eglot-before-save-hook ()
  "Format buffer before save"
  (when (eglot-managed-p)
    (add-hook 'before-save-hook #'eglot-format-buffer t t)))

;;;###autoload
(defun my/eglot-ensure-if-server-available ()
  "Start Eglot when the current mode has an available language server."
  (when-let* ((server-executable (alist-get major-mode my/eglot-mode-server-executables)))
    (when (executable-find server-executable t)
      (eglot-ensure))))

(provide 'my-languages)
;;; my-languages.el ends here