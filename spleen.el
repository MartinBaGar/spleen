;;; spleen.el --- Ephemeral keyboard-driven splash launcher -*- lexical-binding: t; -*-

;; Author: Bari Garnier
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, frames
;; URL: https://github.com/bari-garnier/spleen

;;; Commentary:

;; `spleen' is a keyboard-driven, editorial floating splash screen and
;; action hub for Emacs.  It is designed for Wayland/X11 tiling window
;; managers (Niri, Hyprland, Sway) as well as clean startup dashboards.
;;
;; The defaults are deliberately small and independent of any running
;; Emacs session (no projects, no recent files, no buffers):
;;
;;   a  Launch app        scan .desktop files and start one, detached
;;   r  Run command       run a shell command, detached
;;   t  Run in terminal   run a command (or nothing) in a terminal
;;   k  Kill process      pick one of your processes and signal it
;;
;; Anything else is meant to be grafted on with `spleen-add-section'
;; (see the recipes shipped with the package).
;;
;; Features:
;; - Zero external dependencies (pure Emacs 29.1+ pixel-metric layout).
;; - Mixed `variable-pitch' headings and `fixed-pitch' key/description
;;   columns aligned to exact pixel widths and recentered on resize.
;; - Three layouts: `two-column', `single-column' and `banner-only'.
;; - Two dispatch workflows: two-step visual key hub (default) or
;;   one-step immediate prompt (`spleen-initial-action').
;; - Single-file standalone exporter (`spleen-export-standalone') that
;;   snapshots your `load-path', faces, sections and user-defined actions
;;   into a fast byte-compiled `-Q' boot profile.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar server-client-instructions)

;;;; Customization

(defgroup spleen nil
  "Ephemeral keyboard-driven splash launcher."
  :group 'applications
  :prefix "spleen-")

(defcustom spleen-title "SPLEEN"
  "Main title displayed in the splash banner.
Set to nil or an empty string to omit the title."
  :type '(choice (string :tag "Title text")
                 (const :tag "No title" nil))
  :group 'spleen)

(defcustom spleen-show-rules t
  "When non-nil, draw hairline dividers between banner, menu, and footer."
  :type 'boolean
  :group 'spleen)

(defcustom spleen-show-footer t
  "When non-nil, display the centered quit hint below the menu."
  :type 'boolean
  :group 'spleen)

(defcustom spleen-quit-key "q"
  "Key sequence bound to close the splash frame."
  :type 'string
  :group 'spleen)

(defcustom spleen-quit-label "Close"
  "Description shown beside `spleen-quit-key' in the footer."
  :type 'string
  :group 'spleen)

(defcustom spleen-column-gap 5
  "Horizontal gap between columns measured in `fixed-pitch' space widths."
  :type 'natnum
  :group 'spleen)

(defcustom spleen-layout 'two-column
  "Visual layout of the splash screen.
- `two-column': Centered banner with paired side-by-side action columns.
- `single-column': Centered vertical stack of sections and actions.
- `banner-only': Minimal centered title and divider (pairs well with
  `spleen-initial-action')."
  :type '(choice (const :tag "Two-column grid" two-column)
                 (const :tag "Single centered column" single-column)
                 (const :tag "Banner only" banner-only))
  :group 'spleen)

(defcustom spleen-initial-action nil
  "Optional interactive command to run immediately when `spleen-show' opens.
When nil, display the splash screen and wait for a shortcut key.
When non-nil, render the splash buffer first and immediately invoke this
command via `spleen-run'."
  :type '(choice (const :tag "Two-step (wait for shortcut key)" nil)
                 (function :tag "One-step (run command immediately)"))
  :group 'spleen)

(defcustom spleen-quit-function #'spleen-default-quit
  "Function called with one argument (FRAME) when closing the splash."
  :type 'function
  :group 'spleen)

(defcustom spleen-frame-name "spleen"
  "Frame name and title assigned to the splash frame for compositor rules."
  :type 'string
  :group 'spleen)

(defcustom spleen-buffer-name "*spleen*"
  "Name of the buffer used to render the splash screen."
  :type 'string
  :group 'spleen)

(defcustom spleen-sections
  '((("LAUNCH"
      ("a" "Launch app"      spleen-launch-app)
      ("r" "Run command"     spleen-run-command)
      ("t" "Run in terminal" spleen-run-in-terminal))
     ("SYSTEM"
      ("k" "Kill process"    spleen-kill-process))))
  "Menu specification displayed by `spleen'.
Each element is a row-group of one or two column specs:
  ((LEFT-TITLE (KEY DESC COMMAND) ...)
   (RIGHT-TITLE (KEY DESC COMMAND) ...))
In `single-column' layout, column specs are rendered sequentially.
Use `spleen-add-section' to extend the menu without editing this list."
  :type '(repeat
          (list
           (cons :tag "Left column"
                 (string :tag "Section title")
                 (repeat (list (string :tag "Key")
                               (string :tag "Description")
                               (function :tag "Command"))))
           (option
            (cons :tag "Right column"
                  (string :tag "Section title")
                  (repeat (list (string :tag "Key")
                                (string :tag "Description")
                                (function :tag "Command")))))))
  :group 'spleen)

;;;; Built-in Actions Options

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

;;;; Standalone Exporter Options

(defcustom spleen-standalone-directory
  (expand-file-name "var/spleen-standalone/" user-emacs-directory)
  "Directory where `spleen-export-standalone' writes `early-init.el' and `init.el'."
  :type 'directory
  :group 'spleen)

(defcustom spleen-standalone-packages nil
  "List of library symbols whose `load-path' directories should be exported.
Transitive package dependencies declared in package headers are resolved
automatically when `spleen-export-standalone' runs."
  :type '(repeat symbol)
  :group 'spleen)

(defcustom spleen-standalone-symbols nil
  "Optional extra user function or variable symbols to export.
Commands in `spleen-sections' and `spleen-initial-action' (along with
all helper functions and variables they reference) are exported
automatically."
  :type '(repeat symbol)
  :group 'spleen)

(defcustom spleen-standalone-files nil
  "Optional extra Elisp files loaded at the end of the standalone boot file.
Not required if you define your actions directly in `init.el'."
  :type '(repeat file)
  :group 'spleen)

(defcustom spleen-standalone-completion 'vertico
  "Completion UI enabled in the generated standalone boot file.
- `vertico': Enable `vertico-mode' (and `orderless' if on `load-path'),
  falling back to `fido-vertical-mode'.
- `fido': Always use built-in `fido-vertical-mode'.
- `none': Do not configure a completion UI automatically."
  :type '(choice (const :tag "Vertico + Orderless (with Fido fallback)" vertico)
                 (const :tag "Built-in Fido vertical" fido)
                 (const :tag "None" none))
  :group 'spleen)

(defcustom spleen-standalone-frame-alist
  '((undecorated . t)
    (alpha-background . 92)
    (internal-border-width . 24)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (cursor-type . nil))
  "Additional `default-frame-alist' entries written into the standalone file."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'spleen)

;;;; Faces

(defface spleen-title
  '((t :inherit variable-pitch :height 1.55 :weight bold))
  "Face for the main splash banner title."
  :group 'spleen)

(defface spleen-section
  '((t :inherit (variable-pitch shadow) :height 0.85 :weight bold))
  "Face for section headings above action columns."
  :group 'spleen)

(defface spleen-key
  '((t :inherit (fixed-pitch font-lock-keyword-face) :weight bold))
  "Theme-adaptive accent face for shortcut keys."
  :group 'spleen)

(defface spleen-description
  '((t :inherit (fixed-pitch shadow)))
  "Softer face for shortcut descriptions."
  :group 'spleen)

(defface spleen-rule
  '((t :inherit shadow :height 0.75))
  "Face for hairline dividers."
  :group 'spleen)

;;;; Internal State

(defvar-local spleen--top-pad-overlay nil
  "Overlay at `point-min' used to vertically center splash content.")

(defvar-local spleen--block-px nil
  "Pixel width of the rendered menu block, used to size hairline rules.")

;;;; Frame Lifecycle & Command Dispatch

(defun spleen-default-quit (&optional frame)
  "Close splash FRAME safely across daemon, multi-frame, and standalone runs."
  (let ((target (or frame (selected-frame))))
    (when (frame-live-p target)
      (if (or (daemonp) (> (length (frame-list)) 1))
          (delete-frame target)
        (kill-emacs)))))

(defun spleen-close (&optional frame)
  "Close FRAME (or selected frame) using `spleen-quit-function'."
  (interactive)
  (funcall spleen-quit-function (or frame (selected-frame))))

;;;###autoload
(defun spleen-run (command &optional keep-frame)
  "Call interactive COMMAND inside the splash frame.
Unless KEEP-FRAME is non-nil, close the splash frame once COMMAND
completes or is aborted with `quit' (\\[keyboard-quit])."
  (let ((frame (selected-frame)))
    (unwind-protect
        (condition-case nil
            (call-interactively command)
          (quit nil))
      (when (and (not keep-frame) (frame-live-p frame))
        (spleen-close frame)))))

(defun spleen--wrap-command (command)
  "Return an interactive wrapper invoking COMMAND via `spleen-run'."
  (lambda ()
    (interactive)
    (spleen-run command)))

(defun spleen--build-keymap ()
  "Construct a keymap from `spleen-sections' and `spleen-quit-key'."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (pair spleen-sections)
      (dolist (col pair)
        (dolist (item (cdr col))
          (pcase-let ((`(,key ,_desc ,cmd) item))
            (when (and (stringp key) (not (string-empty-p key)) (functionp cmd))
              (define-key map (kbd key) (spleen--wrap-command cmd)))))))
    (when (and (stringp spleen-quit-key)
               (not (string-empty-p spleen-quit-key)))
      (define-key map (kbd spleen-quit-key) #'spleen-close))
    map))

;;;###autoload
(defun spleen-add-section (title items)
  "Add ITEMS, a list of (KEY DESC COMMAND), under the section named TITLE.
If a section called TITLE already exists, ITEMS are appended to it.
Otherwise a new section is created: in the right-hand column of the
last row if that column is free, or in a new row.
Returns the updated value of `spleen-sections'."
  (let ((found nil))
    (setq spleen-sections
          (mapcar (lambda (row)
                    (mapcar (lambda (col)
                              (if (equal (car col) title)
                                  (progn (setq found t)
                                         (append col items))
                                col))
                            row))
                  spleen-sections))
    (unless found
      (let ((last-row (car (last spleen-sections)))
            (new (cons title items)))
        (setq spleen-sections
              (if (and last-row (= (length last-row) 1))
                  (append (butlast spleen-sections)
                          (list (append last-row (list new))))
                (append spleen-sections (list (list new)))))))
    spleen-sections))

;;;; Built-in Actions

(defvar spleen--app-cache nil
  "Cache of the application scan, as (STAMP . APPS).")

(defun spleen-spawn (program &rest args)
  "Start PROGRAM with ARGS fully detached from Emacs, discarding its output.
The child runs in its own session (through `setsid' when available), so
it survives the closing of the splash frame and `kill-emacs'.  This is
the function to use in recipes that start external programs."
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

;;;;; Applications

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
  "Return the installed applications, rescanning only when directories change."
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

(defun spleen--completing-read (prompt table)
  "Read a candidate from TABLE with PROMPT, forgiving about case and position.
Case is ignored, and `substring' is appended to `completion-styles' so
that typing any part of a candidate finds it, whatever completion UI
is active."
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

;;;;; Shell commands

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

;;;;; Processes

(defun spleen--process-candidates ()
  "Return an alist (DISPLAY . PID) of killable processes, largest memory first."
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
    ;; 15 and 9 are SIGTERM and SIGKILL on every POSIX system.
    (if (zerop (signal-process pid (if force 9 15)))
        (message "Sent %s to %d" (if force "SIGKILL" "SIGTERM") pid)
      (user-error "Could not signal process %d" pid))))

;;;; Pixel Measurement & Centering Engine

(defun spleen--pixel-width (str)
  "Return rendered pixel width of propertized string STR."
  (if (and (display-graphic-p) (fboundp 'string-pixel-width))
      (string-pixel-width str)
    (* (string-width str) (frame-char-width))))

(defun spleen--centered-prefix (pixel-width)
  "Return display space aligning following text to center minus PIXEL-WIDTH/2."
  (if (display-graphic-p)
      (let ((half-px (max 0 (/ pixel-width 2))))
        (propertize " " 'display `(space :align-to (- center (,half-px)))))
    (let ((half-cols (max 0 (/ pixel-width 2))))
      (propertize " " 'display `(space :align-to (- center ,half-cols))))))

(defun spleen--insert-centered (styled-text &optional no-newline)
  "Insert STYLED-TEXT horizontally centered in the current window.
When NO-NEWLINE is non-nil, omit the trailing newline."
  (let* ((width-px (spleen--pixel-width styled-text))
         (prefix (spleen--centered-prefix width-px)))
    (insert (propertize styled-text 'line-prefix prefix))
    (unless no-newline
      (insert "\n"))))

(defun spleen--insert-rule (width-px)
  "Insert a centered hairline divider matching WIDTH-PX."
  (let* ((glyph (propertize "─" 'face 'spleen-rule))
         (glyph-px (max 1 (spleen--pixel-width glyph)))
         (count (max 1 (/ width-px glyph-px)))
         (rule (propertize (make-string count ?─) 'face 'spleen-rule)))
    (spleen--insert-centered rule)))

(defun spleen--recenter-window (&optional window-or-frame)
  "Vertically center the splash buffer inside WINDOW-OR-FRAME."
  (let* ((window (cond
                  ((windowp window-or-frame) window-or-frame)
                  ((framep window-or-frame) (frame-selected-window window-or-frame))
                  (t (selected-window))))
         (buffer (and (window-live-p window) (window-buffer window))))
    (when (and buffer (buffer-local-value 'spleen--top-pad-overlay buffer))
      (with-current-buffer buffer
        (when (overlayp spleen--top-pad-overlay)
          (overlay-put spleen--top-pad-overlay 'before-string "")
          (let* ((body-px (window-body-height window t))
                 (content-px (cdr (window-text-pixel-size window (point-min) (point-max))))
                 (pad-px (max 0 (/ (- body-px content-px) 2))))
            (overlay-put
             spleen--top-pad-overlay
             'before-string
             (if (> pad-px 0)
                 (concat (propertize " " 'display `(space :width 0 :height (,pad-px)))
                         (propertize "\n" 'line-height t))
               ""))))))))

;;;; Widgets & Layout Renderers

(defun spleen--format-title (title)
  "Propertize section TITLE."
  (propertize title 'face 'spleen-section))

(defun spleen--format-item (item)
  "Propertize menu ITEM (KEY DESC COMMAND)."
  (pcase-let ((`(,key ,desc ,_cmd) item))
    (concat (propertize key 'face 'spleen-key)
            (propertize "  " 'face 'fixed-pitch)
            (propertize desc 'face 'spleen-description))))

(defun spleen--render-two-column ()
  "Render `spleen-sections' as a pixel-aligned two-column block."
  (let* ((rendered
          (mapcar
           (lambda (pair)
             (pcase-let ((`((,l-title . ,l-items) (,r-title . ,r-items)) pair))
               (list (spleen--format-title l-title)
                     (mapcar #'spleen--format-item l-items)
                     (and r-title (spleen--format-title r-title))
                     (mapcar #'spleen--format-item r-items))))
           spleen-sections))
         (col1-px 0)
         (col2-px 0)
         (gap-str (make-string (max 1 spleen-column-gap) ?\s))
         (gap-px (spleen--pixel-width (propertize gap-str 'face 'fixed-pitch))))
    (dolist (sec rendered)
      (pcase-let ((`(,l-head ,l-rows ,r-head ,r-rows) sec))
        (setq col1-px (apply #'max col1-px (spleen--pixel-width l-head)
                             (mapcar #'spleen--pixel-width l-rows)))
        (when r-head
          (setq col2-px (apply #'max col2-px (spleen--pixel-width r-head)
                               (mapcar #'spleen--pixel-width r-rows))))))
    (let* ((block-px (if (> col2-px 0) (+ col1-px gap-px col2-px) col1-px))
           (row-prefix (spleen--centered-prefix block-px)))
      (setq spleen--block-px block-px)
      (cl-flet ((insert-row (left right)
                  (let* ((left-px (spleen--pixel-width left))
                         (spacer-px (+ (- col1-px left-px) gap-px))
                         (spacer (if (display-graphic-p)
                                     (propertize " " 'display `(space :width (,spacer-px)))
                                   (make-string (max 1 (/ spacer-px (max 1 (frame-char-width)))) ?\s)))
                         (line (if (or (null right) (string-empty-p right))
                                   left
                                 (concat left spacer right))))
                    (insert (propertize line 'line-prefix row-prefix) "\n"))))
        (let ((remaining rendered))
          (while remaining
            (pcase-let ((`((,l-head ,l-rows ,r-head ,r-rows) . ,rest) remaining))
              (insert-row l-head r-head)
              (dotimes (i (max (length l-rows) (length r-rows)))
                (insert-row (or (nth i l-rows) "")
                            (or (nth i r-rows) "")))
              (when rest
                (insert "\n"))
              (setq remaining rest))))))))

(defun spleen--render-single-column ()
  "Render `spleen-sections' as a single centered column."
  (let ((columns (apply #'append spleen-sections))
        (max-px 0))
    (dolist (col columns)
      (pcase-let ((`(,title . ,items) col))
        (setq max-px (apply #'max max-px
                            (spleen--pixel-width (spleen--format-title title))
                            (mapcar (lambda (it)
                                      (spleen--pixel-width (spleen--format-item it)))
                                    items)))))
    (setq spleen--block-px max-px)
    (let ((row-prefix (spleen--centered-prefix max-px))
          (remaining columns))
      (while remaining
        (pcase-let ((`((,title . ,items) . ,rest) remaining))
          (insert (propertize (spleen--format-title title) 'line-prefix row-prefix) "\n")
          (dolist (it items)
            (insert (propertize (spleen--format-item it) 'line-prefix row-prefix) "\n"))
          (when rest
            (insert "\n"))
          (setq remaining rest))))))

(defun spleen--insert-banner (has-body)
  "Insert the centered title banner and optional top divider.
HAS-BODY indicates whether menu items or a footer follow."
  (when (and (stringp spleen-title) (not (string-empty-p spleen-title)))
    (spleen--insert-centered
     (propertize spleen-title 'face 'spleen-title)
     (not (or has-body spleen-show-rules)))
    (when (or has-body spleen-show-rules)
      (insert "\n")))
  (when (and spleen-show-rules spleen--block-px (> spleen--block-px 0))
    (spleen--insert-rule spleen--block-px)
    (when has-body
      (insert "\n"))))

(defun spleen--insert-footer ()
  "Insert the optional divider and centered quit hint."
  (when spleen-show-footer
    (insert "\n")
    (when (and spleen-show-rules spleen--block-px (> spleen--block-px 0))
      (spleen--insert-rule spleen--block-px)
      (insert "\n"))
    (spleen--insert-centered
     (concat (propertize spleen-quit-key 'face 'spleen-key)
             (propertize "  " 'face 'fixed-pitch)
             (propertize spleen-quit-label 'face 'spleen-description))
     t)))

;;;; Major Mode & Entry Point

(define-derived-mode spleen-mode special-mode "Spleen"
  "Major mode for the keyboard-driven Spleen splash launcher."
  :syntax-table nil
  :abbrev-table nil
  (setq-local mode-line-format nil
              header-line-format nil
              tab-line-format nil
              cursor-type nil
              cursor-in-non-selected-windows nil
              truncate-lines t
              show-trailing-whitespace nil
              buffer-undo-list t
              left-margin-width 0
              right-margin-width 0)
  (when (bound-and-true-p display-line-numbers-mode)
    (display-line-numbers-mode -1))
  (when (bound-and-true-p hl-line-mode)
    (hl-line-mode -1))
  (add-hook 'window-size-change-functions #'spleen--recenter-window nil t))

;;;###autoload
(defun spleen-show ()
  "Render and display the full-frame Spleen splash screen.
If `spleen-initial-action' is non-nil, invoke it immediately after
rendering the splash frame."
  (interactive)
  (let ((buffer (get-buffer-create spleen-buffer-name))
        (frame (selected-frame))
        (show-menu (not (eq spleen-layout 'banner-only))))
    (with-current-buffer buffer
      (when (overlayp spleen--top-pad-overlay)
        (delete-overlay spleen--top-pad-overlay)
        (setq spleen--top-pad-overlay nil))
      (spleen-mode)
      (use-local-map (spleen--build-keymap))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (remove-overlays (point-min) (point-max))
        (let* ((menu-data
                (when show-menu
                  (with-temp-buffer
                    (pcase spleen-layout
                      ('single-column (spleen--render-single-column))
                      (_ (spleen--render-two-column)))
                    (cons spleen--block-px (buffer-string)))))
               (title-px (if (and (stringp spleen-title)
                                  (not (string-empty-p spleen-title)))
                             (spleen--pixel-width
                              (propertize spleen-title 'face 'spleen-title))
                           240)))
          (setq spleen--block-px (or (car menu-data) title-px))
          (spleen--insert-banner (or show-menu spleen-show-footer))
          (when menu-data
            (insert (cdr menu-data)))
          (spleen--insert-footer)))
      (goto-char (point-min))
      (setq spleen--top-pad-overlay (make-overlay (point-min) (point-min) buffer t nil)))
    (switch-to-buffer buffer)
    (delete-other-windows)
    (let ((window (or (get-buffer-window buffer frame) (selected-window))))
      (set-window-fringes window 0 0)
      (set-window-margins window 0 0)
      (set-window-scroll-bars window 0 nil 0 nil)
      (modify-frame-parameters frame `((name . ,spleen-frame-name)
                                       (title . ,spleen-frame-name)
                                       (cursor-type . nil)))
      (with-current-buffer buffer
        (setq-local frame-title-format spleen-frame-name))
      (spleen--recenter-window window)
      (unless (frame-visible-p frame)
        (make-frame-visible frame)))
    (setq server-client-instructions nil)
    (when (functionp spleen-initial-action)
      (run-at-time 0 nil #'spleen-run spleen-initial-action))))

;;;; Standalone `-Q' Boot-File Generator

(defun spleen--builtin-dir-p (dir)
  "Return non-nil if DIR belongs to Emacs's built-in Lisp or data directories."
  (let ((norm (expand-file-name dir))
        (roots (delq nil (list (and (boundp 'lisp-directory) lisp-directory)
                               data-directory))))
    (cl-some (lambda (root)
               (string-prefix-p (file-name-as-directory (expand-file-name root))
                                (file-name-as-directory norm)))
             roots)))

(defun spleen--collect-package-dirs (packages)
  "Resolve `load-path' directories for PACKAGES and their dependencies."
  (require 'package)
  (let ((queue (copy-sequence (cons 'spleen packages)))
        (seen (make-hash-table :test 'eq))
        (dirs nil))
    (while queue
      (let ((pkg (pop queue)))
        (when (and (symbolp pkg)
                   (not (eq pkg 'emacs))
                   (not (gethash pkg seen)))
          (puthash pkg t seen)
          (when-let* ((lib (locate-library (symbol-name pkg))))
            (let ((dir (directory-file-name (file-name-directory lib))))
              (unless (spleen--builtin-dir-p dir)
                (cl-pushnew dir dirs :test #'equal)))
            (when (fboundp 'package--dependencies)
              (dolist (dep (ignore-errors (package--dependencies pkg)))
                (let ((dep-sym (if (consp dep) (car dep) dep)))
                  (when (and (symbolp dep-sym) (not (gethash dep-sym seen)))
                    (push dep-sym queue)))))))))
    (nreverse dirs)))

(defun spleen--user-symbol-p (sym type exported-dirs)
  "Return non-nil if SYM of TYPE (`defun' or `defvar') comes from user config."
  (let ((file (symbol-file sym type)))
    (cond
     ((null file) t)
     ((spleen--builtin-dir-p (file-name-directory file)) nil)
     ((cl-some (lambda (dir)
                 (string-prefix-p (file-name-as-directory (expand-file-name dir))
                                  (expand-file-name file)))
               exported-dirs)
      nil)
     (t t))))

(defun spleen--printable-p (value)
  "Return non-nil if VALUE can be printed and read back."
  (condition-case nil
      (let ((print-circle t)
            (print-length nil)
            (print-level nil))
        (read (prin1-to-string value))
        t)
    (error nil)))

(defun spleen--scan-symbols (obj acc)
  "Collect all symbols referenced inside OBJ into hash table ACC."
  (cond
   ((symbolp obj)
    (puthash obj t acc))
   ((consp obj)
    (spleen--scan-symbols (car obj) acc)
    (spleen--scan-symbols (cdr obj) acc))
   ((vectorp obj)
    (dotimes (i (length obj))
      (spleen--scan-symbols (aref obj i) acc)))
   ((byte-code-function-p obj)
    (when (> (length obj) 2)
      (spleen--scan-symbols (aref obj 2) acc)))
   ((and (fboundp 'closurep) (closurep obj))
    (when (> (length obj) 1)
      (spleen--scan-symbols (aref obj 1) acc)))))

(defun spleen--collect-user-definitions (exported-dirs)
  "Collect `(VARS . FUNS)' defined in user config and used by splash actions."
  (let ((queue (copy-sequence spleen-standalone-symbols))
        (seen-funs (make-hash-table :test 'eq))
        (seen-vars (make-hash-table :test 'eq))
        (funs nil)
        (vars nil))
    (when (symbolp spleen-initial-action)
      (push spleen-initial-action queue))
    (dolist (pair spleen-sections)
      (dolist (col pair)
        (dolist (item (cdr col))
          (let ((cmd (nth 2 item)))
            (when (symbolp cmd)
              (push cmd queue))))))
    (while queue
      (let ((sym (pop queue)))
        (when (and (symbolp sym)
                   (not (gethash sym seen-funs))
                   (fboundp sym))
          (puthash sym t seen-funs)
          (let ((fn (symbol-function sym)))
            (when (and (not (subrp fn))
                       (not (integerp (get sym 'function-documentation)))
                       (spleen--user-symbol-p sym 'defun exported-dirs))
              (push (cons sym fn) funs)
              (let ((refs (make-hash-table :test 'eq)))
                (spleen--scan-symbols fn refs)
                (maphash
                 (lambda (ref _v)
                   (when (and (fboundp ref) (not (gethash ref seen-funs)))
                     (push ref queue))
                   (when (and (boundp ref)
                              (not (gethash ref seen-vars))
                              (not (keywordp ref))
                              (not (memq ref '(t nil)))
                              (not (integerp (get ref 'variable-documentation)))
                              (spleen--user-symbol-p ref 'defvar exported-dirs)
                              (spleen--printable-p (symbol-value ref)))
                     (puthash ref t seen-vars)
                     (push (cons ref (symbol-value ref)) vars)))
                 refs)))))))
    (cons (nreverse vars) (nreverse funs))))

(defun spleen--snapshot-faces ()
  "Capture current frame typography and editorial colors as face specs."
  (let ((valid-color (lambda (c) (and (stringp c) (not (string-prefix-p "unspecified" c))))))
    `((default
       :family ,(face-attribute 'default :family nil t)
       :height ,(face-attribute 'default :height nil t)
       ,@(let ((bg (face-attribute 'default :background nil t)))
           (when (funcall valid-color bg) `(:background ,bg)))
       ,@(let ((fg (face-attribute 'default :foreground nil t)))
           (when (funcall valid-color fg) `(:foreground ,fg))))
      (fixed-pitch
       :family ,(face-attribute 'fixed-pitch :family nil t)
       :height ,(face-attribute 'fixed-pitch :height nil t))
      (variable-pitch
       :family ,(face-attribute 'variable-pitch :family nil t)
       :height ,(face-attribute 'variable-pitch :height nil t))
      (font-lock-keyword-face
       ,@(let ((fg (face-attribute 'font-lock-keyword-face :foreground nil t)))
           (when (funcall valid-color fg) `(:foreground ,fg)))
       :weight ,(face-attribute 'font-lock-keyword-face :weight nil t))
      (shadow
       ,@(let ((fg (face-attribute 'shadow :foreground nil t)))
           (when (funcall valid-color fg) `(:foreground ,fg))))
      (minibuffer-prompt
       ,@(let ((fg (face-attribute 'minibuffer-prompt :foreground nil t)))
           (when (funcall valid-color fg) `(:foreground ,fg)))
       :weight ,(face-attribute 'minibuffer-prompt :weight nil t)))))

;;;###autoload
(defun spleen-export-standalone (&optional directory)
  "Generate and byte-compile a fast, chrome-free profile in DIRECTORY.
Defaults to `spleen-standalone-directory'.  Writes `early-init.el'
\(applied before GTK creates the window) and `init.el' (which boots
directly into `spleen-show' without displaying `*scratch*')."
  (interactive)
  (let* ((dir (file-name-as-directory
               (expand-file-name (or directory spleen-standalone-directory))))
         (early-file (expand-file-name "early-init.el" dir))
         (init-file (expand-file-name "init.el" dir))
         (dirs (spleen--collect-package-dirs spleen-standalone-packages))
         (defs (spleen--collect-user-definitions dirs))
         (user-vars (car defs))
         (user-funs (cdr defs))
         (faces (spleen--snapshot-faces))
         (default-spec (cdr (assq 'default faces)))
         (bg (plist-get default-spec :background))
         (fg (plist-get default-spec :foreground))
         (extra-files (mapcar #'expand-file-name spleen-standalone-files))
         (frame-alist `((name . ,spleen-frame-name)
                        (title . ,spleen-frame-name)
                        ,@(when bg `((background-color . ,bg)))
                        ,@(when fg `((foreground-color . ,fg)))
                        ,@spleen-standalone-frame-alist)))
    (make-directory dir t)
    ;; 1. early-init.el: runs BEFORE Wayland/GTK surface creation
    (with-temp-file early-file
      (let ((print-length nil)
            (print-level nil))
        (insert ";;; early-init.el --- Pre-frame setup for spleen -*- lexical-binding: t; -*-\n\n"
                "(defvar spleen--saved-fnh file-name-handler-alist)\n"
                "(setq gc-cons-threshold most-positive-fixnum\n"
                "      gc-cons-percentage 0.6\n"
                "      file-name-handler-alist nil\n"
                "      package-enable-at-startup nil\n"
                "      site-run-file nil\n"
                "      inhibit-default-init t\n"
                "      inhibit-startup-screen t\n"
                "      inhibit-startup-message t\n"
                "      inhibit-startup-echo-area-message user-login-name\n"
                "      initial-scratch-message nil\n"
                "      frame-inhibit-implied-resize t\n"
                "      ring-bell-function #'ignore\n"
                "      use-short-answers t\n"
                "      create-lockfiles nil\n"
                "      make-backup-files nil\n"
                "      auto-save-default nil)\n\n"
                "(setq-default mode-line-format nil\n"
                "              header-line-format nil\n"
                "              tab-line-format nil\n"
                "              cursor-type nil)\n\n")
        (pp `(setq default-frame-alist ',frame-alist
                   initial-frame-alist ',frame-alist
                   frame-title-format ,spleen-frame-name
                   icon-title-format ,spleen-frame-name)
            (current-buffer))
        (insert "\n")))
    ;; 2. init.el: loads packages, user actions, and sets initial-buffer-choice
    (with-temp-file init-file
      (let ((print-length nil)
            (print-level nil)
            (print-circle t))
        (insert ";;; init.el --- Standalone launcher init for spleen -*- lexical-binding: t; -*-\n\n"
                "(defvar spleen--saved-fnh nil)\n"
                "(add-hook 'emacs-startup-hook\n"
                "          (lambda ()\n"
                "            (setq gc-cons-threshold (* 16 1024 1024)\n"
                "                  gc-cons-percentage 0.1\n"
                "                  file-name-handler-alist spleen--saved-fnh)))\n\n"
                "(require 'seq)\n\n")
        (pp `(eval-and-compile
               (dolist (pdir ',dirs)
                 (when (file-directory-p pdir)
                   (add-to-list 'load-path pdir))))
            (current-buffer))
        (insert "\n")
        (pp `(defun spleen--apply-exported-faces (&optional frame)
               (with-selected-frame (or frame (selected-frame))
                 (when (display-graphic-p)
                   (dolist (spec ',faces)
                     (apply #'set-face-attribute (car spec) nil (cdr spec))))))
            (current-buffer))
        (insert "\n(add-hook 'after-make-frame-functions #'spleen--apply-exported-faces)\n"
                "(spleen--apply-exported-faces)\n\n")
        (pcase spleen-standalone-completion
          ('vertico
           (insert "(defun spleen--lazy-completion ()\n"
                   "  (remove-hook 'minibuffer-setup-hook #'spleen--lazy-completion)\n"
                   "  (if (and (require 'vertico nil t) (fboundp 'vertico-mode))\n"
                   "      (funcall 'vertico-mode 1)\n"
                   "    (fido-vertical-mode 1))\n"
                   "  (when (require 'orderless nil t)\n"
                   "    (setq completion-styles '(orderless basic)\n"
                   "          completion-category-defaults nil\n"
                   "          completion-category-overrides '((file (styles partial-completion))))))\n"
                   "(add-hook 'minibuffer-setup-hook #'spleen--lazy-completion)\n\n"))
          ('fido
           (insert "(fido-vertical-mode 1)\n\n")))
        (insert "(require 'spleen)\n\n")
        (dolist (v user-vars)
          (pp `(defvar ,(car v) ',(cdr v)) (current-buffer)))
        (when user-vars (insert "\n"))
        (dolist (f user-funs)
          (pp `(defalias ',(car f) ',(cdr f)) (current-buffer)))
        (when user-funs (insert "\n"))
        (pp `(setq spleen-title ,spleen-title
                   spleen-layout ',spleen-layout
                   spleen-show-rules ,spleen-show-rules
                   spleen-show-footer ,spleen-show-footer
                   spleen-quit-key ,spleen-quit-key
                   spleen-quit-label ,spleen-quit-label
                   spleen-column-gap ,spleen-column-gap
                   spleen-terminal-program ,spleen-terminal-program
                   spleen-terminal-args ',spleen-terminal-args
                   spleen-terminal-hold ',spleen-terminal-hold
                   spleen-extra-application-directories ',spleen-extra-application-directories
                   spleen-kill-process-all-users ,spleen-kill-process-all-users
                   spleen-initial-action ',spleen-initial-action
                   spleen-sections ',spleen-sections)
            (current-buffer))
        (insert "\n")
        (dolist (ef extra-files)
          (pp `(load ,ef nil t) (current-buffer))
          (insert "\n"))
        (insert "(setq initial-buffer-choice\n"
                "      (lambda ()\n"
                "        (spleen-show)\n"
                "        (get-buffer spleen-buffer-name)))\n")))
    (byte-compile-file early-file)
    (byte-compile-file init-file)
    (when (called-interactively-p 'any)
      (message "Exported and compiled standalone profile in %s (%d vars, %d functions)"
               dir (length user-vars) (length user-funs)))
    dir))

(provide 'spleen)
;;; spleen.el ends here
