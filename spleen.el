;;; spleen.el --- Ephemeral keyboard-driven splash launcher -*- lexical-binding: t; -*-

;; Author: Bari Garnier
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, frames
;; URL: https://github.com/bari-garnier/spleen

;;; Commentary:

;; Spleen is a keyboard-driven splash screen and ephemeral action hub.
;;
;; This file contains the screen, layout engine, command dispatch and
;; extension helpers.  Default actions live in spleen-actions.el and the
;; optional standalone exporter lives in spleen-standalone.el.  Keep all
;; three files in the same directory on `load-path'.
;;
;; Default bindings:
;;   a  Launch app
;;   r  Run command
;;   t  Run in terminal
;;   k  Kill process
;;
;; Extend the menu with `spleen-add-section'.  The action and exporter
;; entry points are explicitly autoloaded below so loading this file
;; directly also works without generated package autoloads.

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

;;;; Companion Module Entry Points

(autoload 'spleen-launch-app "spleen-actions"
  "Launch an installed application, chosen interactively." t)
(autoload 'spleen-run-command "spleen-actions"
  "Run a shell command detached from Emacs." t)
(autoload 'spleen-run-in-terminal "spleen-actions"
  "Run a shell command in a new terminal window." t)
(autoload 'spleen-kill-process "spleen-actions"
  "Choose a process and send it SIGTERM, or SIGKILL with a prefix." t)
(autoload 'spleen-export-standalone "spleen-standalone"
  "Generate and byte-compile a standalone Spleen profile." t)

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

;;;; Shared External Process Helper

(defun spleen-spawn (program &rest args)
  "Start PROGRAM with ARGS asynchronously, discarding its output.
Use `setsid --fork' when available to start the child in its own session.
This is the public spawning helper for actions and recipes."
  (let ((exe (or (executable-find program)
                 (user-error "Command not found: %s" program)))
        (setsid (executable-find "setsid"))
        (default-directory (expand-file-name "~/")))
    (if setsid
        (apply #'call-process setsid nil 0 nil "--fork" exe args)
      (apply #'call-process exe nil 0 nil args))
    nil))

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

(provide 'spleen)
;;; spleen.el ends here
