;;; my-emacs-completion-tests.el --- Tests for completion configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for minibuffer annotations, Corfu policy, and Cape helpers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vertico)
(require 'marginalia)
(require 'eshell)
(require 'agent-shell)
(require 'my-emacs-completion)

(ert-deftest my/project-annotation-shows-the-current-git-branch ()
  (let ((directory (make-temp-file "project-branch-test-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" directory))
          (write-region "ref: refs/heads/jamesl-20260912T163933\n" nil
                        (expand-file-name ".git/HEAD" directory))
          (let ((annotation
                 (my/marginalia-annotate-project-file directory)))
            (should (string-suffix-p "jamesl-20260912T163933"
                                     (substring-no-properties annotation)))
            (should (eq (get-text-property (1- (length annotation))
                                           'face annotation)
                        'marginalia-value))))
      (delete-directory directory t))))

(ert-deftest my/project-annotation-identifies-detached-git-worktrees ()
  (let ((directory (make-temp-file "project-detached-test-" t))
        (git-directory (make-temp-file "project-gitdir-test-" t)))
    (unwind-protect
        (progn
          (write-region (format "gitdir: %s\n" git-directory) nil
                        (expand-file-name ".git" directory))
          (write-region "0123456789012345678901234567890123456789\n" nil
                        (expand-file-name "HEAD" git-directory))
          (let ((annotation
                 (my/marginalia-annotate-project-file directory)))
            (should (string-suffix-p "-"
                                     (substring-no-properties annotation)))
            (should (eq (get-text-property (1- (length annotation))
                                           'face annotation)
                        'marginalia-null))))
      (delete-directory directory t)
      (delete-directory git-directory t))))

(ert-deftest my/project-annotation-retains-standard-non-git-annotation ()
  (let (annotated-candidate)
    (cl-letf (((symbol-function 'marginalia-annotate-project-file)
               (lambda (candidate)
                 (setq annotated-candidate candidate)
                 " standard")))
      (let ((directory (make-temp-file "project-non-git-test-" t)))
        (unwind-protect
            (progn
              (should (equal (my/marginalia-annotate-project-file directory)
                             " standard"))
              (should (equal annotated-candidate directory)))
          (delete-directory directory t))))))

(ert-deftest my/project-annotation-retains-relative-project-file-annotation ()
  (cl-letf (((symbol-function 'my/project-git-branch)
             (lambda (_directory) (ert-fail "relative candidates should not query Git")))
            ((symbol-function 'marginalia-annotate-project-file)
             (lambda (candidate) (concat " standard:" candidate))))
    (should (equal (my/marginalia-annotate-project-file "src/main.el")
                   " standard:src/main.el"))))

(ert-deftest my/project-annotation-is-the-default-project-file-annotator ()
  (should (eq (car (alist-get 'project-file marginalia-annotators))
              #'my/marginalia-annotate-project-file))
  (should (= (seq-count
              (lambda (annotator)
                (eq annotator #'my/marginalia-annotate-project-file))
              (alist-get 'project-file marginalia-annotators))
             1)))

(ert-deftest my/corfu-auto-is-local-to-supported-modes ()
  (should global-corfu-mode)
  (should-not (default-value 'corfu-auto))
  (with-temp-buffer
    (text-mode)
    (should-not corfu-auto)
    (should-not (local-variable-p 'corfu-auto)))
  (with-temp-buffer
    (emacs-lisp-mode)
    (should corfu-auto)
    (should (local-variable-p 'corfu-auto))
    (should (= corfu-auto-delay 0.1))
    (should (= corfu-auto-prefix 2)))
  (with-temp-buffer
    (eshell-mode)
    (should corfu-auto)
    (should (local-variable-p 'corfu-auto))
    (should (eq (car completion-at-point-functions)
                #'pcomplete-completions-at-point))))

(ert-deftest my/compose-auto-preserves-native-capfs-and-inherited-fallbacks ()
  (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
    (with-temp-buffer
      (agent-shell-viewport-edit-mode)
      (should corfu-auto)
      (should (equal completion-at-point-functions
                     '(agent-shell--command-completion-at-point
                       agent-shell--file-completion-at-point t
                       ispell-completion-at-point)))
      (should (= corfu-auto-prefix 2))
      (should (= corfu-auto-delay 0.1)))
    (dolist (mode '(agent-shell-viewport-view-mode comint-mode text-mode))
      (with-temp-buffer
        (funcall mode)
        (should-not corfu-auto)))))

(defun my/completion-test--candidates (capf)
  "Return CAPF's candidates for the current input, using file styles."
  (let* ((beg (nth 0 capf))
         (end (nth 1 capf))
         (input (buffer-substring-no-properties beg end)))
    (all-completions input (nth 2 capf))))

(ert-deftest my/explicit-paths-complete-with-cape-without-editing-input ()
  (let* ((root (make-temp-file "explicit-path-" t))
         (work (expand-file-name "work/" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "nested/" work) t)
          (write-region "" nil (expand-file-name "file with spaces.txt" work))
          (write-region "" nil (expand-file-name "nested/child.txt" work))
          (dolist (input (list "./" "../work/" "./nested/"
                               (concat work "nested/") "~/"))
            (with-temp-buffer
              (let ((default-directory work))
                (insert input)
                (let* ((capf (my/cape-explicit-file-capf))
                       (candidates (my/completion-test--candidates capf)))
                  (should capf)
                  (unless (equal input "~/")
                    (should (member (if (string-suffix-p "nested/" input)
                                        "child.txt" "file with spaces.txt")
                                    candidates)))
                  (should (equal (buffer-string) input))
                  (should-not (plist-get (nthcdr 3 capf) :exit-function))
                  ;; A delayed table keeps the original base directory.
                  (let ((default-directory temporary-file-directory))
                    (should (equal candidates
                                   (my/completion-test--candidates capf)))))))))
      (delete-directory root t))))

(ert-deftest my/explicit-path-guard-rejects-prose-commands-mentions-and-urls ()
  (dolist (input '("prose" "nested/file" "/" "/help" "/usr"
                   "https://example.com/path/" "file:./" "@./" "@/tmp/"))
    (with-temp-buffer
      (insert input)
      (cl-letf (((symbol-function 'cape-file)
                 (lambda (&rest _) (ert-fail "Guard must not call Cape"))))
        (should-not (my/cape-explicit-file-capf))))))

(ert-deftest my/explicit-path-home-and-space-candidates ()
  (let ((root (make-temp-file "completion-home-" t))
        (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (setenv "HOME" root)
          (write-region "" nil (expand-file-name "with spaces.txt" root))
          (make-directory (expand-file-name "space directory" root))
          (with-temp-buffer
            (insert "~/")
            (let* ((capf (my/cape-explicit-file-capf))
                   (candidates (my/completion-test--candidates capf)))
              (should (member "with spaces.txt" candidates))
              (should (member "space directory/" candidates))
              (completion-in-region (nth 0 capf) (nth 1 capf)
                                    '("~/with spaces.txt"))
              (should (equal (buffer-string) "~/with spaces.txt")))))
      (delete-directory root t))))

(ert-deftest my/explicit-path-remote-directory-uses-file-handler-dispatch ()
  ;; Model RPC/TRAMP dispatch only. Never open a connection or invoke SSH.
  (let* ((prefix "/rpc:completion-test:")
         (directory (concat prefix "/work/"))
         calls
         (handler
          (lambda (operation &rest args)
            (push (cons operation args) calls)
            (pcase operation
              ('file-remote-p prefix)
              ('expand-file-name
               (concat prefix
                       (expand-file-name
                        (string-remove-prefix prefix (car args))
                        (string-remove-prefix prefix (or (cadr args) directory)))))
              ('file-exists-p
               (should (equal (car args) directory)) t)
              ('file-name-all-completions
               (should (equal (cadr args) directory))
               '("remote-file.txt"))
              (_ (ert-fail (format "Unexpected file-handler operation: %S %S"
                                   operation args))))))
         (file-name-handler-alist
          (cons (cons (concat "\\`" (regexp-quote prefix)) handler)
                file-name-handler-alist)))
    (with-temp-buffer
      (setq default-directory directory)
      (insert "./")
      (let ((capf (my/cape-explicit-file-capf)))
        ;; The delayed table must not drift to another buffer's local base.
        (let ((default-directory temporary-file-directory))
          (should (equal (my/completion-test--candidates capf)
                         '("remote-file.txt"))))))
    (should (assq 'file-name-all-completions calls))))

(ert-deftest my/explicit-path-fallback-order-and-local-boundary ()
  (let ((capfs (default-value 'completion-at-point-functions)))
    (should (< (seq-position capfs #'my/cape-explicit-file-capf)
               (seq-position capfs #'my/cape-dabbrev-capf))))
  (with-temp-buffer
    ;; A mode with no t marker intentionally suppresses global fallbacks.
    (setq-local completion-at-point-functions '(ignore))
    (cl-letf (((symbol-function 'my/cape-explicit-file-capf)
               (lambda () (ert-fail "Local-only CAPFs must stay local"))))
      (should-not (run-hook-wrapped 'completion-at-point-functions #'funcall))))
  (with-temp-buffer
    (insert "./")
    (let ((native (lambda () (list 1 3 '("./native")))))
      (setq-local completion-at-point-functions (list native t))
      (should (eq (car (run-hook-wrapped 'completion-at-point-functions
                                        #'corfu--capf-wrapper 2)) native)))))

(ert-deftest my/compose-corfu-selects-paths-native-sources-and-word-fallback ()
  (let ((root (make-temp-file "compose-completion-" t)))
    (unwind-protect
        (progn
          (write-region "" nil (expand-file-name "candidate.txt" root))
          (cl-letf (((symbol-function 'agent-shell-viewport--update-header) #'ignore))
            (with-temp-buffer
              (agent-shell-viewport-edit-mode)
              (setq default-directory (file-name-as-directory root))
              (setq-local agent-shell--project-files-cache '("native.txt"))
              (setq-local agent-shell--state
                          '((:available-commands . [((name . "help")
                                                    (description . "Help"))])))
              (cl-letf (((symbol-function 'agent-shell--shell-buffer)
                         (lambda (&rest _) (current-buffer))))
                (dolist (case '(("./" . my/cape-explicit-file-capf)
                                ("@na" . agent-shell--file-completion-at-point)
                                ("/he" . agent-shell--command-completion-at-point)
                                ("completionword\ncomplet" . my/cape-dabbrev-capf)))
                  (erase-buffer)
                  (insert (car case))
                  (let ((result (run-hook-wrapped 'completion-at-point-functions
                                                 #'corfu--capf-wrapper
                                                 corfu-auto-prefix)))
                    (should (eq (car result) (cdr case)))
                    (should (equal (buffer-string) (car case)))))))))
      (delete-directory root t))))

(ert-deftest my/cape-dabbrev-capf-is-a-low-priority-global-fallback ()
  (let ((capfs (default-value 'completion-at-point-functions)))
    (should (eq (car (last capfs)) #'my/cape-dabbrev-capf)))
  (with-temp-buffer
    (insert "ab")
    (should-not (my/cape-dabbrev-capf)))
  (should (eq (keymap-lookup cape-prefix-map "d") #'cape-dabbrev)))

(ert-deftest my/cape-file-uses-the-buffer-directory-without-prefix ()
  (let ((default-directory "/buffer/base/")
        seen-directory)
    (cl-letf (((symbol-function 'cape-file)
               (lambda (interactive)
                 (should interactive)
                 (setq seen-directory cape-file-directory))))
      (my/cape-file nil))
    (should-not seen-directory)
    (should (equal default-directory "/buffer/base/"))))

(ert-deftest my/cape-file-uses-a-temporary-prompted-directory-with-prefix ()
  (let ((default-directory "/buffer/base/")
        (selected-directory "/selected/worktree/")
        seen-capf-directory
        seen-table-directory
        seen-location-directory)
    (cl-letf (((symbol-function 'read-directory-name)
               (lambda (&rest _args) selected-directory))
              ((symbol-function 'cape-file)
               (lambda ()
                 (setq seen-capf-directory cape-file-directory)
                 (list (point) (point)
                       (lambda (&rest _args)
                         (setq seen-table-directory default-directory))
                       :company-location
                       (lambda (&rest _args)
                         (setq seen-location-directory default-directory)))))
              ((symbol-function 'cape-interactive)
               (lambda (context capf)
                 (should (equal context '(cape-file-directory-must-exist)))
                 (let* ((result (funcall capf))
                        (table (nth 2 result))
                        (properties (nthcdr 3 result)))
                   (funcall table "" nil t)
                   (funcall (plist-get properties :company-location)
                            "candidate")))))
      (my/cape-file '(4)))
    (should (equal seen-capf-directory selected-directory))
    (should (equal seen-table-directory selected-directory))
    (should (equal seen-location-directory selected-directory))
    (should (equal default-directory "/buffer/base/"))))

(ert-deftest my/cape-file-replaces-the-upstream-prefix-map-binding ()
  (should (eq (keymap-lookup global-map "C-c p") cape-prefix-map))
  (should (eq (keymap-lookup cape-prefix-map "f") #'my/cape-file)))

(provide 'my-emacs-completion-tests)
;;; my-emacs-completion-tests.el ends here
