;;; canvas-diagram-reader-tests.el --- tests -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'canvas-diagram-reader)

;;;; A toy language and two layouts that note what they get

(defvar canvas-diagram-reader-test--drawn nil
  "What the test layouts were asked to do, newest first.")

(defun canvas-diagram-reader-test--boxes-follow (buffer read name)
  "Note that the boxes layout follows BUFFER through READ, in NAME."
  (push (list 'boxes buffer (funcall read buffer) name) canvas-diagram-reader-test--drawn))

(defun canvas-diagram-reader-test--tree-follow (buffer read name)
  "Note that the tree layout follows BUFFER through READ, in NAME."
  (push (list 'tree buffer (funcall read buffer) name) canvas-diagram-reader-test--drawn))

(defun canvas-diagram-reader-test--boxes-export (spec file)
  "Note that the boxes layout exports SPEC to FILE."
  (push (list 'boxes-export spec file) canvas-diagram-reader-test--drawn)
  'what-the-layout-returns)

(defun canvas-diagram-reader-test--tree-export (spec file)
  "Note that the tree layout exports SPEC to FILE."
  (push (list 'tree-export spec file) canvas-diagram-reader-test--drawn))

(defun canvas-diagram-reader-test--read (text offset)
  "TEXT, a toy diagram at OFFSET: its first word is its kind, the other
words its spec.  The word broken makes it an error."
  (let ((words (split-string text)))
    (when (member "broken" words)
      (error "canvas-toy: the diagram is broken"))
    (cons (intern (car words)) (cdr words))))

(defun canvas-diagram-reader-test--regions ()
  "The toy blocks of the current buffer."
  (canvas-diagram-code-blocks '("toy")))

(defconst canvas-diagram-reader-test--reader
  (canvas-diagram-reader-create :package "canvas-toy" :language "toy"
                                :regions #'canvas-diagram-reader-test--regions
                                :read #'canvas-diagram-reader-test--read)
  "The reader of the toy language.")

(defconst canvas-diagram-reader-test--two
  "# Two\n\n```toy\nboxes a b\n```\n\n```toy\ntree root leaf\n```\n"
  "A markdown text with a boxes diagram and a tree diagram.")

(defmacro canvas-diagram-reader-test--with-layouts (&rest body)
  "Run BODY with only the two test layouts, and nothing noted yet."
  (declare (indent 0))
  `(let ((canvas-diagram-layouts nil)
         (canvas-diagram-reader-test--drawn nil))
     (canvas-diagram-define-layout 'boxes
                                   :follow #'canvas-diagram-reader-test--boxes-follow
                                   :export #'canvas-diagram-reader-test--boxes-export)
     (canvas-diagram-define-layout 'tree
                                   :follow #'canvas-diagram-reader-test--tree-follow
                                   :export #'canvas-diagram-reader-test--tree-export)
     ,@body))

;;;; Layouts

(ert-deftest canvas-diagram-a-layout-is-found-by-its-kind ()
  ;; GIVEN a layout defined for a kind, then defined again
  ;; WHEN the layouts are listed
  ;; THEN the kind has one layout, the one defined last
  (let ((canvas-diagram-layouts nil))
    (canvas-diagram-define-layout 'boxes :follow #'ignore :export #'ignore)
    (canvas-diagram-define-layout 'boxes :follow #'identity :export #'ignore)
    (should (equal canvas-diagram-layouts '((boxes :follow identity :export ignore))))))

(ert-deftest canvas-diagram-a-layout-names-its-functions ()
  ;; GIVEN a layout whose functions are given as lambdas, or not at all
  ;; WHEN it is defined
  ;; THEN that is an error, because a layout names its functions, so that
  ;;      a function defined again takes effect
  (let ((canvas-diagram-layouts nil))
    (should-error (canvas-diagram-define-layout 'boxes :follow (lambda (&rest _)) :export #'ignore))
    (should-error (canvas-diagram-define-layout 'boxes :follow #'ignore))
    (should-error (canvas-diagram-define-layout 'boxes :follow #'ignore :export 'canvas-no-such-function))
    (should-not canvas-diagram-layouts)))

;;;; Showing

(ert-deftest canvas-diagram-reader-draws-with-the-layout-of-its-kind ()
  ;; GIVEN a markdown buffer with a boxes diagram and a tree diagram
  ;; WHEN the diagram point is in is shown, first in the boxes, then in
  ;;      the tree
  ;; THEN each goes to the layout of its kind, which follows this buffer
  ;;      with a reader of its block, AND draws in the buffer named after
  ;;      the package
  (canvas-diagram-reader-test--with-layouts
    (with-temp-buffer
      (insert canvas-diagram-reader-test--two)
      (goto-char (point-min))
      (search-forward "boxes a")
      (canvas-diagram-reader-show canvas-diagram-reader-test--reader)
      (search-forward "root")
      (canvas-diagram-reader-show canvas-diagram-reader-test--reader)
      (should (equal canvas-diagram-reader-test--drawn
                     (list (list 'tree (current-buffer) '("root" "leaf") "*canvas-toy*")
                           (list 'boxes (current-buffer) '("a" "b") "*canvas-toy*")))))))

(ert-deftest canvas-diagram-reader-says-when-there-is-nothing-to-draw ()
  ;; GIVEN a buffer without a toy diagram
  ;; WHEN its diagram is shown
  ;; THEN that is a user error that names the language and the buffer
  (canvas-diagram-reader-test--with-layouts
    (with-temp-buffer
      (rename-buffer "notes" t)
      (insert "Nothing to draw.\n")
      (let ((err (should-error (canvas-diagram-reader-show canvas-diagram-reader-test--reader)
                               :type 'user-error)))
        (should (equal (cadr err) (format "canvas-toy: no toy diagram in %s" (buffer-name)))))
      (should-not canvas-diagram-reader-test--drawn))))

(ert-deftest canvas-diagram-reader-wants-a-layout-for-each-kind ()
  ;; GIVEN a diagram of a kind that no layout draws
  ;; WHEN it is shown
  ;; THEN that is an error that names the kind
  (canvas-diagram-reader-test--with-layouts
    (with-temp-buffer
      (insert "```toy\npie a b\n```\n")
      (let ((err (should-error (canvas-diagram-reader-show canvas-diagram-reader-test--reader))))
        (should (string-match-p "no layout draws a pie" (cadr err)))))))

(ert-deftest canvas-diagram-reader-follows-its-diagram-as-it-is-edited ()
  ;; GIVEN the reader that follows the boxes diagram of a buffer
  (with-temp-buffer
    (insert canvas-diagram-reader-test--two)
    (let* ((region (car (canvas-diagram-reader-test--regions)))
           (read (canvas-diagram-reader-follower canvas-diagram-reader-test--reader
                                                 (copy-marker (car region)) 'boxes)))
      ;; WHEN text is added above the diagram, then a word inside it
      (goto-char (point-min))
      (insert "Words above.\n")
      (search-forward "boxes a b")
      (insert " c")
      ;; THEN the reader reads the diagram where it is now, with the word
      (should (equal (funcall read (current-buffer)) '("a" "b" "c")))
      ;; WHEN the diagram is broken
      (insert " broken")
      ;; THEN it reads nothing AND says why, so the last drawing stays
      (let ((said nil))
        (cl-letf (((symbol-function 'message) (lambda (&rest args) (setq said (apply #'format args)))))
          (should-not (funcall read (current-buffer)))
          (should (string-match-p "broken" said))))
      ;; WHEN the diagram becomes a tree
      (delete-region (line-beginning-position) (line-end-position))
      (insert "tree a b")
      ;; THEN it reads nothing AND says that it is a tree now
      (let ((said nil))
        (cl-letf (((symbol-function 'message) (lambda (&rest args) (setq said (apply #'format args)))))
          (should-not (funcall read (current-buffer)))
          (should (equal said "canvas-toy: the diagram is a tree now; draw it again to see it"))))
      ;; WHEN the diagram is gone
      (erase-buffer)
      ;; THEN it reads nothing
      (should-not (funcall read (current-buffer))))))

(ert-deftest canvas-diagram-reader-shows-the-first-diagram-of-a-file ()
  ;; GIVEN a markdown file with a boxes diagram and a tree diagram
  ;; WHEN the file's diagram is shown
  ;; THEN the boxes layout follows the buffer visiting the file
  (canvas-diagram-reader-test--with-layouts
    (let* ((file (make-temp-file "canvas-diagram-reader-test" nil ".md" canvas-diagram-reader-test--two))
           (buffer nil))
      (unwind-protect
          (progn
            (canvas-diagram-reader-show-file canvas-diagram-reader-test--reader file)
            (setq buffer (find-buffer-visiting file))
            (should (equal canvas-diagram-reader-test--drawn
                           (list (list 'boxes buffer '("a" "b") "*canvas-toy*")))))
        (when buffer (kill-buffer buffer))
        (delete-file file)))))

;;;; Exporting

(ert-deftest canvas-diagram-reader-exports-the-first-diagram-of-a-file ()
  ;; GIVEN a markdown file with a boxes diagram and a tree diagram
  ;; WHEN it is exported to a picture
  ;; THEN the boxes layout writes the boxes spec to the picture, the export
  ;;      returns the picture's name, AND no buffer visits the file
  (canvas-diagram-reader-test--with-layouts
    (let ((file (make-temp-file "canvas-diagram-reader-test" nil ".md" canvas-diagram-reader-test--two)))
      (unwind-protect
          (progn
            (should (equal (canvas-diagram-reader-export canvas-diagram-reader-test--reader file "out.png")
                           "out.png"))
            (should (equal canvas-diagram-reader-test--drawn '((boxes-export ("a" "b") "out.png"))))
            (should-not (find-buffer-visiting file)))
        (delete-file file)))))

(ert-deftest canvas-diagram-reader-export-names-a-file-without-diagrams ()
  ;; GIVEN a file without a toy diagram
  ;; WHEN it is exported
  ;; THEN that is a user error that names the file
  (canvas-diagram-reader-test--with-layouts
    (let ((file (make-temp-file "canvas-diagram-reader-test" nil ".md" "Nothing.\n")))
      (unwind-protect
          (let ((err (should-error (canvas-diagram-reader-export canvas-diagram-reader-test--reader file "out.png")
                                   :type 'user-error)))
            (should (equal (cadr err) (format "canvas-toy: no toy diagram in %s"
                                              (file-name-nondirectory file)))))
        (delete-file file)))))

;;;; The demo

(ert-deftest canvas-diagram-reader-demo-shows-its-text-to-edit ()
  ;; GIVEN the text of a demo diagram, and a mode for it that is not there
  ;; WHEN the demo is run
  ;; THEN a buffer named after the package holds the text, with point at
  ;;      its start, AND its diagram is drawn following that buffer
  (canvas-diagram-reader-test--with-layouts
    (save-window-excursion
      (unwind-protect
          (progn
            (canvas-diagram-reader-demo canvas-diagram-reader-test--reader
                                        "```toy\nboxes x y\n```\n" 'canvas-no-such-mode)
            (with-current-buffer "*canvas-toy demo*"
              (should (equal (buffer-string) "```toy\nboxes x y\n```\n"))
              (should (= (point) (point-min)))
              (should (equal canvas-diagram-reader-test--drawn
                             (list (list 'boxes (current-buffer) '("x" "y") "*canvas-toy*"))))))
        (when (get-buffer "*canvas-toy demo*")
          (kill-buffer "*canvas-toy demo*"))))))

;;; canvas-diagram-reader-tests.el ends here
