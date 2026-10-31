;;; agent-shell-compose-block-edit-tests.el --- Isolated block editing tests -*- lexical-binding: t -*-

(require 'agent-shell-compose-tests)
(require 'agent-shell-compose-block-edit)

(defun agent-shell-compose-block-edit-test--draft (markup language body)
  "Return a draft containing BODY in MARKUP with LANGUAGE."
  (if (eq markup 'org)
      (concat "Before\n#+begin_src " language "\n" body "#+end_src\nAfter\n")
    (concat "Before\n```" language "\n" body "```\nAfter\n")))

(defmacro agent-shell-compose-block-edit-test--with-editor (markup draft &rest body)
  "Open DRAFT's block using MARKUP; run BODY with `source' and `editor' bound."
  (declare (indent 2))
  `(agent-shell-compose-test--with-composer ,markup
     (insert ,draft)
     (goto-char (point-min)) (forward-line 2)
     (let ((source (current-buffer)) editor)
       (unwind-protect
           (save-window-excursion
             (agent-shell-compose-block-edit)
             (setq editor (current-buffer))
             ,@body)
         (when (buffer-live-p editor)
           (with-current-buffer editor
             (set-buffer-modified-p nil) (kill-buffer editor)))))))

(ert-deftest agent-shell-compose-block-edit-native-mode-and-finish ()
  (dolist (markup '(org markdown))
    (let ((draft (agent-shell-compose-block-edit-test--draft
                  markup "emacs-lisp" "  (message \"body\")\n")))
      (agent-shell-compose-block-edit-test--with-editor markup draft
        (should (eq major-mode 'emacs-lisp-mode))
        (should rainbow-delimiters-mode)
        (should-not (bound-and-true-p mixed-pitch-mode))
        (should (equal (buffer-string) "  (message \"body\")\n"))
        (should (eq (key-binding (kbd "C-c C-c")) #'agent-shell-compose-block-edit-finish))
        (goto-char (point-min)) (search-forward "body") (replace-match "edited")
        (font-lock-ensure)
        (agent-shell-compose-block-edit-finish)
        (should (eq (current-buffer) source))
        (should-not (buffer-live-p editor))
        (should (eq major-mode 'agent-shell-viewport-edit-mode))
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       (agent-shell-compose-block-edit-test--draft
                        markup "emacs-lisp" "  (message \"edited\")\n")))))))

(ert-deftest agent-shell-compose-block-edit-native-language-modes ()
  (dolist (markup '(org markdown))
    (dolist (pair '(("diff" . diff-mode) ("python" . python-mode)
                    ("unknown-language" . fundamental-mode) ("" . fundamental-mode)))
      (agent-shell-compose-block-edit-test--with-editor markup
          (agent-shell-compose-block-edit-test--draft markup (car pair) "body\n")
        (should (eq major-mode (cdr pair)))
        (agent-shell-compose-block-edit-cancel)))))

(ert-deftest agent-shell-compose-block-edit-cancel-does-not-change-draft ()
  (dolist (markup '(org markdown))
    (let ((draft (agent-shell-compose-block-edit-test--draft markup "diff" "body\n")))
      (agent-shell-compose-block-edit-test--with-editor markup draft
        (erase-buffer) (insert "replacement\n")
        (agent-shell-compose-block-edit-cancel)
        (should (eq (current-buffer) source))
        (should-not (buffer-live-p editor))
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) draft))))))

(ert-deftest agent-shell-compose-block-edit-refuses-composer-text-changes ()
  (dolist (markup '(org markdown))
    (agent-shell-compose-block-edit-test--with-editor markup
        (agent-shell-compose-block-edit-test--draft markup "diff" "body\n")
      (insert "edited")
      (with-current-buffer source (goto-char (point-max)) (insert "new draft text"))
      (let ((draft (with-current-buffer source (buffer-string))))
        (should-error (agent-shell-compose-block-edit-finish) :type 'user-error)
        (should (buffer-live-p editor))
        (should (string-prefix-p "edited" (buffer-string)))
        (with-current-buffer source (should (equal (buffer-string) draft)))))))

(ert-deftest agent-shell-compose-block-edit-refuses-mode-transitions ()
  (dolist (markup '(org markdown))
    (agent-shell-compose-block-edit-test--with-editor markup
        (agent-shell-compose-block-edit-test--draft markup "diff" "body\n")
      (with-current-buffer source (agent-shell-viewport-view-mode))
      (should-error (agent-shell-compose-block-edit-finish) :type 'user-error)
      (with-current-buffer source
        (agent-shell-viewport-edit-mode)
        (insert (agent-shell-compose-block-edit-test--draft markup "diff" "body\n")))
      (should-error (agent-shell-compose-block-edit-finish) :type 'user-error))))

(ert-deftest agent-shell-compose-block-edit-refuses-killed-source ()
  (agent-shell-compose-block-edit-test--with-editor 'org
      (agent-shell-compose-block-edit-test--draft 'org "diff" "body\n")
    (with-current-buffer source (set-buffer-modified-p nil) (kill-buffer source))
    (should-error (agent-shell-compose-block-edit-finish) :type 'user-error)
    (should (equal (buffer-string) "body\n"))
    (agent-shell-compose-block-edit-cancel)))

(ert-deftest agent-shell-compose-block-edit-preserves-closing-line ()
  (dolist (markup '(org markdown))
    (agent-shell-compose-block-edit-test--with-editor markup
        (agent-shell-compose-block-edit-test--draft markup "diff" "body\n")
      (erase-buffer) (insert "no trailing newline")
      (agent-shell-compose-block-edit-finish)
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     (agent-shell-compose-block-edit-test--draft
                      markup "diff" "no trailing newline\n"))))))

(ert-deftest agent-shell-compose-block-edit-refuses-delimiter-collisions ()
  (dolist (markup '(org markdown))
    (agent-shell-compose-block-edit-test--with-editor markup
        (agent-shell-compose-block-edit-test--draft markup "diff" "body\n")
      (erase-buffer) (insert (if (eq markup 'org) "#+END_SRC\n" "```\n"))
      (should-error (agent-shell-compose-block-edit-finish) :type 'user-error)
      (with-current-buffer source
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       (agent-shell-compose-block-edit-test--draft markup "diff" "body\n")))))))

