;;; my-task-list-tests.el --- Tests for task list behavior -*- lexical-binding: t -*-

;;; Commentary:

;; Task list filtering, display, and standard Dired coverage.

;;; Code:

(require 'my-task-test-support)

(defmacro my/task-list-test--with-launch-files (&rest body)
  "Run BODY in an isolated Dired task list with real task and other files."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "task-list-launch-" t))
          (task (expand-file-name "20261017T183224==todo--same-title.md" root))
          (other (expand-file-name "20261017T183225==todo--same-title.md" root))
          (directory (expand-file-name "20261017T183226==todo--directory.md" root))
          (invalid-names '("notes.md" "20261017T183224==done--task.md"
                           "20261017T183224==discarded--task.md"
                           "20261017T183224==todo--task.org"
                           "20261017T183224==todo--task.md~"
                           ".#20261017T183224==todo--task.md"))
          (my/task-list-epic root)
          (my/task-list-regex "==todo--")
          (my/task-list-reverse t)
          buffer)
     (unwind-protect
         (progn
           (dolist (file (append (list task other)
                                (mapcar (lambda (name) (expand-file-name name root))
                                        invalid-names)))
             (with-temp-file file (insert "---\ntitle: Same title\n---\nSaved task\n")))
           (make-directory directory)
           (setq buffer (dired-noselect root))
           (with-current-buffer buffer
             (my/task-list--prepare-buffer buffer root)
             ,@body))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (dolist (file (list task other))
         (when-let* ((visiting (get-file-buffer file)))
           (with-current-buffer visiting (set-buffer-modified-p nil))
           (kill-buffer visiting)))
       (delete-directory root t))))

(ert-deftest my/task-list-start-agent-passes-exact-file-at-point-and-preserves-state ()
  (my/task-list-test--with-launch-files
    (dired-goto-file other)
    (dired-mark 1)
    (dired-goto-file task)
    (let ((contents (buffer-string))
          (position (point))
          (scope my/task-list--denote-scope)
          (directory-default default-directory)
          (reverter revert-buffer-function)
          calls)
      (cl-letf (((symbol-function 'my/agent-session-start-from-file)
                 (lambda (&optional file) (push file calls) 'launched))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "Unexpected second task picker")))
                ((symbol-function 'dired-get-marked-files)
                 (lambda (&rest _) (ert-fail "Must not consult marked files")))
                ((symbol-function 'my/task-list--filter-save)
                 (lambda () (ert-fail "Must not persist list state"))))
        (should (eq (call-interactively #'my/task-list-start-agent) 'launched)))
      (should (equal calls (list task)))
      (should (equal contents (buffer-string)))
      (should (= position (point)))
      (should (equal scope my/task-list--denote-scope))
      (should (equal directory-default default-directory))
      (should (eq reverter revert-buffer-function))
      (should (equal my/task-list-epic root))
      (should (equal my/task-list-regex "==todo--"))
      (should my/task-list-reverse))))

(ert-deftest my/task-list-start-agent-rejects-invalid-targets-before-launch ()
  (my/task-list-test--with-launch-files
    (cl-letf (((symbol-function 'my/agent-session-start-from-file)
               (lambda (&rest _) (ert-fail "Invalid target reached launcher"))))
      (goto-char (point-min))
      (should-error (my/task-list-start-agent) :type 'user-error)
      (dolist (file (cons directory
                         (mapcar (lambda (name) (expand-file-name name root)) invalid-names)))
        (should (dired-goto-file file))
        (should-error (my/task-list-start-agent) :type 'user-error))
      ;; A stale Dired entry is not an existing saved task.
      (dired-goto-file task)
      (delete-file task)
      (should-error (my/task-list-start-agent) :type 'user-error)
      (with-temp-buffer
        (should-error (my/task-list-start-agent) :type 'user-error))
      (with-temp-buffer
        (denote-dired-empty-mode)
        (should-error (my/task-list-start-agent) :type 'user-error)))))

(ert-deftest my/task-list-start-agent-propagates-launch-outcomes-without-changing-list ()
  (my/task-list-test--with-launch-files
    (dired-goto-file task)
    (let ((contents (buffer-string)) (position (point)))
      (dolist (outcome '(nil (quit) (error "Launch failed") (user-error "Save or revert task")))
        (cl-letf (((symbol-function 'my/agent-session-start-from-file)
                   (lambda (file)
                     (should (equal file task))
                     (when outcome (signal (car outcome) (cdr outcome))))))
          (should (equal (condition-case err
                             (my/task-list-start-agent)
                           ((error quit) err))
                         outcome)))
        (should (equal contents (buffer-string)))
        (should (= position (point)))
        (should (equal my/task-list-epic root))
        (should (equal my/task-list-regex "==todo--"))
        (should my/task-list-reverse)))))

(ert-deftest my/task-list-start-agent-leaves-unsaved-visiting-task-to-launcher ()
  (my/task-list-test--with-launch-files
    (let ((visiting (find-file-noselect task)) saved edited)
      (with-current-buffer visiting
        (setq saved (buffer-string))
        (goto-char (point-max))
        (insert "Unsaved edit\n")
        (setq edited (buffer-string)))
      (dired-goto-file task)
      (cl-letf (((symbol-function 'my/agent-session-start-from-file)
                 (lambda (file)
                   (should (equal file task))
                   (with-current-buffer visiting
                     (should (equal edited (buffer-string)))
                     (should (buffer-modified-p)))
                   (should (equal saved (with-temp-buffer
                                          (insert-file-contents file)
                                          (buffer-string))))
                   (user-error "Task buffer differs from disk; save or revert before launching"))))
        (should-error (my/task-list-start-agent) :type 'user-error))
      (with-current-buffer visiting
        (should (equal edited (buffer-string)))
        (should (buffer-modified-p))))))

(ert-deftest my/task-list-agent-prefix-is-local-and-inherits-global-bindings ()
  (let ((original-global-map (current-global-map))
        (original-dired-agent-prefix (lookup-key dired-mode-map (kbd "C-c a"))))
    (unwind-protect
        (progn
          (use-global-map (copy-keymap original-global-map))
          ;; Model a global agent prefix without depending on init.el, which
          ;; is intentionally outside the catalogue check's my-lisp input.
          (keymap-global-set "C-c a"
                             (define-keymap "f" #'my/agent-session-start-from-file))
          (should (eq (key-binding (kbd "C-c a f")) #'my/agent-session-start-from-file))
          ;; A future global sibling must remain visible in task lists.
          (define-key (lookup-key (current-global-map) (kbd "C-c a")) "d" #'ignore)
          (my/task-list-test--with-launch-files
            (should (eq (key-binding (kbd "C-c a f")) #'my/task-list-start-agent))
            (should (eq (key-binding (kbd "C-c a d")) #'ignore))
            (should (equal (lookup-key dired-mode-map (kbd "C-c a"))
                           original-dired-agent-prefix))
            (my/task-list--revert-buffer)
            (should (eq (key-binding (kbd "C-c a f")) #'my/task-list-start-agent))
            (with-temp-buffer
              (dired-mode root)
              (should (eq (key-binding (kbd "C-c a f")) #'my/agent-session-start-from-file)))
            (with-temp-buffer
              (setq-local my/task-list--managed-p t)
              (denote-dired-empty-mode)
              (should (eq (key-binding (kbd "C-c a f")) #'my/task-list-start-agent))))
          (should (eq (key-binding (kbd "C-c a f")) #'my/agent-session-start-from-file)))
      (use-global-map original-global-map))))

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
