;;; my-emacs-deferred-tests.el --- Deferred registration checks -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'use-package)

(defconst my/deferred-test--directory
  (file-name-directory (locate-library "my-emacs-completion")))

(defun my/deferred-test--declaration (file package)
  "Read PACKAGE's single top-level declaration from FILE."
  (let (declarations)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (eq (car-safe form) 'use-package)
                         (eq (nth 1 form) package))
                (push form declarations))))
        (end-of-file nil)))
    (should (= (length declarations) 1))
    (car declarations)))

(defun my/deferred-test--fresh (&rest forms)
  "Evaluate FORMS in isolated batch Emacs with the same package paths."
  (with-temp-buffer
    (let ((status
           (call-process
            (expand-file-name invocation-name invocation-directory) nil t nil
            "--batch" "-Q"
            "--eval" (prin1-to-string `(setq load-path ',load-path))
            "--eval" "(require 'ert)"
            "--eval" "(require 'use-package)"
            "--eval" (prin1-to-string `(progn ,@forms)))))
      (ert-info ((buffer-string)) (should (equal status 0))))))

(ert-deftest my/deferred-embark-reference-registration-load-orders ()
  (dolist (order '((my-emacs-agents my-emacs-completion consult embark)
                   (consult embark my-emacs-agents my-emacs-completion)
                   (embark consult my-emacs-completion my-emacs-agents)
                   (embark-consult my-emacs-completion my-emacs-agents)
                   (embark-consult my-emacs-agents my-emacs-completion)
                   (my-emacs-completion embark my-emacs-agents consult)))
    (ert-info (order)
      (my/deferred-test--fresh
       ;; Disable only background cleanup; never launch an agent/session.
       '(require 'agent-shell-gc)
       '(advice-add 'agent-shell-gc-mode :override #'ignore)
       `(dolist (feature ',order) (require feature))
       '(should (featurep 'embark-consult))
       '(should (eq (lookup-key embark-file-map (kbd "@"))
                    #'my/agent-shell-insert-reference))
       '(should (eq (keymap-parent my/agent-shell-reference-map) embark-general-map))
       '(should (eq (lookup-key my/agent-shell-reference-map (kbd "@"))
                    #'my/agent-shell-insert-reference))
       '(should (equal (alist-get 'consult-grep embark-keymap-alist)
                       '(my/agent-shell-reference-map)))
       '(should (equal (alist-get 'my/agent-shell-insert-reference
                                 embark-around-action-hooks)
                       '(my/agent-shell--reference-action)))
       '(should (memq #'consult-preview-at-point-mode embark-collect-mode-hook))))))

(ert-deftest my/deferred-embark-consult-has-explicit-load-trigger ()
  (my/deferred-test--fresh
   ;; Embark itself currently loads embark-consult when Consult arrives.  Unload
   ;; that integration in this child to check our declaration's own load trigger.
   '(require 'embark)
   '(require 'consult)
   '(when (featurep 'embark-consult) (unload-feature 'embark-consult t))
   '(should-not (featurep 'embark-consult))
   (my/deferred-test--declaration
    (expand-file-name "my-emacs-completion.el" my/deferred-test--directory)
    'embark-consult)
   '(should (featurep 'embark-consult))))

(ert-deftest my/deferred-completion-does-not-force-agent-module ()
  (my/deferred-test--fresh
   '(require 'my-emacs-completion)
   '(require 'embark)
   '(should (featurep 'embark-consult))
   '(should-not (featurep 'my-agent-shell))
   '(should-not (featurep 'agent-shell))))

(ert-deftest my/deferred-eglot-nix-registration-load-orders ()
  (let ((declaration (my/deferred-test--declaration (locate-library "my-emacs-languages") 'eglot)))
    (dolist (loaded '(nil t))
      (my/deferred-test--fresh
       `(when ,loaded (require 'eglot))
       declaration
       `(should (eq (featurep 'eglot) ,loaded))
       '(require 'eglot)
       '(should (equal (alist-get 'nix-ts-mode eglot-server-programs)
                       '("nixd" :initializationOptions
                         (:formatting (:command ["nixfmt"])))))))))

(ert-deftest my/deferred-magit-diff-binding-load-orders ()
  (let ((declaration (my/deferred-test--declaration (locate-library "my-emacs-git") 'magit-diff)))
    (dolist (loaded '(nil t))
      (my/deferred-test--fresh
       `(when ,loaded (require 'magit-diff))
       declaration
       `(should (eq (featurep 'magit-diff) ,loaded))
       '(require 'magit-diff)
       '(should (eq (lookup-key magit-diff-mode-map (kbd "C-c r"))
                    #'my/agent-shell-quote-region))
       '(should (eq (lookup-key magit-diff-mode-map (kbd "r")) #'magit-rebase))
       '(should-not (eq (lookup-key magit-mode-map (kbd "C-c r"))
                        #'my/agent-shell-quote-region))))))

(ert-deftest my/deferred-go-association-in-mode-declaration ()
  (my/deferred-test--fresh
   '(should-not (featurep 'go-ts-mode))
   (my/deferred-test--declaration (locate-library "my-emacs-languages") 'go-ts-mode)
   '(should-not (featurep 'go-ts-mode))
   '(should (eq (cdr (assoc "\\.go\\'" auto-mode-alist)) 'go-ts-mode))))

(ert-deftest my/deferred-prose-registration-load-orders ()
  (dolist (entry '((org my-emacs-org org-mode-hook my/org-refresh-heading-scaling)
                   (markdown-mode my-emacs-writing markdown-mode-hook
                                  my/markdown-refresh-heading-scaling)))
    (dolist (loaded '(nil t))
      (pcase-let ((`(,package ,module ,hook ,refresh) entry))
        (my/deferred-test--fresh
         `(when ,loaded (require ',package))
         `(require ',module)
         `(should (eq (featurep ',package) ,loaded))
         `(require ',package)
         `(should (memq #'my/prose-wrap ,hook))
         `(should (memq #',refresh enable-theme-functions))
         `(when (eq ',package 'org)
            (should (advice-member-p #'my/org-fontify-comment-block
                                     'org-fontify-meta-lines-and-blocks))))))))

(ert-deftest my/deferred-org-drawings-load-editor-configuration-independently ()
  (dolist (org-first '(nil t))
    (my/deferred-test--fresh
     '(should-not (featurep 'my-emacs-excali))
     `(when ,org-first (require 'org))
     '(require 'my-emacs-org-excali)
     '(should (featurep 'my-emacs-excali))
     '(should-not (featurep 'excali))
     '(require 'org)
     '(should (eq (org-link-get-parameter "excali" :follow) #'my/excali--org-follow))
     '(require 'excali)
     '(should (advice-member-p #'my/excali--new-drawing 'excali-new))
     '(should (advice-member-p #'my/excali--history-snapshot 'excali--snapshot))
     '(should (memq #'my/excali--setup-buffer excali-mode-hook)))))

