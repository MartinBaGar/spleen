;;; spleen-actions.el --- Default actions for Spleen -*- lexical-binding: t; -*-

;; Author: Bari Garnier
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, frames
;; URL: https://github.com/bari-garnier/spleen

;;; Commentary:

;; Default launcher actions and their customization options, extracted
;; from spleen.el.  This module does not require the rendering engine.
;; It also provides `spleen-spawn' for recipes launching external programs.
;;
;; The core should autoload the four interactive entry points and
;; `spleen-spawn' from this library.  Load this library before exporting
;; standalone settings that reference its customization variables.
;;
;; This extraction preserves the supplied implementation, including its
;; terminal hold behavior, case-insensitive matching and process matching.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup spleen nil
  "Ephemeral keyboard-driven splash launcher."
  :group 'applications
  :prefix "spleen-")

;;;; Customization

(defcustom spleen-terminal-program nil
  "Terminal emulator used by `spleen-run-in-terminal' and terminal apps.
When nil, use $TERMINAL if set, otherwise the first of kitty, foot,
alacritty, ghostty and xterm found in `exec-path'."
  :type '(choice (const :tag "Auto-detect" nil)
                 (string :tag "Program"))
  :group 'spleen)

(defcustom spleen-terminal-args '("-e")
  "Arguments placed between the terminal program and the command to run.
Most terminals accept \"-e\".  For WezTerm use (\"start\" \"--\")."
  :type '(repeat string)
  :group 'spleen)

(defcustom spleen-terminal-hold 'auto
  "Whether `spleen-run-in-terminal' keeps the terminal open after the command.
- `auto': only when the command exits within two seconds, so the output
  of short commands such as `ls' can be read while long-lived ones such
  as `htop' close normally.
- `always': always wait for Enter before closing.
- `never': close as soon as the command exits.
A prefix argument to `spleen-run-in-terminal' acts as `always'."
  :type '(choice (const :tag "Only for quick commands" auto)
                 (const :tag "Always" always)
                 (const :tag "Never" never))
  :group 'spleen)

