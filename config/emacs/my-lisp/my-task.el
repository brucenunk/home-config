;;; my-task.el --- Task file capture and commands -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "3.0"))

;;; Commentary:

;; Plain Denote task files, independent of agent and repository lifecycle.
;; Public commands, functions, and predicates:
;;   - my/task-add — create a task note with optional skill metadata
;;   - my/task-directory — return the shared task root
;;   - my/task-file-p — test whether the current buffer visits a task note
;; `my/tasks-map' provides capture/list bindings.  `my/task-workflows' supplies
;; capture choices; `my/task-note-created-hook' refreshes lists after saving.
;; `my/task-list' is owned by my-task-list.el and autoloaded here.

;;; Code:

(require 'denote)

(defgroup my-task nil
  "Denote task files and filtering."
  :group 'denote)

(autoload 'my/task-list "my-task-list" "Open the filtered task list." t)

(defvar-keymap my/tasks-map
  :doc "Shared keymap for task file commands."
  "a" #'my/task-add
  "l" #'my/task-list)

(defvar my/task-note-created-hook nil
  "Hook run after a new task note has been saved.")

(defvar my/task-workflows '("task" "bump-nix" "none")
  "Capture choices for note templates and skill metadata.
`task' uses the structured template, `none' uses an empty template without
skill metadata, and other choices write their name as the skill.")

;;;###autoload
(defun my/task-directory ()
  "Return the shared task file root."
  (expand-file-name "~/work/tasks/"))

(defun my/task--normalize-workflow (workflow)
  "Return canonical capture label for WORKFLOW."
  (pcase workflow
    ((or `nil "none") "none")
    ("task-workflow-v3" "task")
    (_ workflow)))

(defun my/task--read-workflow (extended-p)
  "Return the capture choice, prompting only with EXTENDED-P."
  (if extended-p
      (my/task--normalize-workflow
       (completing-read "Workflow: " my/task-workflows nil t nil nil "task"))
    "task"))

(defun my/task--skill-set (skill)
  "Insert SKILL into the current note's YAML front matter."
  (save-excursion
    (goto-char (point-min))
    (unless (looking-at "---\n")
      (error "Task note has no YAML front matter"))
    (forward-line)
    (unless (re-search-forward "^---$" nil t)
      (error "Task note has no closing front matter delimiter"))
    (beginning-of-line)
    (insert (format "skill:      %s\n" skill))))

;;;###autoload
(defun my/task-add (&optional title workflow extended-workflow-p)
  "Create a task note with TITLE and WORKFLOW.
Interactively, prompt for the title and optional epic subdirectory.  A prefix
argument enables the full workflow choice; otherwise use task-workflow-v3.
The `todo' filename signature is retained only to match the existing default
list filter.  No status lifecycle is managed."
  (interactive (list nil nil current-prefix-arg))
  (let* ((interactive-p (called-interactively-p 'any))
         (denote-directory (my/task-directory))
         (subdir (when interactive-p (denote-subdirectory-prompt)))
         (target-dir (if subdir (expand-file-name subdir denote-directory)
                       denote-directory))
         (title (or title (read-string "Title: ")))
         (workflow (my/task--normalize-workflow
                    (or workflow
                        (if interactive-p
                            (my/task--read-workflow extended-workflow-p)
                          "task"))))
         (skill (pcase workflow
                  ("task" "task-workflow-v3")
                  ("none" nil)
                  (_ workflow)))
         (template (if (equal workflow "task") 'task-workflow-v3 'empty)))
    (make-directory target-dir t)
    (let ((denote-directory target-dir))
      (denote title nil 'markdown-yaml nil nil template "todo")
      (when skill (my/task--skill-set skill))
      (save-buffer)
      (let ((file buffer-file-name))
        (run-hooks 'my/task-note-created-hook)
        (unless interactive-p (kill-buffer))
        file))))

;;;###autoload
(defun my/task-file-p ()
  "Return non-nil if the current buffer visits a Denote task file."
  (and buffer-file-name
       (bound-and-true-p denote-directory)
       (denote-file-is-in-denote-directory-p buffer-file-name)
       (denote-file-has-denoted-filename-p buffer-file-name)))

(provide 'my-task)
;;; my-task.el ends here