(ert-deftest my/deferred-denote-auto-revert-load-orders ()
  (dolist (loaded '(nil t))
    (my/deferred-test--fresh
     `(when ,loaded (require 'autorevert))
     '(require 'my-denote)
     '(my/denote-register-auto-revert)
     `(should (eq (featurep 'autorevert) ,loaded))
     '(require 'autorevert)
     '(should (advice-member-p #'my/denote-task-auto-revert-suppress-redisplay
                              'auto-revert-handler))
     '(should (advice-member-p #'my/denote-task-auto-revert-debounce-notify
                              'auto-revert-notify-handler)))))

(ert-deftest my/deferred-agent-header-hooks-load-orders ()
  (let ((declaration (my/deferred-test--declaration
                      (locate-library "my-emacs-agents") 'agent-shell)))
    (dolist (loaded '(nil t))
      (my/deferred-test--fresh
       '(require 'my-agent-shell)
       `(when ,loaded (require 'agent-shell))
       declaration
       `(should (eq (featurep 'agent-shell) ,loaded))
       '(should (fboundp 'my/agent-shell-header-no-underline))
       '(dolist (hook '(agent-shell-mode-hook
                       agent-shell-viewport-view-mode-hook
                       agent-shell-viewport-edit-mode-hook))
          (should (memq #'my/agent-shell-header-no-underline
                        (symbol-value hook))))))))

(ert-deftest my/deferred-agent-table-shading-load-orders ()
  (let ((declaration (my/deferred-test--declaration
                      (locate-library "my-emacs-agents") 'agent-shell)))
    (dolist (loaded '(nil t))
      (dolist (theme-first '(nil t))
        (my/deferred-test--fresh
         '(require 'my-agent-shell)
         '(require 'my-ui)
         `(when ,loaded (require 'agent-shell))
         '(my/doric-theme-preload 'doric-earth)
         `(when ,theme-first (enable-theme 'doric-earth))
         declaration
         `(should (eq (featurep 'agent-shell) ,loaded))
         '(require 'agent-shell)
         `(unless ,theme-first (enable-theme 'doric-earth))
         '(should (memq #'my/agent-shell-table-faces-refresh enable-theme-functions))
         '(should (equal (face-background 'agent-shell-markdown-table-zebra nil t)
                         (doric-themes-with-colors bg-shadow-subtle))))))))

(ert-deftest my/deferred-mixed-pitch-hooks-load-orders ()
  (let ((declaration (my/deferred-test--declaration
                      (locate-library "my-emacs-ui") 'mixed-pitch)))
    (dolist (loaded '(nil t))
      (my/deferred-test--fresh
       '(require 'my-ui)
       `(when ,loaded (require 'mixed-pitch))
       declaration
       `(should (eq (featurep 'mixed-pitch) ,loaded))
       '(dolist (hook '(markdown-mode-hook org-mode-hook
                       agent-shell-viewport-view-mode-hook
                       agent-shell-viewport-edit-mode-hook))
          (should (memq #'mixed-pitch-mode (symbol-value hook))))
       '(should (memq #'my/viewport-prompt-variable-pitch mixed-pitch-mode-hook))
       '(should (memq #'my/refresh-mixed-pitch-mode fontaine-set-preset-hook))
       ;; Fontaine can change fonts before mixed-pitch has ever loaded.
       '(run-hooks 'fontaine-set-preset-hook)
       `(should (eq (featurep 'mixed-pitch) ,loaded))
       '(require 'mixed-pitch)
       '(should (memq #'my/viewport-prompt-variable-pitch mixed-pitch-mode-hook))))))

(ert-deftest my/deferred-fontaine-registers-real-frame-hook ()
  (my/deferred-test--fresh
   '(require 'my-ui)
   (my/deferred-test--declaration (locate-library "my-emacs-ui") 'fontaine)
   '(should (memq #'my/fontaine-setup-frame after-init-hook))
   '(should (memq #'my/fontaine-setup-frame after-make-frame-functions))
   '(should-not (memq #'my/fontaine-setup-frame
                      (and (boundp 'after-make-frame-functions-hook)
                           after-make-frame-functions-hook)))))

(ert-deftest my/deferred-fontaine-iosevka-comparison-presets ()
  (my/deferred-test--fresh
   (my/deferred-test--declaration (locate-library "my-emacs-ui") 'fontaine)
   '(require 'fontaine)
   '(let* ((defaults (alist-get t fontaine-presets))
           (presets (seq-filter
                     (lambda (preset)
                       (string-prefix-p "iosevka-" (symbol-name (car preset))))
                     fontaine-presets))
           (families (mapcar (lambda (preset)
                              (plist-get (cdr preset) :default-family))
                            presets)))
      (should (equal (mapcar #'car presets)
                     '(iosevka-fixed iosevka-fixed-ss14-jetbrains-mono)))
      (should (equal (plist-get defaults :default-family) "Iosevka Fixed SS14"))
      (should (equal (plist-get defaults :fixed-pitch-family) "Iosevka Fixed SS14"))
      (should (equal (plist-get defaults :variable-pitch-family) "Bricolage Grotesque"))
      (should (equal (plist-get (alist-get 'aporetic-serif-mono fontaine-presets)
                                :default-family)
                     "Aporetic Serif Mono"))
      (should (assq 'aporetic-sans-mono fontaine-presets))
      (should (equal families '("Iosevka Fixed" "Iosevka Fixed SS14")))
      (dolist (preset presets)
        (should (equal (plist-get (cdr preset) :default-family)
                       (plist-get (cdr preset) :fixed-pitch-family)))
        ;; Inherit Bricolage and the existing sizes rather than overriding them.
        (dolist (property '(:variable-pitch-family :default-height
                            :fixed-pitch-height :variable-pitch-height))
          (should-not (plist-member (cdr preset) property)))))))

(ert-deftest my/deferred-fontaine-preview-keeps-package-lazy ()
  (my/deferred-test--fresh
   '(require 'my-ui)
   '(should (commandp 'my/fontaine-preview-presets))
   '(should-not (featurep 'fontaine))
   (my/deferred-test--declaration (locate-library "my-emacs-ui") 'fontaine)
   '(should (eq (key-binding (kbd "C-c M-f")) #'my/fontaine-preview-presets))
   '(should-not (featurep 'fontaine))))

(ert-deftest my/deferred-forge-options-load-orders ()
  (let ((declaration (my/deferred-test--declaration
                      (locate-library "my-emacs-git") 'forge)))
    (dolist (loaded '(nil t))
      (my/deferred-test--fresh
       `(when ,loaded (require 'magit))
       declaration
       `(should (eq (featurep 'magit) ,loaded))
       '(require 'magit)
       '(require 'forge)
       '(should-not forge-add-default-sections)
       '(should-not forge-add-pullreq-refspec)))))

(ert-deftest my/deferred-denote-configuration-load-orders ()
  (dolist (loaded '(nil t))
    (my/deferred-test--fresh
     `(when ,loaded (require 'denote))
     '(require 'my-emacs-denote)
     '(should (eq denote-file-type 'org))
     '(should (equal denote-directory (expand-file-name "~/work/docs/")))
     '(should (equal denote-dired-directories (list denote-directory)))
     '(should (assq 'task-workflow denote-templates))
     '(should (memq #'my/denote-startup emacs-startup-hook))
     '(should (memq #'my/denote-rename-new-buffer-maybe find-file-hook))
     '(should (memq #'my/denote-task-auto-revert-enable-maybe find-file-hook))
     '(should (memq #'my/denote-rename-new-buffer-maybe denote-after-new-note-hook))
     '(should-not (memq #'denote-rename-buffer-rename-function-or-fallback
                        denote-after-new-note-hook))
     '(should-not (memq #'denote-rename-buffer-rename-function-or-fallback
                        find-file-hook)))))

(ert-deftest my/deferred-package-declarations-are-unique ()
  (let ((seen (make-hash-table :test #'eq)))
    (dolist (file (append (list (expand-file-name "../init.el" my/deferred-test--directory))
                          (directory-files my/deferred-test--directory t "\\.el\\'")
                          (directory-files (file-name-directory (locate-library "my-agent-shell"))
                                           t "\\.el\\'")))
      (unless (string-suffix-p "-tests.el" file)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (condition-case nil
              (while t
                (let ((form (read (current-buffer))))
                  (when (eq (car-safe form) 'use-package)
                    (let ((package (nth 1 form)))
                      (ert-info ((format "%s declared in %s and %s"
                                         package (gethash package seen) file))
                        (should-not (gethash package seen)))
                      (puthash package file seen)))))
            (end-of-file nil)))))))

(provide 'my-emacs-deferred-tests)
;;; my-emacs-deferred-tests.el ends here