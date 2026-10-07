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
;; Capture writes repository, machine, model and thinking hints from
;; the Nix-generated Herdsman catalogue.  Herdsman owns final launch selection.
;; `my/tasks-map' provides capture/list bindings.  `my/task-workflows' supplies
;; capture choices; `my/task-note-created-hook' refreshes lists after saving.
;; `my/task-list' is owned by my-task-list.el and autoloaded here.

;;; Code:

(require 'denote)
(require 'cl-lib)
(require 'json)
(require 'subr-x)

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

(defcustom my/task-catalogue-file
  (expand-file-name "herdsman/catalogue.json"
                    (let ((xdg (getenv "XDG_CONFIG_HOME")))
                      (if (and xdg (not (string-empty-p xdg)))
                          xdg
                        (expand-file-name "~/.config/"))))
  "Nix-generated catalogue supplying capture choices and defaults."
  :type 'file
  :group 'my-task)

(defun my/task--hint-p (value)
  "Return non-nil when VALUE is a bounded single-line hint."
  (and (stringp value) (not (string-empty-p value))
       (<= (length value) 4096)
       (not (string-match-p "[[:cntrl:]]" value))))

(defun my/task--catalogue-read ()
  "Read and validate the generated capture catalogue, or signal a user error."
  (condition-case err
      (let* ((data (with-temp-buffer
                     ;; Read a bounded local configuration, never probe a host.
                     (when (file-remote-p my/task-catalogue-file)
                       (error "Catalogue must be a local file"))
                     (insert-file-contents my/task-catalogue-file nil 0 1048577)
                     (when (> (1- (position-bytes (point-max))) 1048576)
                       (error "Catalogue exceeds 1 MiB"))
                     (let ((value (json-parse-buffer :object-type 'alist :array-type 'list
                                                     :null-object nil :false-object :false)))
                       (skip-chars-forward " \t\r\n")
                       (unless (eobp) (error "Catalogue must contain one JSON object"))
                       value)))
             (machines (alist-get 'machines data))
             (local (alist-get 'localMachine data)))
        (unless (and (my/task--hint-p local) (listp machines) machines
                     (assoc (intern local) machines))
          (error "Missing named localMachine or machines"))
        (dolist (entry machines)
          (let* ((name (symbol-name (car entry)))
                 (machine (cdr entry))
                 (repos (alist-get 'repositories machine))
                 (refs (alist-get 'defaultBaseRefs machine))
                 (models (alist-get 'models machine))
                 (default-model (alist-get 'defaultModel machine)))
            (unless (and (my/task--hint-p name) (not (equal name "local"))
                         (cl-every (lambda (key) (assq key machine))
                                   '(repositories defaultBaseRefs defaultModel models))
                         (listp repos) (listp refs) (listp models)
                         (stringp default-model)
                         (= (length repos) (length (delete-dups (copy-sequence repos))))
                         (= (length repos) (length refs)))
              (error "Invalid machine %s" name))
            (dolist (repo repos)
              (unless (and (my/task--hint-p repo)
                           (string-match-p "\\`[^/[:space:]]+/[^/[:space:]]+\\'" repo)
                           (my/task--hint-p (alist-get (intern repo) refs)))
                (error "Missing repository/base-ref data on %s" name)))
            (let (names)
              (dolist (model models)
                (let ((reference (alist-get 'name model))
                      (levels (alist-get 'thinkingLevels model))
                      (default (alist-get 'defaultThinking model)))
                  (unless (and (my/task--hint-p reference)
                               ;; The remainder of the model ID may contain slashes.
                               (string-match-p "\\`[^/[:space:]]+/[^[:space:]]+\\'" reference)
                               (not (member (downcase reference) names))
                               (listp levels)
                               (assq 'thinkingLevels model)
                               (= (length levels) (length (delete-dups (copy-sequence levels))))
                               (cl-every (lambda (level)
                                           (member level '("off" "minimal" "low" "medium" "high" "xhigh" "max")))
                                         levels)
                               (stringp default)
                               (equal default (cond ((member "medium" levels) "medium")
                                                    ((member "off" levels) "off")
                                                    (t ""))))
                    (error "Invalid model on %s" name))
                  (push (downcase reference) names)))
              (unless (if models
                          (cl-find default-model models :key (lambda (model) (alist-get 'name model)) :test #'equal)
                        (equal default-model ""))
                (error "Missing or invalid model default on %s" name)))))
        data)
    (error (user-error "Cannot capture task: fix/rebuild Herdsman catalogue %s (%s)"
                       my/task-catalogue-file (error-message-string err)))))

(defun my/task--choice-read (prompt choices default)
  "Read a required choice using PROMPT, CHOICES and DEFAULT."
  (unless choices (user-error "Cannot capture task: no choices for %s" prompt))
  (let ((value (completing-read prompt choices nil t nil nil default)))
    (unless (member value choices)
      (user-error "Choose a supported value for %s" prompt))
    value))

(defun my/task--metadata-read (extended-p)
  "Collect capture metadata in Herdsman's order, prompting with EXTENDED-P."
  (let* ((catalogue (my/task--catalogue-read))
         (machines (alist-get 'machines catalogue))
         (repos (sort (delete-dups
                       (cl-mapcan (lambda (entry)
                                    (copy-sequence (alist-get 'repositories (cdr entry))))
                                  machines)) #'string<))
         (repo (my/task--choice-read "Repository: " repos nil))
         (eligible (sort (cl-loop for (name . machine) in machines
                                 when (member repo (alist-get 'repositories machine))
                                 collect (symbol-name name)) #'string<))
         (local (alist-get 'localMachine catalogue))
         (destination (if (member local eligible) local (car eligible)))
         (machine-name (if (cdr eligible)
                           (my/task--choice-read "Machine: " eligible destination)
                         destination))
         (machine (alist-get (intern machine-name) machines))
         (models (alist-get 'models machine))
         (model-default (alist-get 'defaultModel machine))
         (model-name (if extended-p
                         (my/task--choice-read "Model: "
                                               (mapcar (lambda (model) (alist-get 'name model)) models)
                                               model-default)
                       model-default))
         (model (or (cl-find model-name models :key (lambda (item) (alist-get 'name item)) :test #'equal)
                    (user-error "Cannot capture task: no configured model for %s; fix/rebuild %s"
                                machine-name my/task-catalogue-file)))
         (levels (alist-get 'thinkingLevels model))
         (thinking-default (alist-get 'defaultThinking model))
         (thinking (if (or extended-p (equal thinking-default ""))
                       (my/task--choice-read "Thinking: " levels
                                             (unless (equal thinking-default "") thinking-default))
                     thinking-default)))
    (unless (and model (member thinking levels))
      (user-error "Cannot capture task: destination needs a model and supported thinking level"))
    `((repo . ,repo) (machine . ,machine-name)
      (model . ,model-name) (thinking . ,thinking))))

(defun my/task--metadata-insert (metadata)
  "Append captured METADATA to the new note's YAML front matter."
  (save-excursion
    (goto-char (point-min))
    (unless (looking-at "---\n") (error "Task note has no YAML front matter"))
    (forward-line)
    (unless (re-search-forward "^---$" nil t) (error "Task note has no closing front matter delimiter"))
    (beginning-of-line)
    (dolist (entry metadata)
      ;; JSON strings are YAML quoted scalars, including escaped special characters.
      (insert (format "%s: " (car entry)))
      (json-insert (cdr entry))
      (insert "\n"))))

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
argument enables skill and launch-hint choices; otherwise use task-workflow-v3
and catalogue defaults.  Repository is always prompted, as is machine when
multiple destinations qualify.  Herdsman alone gathers the base ref at launch.
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
         (template (if (equal workflow "task") 'task-workflow-v3 'empty))
         ;; Finish all selection before Denote creates any file or buffer.
         (metadata (my/task--metadata-read extended-workflow-p)))
    (make-directory target-dir t)
    (let ((denote-directory target-dir))
      (denote title nil 'markdown-yaml nil nil template "todo")
      (when skill (my/task--skill-set skill))
      (my/task--metadata-insert metadata)
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
