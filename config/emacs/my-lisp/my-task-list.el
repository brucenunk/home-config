;;; my-task-list.el --- Task list UI -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "3.0") (seq "2.24"))

;;; Commentary:

;; Dired-based task list UI with filtering and overlays.
;;
;; Public commands:
;;   - my/task-list — open task list
;;   - my/task-list-pickup — start or resume the task at point without leaving the list
;;   - my/task-list-filter-epic — filter by epic
;;   - my/task-list-filter-regex — filter by regex
;;   - my/task-list-filter-sort — toggle sort direction

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'denote)
(require 'seq)

(defvar my/task-state-change-functions nil
  "Hook run after task-visible state changes.")

(declare-function my/task-pickup-start-async "my-task"
                  (task-id &rest args))
(declare-function my/task-session-restore "my-task" (task))
(declare-function my/task-state-entries "my-task" ())
(declare-function my/task-note-title "my-task-note" (task))
(declare-function denote-sort-dired-revert "denote" (&rest args))

;;; Filter state

(defvar my/task-list-epic nil
  "Current epic directory for task list filtering.
When nil, shows all tasks from the shared task root.
When set, restricts to tasks within that epic subdirectory.")

(defvar my/task-list-regex "==todo--"
  "Current regex filter for task list.
Matches signature=todo (WIP tasks are todo with branch set).")

(defvar my/task-list-reverse nil
  "Sort direction for task list.
When non-nil, oldest first (reverse chronological by identifier).
When nil, newest first (default).")

(defcustom my/task-list-filter-file
  (expand-file-name "task-list-filter.el" "~/.cache/emacs/")
  "File storing task list filter state as a Lisp alist."
  :type 'file
  :group 'my-task)

(defvar my/task-list-filter-map
  "Keymap for task filter commands.")

;;; Filter persistence

(defun my/task-list--filter-load ()
  "Load filter state from `my/task-list-filter-file'.
Handles missing file (no-op), invalid Elisp (log + keep defaults),
and missing keys (only update present keys).
Validates epic path exists; logs and clears if stale."
  (condition-case err
      (when (file-exists-p my/task-list-filter-file)
        (with-temp-buffer
          (insert-file-contents my/task-list-filter-file)
          (let ((state (read (current-buffer))))
            (when-let ((epic (alist-get 'epic state)))
              (if (file-directory-p epic)
                  (setq my/task-list-epic epic)
                (message "Warning: stale epic path cleared: %s" epic)
                (setq my/task-list-epic nil)))
            (when (assq 'regex state)
              (setq my/task-list-regex (alist-get 'regex state)))
            (when (assq 'reverse state)
              (setq my/task-list-reverse (alist-get 'reverse state)))
            ;; Drop stale owner state from pre-shared-root task-list config.
            (when (assq 'owner state)
              (my/task-list--filter-save)))))
    (error
     (message "Warning: failed to load task filter state: %s"
              (error-message-string err)))))

(defun my/task-list--filter-save ()
  "Save filter state to `my/task-list-filter-file' atomically.
Uses temp file + rename for atomicity."
  (condition-case err
      (let ((dir (file-name-directory my/task-list-filter-file)))
        (make-directory dir t)
        (let ((temp-file (make-temp-file (expand-file-name "task-list-filter" dir))))
          (with-temp-file temp-file
            (prin1 `((epic . ,my/task-list-epic)
                     (regex . ,my/task-list-regex)
                     (reverse . ,my/task-list-reverse))
                   (current-buffer)))
          (rename-file temp-file my/task-list-filter-file t)))
    (error
     (message "Warning: failed to save task filter state: %s"
              (error-message-string err)))))

;;; Helpers

(defun my/task-list--root-dir ()
  "Return the shared task root directory."
  (car (denote-directories)))

(defun my/task-list--epic-list ()
  "Return list of epic subdirectories in the shared task root, sorted."
  (let ((base (my/task-list--root-dir)))
    (when (and base (file-directory-p base))
      (sort
       (seq-filter
        (lambda (dir) (file-directory-p dir))
        (directory-files base t "^[^.]" t))
       (lambda (a b)
         (string< (file-name-nondirectory a)
                  (file-name-nondirectory b)))))))

(defvar-local my/task-list--managed-p nil
  "Non-nil when the current Dired buffer is managed as a task list.")

(put 'my/task-list--managed-p 'permanent-local t)

(defvar-local my/task-list--denote-scope nil
  "Pinned Denote directory scope for this task-list buffer.")

(put 'my/task-list--denote-scope 'permanent-local t)

(defvar my/task-list--notifications-installed nil
  "Non-nil once task-list UI has subscribed to task-state changes.")

;;; Buffer setup

;;;###autoload
(defun my/task-list-setup ()
  "Set up task list buffer with task-prefix bindings."
  (setq-local my/task-list--managed-p t)
  (add-hook 'dired-after-readin-hook #'my/task-list--after-readin nil t)
  (local-set-key (kbd "C-c t") (my/task-list--task-prefix-map)))

(defun my/task-list--task-prefix-map ()
  "Return task prefix map for task-list buffers."
  (let ((map (make-sparse-keymap)))
    (when-let ((global-task-map (lookup-key (current-global-map) (kbd "C-c t"))))
      (set-keymap-parent map global-task-map))
    (define-key map (kbd "p") #'my/task-list-pickup)
    (define-key map (kbd "f") (symbol-value 'my/task-list-filter-map))
    map))

(defun my/task-list--tasks-directory-p (&optional dir)
  "Return non-nil when DIR is the shared task root or a subdirectory."
  (string-match-p
   (concat "\\`" (regexp-quote (file-name-as-directory
                                (expand-file-name "~/work/tasks/"))))
   (file-name-as-directory (expand-file-name (or dir default-directory)))))

(defun my/task-list--empty-mode-setup ()
  "Restore task-list bindings in Denote empty buffers for task directories."
  (when (or my/task-list--managed-p
            (my/task-list--tasks-directory-p))
    (setq-local my/task-list--managed-p t)
    (local-set-key (kbd "C-c t") (my/task-list--task-prefix-map))))

(defun my/task-list--clone-buffer (buffer)
  "Return a cloned managed task-list BUFFER.
This preserves coexistence across windows while keeping the existing shared
filter globals, so reopening the list refreshes the underlying view and then
clones it when another window already displays the canonical Dired buffer."
  (with-current-buffer buffer
    (clone-buffer nil nil)))

(defun my/task-list--buffer-scope ()
  "Return the Denote scope pinned to the current task-list buffer."
  (file-name-as-directory
   (expand-file-name
    (or my/task-list--denote-scope
        (bound-and-true-p denote-directory)
        (and (boundp 'dired-directory)
             (consp dired-directory)
             (car dired-directory))
        default-directory))))

(defun my/task-list--restore-after-revert-error (contents point modified-p)
  "Restore CONTENTS, POINT, and MODIFIED-P after a failed task-list revert."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert contents)
    (goto-char (min point (point-max)))
    (set-buffer-modified-p modified-p)))

(defun my/task-list--revert-buffer (&rest args)
  "Revert the current task-list buffer within its pinned Denote scope.

Denote also reverts Dired buffers as a side effect of renaming notes.  Its
revert path is sensitive to the current buffer's `default-directory', which can
leave a task-list buffer blank if a cloned/list buffer is reverted with stale
context.  Bind both `default-directory' and `denote-directory' to the pinned
scope and restore the previous contents if the underlying Dired rebuild still
fails."
  (let ((contents (buffer-substring-no-properties (point-min) (point-max)))
        (point (point))
        (modified-p (buffer-modified-p))
        (scope (my/task-list--buffer-scope)))
    (condition-case err
        (let ((default-directory scope)
              (denote-directory scope))
          (if (fboundp 'denote-sort-dired-revert)
              (apply #'denote-sort-dired-revert args)
            (dired-revert)))
      (error
       (my/task-list--restore-after-revert-error contents point modified-p)
       (message "Warning: task list revert failed for %s: %s"
                (buffer-name)
                (error-message-string err))))
    (setq-local my/task-list--denote-scope scope)
    (setq-local denote-directory scope)
    (setq-local default-directory scope)
    (setq-local revert-buffer-function #'my/task-list--revert-buffer)
    (when (derived-mode-p 'dired-mode)
      (my/task-list-setup)
      (my/task-list--after-readin))))

(defun my/task-list--prepare-buffer (buffer denote-scope)
  "Prepare task-list BUFFER for display within DENOTE-SCOPE."
  ;; Pin denote scope in task list buffer so revert keeps the current epic/root scope.
  (with-current-buffer buffer
    (setq-local my/task-list--denote-scope denote-scope)
    (setq-local denote-directory denote-scope)
    (setq-local default-directory denote-scope)
    (setq-local revert-buffer-function #'my/task-list--revert-buffer)
    (my/task-list-setup)
    ;; The initial Dired read has already completed by the time setup runs,
    ;; so refresh overlays explicitly on first show.
    (my/task-list--after-readin))
  buffer)

;;;###autoload
(defun my/task-list-show ()
  "Show tasks in dired.
Uses `my/task-list-regex', `my/task-list-epic', and
`my/task-list-reverse' for filtering and sorting."
  (require 'denote)
  (let* ((selected-buffer (window-buffer (selected-window)))
         (existing-buffers (my/task-list--buffers))
         (denote-scope (file-name-as-directory
                        (expand-file-name
                         (or my/task-list-epic
                             (my/task-list--root-dir)))))
         (regex my/task-list-regex)
         (reverse my/task-list-reverse)
         (base-buffer
          (let* ((before-buffer (current-buffer))
                 (sort-result (let ((denote-directory denote-scope))
                                (denote-sort-dired regex 'identifier reverse nil)))
                 (candidate-buffer
                  (cond
                   ((bufferp sort-result) sort-result)
                   ((stringp sort-result) (get-buffer sort-result))
                   ((not (eq (current-buffer) before-buffer)) (current-buffer)))))
            (or candidate-buffer
                (with-current-buffer (get-buffer-create "*Denote Dired Empty*")
                  (setq-local default-directory denote-scope)
                  (denote-dired-empty-mode)
                  (current-buffer)))))
         (task-list-buffer
          (if (and (buffer-live-p base-buffer)
                   (memq base-buffer existing-buffers)
                   (not (eq selected-buffer base-buffer)))
              (my/task-list--clone-buffer base-buffer)
            base-buffer)))
    (switch-to-buffer (my/task-list--prepare-buffer task-list-buffer denote-scope))))

;;; Filter commands

(defun my/task-list--task-id-at-point ()
  "Return the denote task id at point, or nil when point is not on a task file."
  (when-let ((file (ignore-errors (dired-get-filename nil t))))
    (when (and (denote-file-is-in-denote-directory-p file)
               (denote-file-has-denoted-filename-p file))
      (denote-retrieve-filename-identifier file))))

(defun my/task-list--pickup-worktree-label (path)
  "Return compact user-facing label for worktree PATH."
  (let* ((expanded (directory-file-name (expand-file-name path)))
         (parts (split-string expanded "/" t))
         (len (length parts)))
    (if (>= len 2)
        (mapconcat #'identity (last parts 2) "/")
      expanded)))

(defun my/task-list--pickup-unusable-summary (entries)
  "Return user-facing suffix for unusable worktree ENTRIES."
  (when entries
    (format " [unusable worktrees: %s]"
            (mapconcat #'my/task-list--pickup-worktree-label
                       (delete-dups
                        (delq nil
                              (mapcar (lambda (entry)
                                        (plist-get entry :path))
                                      entries)))
                       ", "))))

(defun my/task-list--pickup-result-message (result)
  "Return user-facing pickup message for RESULT."
  (let ((suffix (my/task-list--pickup-unusable-summary
                 (plist-get result :unusable-worktrees))))
    (pcase (plist-get result :outcome)
      ('started
       (format "Task pickup: started%s" (or suffix "")))
      ('live
       (format "Task pickup: already live%s" (or suffix "")))
      (_
       (format "Task pickup: unexpected outcome %S%s"
               (plist-get result :outcome)
               (or suffix ""))))))

(defun my/task-list--pickup-error-message (err)
  "Return user-facing pickup error message for ERR."
  (let* ((message (if (stringp err)
                      err
                    (or (plist-get err :message)
                        (format "%s" err))))
         (suffix (my/task-list--pickup-unusable-summary
                  (and (listp err)
                       (plist-get err :unusable-worktrees)))))
    (format "Task pickup failed: %s%s" message (or suffix ""))))

(defun my/task-list--task-state-table ()
  "Return repaired task state entries keyed by task id."
  (require 'my-task)
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry (my/task-state-entries))
      (when-let ((task-id (plist-get entry :task-id)))
        (puthash task-id entry table)))
    table))

;;;###autoload
(defun my/task-list-pickup (&optional advanced-options)
  "Start or resume the task at point and display it in this window.
With prefix argument, prompt for advanced startup options first."
  (interactive "P")
  (require 'my-task)
  (let* ((task-id (my/task-list--task-id-at-point))
         (origin-window (selected-window))
         (origin-buffer (window-buffer (selected-window))))
    (unless task-id
      (user-error "No task at point"))
    (my/task-pickup-start-async
     task-id
     :advanced-options advanced-options
     :restore-session nil
     :interactive-p t
     :on-success (lambda (result)
                   (condition-case err
                       (progn
                         (when (and (window-live-p origin-window)
                                    (eq (window-buffer origin-window)
                                        origin-buffer))
                           (with-selected-window origin-window
                             (my/task-session-restore task-id)))
                         (message "%s"
                                  (my/task-list--pickup-result-message result)))
                     (error
                      (message "Task pickup started but could not display session: %s"
                               (error-message-string err)))))
     :on-error (lambda (err)
                 (message "%s"
                          (my/task-list--pickup-error-message err))))))

;;;###autoload
(defun my/task-list-filter-epic (epic)
  "Filter tasks by EPIC, keeping current regex filter.
EPIC is an epic subdirectory path, or nil for all tasks."
  (interactive
   (let* ((epics (my/task-list--epic-list))
          (epic-names (sort (mapcar #'file-name-nondirectory epics) #'string<))
          (candidates (cons "(none)" epic-names))
          (default (if my/task-list-epic
                       (file-name-nondirectory my/task-list-epic)
                     "(none)"))
          (selection (completing-read
                      (format "Epic [%s]: " default)
                      candidates nil t nil nil default)))
     (list (unless (string= selection "(none)")
             (seq-find (lambda (p)
                         (string= (file-name-nondirectory p) selection))
                       epics)))))
  (setq my/task-list-epic epic)
  (my/task-list--filter-save)
  (my/task-list-show))

;;;###autoload
(defun my/task-list-filter-regex (regex)
  "Filter tasks by REGEX, keeping current epic filter."
  (interactive
   (list (read-string (format "Filter regex [%s]: " my/task-list-regex)
                      nil nil my/task-list-regex)))
  (setq my/task-list-regex regex)
  (my/task-list--filter-save)
  (my/task-list-show))

;;;###autoload
(defun my/task-list-filter-sort ()
  "Toggle sort direction for task list.
Switches between oldest-first and newest-first, then refreshes the list."
  (interactive)
  (setq my/task-list-reverse (not my/task-list-reverse))
  (my/task-list--filter-save)
  (message "Task sort: %s" (if my/task-list-reverse "oldest first" "newest first"))
  (my/task-list-show))

(setq my/task-list-filter-map
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "e") #'my/task-list-filter-epic)
        (define-key map (kbd "r") #'my/task-list-filter-regex)
        (define-key map (kbd "s") #'my/task-list-filter-sort)
        map))

(put 'my/task-list-filter-map 'variable-documentation
     "Keymap for task filter commands.
\\<my/task-list-filter-map>
\\[my/task-list-pickup] - Pick up the task at point in place
\\[my/task-list-filter-epic] - Filter by epic
\\[my/task-list-filter-regex] - Filter by regex
\\[my/task-list-filter-sort] - Toggle sort direction")

;;; Buffer queries

;;;###autoload
(defun my/task-list-buffer ()
  "Return the first task list dired buffer, or nil if none open.
The task list buffer is any dired buffer visiting ~/work/tasks/ or subdirectory."
  (car (my/task-list--buffers)))

(defun my/task-list--buffers ()
  "Return all task list dired buffers.
Task list buffers are dired buffers visiting any denote directory
or subdirectory."
  (let ((dirs (denote-directories)))
    (seq-filter (lambda (buf)
                  (with-current-buffer buf
                    (let ((dir (expand-file-name default-directory)))
                      (or (and (derived-mode-p 'dired-mode)
                               (or my/task-list--managed-p
                                   (seq-some (lambda (d) (string-prefix-p d dir)) dirs)))
                          (and (eq major-mode 'denote-dired-empty-mode)
                               (or my/task-list--managed-p
                                   (my/task-list--tasks-directory-p dir)))))))
                (buffer-list))))

(defun my/task-list--after-readin ()
  "Refresh overlays after the current task list Dired buffer is rebuilt."
  (when my/task-list--managed-p
    (my/task-list--refresh-overlays-in-buffer)))

(defun my/task-list--refresh-overlays-in-buffer ()
  "Reapply active and WIP overlays in the current task list buffer."
  (let ((state-table (my/task-list--task-state-table)))
    (remove-overlays (point-min) (point-max) 'my-task-state 'active)
    (remove-overlays (point-min) (point-max) 'my-task-state 'wip)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((file (ignore-errors (dired-get-filename nil t)))
                    ((string-match-p "==todo--" file))
                    (id (denote-retrieve-filename-identifier file)))
          (let ((bol (line-beginning-position))
                (eol (1+ (line-end-position)))
                (entry (gethash id state-table)))
            (cond
             ((and entry (plist-get entry :active))
              (let ((ov (make-overlay bol eol)))
                (overlay-put ov 'my-task-state 'active)
                (overlay-put ov 'face 'pulsar-green)))
             ((and entry (plist-get entry :worktree))
              (let ((ov (make-overlay bol eol)))
                (overlay-put ov 'my-task-state 'wip)
                (overlay-put ov 'face 'pulsar-generic))))))
        (forward-line 1)))))

(defun my/task-list--handle-task-state-change (event)
  "Refresh task-list UI in response to task-state change EVENT."
  (let ((changes (plist-get event :changes)))
    (cond
     ((plist-get event :revert-buffers)
      (my/task-list-revert-buffers))
     ((or (memq :active changes)
          (memq :worktree changes))
      (my/task-list-maybe-refresh-overlays)))))

(defun my/task-list--install-notifications ()
  "Subscribe task-list UI to task-state change notifications."
  (unless my/task-list--notifications-installed
    (add-hook 'my/task-state-change-functions #'my/task-list--handle-task-state-change)
    (setq my/task-list--notifications-installed t)))

;;; Overlays

;;;###autoload
(defun my/task-list-refresh-overlays ()
  "Reapply active and WIP overlays for all todo tasks.
Active sessions use `pulsar-green', WIP (non-active) uses `pulsar-generic'.
Only applies to tasks with `==todo--' in filename.
No-op if no task list buffers exist."
  (dolist (task-list-buf (my/task-list--buffers))
    (with-current-buffer task-list-buf
      (my/task-list--refresh-overlays-in-buffer))))

;;;###autoload
(defun my/task-list-maybe-refresh-overlays ()
  "Refresh overlays if task list buffer exists.
Safe to call frequently; no-op when buffer doesn't exist."
  (when (my/task-list-buffer)
    (my/task-list-refresh-overlays)))

;;;###autoload
(defun my/task-list-refresh-active ()
  "Reapply active session overlays for all tasks in active sessions.
Wrapper for backward compatibility; calls `my/task-list-refresh-overlays'."
  (my/task-list-refresh-overlays))

;;;###autoload
(defun my/task-list-maybe-refresh-active ()
  "Refresh active session overlays if this is the task list buffer.
Wrapper for backward compatibility; calls `my/task-list-maybe-refresh-overlays'."
  (my/task-list-maybe-refresh-overlays))

;;;###autoload
(defun my/task-list-revert-buffers ()
  "Revert visible task-list Dired buffers."
  (dolist (task-list-buf (my/task-list--buffers))
    (with-current-buffer task-list-buf
      (revert-buffer t t t))))

;;; Entry point

;;;###autoload
(defun my/task-list ()
  "Open task list, using persisted filter settings."
  (interactive)
  (dolist (dir (denote-directories))
    (make-directory dir t))
  (my/task-list-show))

(my/task-list--install-notifications)
(add-hook 'denote-dired-empty-mode-hook #'my/task-list--empty-mode-setup)
(my/task-list--filter-load)

(provide 'my-task-list)
;;; my-task-list.el ends here
