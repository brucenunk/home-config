;;; my-task-list-tests.el --- Tests for task list behavior -*- lexical-binding: t -*-

;;; Commentary:

;; Task list filtering, display, and standard Dired coverage.

;;; Code:

(require 'my-task-test-support)

(ert-deftest my/task-list-root-dir-uses-denote-directory ()
  (cl-letf (((symbol-function 'denote-directories)
             (lambda ()
               '("/tmp/tasks/"))))
    (should (equal (my/task-list--root-dir) "/tmp/tasks/"))))

(ert-deftest my/task-list-filter-load-drops-legacy-owner-state ()
  (let* ((temp-dir (make-temp-file "my-task-list-filter" t))
         (my/task-list-filter-file (expand-file-name "task-list-filter.el" temp-dir))
         (saved-state nil)
         (real-file-directory-p (symbol-function 'file-directory-p)))
    (with-temp-file my/task-list-filter-file
      (prin1 '((owner . "brucenunk")
               (epic . "/tmp/epic/")
               (regex . "==todo--")
               (reverse . t))
             (current-buffer)))
    (cl-letf (((symbol-function 'file-directory-p)
               (lambda (path)
                 (or (string= path "/tmp/epic/")
                     (funcall real-file-directory-p path))))
              ((symbol-function 'my/task-list--filter-save)
               (lambda ()
                 (setq saved-state
                       `((epic . ,my/task-list-epic)
                         (regex . ,my/task-list-regex)
                         (reverse . ,my/task-list-reverse))))))
      (setq my/task-list-epic nil
            my/task-list-regex "==todo--"
            my/task-list-reverse nil)
      (my/task-list--filter-load)
      (should (equal my/task-list-epic "/tmp/epic/"))
      (should my/task-list-reverse)
      (should (equal saved-state
                     '((epic . "/tmp/epic/")
                       (regex . "==todo--")
                       (reverse . t)))))
    (delete-directory temp-dir t)))

(ert-deftest my/task-list-show-uses-denote-sort-dired-42-side-effect ()
  (let* ((temp-dir (make-temp-file "my-task-list-tests" t))
         (task-id "20260526T111128")
         (task-file (expand-file-name
                     (format "%s==todo--generate-jwtextauthzconfig-dynamically.md" task-id)
                     temp-dir))
         (denote-directory temp-dir)
         (my/task-list-epic nil)
         (my/task-list-regex "==todo--")
         (my/task-list-reverse nil)
         (my/task-list-filter-file (expand-file-name "task-list-filter.el" temp-dir))
         task-list-buffer)
    (unwind-protect
        (progn
          (with-temp-file task-file
            (insert "---\n---\n"))
          (cl-letf (((symbol-function 'denote-directories)
                     (lambda () (list (file-name-as-directory temp-dir))))
                    ((symbol-function 'denote-sort-dired)
                     (lambda (regex sort-component reverse exclude-regexp)
                       (should (equal regex "==todo--"))
                       (should (eq sort-component 'identifier))
                       (should-not reverse)
                       (should-not exclude-regexp)
                       (dired (cons denote-directory
                                    (directory-files denote-directory nil regex t)))
                       'denote-sort-dired-revert)))
            (save-window-excursion
              (my/task-list-show)
              (setq task-list-buffer (current-buffer))
              (with-current-buffer task-list-buffer
                (goto-char (point-min))
                (should (re-search-forward task-id nil t))))))
      (when (buffer-live-p task-list-buffer)
        (kill-buffer task-list-buffer))
      (when-let* ((buf (get-file-buffer task-file)))
        (kill-buffer buf))
      (delete-directory temp-dir t))))

(ert-deftest my/task-list-show-no-matches-does-not-open-raw-directory ()
  (let* ((temp-dir (make-temp-file "my-task-list-tests" t))
         (done-id "20260526T111129")
         (done-file (expand-file-name
                     (format "%s==done--hidden-task.md" done-id)
                     temp-dir))
         (denote-directory temp-dir)
         (my/task-list-epic nil)
         (my/task-list-regex "==todo--")
         (my/task-list-reverse nil)
         (my/task-list-filter-file (expand-file-name "task-list-filter.el" temp-dir))
         task-list-buffer)
    (unwind-protect
        (progn
          (with-temp-file done-file
            (insert "---\n---\n"))
          (cl-letf (((symbol-function 'denote-directories)
                     (lambda () (list (file-name-as-directory temp-dir))))
                    ((symbol-function 'denote-sort-dired)
                     (lambda (&rest _)
                       nil)))
            (save-window-excursion
              (my/task-list-show)
              (setq task-list-buffer (current-buffer))
              (with-current-buffer task-list-buffer
                (should my/task-list--managed-p)
                (goto-char (point-min))
                (should-not (re-search-forward done-id nil t))))))
      (when (buffer-live-p task-list-buffer)
        (kill-buffer task-list-buffer))
      (when-let* ((buf (get-file-buffer done-file)))
        (kill-buffer buf))
      (delete-directory temp-dir t))))

(ert-deftest my/task-list-show-filters-todo-after-denote-4-2-exclude-change ()
  (let* ((temp-dir (make-temp-file "my-task-list-tests" t))
         (todo-id "20260526T111128")
         (done-id "20260526T111129")
         (todo-file (expand-file-name
                     (format "%s==todo--visible-task.md" todo-id)
                     temp-dir))
         (done-file (expand-file-name
                     (format "%s==done--hidden-task.md" done-id)
                     temp-dir))
         (denote-directory temp-dir)
         (my/task-list-epic nil)
         (my/task-list-regex "==todo--")
         (my/task-list-reverse nil)
         (my/task-list-filter-file (expand-file-name "task-list-filter.el" temp-dir))
         task-list-buffer)
    (unwind-protect
        (progn
          (with-temp-file todo-file
            (insert "---\n---\n"))
          (with-temp-file done-file
            (insert "---\n---\n"))
          (cl-letf (((symbol-function 'denote-directories)
                     (lambda () (list (file-name-as-directory temp-dir)))))
            (save-window-excursion
              (my/task-list-show)
              (setq task-list-buffer (current-buffer))
              (with-current-buffer task-list-buffer
                (goto-char (point-min))
                (should (re-search-forward todo-id nil t))
                (goto-char (point-min))
                (should-not (re-search-forward done-id nil t))))))
      (when (buffer-live-p task-list-buffer)
        (kill-buffer task-list-buffer))
      (dolist (file (list todo-file done-file))
        (when-let* ((buf (get-file-buffer file)))
          (kill-buffer buf)))
      (delete-directory temp-dir t))))

(ert-deftest my/task-list-show-preserves-existing-window-layout ()
  (let* ((temp-dir (make-temp-file "my-task-list-layout" t))
         (task-file (expand-file-name "20260324T103418==todo--layout.md" temp-dir))
         (my/task-list-epic nil)
         (my/task-list-regex "==todo--")
         (my/task-list-reverse nil)
         task-list-buffer)
    (unwind-protect
        (progn
          (with-temp-file task-file
            (insert "---\n---\n"))
          (cl-letf (((symbol-function 'denote-directories)
                     (lambda () (list (file-name-as-directory temp-dir)))))
            (save-window-excursion
              (delete-other-windows)
              (switch-to-buffer (get-buffer-create " *task-list-left*"))
              (split-window-right)
              (other-window 1)
              (switch-to-buffer (get-buffer-create " *task-list-right*"))
              (other-window -1)
              (my/task-list-show)
              (setq task-list-buffer (current-buffer))
              (should (= (length (window-list)) 2))
              (should (eq (window-buffer (selected-window)) task-list-buffer)))))
      (when (buffer-live-p task-list-buffer)
        (kill-buffer task-list-buffer))
      (when-let* ((buf (get-file-buffer task-file)))
        (kill-buffer buf))
      (delete-directory temp-dir t))))

(ert-deftest my/task-list-show-allows-multiple-visible-buffers ()
  (let* ((temp-dir (make-temp-file "my-task-list-layout" t))
         (task-file (expand-file-name "20260324T103418==todo--multi.md" temp-dir))
         (my/task-list-epic nil)
         (my/task-list-regex "==todo--")
         (my/task-list-reverse nil)
         left-window right-window first-buffer second-buffer)
    (unwind-protect
        (progn
          (with-temp-file task-file
            (insert "---\n---\n"))
          (cl-letf (((symbol-function 'denote-directories)
                     (lambda () (list (file-name-as-directory temp-dir)))))
            (save-window-excursion
              (delete-other-windows)
              (switch-to-buffer (get-buffer-create " *task-list-left*"))
              (setq left-window (selected-window))
              (split-window-right)
              (other-window 1)
              (switch-to-buffer (get-buffer-create " *task-list-right*"))
              (setq right-window (selected-window))
              (select-window left-window)
              (my/task-list-show)
              (setq first-buffer (current-buffer))
              (select-window right-window)
              (my/task-list-show)
              (setq second-buffer (current-buffer))
              (should (= (length (window-list)) 2))
              (should (buffer-live-p first-buffer))
              (should (buffer-live-p second-buffer))
              (should-not (eq first-buffer second-buffer))
              (should (eq (window-buffer left-window) first-buffer))
              (should (eq (window-buffer right-window) second-buffer))
              (should (memq first-buffer (my/task-list--buffers)))
              (should (memq second-buffer (my/task-list--buffers))))))
      (when (buffer-live-p first-buffer)
        (kill-buffer first-buffer))
      (when (buffer-live-p second-buffer)
        (kill-buffer second-buffer))
      (when-let* ((buf (get-file-buffer task-file)))
        (kill-buffer buf))
      (delete-directory temp-dir t))))

(ert-deftest my/task-list-empty-buffer-keeps-filter-bindings ()
  (let* ((temp-root (make-temp-file "my-task-list-root" t))
         (temp-dir (expand-file-name "demo/" temp-root))
         (task-id "20260324T103418")
         (task-file (expand-file-name
                     (format "%s==todo--empty-regression.md" task-id)
                     temp-dir))
         (my/task-list-epic temp-dir)
         (my/task-list-regex "==todo--")
         (my/task-list-reverse nil)
         (my/task-list-filter-file (expand-file-name "task-list-filter.el" temp-root))
         (original-task-prefix (lookup-key (current-global-map) (kbd "C-c t")))
         task-list-buffer)
    (make-directory temp-dir t)
    (unwind-protect
        (progn
          (keymap-global-set "C-c t" my/tasks-map)
          (with-temp-file task-file
            (insert "---\n---\n"))
          (cl-letf (((symbol-function 'denote-directories)
                     (lambda () (list (file-name-as-directory temp-dir)))))
            (save-window-excursion
              (my/task-list-show)
              (setq task-list-buffer (current-buffer))
              (with-current-buffer task-list-buffer
                (setq-local major-mode 'denote-dired-empty-mode)
                (my/task-list--empty-mode-setup)
                (should (eq major-mode 'denote-dired-empty-mode))
                (should (eq (lookup-key (current-local-map) (kbd "C-c t a"))
                            #'my/task-add))
                (should (eq (lookup-key (current-local-map) (kbd "C-c t p"))
                            nil))
                (should-not (lookup-key (current-local-map) (kbd "C-c t D")))
                (should (eq (lookup-key (current-local-map) (kbd "C-c t f e"))
                            #'my/task-list-filter-epic))
                (should (memq task-list-buffer (my/task-list--buffers)))))))
      (when (buffer-live-p task-list-buffer)
        (kill-buffer task-list-buffer))
      (when-let* ((buf (get-file-buffer task-file)))
        (kill-buffer buf))
      (keymap-global-set "C-c t" original-task-prefix)
      (delete-directory temp-root t))))

(ert-deftest my/task-list-empty-buffer-ignores-non-task-denote-buffers ()
  (let ((temp-dir (make-temp-file "my-task-list-denote" t))
        (buffer (generate-new-buffer "*my-task-list-denote-empty*")))
    (unwind-protect
        (cl-letf (((symbol-function 'denote-directories)
                   (lambda () (list (file-name-as-directory temp-dir)))))
          (with-current-buffer buffer
            (setq default-directory temp-dir)
            (setq-local major-mode 'denote-dired-empty-mode)
            (should-not (memq buffer (my/task-list--buffers)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory temp-dir t))))

(ert-deftest my/task-list-setup-keeps-standard-dired-bindings ()
  (let ((original-task-prefix (lookup-key (current-global-map) (kbd "C-c t"))))
    (unwind-protect
        (with-temp-buffer
          (dired-mode default-directory)
          (keymap-global-set "C-c t" my/tasks-map)
          (my/task-list-setup)
          (should (eq (lookup-key (current-local-map) (kbd "P"))
                      #'dired-do-print))
          (should (eq (lookup-key (current-local-map) (kbd "d"))
                      #'dired-flag-file-deletion))
          (should (eq (lookup-key (current-local-map) (kbd "D"))
                      #'dired-do-delete))
          (should (eq (lookup-key (current-local-map) (kbd "C-c t p"))
                      nil))
          (should-not (lookup-key (current-local-map) (kbd "C-c t D")))
          (should-not (local-variable-p 'my/task-list-preview-window)))
      (keymap-global-set "C-c t" original-task-prefix))))

(ert-deftest my/task-list-prepare-buffer-installs-pinned-revert ()
  (let ((temp-dir (file-name-as-directory (make-temp-file "my-task-list-scope" t)))
        (buffer (generate-new-buffer " *my-task-list-prepare*")))
    (unwind-protect
        (with-current-buffer buffer
          (my/task-list--prepare-buffer buffer temp-dir)
          (should my/task-list--managed-p)
          (should (equal my/task-list--denote-scope temp-dir))
          (should (equal denote-directory temp-dir))
          (should (equal default-directory temp-dir))
          (should (eq revert-buffer-function #'my/task-list--revert-buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory temp-dir t))))

(ert-deftest my/task-list-revert-buffer-binds-pinned-scope ()
  (let* ((temp-root (file-name-as-directory (make-temp-file "my-task-list-root" t)))
         (wrong-dir (file-name-as-directory (make-temp-file "my-task-list-wrong" t)))
         captured-default captured-denote captured-args)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory wrong-dir)
          (setq-local denote-directory wrong-dir)
          (setq-local my/task-list--denote-scope temp-root)
          (cl-letf (((symbol-function 'denote-sort-dired-revert)
                     (lambda (&rest args)
                       (setq captured-default default-directory
                             captured-denote denote-directory
                             captured-args args)))
                    ((symbol-function 'my/task-list-setup)
                     (lambda () nil))
)
            (my/task-list--revert-buffer 'ignore-auto 'noconfirm)
            (should (equal captured-default temp-root))
            (should (equal captured-denote temp-root))
            (should (equal captured-args '(ignore-auto noconfirm)))
            (should (equal default-directory temp-root))
            (should (equal denote-directory temp-root))
            (should (eq revert-buffer-function #'my/task-list--revert-buffer))))
      (delete-directory temp-root t)
      (delete-directory wrong-dir t))))

(ert-deftest my/task-list-revert-buffer-restores-contents-on-error ()
  (let ((temp-root (file-name-as-directory (make-temp-file "my-task-list-root" t)))
        message-text)
    (unwind-protect
        (with-temp-buffer
          (insert "stale task list")
          (goto-char 7)
          (set-buffer-modified-p nil)
          (setq-local my/task-list--denote-scope temp-root)
          (cl-letf (((symbol-function 'denote-sort-dired-revert)
                     (lambda (&rest _args)
                       (let ((inhibit-read-only t))
                         (erase-buffer))
                       (error "dired boom")))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq message-text (apply #'format format-string args)))))
            (my/task-list--revert-buffer)
            (should (equal (buffer-string) "stale task list"))
            (should (= (point) 7))
            (should-not (buffer-modified-p))
            (should (string-match-p "task list revert failed" message-text))))
      (delete-directory temp-root t))))


(ert-deftest my/task-list-filter-save-roundtrips-current-state ()
  (let* ((root (make-temp-file "task-filter-" t))
         (my/task-list-filter-file (expand-file-name "filter.el" root))
         (my/task-list-epic root)
         (my/task-list-regex "==done--")
         (my/task-list-reverse t))
    (unwind-protect
        (progn
          (my/task-list--filter-save)
          (setq my/task-list-epic nil my/task-list-regex "==todo--" my/task-list-reverse nil)
          (my/task-list--filter-load)
          (should (equal my/task-list-epic root))
          (should (equal my/task-list-regex "==done--"))
          (should my/task-list-reverse))
      (delete-directory root t))))

(ert-deftest my/task-list-note-change-refreshes-all-managed-buffers ()
  (let ((buffers (list (generate-new-buffer " *task-list-one*")
                       (generate-new-buffer " *task-list-two*")))
        reverted)
    (unwind-protect
        (cl-letf (((symbol-function 'my/task-list--buffers) (lambda () buffers))
                  ((symbol-function 'revert-buffer)
                   (lambda (&rest _) (push (current-buffer) reverted))))
          (run-hooks 'my/task-note-created-hook)
          (should (equal (nreverse reverted) buffers)))
      (mapc #'kill-buffer buffers))))

(provide 'my-task-list-tests)
;;; my-task-list-tests.el ends here
