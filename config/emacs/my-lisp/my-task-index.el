;;; my-task-index.el --- Transient task state storage -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; In-memory task-local state.
;;
;; This module now owns only transient task state used by the current Emacs
;; session. Durable repo/worktree indexing has been removed.
;;
;; Functions:
;;   - my/task-index-entry — get read-only task entry by task-id
;;   - my/task-index-get — get task entry by task-id
;;   - my/task-index-put — create/update entry
;;   - my/task-index-remove — remove entry
;;   - my/task-index-entries — list all task entries
;;   - my/task-index-find-by-worktree — find task-id by transient worktree path
;;   - my/task-index-claimed-worktrees — list transient assigned worktree paths
;;   - my/task-index-worktree — get transient claimed worktree path
;;   - my/task-index-worktree-set — set transient claimed worktree path
;;   - my/task-index-worktree-clear — clear transient claimed worktree path
;;   - my/task-index-entries-where — filter entries by field value
;;   - my/task-index-entries-matching — filter entries by exact field value
;;   - my/task-index-entry-count — count indexed task entries

;;; Code:

(require 'cl-lib)

(defconst my/task-index--task-id-regexp "\\`[0-9]\\{8\\}T[0-9]\\{6\\}\\'"
  "Regexp matching valid Denote task identifiers.")

(define-error 'my/task-index-persistence-error
  "Task index persistence has been removed")

(defvar my/task-index (make-hash-table :test 'equal)
  "Hash table keyed by task-id (denote identifier).
Each value is a plist:
  :task-id ID
  :worktree PATH-OR-NIL
  :active BOOL")

(defcustom my/task-index-file
  (expand-file-name "task-index.el" "~/.cache/emacs/")
  "Compatibility variable for removed task-index persistence."
  :type 'file
  :group 'my-task)

(defun my/task-index--valid-task-id-p (task-id)
  "Return non-nil when TASK-ID is a valid Denote task identifier."
  (and (stringp task-id)
       (string-match-p my/task-index--task-id-regexp task-id)))

(defun my/task-index--normalize-worktree (worktree)
  "Return WORKTREE normalized as an absolute directory name, or nil."
  (and worktree
       (file-name-as-directory (expand-file-name worktree))))

(defun my/task-index--stateful-entry-p (entry)
  "Return non-nil when ENTRY contains any non-empty transient state."
  (or (plist-get entry :worktree)
      (plist-get entry :active)))

(defun my/task-index--prune-or-store (task-id entry)
  "Store ENTRY for TASK-ID, or remove it when empty.
Returns the stored entry, or nil when it was removed."
  (if (my/task-index--stateful-entry-p entry)
      (progn
        (puthash task-id entry my/task-index)
        entry)
    (remhash task-id my/task-index)
    nil))

;;; Compatibility stubs for removed persistence

(defun my/task-index--read-file (&optional _strict)
  "Return an empty transient table.
Durable task-index persistence has been removed."
  (make-hash-table :test 'equal))

(defun my/task-index--write-file (_table)
  "Compatibility no-op for removed task-index persistence."
  nil)

(defun my/task-index--persist-change (_operation _mutator)
  "Signal that durable task-index persistence has been removed."
  (signal 'my/task-index-persistence-error
          '("Task index persistence has been removed")))

(defun my/task-index-prune-invalid ()
  "Remove invalid task-id entries from the in-memory index.
Returns the number of pruned entries."
  (let ((pruned 0))
    (maphash (lambda (task-id _entry)
               (unless (my/task-index--valid-task-id-p task-id)
                 (remhash task-id my/task-index)
                 (cl-incf pruned)))
             my/task-index)
    pruned))

;;; Query API

;;;###autoload
(defun my/task-index-entry (task-id)
  "Return read-only task entry plist for TASK-ID, or nil."
  (when-let ((entry (my/task-index-get task-id)))
    (copy-tree entry)))

;;;###autoload
(defun my/task-index-get (task-id)
  "Return task entry plist for TASK-ID, or nil."
  (when (my/task-index--valid-task-id-p task-id)
    (gethash task-id my/task-index)))

;;;###autoload
(defun my/task-index-entries ()
  "Return list of all task entry plists."
  (let (result)
    (maphash (lambda (_task-id entry)
               (push entry result))
             my/task-index)
    result))

;;;###autoload
(defun my/task-index-put (task-id plist &optional _persist)
  "Create or update transient entry for TASK-ID with PLIST."
  (unless (my/task-index--valid-task-id-p task-id)
    (error "Invalid task-id for task index: %S" task-id))
  (let ((entry (copy-tree (or (gethash task-id my/task-index)
                              (list :task-id task-id)))))
    (cl-loop for (key val) on plist by #'cddr
             do (setq entry (plist-put entry key
                                       (if (eq key :worktree)
                                           (my/task-index--normalize-worktree val)
                                         val))))
    (my/task-index--prune-or-store task-id entry)))

;;;###autoload
(defun my/task-index-remove (task-id)
  "Remove transient entry for TASK-ID."
  (when (my/task-index--valid-task-id-p task-id)
    (remhash task-id my/task-index)))

;;;###autoload
(defun my/task-index-find-by-worktree (path)
  "Return task-id for transient entry with :worktree matching PATH, or nil."
  (let ((expanded (my/task-index--normalize-worktree path))
        (found nil))
    (maphash (lambda (task-id entry)
               (when-let ((wt (plist-get entry :worktree)))
                 (when (string= wt expanded)
                   (setq found task-id))))
             my/task-index)
    found))

;;;###autoload
(defun my/task-index-claimed-worktrees ()
  "Return list of all transient non-nil :worktree values."
  (let (result)
    (maphash (lambda (_k v)
               (when-let ((wt (plist-get v :worktree)))
                 (push wt result)))
             my/task-index)
    result))

;;;###autoload
(defun my/task-index-entries-where (field value)
  "Return list of entry plists where FIELD has a truthy/falsy match.
When VALUE is non-nil, matches entries where FIELD is non-nil.
When VALUE is nil, matches entries where FIELD is nil."
  (let (result)
    (maphash (lambda (_k entry)
               (let ((actual (plist-get entry field)))
                 (when (if value actual (not actual))
                   (push entry result))))
             my/task-index)
    result))

;;;###autoload
(defun my/task-index-entries-matching (field value)
  "Return list of entry plists where FIELD is exactly VALUE."
  (let (result)
    (maphash (lambda (_task-id entry)
               (when (equal (plist-get entry field) value)
                 (push entry result)))
             my/task-index)
    result))

;;;###autoload
(defun my/task-index-entry-count ()
  "Return the number of transient task entries."
  (hash-table-count my/task-index))

;;; Field accessors

;;;###autoload
(defun my/task-index-worktree (task-id)
  "Return transient claimed worktree path for TASK-ID, or nil."
  (plist-get (my/task-index-get task-id) :worktree))

;;;###autoload
(defun my/task-index-worktree-set (task-id worktree &optional _persist)
  "Set transient WORKTREE path for TASK-ID."
  (my/task-index-put task-id (list :worktree worktree)))

;;;###autoload
(defun my/task-index-worktree-clear (task-id &optional _persist)
  "Clear transient claimed worktree path for TASK-ID."
  (my/task-index-put task-id (list :worktree nil)))

(provide 'my-task-index)
;;; my-task-index.el ends here
