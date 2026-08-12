;;; my-emacs-completion.el --- Completion and minibuffer configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Savehist, which-key, vertico, orderless, marginalia, corfu, consult,
;; embark, and avy configuration.

;;; Code:

(use-package savehist
  :ensure nil
  :hook (after-init . savehist-mode)
  :config
  (setq savehist-file (locate-user-emacs-file "savehist"))
  (setq history-length 100)
  (setq history-delete-duplicates t)
  (setq savehist-save-minibuffer-history t))

(use-package which-key
  :ensure nil
  :hook (after-init . which-key-mode)
  :config
  (setq which-key-add-column-padding 1)
  (setq which-key-idle-delay 1.5)
  (setq which-key-max-description-length 40)
  (setq which-key-prefix-prefix "... ")
  (setq which-key-separator "  "))

;; Pimp the minibuffer.
;; https://github.com/minad/vertico
(use-package vertico
  :ensure nil
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy)
  :init
  (vertico-mode))

;; https://github.com/oantolin/orderless
(use-package orderless
  :ensure nil
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles basic partial-completion)))))

;; https://github.com/minad/marginalia
(use-package marginalia
  :ensure nil
  :init
  (marginalia-mode))

;; Completion.
;; https://github.com/minad/corfu
(use-package corfu
  :ensure nil
  :init
  ;; Must be set before calling `global-corfu-mode'.
  (setq corfu-auto t
        corfu-auto-delay 0.1
        corfu-auto-prefix 2
        corfu-separator ?\s
        corfu-excluded-modes '(eshell-mode
                               ghostel-mode
                               help-mode))
  :custom
  (corfu-cycle t)
  (corfu-preselect 'prompt)
  (corfu-preview-current 'insert)
  (corfu-on-exact-match nil)
  (corfu-quit-at-boundary t)
  (corfu-quit-no-match 'separator)

  :config
  ;; Enable indentation+completion using the TAB key.
  (setq tab-always-indent 'complete)
  (global-corfu-mode))

(use-package corfu-popupinfo
  :ensure nil
  :hook (corfu-mode . corfu-popupinfo-mode)
  :custom (corfu-popupinfo-delay '(0.2 . 0.1)))

(use-package consult
  :ensure nil
  :bind
  (;; C-c bindings in `mode-specific-map'
   ("C-c i" . consult-info)
   ;; C-x bindings in `ctl-x-map'
   ("C-x b" . consult-buffer)
   ;; M-g bindings in `goto-map'
   ("M-g f" . consult-flymake)
   ;; M-s bindings in `search-map'
   ("M-s d" . consult-fd)
   ("M-s r" . consult-ripgrep)
   ("M-s l" . consult-line)
   ("M-s L" . consult-line-thing-at-point))
  :demand t
  :config
  ;; Use Consult to select xref locations with preview
  (declare-function consult-xref "consult-xref")
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref)
  (consult-customize
   consult-line
   :add-history (seq-some #'thing-at-point '(region symbol)))

  (defalias 'consult-line-thing-at-point 'consult-line)

  (consult-customize
   consult-line-thing-at-point
   :initial (thing-at-point 'symbol)))

(use-package embark
  :ensure nil
  :bind
  (("C-." . embark-act)))

(use-package embark-consult
  :ensure nil
  :after (embark consult)
  :hook
  (embark-collect-mode . consult-preview-at-point-mode))

;; https://github.com/abo-abo/avy
(use-package avy
  :ensure nil
  :custom
  (avy-all-windows t)
  (avy-dispatch-alist
   '((?K . avy-action-kill-move)
     (?k . avy-action-kill-stay)
     (?l . avy-action-teleport)
     (?m . avy-action-mark)
     (?w . avy-action-copy)
     (?y . avy-action-yank)
     (?Y . avy-action-yank-line)))
  (avy-keys '(?a ?t ?e ?n ?i ?c))
  (avy-style 'de-bruijn)
  :bind
  ("C-'" . avy-goto-char-timer))

(provide 'my-emacs-completion)
;;; my-emacs-completion.el ends here
