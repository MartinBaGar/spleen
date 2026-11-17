;;; spleen-standalone.el --- Standalone profile exporter for Spleen -*- lexical-binding: t; -*-

;; Author: Bari Garnier
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, frames

;;; Commentary:

;; Export Spleen settings, faces, and user actions into an independent
;; Emacs initialization directory.  This profile still loads the Spleen
;; libraries from their original location; it is not a portable bundle.
;;
;; Load this module explicitly when exporting:
;;   (require 'spleen-standalone)
;;   (spleen-export-standalone "/tmp/spleen-default/")
;;
;; Launch the generated profile without -Q, which would skip its init:
;;   emacs --init-directory /tmp/spleen-default/

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'spleen)
(require 'spleen-actions)

;;;; Customization

(defcustom spleen-standalone-directory
  (expand-file-name "var/spleen-standalone/" user-emacs-directory)
  "Directory where the exporter writes early-init.el and init.el."
  :type 'directory
  :group 'spleen)

(defcustom spleen-standalone-packages nil
  "Library symbols whose load-path directories should be exported.
Dependency discovery is best-effort and depends on available package metadata."
  :type '(repeat symbol)
  :group 'spleen)

(defcustom spleen-standalone-symbols nil
  "Extra user function symbols to inspect when exporting.
Bound variables referenced by exported functions are also considered."
  :type '(repeat symbol)
  :group 'spleen)

(defcustom spleen-standalone-files nil
  "Extra Elisp files loaded at the end of the standalone boot file."
  :type '(repeat file)
  :group 'spleen)

(defcustom spleen-standalone-completion 'vertico
  "Completion UI configured in the standalone profile.
Vertico falls back to Fido when unavailable."
  :type '(choice (const :tag "Vertico + Orderless (Fido fallback)" vertico)
                 (const :tag "Fido vertical" fido)
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
  "Additional frame parameters written into the standalone profile."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'spleen)

;;;; Dependency discovery

(defun spleen--builtin-dir-p (dir)
  "Return non-nil if DIR belongs to Emacs Lisp or data directories."
  (let ((norm (expand-file-name dir))
        (roots (delq nil (list (and (boundp 'lisp-directory) lisp-directory)
                               data-directory))))
    (cl-some
     (lambda (root)
       (string-prefix-p (file-name-as-directory (expand-file-name root))
                        (file-name-as-directory norm)))
     roots)))

(defun spleen--collect-package-dirs (packages)
  "Resolve library directories for PACKAGES and discoverable dependencies."
  (require 'package)
  (let ((queue (copy-sequence
                (append '(spleen spleen-actions) packages)))
        (seen (make-hash-table :test 'eq))
        dirs)
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
            ;; Avoid relying on package.el private dependency functions.
            (let ((descriptor (car (alist-get pkg package-alist))))
              (when descriptor
                (dolist (dependency (package-desc-reqs descriptor))
                  (let ((name (car dependency)))
                    (unless (gethash name seen)
                      (push name queue))))))))))
    (nreverse dirs)))

;;;; User definitions

(defun spleen--user-symbol-p (sym type exported-dirs)
  "Return non-nil if SYM of TYPE comes from outside exported libraries."
  (let ((file (symbol-file sym type)))
    (cond
     ((null file) t)
     ((spleen--builtin-dir-p (file-name-directory file)) nil)
     ((cl-some
       (lambda (dir)
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

(defun spleen--scan-symbols (obj acc &optional visited)
  "Collect symbols inside OBJ into ACC.
VISITED avoids revisiting shared or circular conses and vectors."
  (let ((seen (or visited (make-hash-table :test 'eq))))
    (cond
     ((symbolp obj) (puthash obj t acc))
     ((or (consp obj) (vectorp obj) (byte-code-function-p obj))
      (unless (gethash obj seen)
        (puthash obj t seen)
        (if (consp obj)
            (progn
              (spleen--scan-symbols (car obj) acc seen)
              (spleen--scan-symbols (cdr obj) acc seen))
          (dotimes (i (length obj))
            (spleen--scan-symbols (aref obj i) acc seen))))))))

(defun spleen--collect-user-definitions (exported-dirs)
  "Collect (VARS . FUNS) referenced by user-defined splash actions.
This is best-effort inspection, not a general closure serialization system."
  (let ((queue (copy-sequence spleen-standalone-symbols))
        (seen-funs (make-hash-table :test 'eq))
        (seen-vars (make-hash-table :test 'eq))
        funs vars)
    (when (symbolp spleen-initial-action)
      (push spleen-initial-action queue))
    (dolist (pair spleen-sections)
      (dolist (col pair)
        (dolist (item (cdr col))
          (let ((cmd (nth 2 item)))
            (when (symbolp cmd) (push cmd queue))))))
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
              (unless (spleen--printable-p fn)
                (user-error "Cannot export function %s; use spleen-standalone-files" sym))
              (push (cons sym fn) funs)
              (let ((refs (make-hash-table :test 'eq)))
                (spleen--scan-symbols fn refs)
                (maphash
                 (lambda (ref _value)
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

;;;; Face snapshot

(defun spleen--snapshot-faces ()
  "Capture current frame typography and colors as face specifications."
  (let ((valid-color
         (lambda (color)
           (and (stringp color)
                (not (string-prefix-p "unspecified" color))))))
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

;;;; Export

;;;###autoload
(defun spleen-export-standalone (&optional directory)
  "Generate and byte-compile a standalone profile in DIRECTORY.
Defaults to `spleen-standalone-directory'.  Export from a graphical
frame for a meaningful font and color snapshot.  Existing generated
initialization files in DIRECTORY are overwritten."
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
    (with-temp-file early-file
      (let ((print-length nil)
            (print-level nil))
        (insert ";;; early-init.el --- Generated Spleen setup -*- lexical-binding: t; -*-\n\n"
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
            (current-buffer))))
    (with-temp-file init-file
      (let ((print-length nil)
            (print-level nil)
            (print-circle t))
        (insert ";;; init.el --- Generated Spleen profile -*- lexical-binding: t; -*-\n\n"
                "(defvar spleen--saved-fnh nil)\n"
                "(add-hook 'emacs-startup-hook\n"
                "          (lambda ()\n"
                "            (setq gc-cons-threshold (* 16 1024 1024)\n"
                "                  gc-cons-percentage 0.1\n"
                "                  file-name-handler-alist spleen--saved-fnh)))\n\n")
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
          ('fido (insert "(fido-vertical-mode 1)\n\n")))
        (insert "(require 'spleen)\n(require 'spleen-actions)\n\n")
        (dolist (v user-vars)
          (pp `(defvar ,(car v) ',(cdr v)) (current-buffer)))
        (dolist (f user-funs)
          (pp `(defalias ',(car f) ',(cdr f)) (current-buffer)))
        (insert "\n")
        (pp `(setq spleen-title ,spleen-title
                   spleen-frame-name ,spleen-frame-name
                   spleen-buffer-name ,spleen-buffer-name
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
        (dolist (file extra-files)
          (pp `(load ,file nil t) (current-buffer)))
        (insert "\n(setq initial-buffer-choice\n"
                "      (lambda ()\n"
                "        (spleen-show)\n"
                "        (get-buffer spleen-buffer-name)))\n")))
    ;; Remove old bytecode so a failed compilation cannot leave a stale profile.
    (dolist (file (list early-file init-file))
      (let ((compiled (concat file "c")))
        (when (file-exists-p compiled)
          (delete-file compiled)))
      (unless (byte-compile-file file)
        (error "Standalone compilation failed: %s" file)))
    (when (called-interactively-p 'any)
      (message "Exported standalone profile to %s (%d vars, %d functions)"
               dir (length user-vars) (length user-funs)))
    dir))

(provide 'spleen-standalone)
;;; spleen-standalone.el ends here
