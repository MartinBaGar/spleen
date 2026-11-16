;;; omni-splash.el --- Ephemeral pixel-centered splash launcher -*- lexical-binding: t; -*-

;; Author: Bari Garnier
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, frames, launcher
;; URL: https://github.com/bari-garnier/omni-splash

;;; Commentary:

;; `omni-splash' provides a keyboard-driven, editorial floating splash screen
;; and action hub for Emacs.  It is designed for Wayland/X11 tiling window
;; managers (Niri, Hyprland, Sway) as well as clean startup dashboards.
;;
;; Features:
;; - Zero external dependencies (pure Emacs 29.1+ pixel-metric layout).
;; - Mixed `variable-pitch' headings and `fixed-pitch' key/description columns
;;   aligned to exact pixel widths and recentered dynamically on resize.
;; - Three built-in layouts: `two-column', `single-column', and `banner-only'.
;; - Two dispatch workflows: two-step visual key hub (default) or one-step
;;   immediate prompt (`omni-splash-initial-action').
;; - Unified frame lifecycle across daemon (`emacsclient -c') and standalone
;;   (`emacs -Q -l ...') invocations, including clean `C-g' dismissal.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(defvar server-client-instructions)

;;;; Customization

(defgroup omni-splash nil
  "Ephemeral pixel-centered splash launcher."
  :group 'applications
  :prefix "omni-splash-")

(defcustom omni-splash-title "OMNI SEARCH"
  "Main title displayed in the splash banner.
Set to nil or an empty string to omit the title."
  :type '(choice (string :tag "Title text")
                 (const :tag "No title" nil))
  :group 'omni-splash)

(defcustom omni-splash-show-rules t
  "When non-nil, draw hairline dividers between banner, menu, and footer."
  :type 'boolean
  :group 'omni-splash)

(defcustom omni-splash-show-footer t
  "When non-nil, display the centered quit hint below the menu."
  :type 'boolean
  :group 'omni-splash)

(defcustom omni-splash-quit-key "q"
  "Key sequence bound to close the splash frame."
  :type 'string
  :group 'omni-splash)

(defcustom omni-splash-quit-label "Close"
  "Description shown beside `omni-splash-quit-key' in the footer."
  :type 'string
  :group 'omni-splash)

(defcustom omni-splash-column-gap 5
  "Horizontal gap between columns measured in `fixed-pitch' space widths."
  :type 'natnum
  :group 'omni-splash)

(defcustom omni-splash-layout 'two-column
  "Visual layout of the splash screen.
- `two-column': Centered banner with paired side-by-side action columns.
- `single-column': Centered vertical stack of sections and actions.
- `banner-only': Minimal centered title and divider (pairs well with
  `omni-splash-initial-action')."
  :type '(choice (const :tag "Two-column grid" two-column)
                 (const :tag "Single centered column" single-column)
                 (const :tag "Banner only" banner-only))
  :group 'omni-splash)

(defcustom omni-splash-initial-action nil
  "Optional interactive command to run immediately when `omni-splash-show' opens.
When nil, display the splash screen and wait for a shortcut key.
When non-nil, render the splash buffer first and immediately invoke this
command via `omni-splash-run'."
  :type '(choice (const :tag "Two-step (wait for shortcut key)" nil)
                 (function :tag "One-step (run command immediately)"))
  :group 'omni-splash)

(defcustom omni-splash-quit-function #'omni-splash-default-quit
  "Function called with one argument (FRAME) when closing the splash."
  :type 'function
  :group 'omni-splash)

(defcustom omni-splash-frame-name "omni-splash"
  "Frame name and title assigned to the splash frame for compositor rules."
  :type 'string
  :group 'omni-splash)

(defcustom omni-splash-buffer-name "*omni-splash*"
  "Name of the buffer used to render the splash screen."
  :type 'string
  :group 'omni-splash)

(defcustom omni-splash-sections
  '((("FILES"
      ("f" "Find file"        find-file)
      ("p" "Switch project"   project-switch-project)
      ("r" "Recent files"     recentf-open-files))
     ("WORKSPACE"
      ("b" "Switch buffer"    switch-to-buffer)
      ("s" "Shell (Eshell)"   eshell)
      ("x" "Execute command"  execute-extended-command))))
  "Menu specification displayed by `omni-splash'.
Each element is a row-group of one or two column specs:
  ((LEFT-TITLE (KEY DESC COMMAND) ...)
   (RIGHT-TITLE (KEY DESC COMMAND) ...))
In `single-column' layout, column specs are rendered sequentially."
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
  :group 'omni-splash)

;;;; Faces

(defface omni-splash-title
  '((t :inherit variable-pitch :height 1.55 :weight bold))
  "Face for the main splash banner title."
  :group 'omni-splash)

(defface omni-splash-section
  '((t :inherit (variable-pitch shadow) :height 0.85 :weight bold))
  "Face for section headings above action columns."
  :group 'omni-splash)

(defface omni-splash-key
  '((t :inherit (fixed-pitch font-lock-keyword-face) :weight bold))
  "Theme-adaptive accent face for shortcut keys."
  :group 'omni-splash)

(defface omni-splash-description
  '((t :inherit (fixed-pitch shadow)))
  "Softer face for shortcut descriptions."
  :group 'omni-splash)

(defface omni-splash-rule
  '((t :inherit shadow :height 0.75))
  "Face for hairline dividers."
  :group 'omni-splash)

;;;; Internal State

(defvar-local omni-splash--top-pad-overlay nil
  "Overlay at `point-min' used to vertically center splash content.")

(defvar-local omni-splash--block-px nil
  "Pixel width of the rendered menu block, used to size hairline rules.")

;;;; Frame Lifecycle & Command Dispatch

(defun omni-splash-default-quit (&optional frame)
  "Close splash FRAME safely across daemon, multi-frame, and standalone runs."
  (let ((target (or frame (selected-frame))))
    (when (frame-live-p target)
      (if (or (daemonp) (> (length (frame-list)) 1))
          (delete-frame target)
        (kill-emacs)))))

(defun omni-splash-close (&optional frame)
  "Close FRAME (or selected frame) using `omni-splash-quit-function'."
  (interactive)
  (funcall omni-splash-quit-function (or frame (selected-frame))))

;;;###autoload
(defun omni-splash-run (command &optional keep-frame)
  "Call interactive COMMAND inside the splash frame.
Unless KEEP-FRAME is non-nil, close the splash frame once COMMAND
completes or is aborted with `quit' (\\[keyboard-quit])."
  (let ((frame (selected-frame))
        (completed nil))
    (unwind-protect
        (condition-case nil
            (progn
              (call-interactively command)
              (setq completed t))
          (quit nil))
      (when (and (not keep-frame)
                 (frame-live-p frame)
                 (or completed t))
        (omni-splash-close frame)))))

(defun omni-splash--wrap-command (command)
  "Return an interactive wrapper invoking COMMAND via `omni-splash-run'."
  (lambda ()
    (interactive)
    (omni-splash-run command)))

(defun omni-splash--build-keymap ()
  "Construct a keymap from `omni-splash-sections' and `omni-splash-quit-key'."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (dolist (pair omni-splash-sections)
      (dolist (col pair)
        (dolist (item (cdr col))
          (pcase-let ((`(,key ,_desc ,cmd) item))
            (when (and (stringp key) (not (string-empty-p key)) (functionp cmd))
              (define-key map (kbd key) (omni-splash--wrap-command cmd)))))))
    (when (and (stringp omni-splash-quit-key)
               (not (string-empty-p omni-splash-quit-key)))
      (define-key map (kbd omni-splash-quit-key) #'omni-splash-close))
    map))

;;;; Pixel Measurement & Centering Engine

(defun omni-splash--pixel-width (str)
  "Return rendered pixel width of propertized string STR."
  (if (and (display-graphic-p) (fboundp 'string-pixel-width))
      (string-pixel-width str)
    (* (string-width str) (frame-char-width))))

(defun omni-splash--centered-prefix (pixel-width)
  "Return display space aligning following text to center minus PIXEL-WIDTH/2."
  (if (display-graphic-p)
      (let ((half-px (max 0 (/ pixel-width 2))))
        (propertize " " 'display `(space :align-to (- center (,half-px)))))
    (let ((half-cols (max 0 (/ pixel-width 2))))
      (propertize " " 'display `(space :align-to (- center ,half-cols))))))

(defun omni-splash--insert-centered (styled-text &optional no-newline)
  "Insert STYLED-TEXT horizontally centered in the current window.
When NO-NEWLINE is non-nil, omit the trailing newline."
  (let* ((width-px (omni-splash--pixel-width styled-text))
         (prefix (omni-splash--centered-prefix width-px)))
    (insert (propertize styled-text 'line-prefix prefix))
    (unless no-newline
      (insert "\n"))))

(defun omni-splash--insert-rule (width-px)
  "Insert a centered hairline divider matching WIDTH-PX."
  (let* ((glyph (propertize "─" 'face 'omni-splash-rule))
         (glyph-px (max 1 (omni-splash--pixel-width glyph)))
         (count (max 1 (/ width-px glyph-px)))
         (rule (propertize (make-string count ?─) 'face 'omni-splash-rule)))
    (omni-splash--insert-centered rule)))

(defun omni-splash--recenter-window (&optional window-or-frame)
  "Vertically center the splash buffer inside WINDOW-OR-FRAME."
  (let* ((window (cond
                  ((windowp window-or-frame) window-or-frame)
                  ((framep window-or-frame) (frame-selected-window window-or-frame))
                  (t (selected-window))))
         (buffer (and (window-live-p window) (window-buffer window))))
    (when (and buffer (buffer-local-value 'omni-splash--top-pad-overlay buffer))
      (with-current-buffer buffer
        (when (overlayp omni-splash--top-pad-overlay)
          (overlay-put omni-splash--top-pad-overlay 'before-string "")
          (let* ((body-px (window-body-height window t))
                 (content-px (cdr (window-text-pixel-size window (point-min) (point-max))))
                 (pad-px (max 0 (/ (- body-px content-px) 2))))
            (overlay-put
             omni-splash--top-pad-overlay
             'before-string
             (if (> pad-px 0)
                 (concat (propertize " " 'display `(space :width 0 :height (,pad-px)))
                         (propertize "\n" 'line-height t))
               ""))))))))

;;;; Widgets & Layout Renderers

(defun omni-splash--format-title (title)
  "Propertize section TITLE."
  (propertize title 'face 'omni-splash-section))

(defun omni-splash--format-item (item)
  "Propertize menu ITEM (KEY DESC COMMAND)."
  (pcase-let ((`(,key ,desc ,_cmd) item))
    (concat (propertize key 'face 'omni-splash-key)
            (propertize "  " 'face 'fixed-pitch)
            (propertize desc 'face 'omni-splash-description))))

(defun omni-splash--render-two-column ()
  "Render `omni-splash-sections' as a pixel-aligned two-column block."
  (let* ((rendered
          (mapcar
           (lambda (pair)
             (pcase-let ((`((,l-title . ,l-items) (,r-title . ,r-items)) pair))
               (list (omni-splash--format-title l-title)
                     (mapcar #'omni-splash--format-item l-items)
                     (and r-title (omni-splash--format-title r-title))
                     (mapcar #'omni-splash--format-item r-items))))
           omni-splash-sections))
         (col1-px 0)
         (col2-px 0)
         (gap-str (make-string (max 1 omni-splash-column-gap) ?\s))
         (gap-px (omni-splash--pixel-width (propertize gap-str 'face 'fixed-pitch))))
    (dolist (sec rendered)
      (pcase-let ((`(,l-head ,l-rows ,r-head ,r-rows) sec))
        (setq col1-px (apply #'max col1-px (omni-splash--pixel-width l-head)
                             (mapcar #'omni-splash--pixel-width l-rows)))
        (when r-head
          (setq col2-px (apply #'max col2-px (omni-splash--pixel-width r-head)
                               (mapcar #'omni-splash--pixel-width r-rows))))))
    (let* ((block-px (if (> col2-px 0) (+ col1-px gap-px col2-px) col1-px))
           (row-prefix (omni-splash--centered-prefix block-px)))
      (setq omni-splash--block-px block-px)
      (cl-flet ((insert-row (left right)
                  (let* ((left-px (omni-splash--pixel-width left))
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

(defun omni-splash--render-single-column ()
  "Render `omni-splash-sections' as a single centered column."
  (let ((columns (apply #'append omni-splash-sections))
        (max-px 0))
    (dolist (col columns)
      (pcase-let ((`(,title . ,items) col))
        (setq max-px (apply #'max max-px
                            (omni-splash--pixel-width (omni-splash--format-title title))
                            (mapcar (lambda (it)
                                      (omni-splash--pixel-width (omni-splash--format-item it)))
                                    items)))))
    (setq omni-splash--block-px max-px)
    (let ((row-prefix (omni-splash--centered-prefix max-px))
          (remaining columns))
      (while remaining
        (pcase-let ((`((,title . ,items) . ,rest) remaining))
          (insert (propertize (omni-splash--format-title title) 'line-prefix row-prefix) "\n")
          (dolist (it items)
            (insert (propertize (omni-splash--format-item it) 'line-prefix row-prefix) "\n"))
          (when rest
            (insert "\n"))
          (setq remaining rest))))))

(defun omni-splash--insert-banner (has-body)
  "Insert the centered title banner and optional top divider.
HAS-BODY indicates whether menu items or a footer follow."
  (when (and (stringp omni-splash-title) (not (string-empty-p omni-splash-title)))
    (omni-splash--insert-centered
     (propertize omni-splash-title 'face 'omni-splash-title)
     (not (or has-body omni-splash-show-rules)))
    (when (or has-body omni-splash-show-rules)
      (insert "\n")))
  (when (and omni-splash-show-rules omni-splash--block-px (> omni-splash--block-px 0))
    (omni-splash--insert-rule omni-splash--block-px)
    (when has-body
      (insert "\n"))))

(defun omni-splash--insert-footer ()
  "Insert the optional divider and centered quit hint."
  (when omni-splash-show-footer
    (insert "\n")
    (when (and omni-splash-show-rules omni-splash--block-px (> omni-splash--block-px 0))
      (omni-splash--insert-rule omni-splash--block-px)
      (insert "\n"))
    (omni-splash--insert-centered
     (concat (propertize omni-splash-quit-key 'face 'omni-splash-key)
             (propertize "  " 'face 'fixed-pitch)
             (propertize omni-splash-quit-label 'face 'omni-splash-description))
     t)))

;;;; Major Mode & Entry Point

(define-derived-mode omni-splash-mode special-mode "Omni-Splash"
  "Major mode for the keyboard-driven Omni splash launcher."
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
  (add-hook 'window-size-change-functions #'omni-splash--recenter-window nil t))

;;;###autoload
(defun omni-splash-show ()
  "Render and display the full-frame Omni splash screen.
If `omni-splash-initial-action' is non-nil, invoke it immediately after
rendering the splash frame."
  (interactive)
  (let ((buffer (get-buffer-create omni-splash-buffer-name))
        (frame (selected-frame))
        (show-menu (not (eq omni-splash-layout 'banner-only))))
    (with-current-buffer buffer
      (when (overlayp omni-splash--top-pad-overlay)
        (delete-overlay omni-splash--top-pad-overlay)
        (setq omni-splash--top-pad-overlay nil))
      (omni-splash-mode)
      (use-local-map (omni-splash--build-keymap))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (remove-overlays (point-min) (point-max))
        (let* ((menu-data
                (when show-menu
                  (with-temp-buffer
                    (pcase omni-splash-layout
                      ('single-column (omni-splash--render-single-column))
                      (_ (omni-splash--render-two-column)))
                    (cons omni-splash--block-px (buffer-string)))))
               (title-px (if (and (stringp omni-splash-title)
                                  (not (string-empty-p omni-splash-title)))
                             (omni-splash--pixel-width
                              (propertize omni-splash-title 'face 'omni-splash-title))
                           240)))
          (setq omni-splash--block-px (or (car menu-data) title-px))
          (omni-splash--insert-banner (or show-menu omni-splash-show-footer))
          (when menu-data
            (insert (cdr menu-data)))
          (omni-splash--insert-footer)))
      (goto-char (point-min))
      (setq omni-splash--top-pad-overlay (make-overlay (point-min) (point-min) buffer t nil)))
    (switch-to-buffer buffer)
    (delete-other-windows)
    (let ((window (or (get-buffer-window buffer frame) (selected-window))))
      (set-window-fringes window 0 0)
      (set-window-margins window 0 0)
      (set-window-scroll-bars window 0 nil 0 nil)
      (modify-frame-parameters frame `((name . ,omni-splash-frame-name)
                                       (title . ,omni-splash-frame-name)
                                       (cursor-type . nil)))
      (omni-splash--recenter-window window))
    (setq server-client-instructions nil)
    (when (functionp omni-splash-initial-action)
      (run-at-time 0 nil #'omni-splash-run omni-splash-initial-action))))

(provide 'omni-splash)
;;; omni-splash.el ends here