(ert-deftest agent-shell-compose-block-edit-accepts-tilde-and-long-fences ()
  (dolist (fence '("~~~" "`````"))
    (agent-shell-compose-block-edit-test--with-editor 'markdown
        (concat "Before\n" fence "diff\nbody\n" fence "\nAfter\n")
      (should (eq major-mode 'diff-mode))
      (goto-char (point-max)) (insert "```\n")
      (agent-shell-compose-block-edit-finish)
      (should (string-match-p "body\n```\n" (buffer-string))))))

(ert-deftest agent-shell-compose-block-edit-rejects-incomplete-blocks-and-prose ()
  (dolist (markup '(org markdown))
    (agent-shell-compose-test--with-composer markup
      (insert (if (eq markup 'org) "#+begin_src diff\nbody\n" "```diff\nbody\n"))
      (goto-char (point-min)) (forward-line 1)
      (should-error (agent-shell-compose-block-edit) :type 'user-error)
      (erase-buffer) (insert "ordinary prose")
      (should-error (agent-shell-compose-block-edit) :type 'user-error))))

(ert-deftest agent-shell-compose-block-edit-write-back-is-undoable ()
  (dolist (markup '(org markdown))
    (let ((draft (agent-shell-compose-block-edit-test--draft markup "diff" "body\n")))
      (agent-shell-compose-block-edit-test--with-editor markup draft
        (with-current-buffer source
          (buffer-enable-undo)
          (setq buffer-undo-list nil))
        (erase-buffer) (insert "edited\n")
        (agent-shell-compose-block-edit-finish)
        (undo-boundary)
        (undo-only)
        (font-lock-ensure)
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) draft))
        (when (eq markup 'org)
          (with-current-buffer agent-shell-compose--org-buffer
            (should (equal (buffer-substring-no-properties (point-min) (point-max)) draft))))))))

(ert-deftest agent-shell-compose-block-edit-finish-widens-the-edit-copy ()
  (dolist (markup '(org markdown))
    (agent-shell-compose-block-edit-test--with-editor markup
        (agent-shell-compose-block-edit-test--draft
         markup "emacs-lisp" "(defun one () 1)\n(defun two () 2)\n")
      (goto-char (point-min)) (forward-line 1)
      (narrow-to-region (point) (point-max))
      (search-forward "2") (replace-match "3")
      (agent-shell-compose-block-edit-finish)
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     (agent-shell-compose-block-edit-test--draft
                      markup "emacs-lisp" "(defun one () 1)\n(defun two () 3)\n"))))))

(ert-deftest agent-shell-compose-block-edit-refuses-org-headlines ()
  (agent-shell-compose-block-edit-test--with-editor 'org
      (agent-shell-compose-block-edit-test--draft 'org "diff" "body\n")
    (erase-buffer) (insert "* Heading\n")
    (should-error (agent-shell-compose-block-edit-finish) :type 'user-error)
    (with-current-buffer source
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     (agent-shell-compose-block-edit-test--draft 'org "diff" "body\n"))))))

(ert-deftest agent-shell-compose-block-edit-does-not-strip-image-attachments ()
  (dolist (markup '(org markdown))
    (agent-shell-compose-test--with-composer markup
      (insert (agent-shell-compose-block-edit-test--draft markup "diff" "image\n"))
      (goto-char (point-min)) (search-forward "image")
      (add-text-properties (- (point) 5) (point)
                           '(agent-shell-context-image t display "image preview"))
      (let ((draft (buffer-string)))
        (should-error (agent-shell-compose-block-edit) :type 'user-error)
        (should (equal (substring-no-properties draft)
                       (buffer-substring-no-properties (point-min) (point-max))))
        (dotimes (n (length draft))
          (dolist (prop '(display agent-shell-context-image))
            (should (equal (get-text-property n prop draft)
                           (get-text-property (1+ n) prop)))))))))

(ert-deftest agent-shell-compose-block-edit-undo-cannot-remove-initial-body ()
  (dolist (markup '(org markdown))
    (agent-shell-compose-block-edit-test--with-editor markup
        (agent-shell-compose-block-edit-test--draft markup "diff" "body\n")
      (should-not buffer-undo-list)
      (should-error (undo-only) :type 'user-error)
      (goto-char (point-min)) (insert "edited ")
      (undo-boundary)
      (let ((last-command nil)) (undo-only))
      (should (equal (buffer-string) "body\n"))
      (let ((last-command 'undo))
        (should-error (undo-only) :type 'user-error))
      (should (equal (buffer-string) "body\n")))))

(ert-deftest agent-shell-compose-block-edit-restores-popup-and-reused-windows ()
  (dolist (markup '(org markdown))
    (dolist (action '(display-buffer-pop-up-window display-buffer-same-window))
      (dolist (return '(agent-shell-compose-block-edit-finish
                        agent-shell-compose-block-edit-cancel))
        (agent-shell-compose-test--with-composer markup
          (insert (agent-shell-compose-block-edit-test--draft markup "diff" "body\n"))
          (goto-char (point-min)) (forward-line 2)
          (let ((source (current-buffer))
                (other (generate-new-buffer " *compose-other-window*")) editor)
            (unwind-protect
                (save-window-excursion
                  (delete-other-windows)
                  (set-window-buffer (selected-window) source)
                  (set-window-buffer (split-window-right) other)
                  (let ((source-window (selected-window))
                        (before (mapcar (lambda (window)
                                          (list (window-buffer window) (window-edges window)))
                                        (window-list)))
                        (display-buffer-overriding-action (list (list action)))
                        (split-window-preferred-function
                         (lambda (window) (split-window window nil 'below))))
                    (agent-shell-compose-block-edit)
                    (setq editor (current-buffer))
                    (when (eq action 'display-buffer-pop-up-window)
                      (should (= (length (window-list)) 3)))
                    (insert "edited ")
                    (funcall return)
                    (should-not (buffer-live-p editor))
                    (should (eq (current-buffer) source))
                    (should (eq (selected-window) source-window))
                    (when (eq return 'agent-shell-compose-block-edit-finish)
                      (should (= (point)
                                 (+ (save-excursion
                                      (goto-char (point-min)) (forward-line 2) (point))
                                    (length "edited ")))))
                    (should (equal before
                                   (mapcar (lambda (window)
                                             (list (window-buffer window) (window-edges window)))
                                           (window-list))))))
              (when (buffer-live-p editor)
                (with-current-buffer editor
                  (set-buffer-modified-p nil) (kill-buffer editor)))
              (kill-buffer other))))))))

(ert-deftest agent-shell-compose-block-edit-keeps-controls-when-selecting-a-mode ()
  (dolist (markup '(org markdown))
    (dolist (return '(agent-shell-compose-block-edit-finish
                      agent-shell-compose-block-edit-cancel))
      (agent-shell-compose-block-edit-test--with-editor markup
          (agent-shell-compose-block-edit-test--draft markup "unknown-language" "body\n")
        (should (eq major-mode 'fundamental-mode))
        (emacs-lisp-mode)
        (should agent-shell-compose-block-edit-mode)
        (should (eq agent-shell-compose-block-edit--source source))
        (should (eq (key-binding (kbd "C-c C-c")) #'agent-shell-compose-block-edit-finish))
        (should (eq (key-binding (kbd "C-c C-k")) #'agent-shell-compose-block-edit-cancel))
        (goto-char (point-min)) (insert "edited ")
        (funcall return)
        (should (eq (current-buffer) source))
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       (agent-shell-compose-block-edit-test--draft
                        markup "unknown-language"
                        (if (eq return 'agent-shell-compose-block-edit-finish)
                            "edited body\n" "body\n"))))))))

(ert-deftest agent-shell-compose-block-edit-go-policy-matches-fontification ()
  (require 'go-ts-mode)
  ;; The minimal package check has no grammars; the configured-host run retains
  ;; Nix site-start and executes this test with the installed Go grammar.
  (skip-unless (treesit-ready-p 'go t))
  (let ((agent-shell-compose-language-modes '(("go" . go-ts-mode)))
        (auto-mode-alist (cons '("\\.go\\'" . go-ts-mode) auto-mode-alist))
        (go-ts-mode-hook nil))
    (dolist (markup '(org markdown))
      (agent-shell-compose-block-edit-test--with-editor markup
          (agent-shell-compose-block-edit-test--draft
           markup "go" "package main\nfunc main() { println(\"hello\") }\n")
        (should (eq major-mode 'go-ts-mode))
        (should-not buffer-file-name)
        (with-current-buffer source
          (font-lock-ensure)
          (should (memq 'font-lock-keyword-face (agent-shell-compose-test--faces "package"))))
        (agent-shell-compose-block-edit-cancel)))))

(ert-deftest agent-shell-compose-block-edit-yaml-policy-matches-fontification ()
  (skip-unless (require 'yaml-mode nil t))
  (let ((agent-shell-compose-language-modes '(("yaml" . yaml-mode)))
        (yaml-mode-hook nil))
    (dolist (markup '(org markdown))
      (agent-shell-compose-block-edit-test--with-editor markup
          (agent-shell-compose-block-edit-test--draft markup "yaml" "key: value\n")
        (should (eq major-mode 'yaml-mode))
        (should-not buffer-file-name)
        (with-current-buffer source
          (font-lock-ensure)
          (should (memq 'font-lock-variable-name-face (agent-shell-compose-test--faces "key"))))
        (agent-shell-compose-block-edit-cancel)))))

(provide 'agent-shell-compose-block-edit-tests)
;;; agent-shell-compose-block-edit-tests.el ends here