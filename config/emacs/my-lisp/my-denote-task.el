;;; my-denote-task.el --- Task file capture and commands -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "3.0"))

;;; Commentary:

;; Plain Denote task files, independent of agent and repository lifecycle.
;; Public commands, functions, and predicates:
;;   - my/denote-task — create a task note with optional skill metadata
;;   - my/denote-task-directory — return the shared task root
;;   - my/denote-task-file-p — test whether the current buffer visits a task note
;; Capture writes repository, machine, model and thinking hints from
;; the Nix-generated agent catalogue.  Capture does not launch sessions.
;; `my/denote-task-workflows' supplies capture choices.

;;; Code:

(require 'denote)
(require 'cl-lib)
(require 'subr-x)
(require 'my-agent-catalogue)

(defvar vertico-preselect)

(defgroup my-denote-task nil
  "Denote task capture."
  :group 'denote)

(defvar my/denote-task-workflows '("task" "bump-nix" "none")
  "Capture choices for note templates and skill metadata.
`task' uses the task-workflow template, `none' uses an empty body without
skill metadata, and other choices write their name as the skill.")

(defun my/denote-task--choice-read (prompt choices default)
  "Read a required choice using PROMPT, CHOICES and DEFAULT."
  (unless choices (user-error "Cannot capture task: no choices for %s" prompt))
  (let ((value (completing-read prompt choices nil t nil nil default)))
    (unless (member value choices)
      (user-error "Choose a supported value for %s" prompt))
    value))

(defun my/denote-task--metadata-read (extended-p)
  "Collect capture metadata from loaded agent configuration with EXTENDED-P."
  (unless my/agent-machines
    (user-error "Cannot capture task: configure machines and run M-x my/agent-catalogue-reload"))
  (let* ((machines my/agent-machines)
         (repos (sort (delete-dups
                       (cl-mapcan (lambda (entry)
                                    (mapcar (lambda (repo) (plist-get repo :name))
                                            (plist-get (cdr entry) :repositories)))
                                  machines)) #'string<))
         (repo (my/denote-task--choice-read "Repository: " repos nil))
         (eligible (sort (cl-loop for (name . machine) in machines
                                 when (cl-find repo (plist-get machine :repositories)
                                               :key (lambda (item) (plist-get item :name)) :test #'equal)
                                 collect name) #'string<))
         (machine-name (if (cdr eligible)
                           ;; Vertico otherwise selects its first candidate,
                           ;; even with no completing-read default.
                           (let ((vertico-preselect 'prompt))
                             (my/denote-task--choice-read "Machine: " eligible nil))
                         (car eligible)))
         (machine (cdr (assoc machine-name machines)))
         (models (plist-get machine :models))
         (model-default (plist-get machine :default-model))
         (model-name (if extended-p
                         (my/denote-task--choice-read "Model: "
                                                      (mapcar (lambda (model) (plist-get model :name)) models)
                                                      model-default)
                       model-default))
         (model (or (cl-find model-name models :key (lambda (item) (plist-get item :name)) :test #'equal)
                    (user-error "Cannot capture task: no configured model for %s; rebuild and run M-x my/agent-catalogue-reload"
                                machine-name)))
         (levels (plist-get model :thinking-levels))
         (thinking-default (plist-get model :default-thinking))
         (thinking (if (or extended-p (equal thinking-default ""))
                       (my/denote-task--choice-read "Thinking: " levels
                                                    (unless (equal thinking-default "") thinking-default))
                     thinking-default)))
    (unless (and model (member thinking levels))
      (user-error "Cannot capture task: destination needs a model and supported thinking level"))
    `((repo . ,repo) (machine . ,machine-name)
      (model . ,model-name) (thinking . ,thinking))))

(defun my/denote-task--metadata-insert (metadata)
  "Append single-line METADATA to the new note's Org keyword header."
  (save-excursion
    (goto-char (point-min))
    (unless (looking-at "#\\+title:") (error "Task note has no Org keyword header"))
    (unless (re-search-forward "^$" nil t) (error "Task note has no header separator"))
    (dolist (entry metadata)
      (unless (and (stringp (cdr entry))
                   (not (string-empty-p (string-trim (cdr entry))))
                   (not (string-match-p "[[:cntrl:]]" (cdr entry))))
        (user-error "Task %s must be a non-empty single-line string" (car entry)))
      (insert (format "#+%s: %s\n" (car entry) (cdr entry))))))

;;;###autoload
(defun my/denote-task-directory ()
  "Return the shared task file root."
  (expand-file-name "~/work/docs/tasks/"))

(defun my/denote-task--normalize-workflow (workflow)
  "Return canonical capture label for WORKFLOW."
  (pcase workflow
    ((or `nil "none") "none")
    ("task-workflow" "task")
    (_ workflow)))

(defun my/denote-task--read-workflow (extended-p)
  "Return the capture choice, prompting only with EXTENDED-P."
  (if extended-p
      (my/denote-task--normalize-workflow
       (completing-read "Workflow: " my/denote-task-workflows nil t nil nil "task"))
    "task"))

;;;###autoload
(defun my/denote-task (&optional title workflow extended-workflow-p)
  "Create a task note with TITLE and WORKFLOW.
Interactively, prompt for the title and optional epic subdirectory.  A prefix
argument enables skill and launch-hint choices; otherwise use task-workflow
and catalogue defaults.  Repository is always prompted, as is machine when
multiple destinations qualify, with no machine default.  Capture does not
gather a base ref or launch a session.
New notes have no filename signature.  No status lifecycle is managed."
  (interactive (list nil nil current-prefix-arg))
  (let* ((interactive-p (called-interactively-p 'any))
         (denote-directory (my/denote-task-directory))
         (subdir (when interactive-p (denote-subdirectory-prompt)))
         (target-dir (if subdir (expand-file-name subdir denote-directory)
                       denote-directory))
         (title (or title (read-string "Title: ")))
         (_ (unless (and (stringp title)
                         (not (string-empty-p (string-trim title)))
                         (not (string-match-p "[[:cntrl:]]" title)))
              (user-error "Task title must be a non-empty single-line string")))
         (workflow (my/denote-task--normalize-workflow
                    (or workflow
                        (if interactive-p
                            (my/denote-task--read-workflow extended-workflow-p)
                          "task"))))
         (skill (pcase workflow
                  ("task" "task-workflow")
                  ("none" nil)
                  (_ workflow)))
         (template (if (equal workflow "task") 'task-workflow ""))
         ;; Finish all selection before Denote creates any file or buffer.
         (metadata (my/denote-task--metadata-read extended-workflow-p)))
    (make-directory target-dir t)
    (let ((denote-directory target-dir))
      (denote title nil 'org nil nil template nil)
      (my/denote-task--metadata-insert
       (append (when skill (list (cons 'skill skill))) metadata))
      (save-buffer)
      (let ((file buffer-file-name))
        (unless interactive-p (kill-buffer))
        file))))

;;;###autoload
(defun my/denote-task-file-p ()
  "Return non-nil if the current buffer visits a Denote task file."
  (and buffer-file-name
       (equal (file-name-extension buffer-file-name) "org")
       (file-in-directory-p buffer-file-name (my/denote-task-directory))
       (denote-file-has-denoted-filename-p buffer-file-name)))

(provide 'my-denote-task)
;;; my-denote-task.el ends here