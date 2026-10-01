;;; canvas-diagram-reader.el --- Readers of diagram languages, and the layouts they draw with -*- lexical-binding: t -*-

;; Copyright (C) 2026 canvas-diagram contributors

;; Author: Daskeladden
;; Version: 0.1.0
;; Keywords: multimedia, tools, convenience
;; URL: https://github.com/Daskeladden/canvas-diagram

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A reader turns the text of a diagram language, such as mermaid or
;; PlantUML, into the spec of a layout, such as the graph of
;; canvas-graph or the tree of canvas-mindmap.  Each layout defines
;; itself here by the kind of spec it draws.  A reader says which
;; regions of a buffer hold its diagrams and how to read one.  This
;; file does the rest the same way for every language: it finds the
;; diagram at point, draws it with the layout of its kind, follows it
;; as it is edited, and exports it to a picture.

;;; Code:

(require 'cl-lib)
(require 'canvas-diagram)

;;;; Layouts

(defvar canvas-diagram-layouts nil
  "The layouts that readers draw with, as ((KIND . PLIST)...).
KIND is the kind of spec a layout draws, such as `graph'.  PLIST has
:follow, a function of a source buffer, a function that reads a spec
from that buffer, and the name of the buffer to draw in; and :export, a
function of a spec and the name of a picture file.  A layout defines
itself with `canvas-diagram-define-layout'.")

(defun canvas-diagram--check-layout-function (kind key function)
  "Signal unless FUNCTION, the KEY of the layout of KIND, is a named function."
  (unless (and function (symbolp function) (fboundp function))
    (error "canvas-diagram: the layout of %s needs %s, a named function, not %S"
           kind key function)))

(defun canvas-diagram-define-layout (kind &rest props)
  "Define the layout that draws specs of KIND, a symbol, and return KIND.
PROPS are :follow and :export, as `canvas-diagram-layouts' describes.
Name each function, so that a function defined again takes effect."
  (dolist (key '(:follow :export))
    (canvas-diagram--check-layout-function kind key (plist-get props key)))
  (setf (alist-get kind canvas-diagram-layouts)
        (list :follow (plist-get props :follow) :export (plist-get props :export)))
  kind)

(defun canvas-diagram--layout-function (kind key)
  "The function KEY of the layout of KIND.  No such layout is an error."
  (or (plist-get (alist-get kind canvas-diagram-layouts) key)
      (error "canvas-diagram: no layout draws a %s; load the package that gives it" kind)))

;;;; Readers

(cl-defstruct (canvas-diagram-reader (:constructor canvas-diagram-reader-create)
                                     (:copier nil))
  "The reader of a diagram language."
  (package nil :read-only t
           :documentation "The package of the reader, such as \"canvas-mermaid\".
It begins the reader's messages and names the buffer it draws in.")
  (language nil :read-only t
            :documentation "The name of the language in messages, such as \"PlantUML\".")
  (regions nil :read-only t
           :documentation "A function of no arguments that returns the diagrams
of the current buffer, as ((START . END)...).")
  (read nil :read-only t
        :documentation "A function of the text of a diagram and the buffer
position it begins at, that returns (KIND . SPEC)."))

(defun canvas-diagram-reader--drawing-buffer (reader)
  "The name of the buffer that READER draws in."
  (format "*%s*" (canvas-diagram-reader-package reader)))

(defun canvas-diagram-reader--regions-or-error (reader &optional name)
  "The diagrams of READER's language in the current buffer.
None is a user error that names the buffer, or NAME."
  (or (funcall (canvas-diagram-reader-regions reader))
      (user-error "%s: no %s diagram in %s" (canvas-diagram-reader-package reader)
                  (canvas-diagram-reader-language reader) (or name (buffer-name)))))

(defun canvas-diagram-reader-read-region (reader region)
  "The diagram in REGION, (START . END) of the current buffer, as (KIND . SPEC).
READER reads it with its nodes placed in the buffer."
  (funcall (canvas-diagram-reader-read reader)
           (buffer-substring-no-properties (car region) (cdr region)) (car region)))

(defun canvas-diagram-reader--spec-of (reader region kind)
  "The spec of the diagram in REGION of the current buffer, of KIND.
A diagram of another kind is a user error."
  (pcase-let ((`(,found . ,spec) (canvas-diagram-reader-read-region reader region)))
    (unless (eq found kind)
      (user-error "%s: the diagram is a %s now; draw it again to see it"
                  (canvas-diagram-reader-package reader) found))
    spec))

(defun canvas-diagram-reader-follower (reader marker kind)
  "A function of a buffer that reads the diagram at MARKER as a spec of KIND.
READER reads it.  See `canvas-diagram-region-reader' for when it reads nil."
  (canvas-diagram-region-reader marker (canvas-diagram-reader-regions reader)
                                (lambda (region) (canvas-diagram-reader--spec-of reader region kind))))

;;;; Showing and exporting

(defun canvas-diagram-reader--show-region (reader region)
  "Draw the diagram in REGION of the current buffer, and follow it.
READER reads it, and the layout of its kind draws it."
  (let ((kind (car (canvas-diagram-reader-read-region reader region))))
    (funcall (canvas-diagram--layout-function kind :follow)
             (current-buffer)
             (canvas-diagram-reader-follower reader (copy-marker (car region)) kind)
             (canvas-diagram-reader--drawing-buffer reader))))

(defun canvas-diagram-reader-show (reader)
  "Draw the diagram of READER's language that point is in, and follow it.
With a single diagram in the buffer, point may be anywhere."
  (canvas-diagram-reader--show-region
   reader (canvas-diagram-region-at (canvas-diagram-reader--regions-or-error reader) (point))))

(defun canvas-diagram-reader-show-file (reader file)
  "Draw the first diagram of READER's language in FILE.
The drawing follows the buffer that visits FILE."
  (with-current-buffer (find-file-noselect file)
    (canvas-diagram-reader--show-region reader (car (canvas-diagram-reader--regions-or-error reader)))))

(defun canvas-diagram-reader-export (reader file out)
  "Draw the first diagram of READER's language in FILE into OUT, and return OUT.
OUT is a PNG, an SVG or a PDF, by its name.  No buffer visits FILE, and
no frame is needed, so this works in batch."
  (pcase-let ((`(,kind . ,spec)
               (with-temp-buffer
                 (insert-file-contents file)
                 (canvas-diagram-reader-read-region
                  reader (car (canvas-diagram-reader--regions-or-error
                               reader (file-name-nondirectory file)))))))
    (funcall (canvas-diagram--layout-function kind :export) spec out)
    out))

(defun canvas-diagram-reader-demo (reader text mode)
  "Show TEXT, a diagram of READER's language, in a buffer to edit and watch.
The buffer turns on MODE when that is defined."
  (with-current-buffer (get-buffer-create (format "*%s demo*" (canvas-diagram-reader-package reader)))
    (erase-buffer)
    (insert text)
    (when (fboundp mode)
      (funcall mode))
    (goto-char (point-min))
    (switch-to-buffer (current-buffer))
    (canvas-diagram-reader-show reader)))

(provide 'canvas-diagram-reader)
;;; canvas-diagram-reader.el ends here
