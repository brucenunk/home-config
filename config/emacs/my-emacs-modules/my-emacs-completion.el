;;; my-emacs-completion.el --- Completion and minibuffer configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Savehist, which-key, vertico, orderless, marginalia, corfu, cape, consult,
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
  (marginalia-mode)
  :config
  (defun my/project-git-branch (directory)
    "Return DIRECTORY's current Git branch, or `detached'."
    (let* ((dot-git (expand-file-name ".git" directory))
           (git-directory
            (cond
             ((file-directory-p dot-git) dot-git)
             ((file-regular-p dot-git)
              (with-temp-buffer
                (insert-file-contents dot-git)
                (let ((gitdir (string-trim (buffer-string))))
                  (when (string-prefix-p "gitdir: " gitdir)
                    (expand-file-name
                     (string-remove-prefix "gitdir: " gitdir)
                     directory)))))))
           (head-file (and git-directory
                           (expand-file-name "HEAD" git-directory))))
      (when (and head-file (file-readable-p head-file))
        (with-temp-buffer
          (insert-file-contents head-file)
          (let ((head (string-trim (buffer-string))))
            (cond
             ((string-prefix-p "ref: refs/heads/" head)
              (string-remove-prefix "ref: refs/heads/" head))
             ((string-match-p "\\`[[:xdigit:]]+\\'" head) "detached")))))))

  (defun my/marginalia-annotate-project-file (candidate)
    "Annotate project CANDIDATE with its Git branch when appropriate.
Detached Git worktrees are labelled `detached'.  Other project-file
candidates retain Marginalia's standard file annotation."
    (if (and (file-name-absolute-p candidate)
             (not (file-remote-p candidate))
             (file-directory-p candidate))
        (let ((default-directory
               (file-name-as-directory (expand-file-name candidate))))
          (let ((branch (my/project-git-branch default-directory)))
            (if branch
                (let ((detached (equal branch "detached")))
                  (marginalia--fields
                   ((if detached "-" branch)
                    :face (if detached
                              'marginalia-null
                            'marginalia-value))))
              (marginalia-annotate-project-file candidate))))
      (marginalia-annotate-project-file candidate)))

  (setf (alist-get 'project-file marginalia-annotators)
        (cons #'my/marginalia-annotate-project-file
              (remove #'my/marginalia-annotate-project-file
                      (alist-get 'project-file marginalia-annotators)))))

;; Completion.
;; https://github.com/minad/corfu
(defun my/corfu-enable-auto ()
  "Enable Corfu automatic completion in the current supported buffer."
  (setq-local corfu-auto t))

(use-package corfu
  :ensure nil
  :demand t
  :hook ((prog-mode eshell-mode) . my/corfu-enable-auto)
  :init
  ;; Must be set before calling `global-corfu-mode'.
  (setq corfu-auto nil
        corfu-auto-delay 0.1
        corfu-auto-prefix 2
        corfu-separator ?\s)
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

;; https://github.com/minad/cape
(use-package cape
  :ensure nil
  :demand t
  :config
  (defun my/cape-file-capf (directory)
    "Return a `cape-file' CAPF which resolves relative to DIRECTORY."
    (let ((cape-file-directory directory))
      (pcase (cape-file)
        (`(,beg ,end ,table . ,properties)
         (let* ((properties (copy-sequence properties))
                (location (plist-get properties :company-location)))
           (when location
             (setq properties
                   (plist-put
                    properties :company-location
                    (lambda (&rest args)
                      (let ((default-directory directory))
                        (apply location args))))))
           `(,beg ,end
                  ,(lambda (string predicate action)
                     (let ((default-directory directory))
                       (complete-with-action action table string predicate)))
                  ,@properties))))))

  (defun my/cape-file (prefix)
    "Complete a file, prompting for a temporary base directory with PREFIX."
    (interactive "P")
    (if prefix
        (let ((directory
               (read-directory-name "File completion base directory: "
                                    default-directory nil t)))
          (cape-interactive
           '(cape-file-directory-must-exist)
           (lambda () (my/cape-file-capf directory))))
      (cape-file t)))

  (defun my/cape-dabbrev-capf ()
    "Complete via `cape-dabbrev' after a three-character prefix."
    (funcall (cape-capf-prefix-length #'cape-dabbrev 3)))

  (keymap-set cape-prefix-map "f" #'my/cape-file)
  (keymap-global-set "C-c p" cape-prefix-map)
  (add-hook 'completion-at-point-functions #'my/cape-dabbrev-capf 90))

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
