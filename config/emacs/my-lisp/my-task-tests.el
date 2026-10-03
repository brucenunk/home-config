;;; my-task-tests.el --- Tests for task file capture -*- lexical-binding: t -*-

;;; Commentary:

;; Capture and file identity checks against real Denote, with no lifecycle.

;;; Code:

(require 'my-task-test-support)

(defmacro my/task-test--with-directory (&rest body)
  "Run BODY with an isolated shared task directory."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "task-files-" t))
          (denote-directory root)
          (denote-save-buffers t)
          (denote-templates '((task-workflow-v3 . "## Context\n\nCapture context.\n")
                              (empty . "")))
          (my/task-note-created-hook nil))
     (unwind-protect
         (cl-letf (((symbol-function 'my/task-directory) (lambda () root)))
           ,@body)
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-file-name buffer)))
           (when (string-prefix-p root file)
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer))))
       (delete-directory root t))))

(ert-deftest my/task-add-creates-a-plain-note-with-skill ()
  (my/task-test--with-directory
    (let* ((notifications 0)
           (my/task-note-created-hook (list (lambda () (cl-incf notifications))))
           (file (my/task-add "New task")))
      (should (file-exists-p file))
      (should (equal (file-name-directory file) (file-name-as-directory root)))
      (should (denote-file-has-denoted-filename-p file))
      (should (string-match-p "==todo--" (file-name-nondirectory file)))
      (should (= notifications 1))
      (should-not (find-buffer-visiting file))
      (with-temp-buffer
        (insert-file-contents file)
        (should (search-forward "skill:      task-workflow-v3" nil t))
        (should (search-forward "## Context" nil t))
        (goto-char (point-min))
        (should-not (re-search-forward "^repo:" nil t))
        (should-not (search-forward "## Dependencies" nil t))))))

(ert-deftest my/task-add-named-skill-uses-an-empty-template ()
  (my/task-test--with-directory
    (let ((file (my/task-add "Bump inputs" "bump-nix")))
      (with-temp-buffer
        (insert-file-contents file)
        (should (search-forward "skill:      bump-nix" nil t))
        (should-not (search-forward "## Context" nil t))))))

(ert-deftest my/task-add-unscripted-note-has-no-skill ()
  (my/task-test--with-directory
    (let ((file (my/task-add "Plain note" "none")))
      (with-temp-buffer
        (insert-file-contents file)
        (should-not (re-search-forward "^skill:" nil t))))))

(ert-deftest my/task-add-interactive-prompts-for-title-and-epic-not-repo ()
  (my/task-test--with-directory
    (let ((epic (expand-file-name "epic/" root))
          note-buffer)
      (make-directory epic)
      (cl-letf (((symbol-function 'called-interactively-p) (lambda (&rest _) t))
                ((symbol-function 'denote-subdirectory-prompt) (lambda () epic))
                ((symbol-function 'read-string)
                 (lambda (prompt &rest _)
                   (should (equal prompt "Title: "))
                   "Interactive note"))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "Default capture must not prompt for repo/workflow"))))
        (let ((current-prefix-arg nil))
          (call-interactively #'my/task-add))
        (setq note-buffer (current-buffer)))
      (with-current-buffer note-buffer
        (should (equal (file-name-directory buffer-file-name)
                       (file-name-as-directory epic)))
        (should (my/task-file-p))))))

(ert-deftest my/task-add-prefix-prompts-for-skill ()
  (my/task-test--with-directory
    (cl-letf (((symbol-function 'called-interactively-p) (lambda (&rest _) t))
              ((symbol-function 'denote-subdirectory-prompt) (lambda () nil))
              ((symbol-function 'read-string) (lambda (&rest _) "Bump"))
              ((symbol-function 'completing-read)
               (lambda (prompt choices &rest _)
                 (should (equal prompt "Workflow: "))
                 (should (member "bump-nix" choices))
                 "bump-nix")))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'my/task-add))
      (goto-char (point-min))
      (should (search-forward "skill:      bump-nix" nil t)))))

(ert-deftest my/task-file-p-recognizes-existing-notes-without-mutating-them ()
  (my/task-test--with-directory
    (let* ((file (expand-file-name "20260324T103418==done--legacy.md" root))
           (contents "---\nrepo: example/project\n---\n\n## Dependencies\n\n- [ ] [denote:20260324T103419](Old task)\n"))
      (with-temp-file file (insert contents))
      (with-temp-buffer
        (setq-local buffer-file-name file)
        (should (my/task-file-p)))
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) contents))))))

(ert-deftest my/task-file-p-rejects-non-denote-files ()
  (my/task-test--with-directory
    (with-temp-buffer
      (setq-local buffer-file-name (expand-file-name "ordinary.md" root))
      (should-not (my/task-file-p)))))

(ert-deftest my/tasks-map-only-offers-capture-and-list ()
  (should (eq (lookup-key my/tasks-map "a") #'my/task-add))
  (should (eq (lookup-key my/tasks-map "l") #'my/task-list))
  (dolist (key '("D" "F" "p" "X"))
    (should-not (lookup-key my/tasks-map key)))
  (dolist (feature '(my-task-finish my-task-session my-task-index my-agent
                    my-agent-pi my-hephaestus my-worktree-repair my-git my-repo my-worktree))
    (should-not (featurep feature))))

(provide 'my-task-tests)
;;; my-task-tests.el ends here