(defcustom spleen-extra-application-directories nil
  "Extra directories of .desktop files scanned by `spleen-launch-app'.
They are scanned after the XDG data directories (lowest precedence)."
  :type '(repeat directory)
  :group 'spleen)

(defcustom spleen-kill-process-all-users nil
  "When non-nil, `spleen-kill-process' lists every user's processes.
By default only processes owned by the current user are offered."
  :type 'boolean
  :group 'spleen)

;;;; Detached Processes and Terminal Selection

;;;###autoload
(defun spleen-spawn (program &rest args)
  "Start PROGRAM with ARGS detached from Emacs, discarding its output.
Use `setsid' when available to start a separate session.  This is the
helper for recipes that start external programs."
  (let ((exe (or (executable-find program)
                 (user-error "Command not found: %s" program)))
        (setsid (executable-find "setsid"))
        (default-directory (expand-file-name "~/")))
    (if setsid
        (apply #'call-process setsid nil 0 nil "--fork" exe args)
      (apply #'call-process exe nil 0 nil args))
    nil))

(defun spleen--terminal ()
  "Return the terminal emulator program to use."
  (or spleen-terminal-program
      (let ((env (getenv "TERMINAL")))
        (and env (not (string-empty-p env)) (executable-find env) env))
      (cl-find-if #'executable-find '("kitty" "foot" "alacritty" "ghostty" "xterm"))
      (user-error "No terminal found; set `spleen-terminal-program'")))

;;;; Applications

(defvar spleen--app-cache nil
  "Cache of the application scan, as (STAMP . APPS).")

(defun spleen--xdg-data-home ()
  "Return $XDG_DATA_HOME, or its default."
  (let ((home (getenv "XDG_DATA_HOME")))
    (if (and home (not (string-empty-p home)))
        home
      (expand-file-name ".local/share" "~"))))

(defun spleen--application-directories ()
  "Return existing directories holding .desktop files, highest precedence first."
  (let* ((home (spleen--xdg-data-home))
         (system (split-string (or (getenv "XDG_DATA_DIRS")
                                   "/usr/local/share:/usr/share")
                               ":" t))
         (bases (append (list home) system
                        (list (expand-file-name "flatpak/exports/share" home)
                              "/var/lib/flatpak/exports/share")))
         (dirs nil))
    (dolist (base bases)
      (let ((dir (expand-file-name "applications" base)))
        (when (file-directory-p dir)
          (cl-pushnew dir dirs :test #'equal))))
    (append (nreverse dirs)
            (cl-remove-if-not #'file-directory-p
                              (mapcar #'expand-file-name
                                      spleen-extra-application-directories)))))

(defun spleen--name-keys ()
  "Return the desktop-entry keys to try for a display name, best first."
  (let* ((locale (or (getenv "LC_ALL") (getenv "LC_MESSAGES") (getenv "LANG") ""))
         (full (car (split-string locale "[.@]")))
         (short (car (split-string full "_"))))
    (delq nil (list (and (not (string-empty-p full)) (format "Name[%s]" full))
                    (and (not (string-empty-p short)) (format "Name[%s]" short))
                    "Name"))))

(defun spleen--parse-desktop-file (file name-keys)
  "Parse the [Desktop Entry] group of FILE.
Return a plist (:name :exec :comment :terminal), or nil when the entry
is not a launchable application.  NAME-KEYS is from `spleen--name-keys'."
  (let ((fields (make-hash-table :test #'equal))
        (in-entry nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (catch 'done
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (cond
             ((string-match "\\`\\[\\(.*\\)\\]" line)
              (when in-entry (throw 'done nil))
              (setq in-entry (string= (match-string 1 line) "Desktop Entry")))
             ((and in-entry
                   (string-match
                    "\\`\\([^#=[:space:]]+\\)[[:space:]]*=[[:space:]]*\\(.*\\)\\'"
                    line))
              (puthash (match-string 1 line) (match-string 2 line) fields))))
          (forward-line 1))))
    (let ((name (cl-some (lambda (key) (gethash key fields)) name-keys))
          (exec (gethash "Exec" fields))
          (try-exec (gethash "TryExec" fields)))
      (when (and name exec
                 (equal (gethash "Type" fields) "Application")
                 (not (equal (gethash "NoDisplay" fields) "true"))
                 (not (equal (gethash "Hidden" fields) "true"))
                 (or (null try-exec) (executable-find try-exec)))
        (list :name name
              :exec exec
              :comment (gethash "Comment" fields)
              :terminal (equal (gethash "Terminal" fields) "true"))))))

(defun spleen--scan-applications (dirs)
  "Scan DIRS and return an alist (DISPLAY-NAME . PLIST), sorted by name.
Earlier directories win over later ones for the same desktop-file id."
  (let ((seen (make-hash-table :test #'equal))
        (keys (spleen--name-keys))
        (entries nil)
        (counts (make-hash-table :test #'equal)))
    (dolist (dir dirs)
      (dolist (file (ignore-errors (directory-files-recursively dir "\\.desktop\\'")))
        (let ((id (subst-char-in-string ?/ ?- (file-relative-name file dir))))
          (unless (gethash id seen)
            ;; Mark first: a hidden entry must mask lower-precedence ones.
            (puthash id t seen)
            (when-let* ((app (ignore-errors (spleen--parse-desktop-file file keys))))
              (push (cons id app) entries))))))
    (dolist (entry entries)
      (cl-incf (gethash (plist-get (cdr entry) :name) counts 0)))
    (sort (mapcar (lambda (entry)
                    (let ((name (plist-get (cdr entry) :name)))
                      (cons (if (> (gethash name counts) 1)
                                (format "%s  [%s]" name
                                        (file-name-sans-extension (car entry)))
                              name)
                            (cdr entry))))
                  entries)
          (lambda (a b) (string-lessp (downcase (car a)) (downcase (car b)))))))

(defun spleen--applications ()
  "Return installed applications, using directory timestamps for the cache."
  (let* ((dirs (spleen--application-directories))
         (stamp (mapcar (lambda (dir)
                          (cons dir (file-attribute-modification-time
                                     (file-attributes dir))))
                        dirs)))
    (if (equal (car spleen--app-cache) stamp)
        (cdr spleen--app-cache)
      (let ((apps (spleen--scan-applications dirs)))
        (setq spleen--app-cache (cons stamp apps))
        apps))))

(defun spleen--exec-argv (exec)
  "Split the desktop-entry EXEC line into an argument list.
Field codes such as %U and %f are dropped; %% becomes a literal percent."
  (delq nil
        (mapcar (lambda (arg)
                  (let ((clean (replace-regexp-in-string
                                "%." (lambda (m) (if (equal m "%%") "%" ""))
                                arg t t)))
                    (and (not (string-empty-p clean)) clean)))
                (split-string-shell-command exec))))

;;;; Completion Shared by Applications and Processes

(defun spleen--completing-read (prompt table)
  "Read a candidate from TABLE with PROMPT, forgiving about case and position.
Bind `completion-ignore-case' and append `substring' to
`completion-styles' for this prompt."
  (let ((completion-ignore-case t)
        (completion-styles (if (memq 'substring completion-styles)
                               completion-styles
                             (append completion-styles '(substring)))))
    (completing-read prompt table nil t)))

(defun spleen--read-application ()
  "Prompt for an installed application and return its entry plist."
  (let ((apps (spleen--applications)))
    (unless apps
      (user-error "No desktop entries found in %s"
                  (string-join (spleen--application-directories) ", ")))
    (let* ((completion-extra-properties
            (list :annotation-function
                  (lambda (name)
                    (when-let* ((comment (plist-get (cdr (assoc name apps)) :comment)))
                      (concat "  " (propertize comment 'face 'completions-annotations))))))
           (choice (spleen--completing-read "Launch: " apps)))
      (cdr (assoc-string choice apps t)))))

;;;###autoload
(defun spleen-launch-app (app)
  "Launch the installed application APP, chosen from the scanned .desktop files.
Interactively, prompt for it.  The application starts detached from Emacs."
  (interactive (list (spleen--read-application)))
  (let ((argv (spleen--exec-argv (plist-get app :exec))))
    (unless argv (user-error "Empty Exec line for %s" (plist-get app :name)))
    (if (plist-get app :terminal)
        (apply #'spleen-spawn (spleen--terminal)
               (append spleen-terminal-args argv))
      (apply #'spleen-spawn argv))))

;;;; Shell Commands

;;;###autoload
(defun spleen-run-command (command)
  "Run the shell COMMAND detached from Emacs, discarding its output.
Interactively, prompt for it with shell command completion."
  (interactive (list (read-shell-command "Run: ")))
  (unless (string-empty-p (string-trim command))
    (spleen-spawn "sh" "-c" command)))

;;;###autoload
(defun spleen-run-in-terminal (command &optional hold)
  "Run the shell COMMAND in a new terminal window.
An empty COMMAND just opens a terminal.  With prefix argument HOLD, wait
for Enter before closing.  Otherwise follow `spleen-terminal-hold'."
  (interactive (list (read-shell-command "Run in terminal: ") current-prefix-arg))
  (let ((terminal (spleen--terminal))
        (mode (if hold 'always spleen-terminal-hold)))
    (if (string-empty-p (string-trim command))
        (spleen-spawn terminal)
      (apply #'spleen-spawn terminal
             (append spleen-terminal-args
                     (list "sh" "-c" (spleen--terminal-script command mode)))))))

(defun spleen--terminal-script (command mode)
  "Return a shell script running COMMAND, holding the terminal per MODE.
MODE is `auto', `always' or `never', as in `spleen-terminal-hold'."
  (let ((wait (concat "printf '\\n[exit %s] press Enter to close ' \"$rc\"; read _")))
    (pcase mode
      ('never command)
      ('always (concat command "\nrc=$?\n" wait))
      (_ (concat "t0=$(date +%s)\n" command "\nrc=$?\n"
                 "if [ $(( $(date +%s) - t0 )) -lt 2 ]; then " wait "; fi")))))

;;;; Processes

(defun spleen--process-candidates ()
  "Return an alist (DISPLAY . PID) of process candidates, largest memory first."
  (let ((uid (user-uid))
        (self (emacs-pid))
        (rows nil))
    (dolist (pid (list-system-processes))
      (let ((attrs (process-attributes pid)))
        (when (and attrs
                   (/= pid self)
                   (or spleen-kill-process-all-users
                       (eql (alist-get 'euid attrs) uid)))
          (push (list pid
                      (or (alist-get 'comm attrs) "?")
                      (or (alist-get 'rss attrs) 0)
                      (or (alist-get 'args attrs) ""))
                rows))))
    (mapcar (lambda (row)
              (pcase-let ((`(,pid ,comm ,rss ,args) row))
                (cons (format "%-16s %7d %7.0f MB  %s"
                              (truncate-string-to-width comm 16 nil nil "…")
                              pid
                              (/ rss 1024.0)
                              (truncate-string-to-width args 90 nil nil "…"))
                      pid)))
            (sort rows (lambda (a b) (> (nth 2 a) (nth 2 b)))))))

;;;###autoload
(defun spleen-kill-process (&optional force)
  "Prompt for one of your processes and send it SIGTERM.
With prefix argument FORCE, send SIGKILL instead."
  (interactive "P")
  (let* ((cands (spleen--process-candidates))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action cands string pred))))
         (choice (spleen--completing-read (if force "Kill -9: " "Kill: ") table))
         (pid (cdr (assoc-string choice cands t))))
    (unless pid (user-error "No such process"))
    (if (zerop (signal-process pid (if force 9 15)))
        (message "Sent %s to %d" (if force "SIGKILL" "SIGTERM") pid)
      (user-error "Could not signal process %d" pid))))

(provide 'spleen-actions)
;;; spleen-actions.el ends here
