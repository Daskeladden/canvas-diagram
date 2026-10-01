;;; canvas-diagram-tests.el --- tests -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'canvas-diagram)
(require 'lisp-mnt)
(require 'package)

;;;; The module

(defun canvas-diagram-test--canvas (w h)
  "A fresh W x H canvas spec.  Each call makes a distinct `:id'."
  (list 'image :type 'canvas :id (make-symbol "test-canvas")
        :data-width w :data-height h))

(defmacro canvas-diagram-test--with-context (var w h &rest body)
  "Run BODY with VAR bound to a context on a fresh W x H canvas."
  (declare (indent 3))
  `(let ((,var (canvas-cairo-context (canvas-diagram-test--canvas ,w ,h))))
     (unwind-protect (progn ,@body)
       (canvas-cairo-destroy ,var))))

(ert-deftest canvas-cairo-clear-paints-every-pixel ()
  ;; GIVEN a context on a small canvas
  ;; WHEN it is cleared to opaque red
  ;; THEN every corner reads back as opaque red in the canvas's ARGB32 format
  (canvas-diagram-test--with-context ctx 4 4
    (canvas-cairo-clear ctx 1 0 0 1)
    (dolist (xy '((0 . 0) (3 . 0) (0 . 3) (3 . 3)))
      (should (= (canvas-cairo-pixel ctx (car xy) (cdr xy)) #xFFFF0000)))))

(ert-deftest canvas-cairo-fill-stays-inside-the-path ()
  ;; GIVEN a canvas cleared to red
  ;; WHEN a two-pixel blue square is filled at (1,1)
  ;; THEN the pixels inside are blue AND those outside are still red
  (canvas-diagram-test--with-context ctx 4 4
    (canvas-cairo-clear ctx 1 0 0 1)
    (canvas-cairo-set-color ctx 0 0 1 1)
    (canvas-cairo-rectangle ctx 1 1 2 2)
    (canvas-cairo-fill ctx)
    (should (= (canvas-cairo-pixel ctx 1 1) #xFF0000FF))
    (should (= (canvas-cairo-pixel ctx 2 2) #xFF0000FF))
    (should (= (canvas-cairo-pixel ctx 0 0) #xFFFF0000))
    (should (= (canvas-cairo-pixel ctx 3 3) #xFFFF0000))))

(ert-deftest canvas-cairo-set-dash-leaves-gaps-in-a-stroke ()
  ;; GIVEN a black canvas and a white one-pixel line through row 2
  ;; WHEN the line is stroked with the dash pattern [4 4]
  ;; THEN the pixels of the first and the second dash are white
  ;;      AND the gap between them stays black
  (canvas-diagram-test--with-context ctx 20 5
    (canvas-cairo-clear ctx 0 0 0 1)
    (canvas-cairo-set-color ctx 1 1 1 1)
    (canvas-cairo-set-line-width ctx 1)
    (canvas-cairo-set-dash ctx [4 4])
    (canvas-cairo-new-path ctx)
    (canvas-cairo-move-to ctx 0 2.5)
    (canvas-cairo-line-to ctx 20 2.5)
    (canvas-cairo-stroke ctx)
    (should (= (canvas-cairo-pixel ctx 1 2) #xFFFFFFFF))
    (should (= (canvas-cairo-pixel ctx 5 2) #xFF000000))
    (should (= (canvas-cairo-pixel ctx 9 2) #xFFFFFFFF))))

(ert-deftest canvas-cairo-set-dash-with-an-empty-vector-draws-solid ()
  ;; GIVEN a black canvas whose context was given the dash pattern [4 4]
  ;; WHEN the pattern is set to [] and a white line is stroked through row 2
  ;; THEN the pixel in the place of the first gap is white
  (canvas-diagram-test--with-context ctx 20 5
    (canvas-cairo-clear ctx 0 0 0 1)
    (canvas-cairo-set-color ctx 1 1 1 1)
    (canvas-cairo-set-line-width ctx 1)
    (canvas-cairo-set-dash ctx [4 4])
    (canvas-cairo-set-dash ctx [])
    (canvas-cairo-new-path ctx)
    (canvas-cairo-move-to ctx 0 2.5)
    (canvas-cairo-line-to ctx 20 2.5)
    (canvas-cairo-stroke ctx)
    (should (= (canvas-cairo-pixel ctx 5 2) #xFFFFFFFF))))

(ert-deftest canvas-cairo-set-dash-refuses-lengths-it-cannot-draw ()
  ;; GIVEN a context
  ;; WHEN it is given a negative length, only zeros, a length or an offset that is
  ;;      NaN or infinite, a string length or a list
  ;; THEN each is an error, and a bad number is named in the message
  ;;      AND the pattern [2 2] with the offset 1 is not
  (canvas-diagram-test--with-context ctx 4 4
    (let ((err (should-error (canvas-cairo-set-dash ctx [2 -1]))))
      (should (string-search "negative" (cadr err))))
    (let ((err (should-error (canvas-cairo-set-dash ctx [0 0]))))
      (should (string-search "all 0" (cadr err))))
    (pcase-dolist (`(,dashes ,offset ,named) (list (list (vector 0.0e+NaN 1) nil "length nan")
                                                   (list (vector 1.0e+INF 1) nil "length inf")
                                                   (list [2 2] 0.0e+NaN "offset nan")
                                                   (list [2 2] 1.0e+INF "offset inf")))
      (let ((err (should-error (canvas-cairo-set-dash ctx dashes offset))))
        (should (string-search named (cadr err)))))
    (should-error (canvas-cairo-set-dash ctx ["2" 2]) :type 'wrong-type-argument)
    (should-error (canvas-cairo-set-dash ctx '(2 2)) :type 'wrong-type-argument)
    (should-not (canvas-cairo-set-dash ctx [2 2] 1))))

(ert-deftest canvas-cairo-set-dash-works-on-a-file-context ()
  ;; GIVEN a context that draws into an SVG file
  ;; WHEN a line is stroked with the dash pattern [4 4] and the context is destroyed
  ;; THEN the SVG file holds a dash array
  (let ((file (make-temp-file "canvas-dash-" nil ".svg")))
    (unwind-protect
        (let ((ctx (canvas-cairo-file-context file 20 5)))
          (canvas-cairo-set-color ctx 0 0 0 1)
          (canvas-cairo-set-dash ctx [4 4])
          (canvas-cairo-new-path ctx)
          (canvas-cairo-move-to ctx 0 2.5)
          (canvas-cairo-line-to ctx 20 2.5)
          (canvas-cairo-stroke ctx)
          (canvas-cairo-destroy ctx)
          (with-temp-buffer
            (insert-file-contents file)
            (should (search-forward "stroke-dasharray" nil t))))
      (delete-file file))))

(ert-deftest canvas-cairo-pixels-returns-a-region-row-by-row ()
  ;; GIVEN a red canvas with a blue square at (1,1)
  ;; WHEN the whole canvas is read as a vector
  ;; THEN it has one entry per pixel, in row order, with the square in place
  ;;      AND a region past the edge is an error
  (canvas-diagram-test--with-context ctx 4 4
    (canvas-cairo-clear ctx 1 0 0 1)
    (canvas-cairo-set-color ctx 0 0 1 1)
    (canvas-cairo-rectangle ctx 1 1 2 2)
    (canvas-cairo-fill ctx)
    (let ((v (canvas-cairo-pixels ctx 0 0 4 4)))
      (should (= (length v) 16))
      (should (= (aref v 0) #xFFFF0000))
      (should (= (aref v 5) #xFF0000FF))
      (should (= (aref v 15) #xFFFF0000)))
    (should (= (length (canvas-cairo-pixels ctx 1 1 2 2)) 4))
    (should-error (canvas-cairo-pixels ctx 1 1 4 4))))

(ert-deftest canvas-cairo-coordinates-may-be-integers-or-floats ()
  ;; GIVEN a canvas cleared to red
  ;; WHEN a square is filled with float coordinates
  ;; THEN it lands where the integer version would
  (canvas-diagram-test--with-context ctx 4 4
    (canvas-cairo-clear ctx 1.0 0 0.0 1)
    (canvas-cairo-set-color ctx 0 0 1.0 1)
    (canvas-cairo-rectangle ctx 1.0 1.0 2.0 2.0)
    (canvas-cairo-fill ctx)
    (should (= (canvas-cairo-pixel ctx 1 1) #xFF0000FF))
    (should (= (canvas-cairo-pixel ctx 0 0) #xFFFF0000))))

(ert-deftest canvas-cairo-stroked-curve-leaves-ink ()
  ;; GIVEN a white canvas
  ;; WHEN a black curve is stroked from the left edge to the right edge
  ;; THEN some pixel on the middle column is no longer white
  ;;      AND the corners, far from the curve, are untouched
  (canvas-diagram-test--with-context ctx 16 16
    (canvas-cairo-clear ctx 1 1 1 1)
    (canvas-cairo-set-color ctx 0 0 0 1)
    (canvas-cairo-set-line-width ctx 2)
    (canvas-cairo-move-to ctx 0 8)
    (canvas-cairo-curve-to ctx 5 8 11 8 16 8)
    (canvas-cairo-stroke ctx)
    (should (cl-some (lambda (y) (/= (canvas-cairo-pixel ctx 8 y) #xFFFFFFFF))
                     (number-sequence 0 15)))
    (should (= (canvas-cairo-pixel ctx 0 0) #xFFFFFFFF))
    (should (= (canvas-cairo-pixel ctx 15 15) #xFFFFFFFF))))

(ert-deftest canvas-cairo-clip-limits-painting ()
  ;; GIVEN a red canvas with the clip set to its top-left quarter
  ;; WHEN the whole canvas is cleared to blue
  ;; THEN only the clipped quarter turns blue
  (canvas-diagram-test--with-context ctx 4 4
    (canvas-cairo-clear ctx 1 0 0 1)
    (canvas-cairo-rectangle ctx 0 0 2 2)
    (canvas-cairo-clip ctx)
    (canvas-cairo-clear ctx 0 0 1 1)
    (should (= (canvas-cairo-pixel ctx 0 0) #xFF0000FF))
    (should (= (canvas-cairo-pixel ctx 3 3) #xFFFF0000))
    ;; WHEN the clip is reset and the canvas cleared again
    ;; THEN the whole canvas is painted
    (canvas-cairo-reset-clip ctx)
    (canvas-cairo-clear ctx 0 1 0 1)
    (should (= (canvas-cairo-pixel ctx 3 3) #xFF00FF00))))

(ert-deftest canvas-cairo-save-and-restore-bracket-a-transform ()
  ;; GIVEN a context translated by (2,2) inside a save/restore pair
  ;; WHEN a pixel is filled at the origin before and after the restore
  ;; THEN the first lands at (2,2) AND the second at (0,0)
  (canvas-diagram-test--with-context ctx 4 4
    (canvas-cairo-clear ctx 0 0 0 1)
    (canvas-cairo-set-color ctx 1 1 1 1)
    (canvas-cairo-save ctx)
    (canvas-cairo-translate ctx 2 2)
    (canvas-cairo-rectangle ctx 0 0 1 1)
    (canvas-cairo-fill ctx)
    (canvas-cairo-restore ctx)
    (canvas-cairo-rectangle ctx 0 0 1 1)
    (canvas-cairo-fill ctx)
    (should (= (canvas-cairo-pixel ctx 2 2) #xFFFFFFFF))
    (should (= (canvas-cairo-pixel ctx 0 0) #xFFFFFFFF))
    (should (= (canvas-cairo-pixel ctx 1 1) #xFF000000))))

(ert-deftest canvas-cairo-text-is-measured-and-drawn ()
  ;; GIVEN a white canvas
  ;; WHEN a word is measured and then drawn in black
  ;; THEN the size is positive, a longer word is wider
  ;;      AND the drawn word leaves ink inside its measured box
  (canvas-diagram-test--with-context ctx 120 40
    (canvas-cairo-clear ctx 1 1 1 1)
    (let ((one (canvas-cairo-text-size ctx "H" "Sans 12px"))
          (word (canvas-cairo-text-size ctx "Hello" "Sans 12px")))
      (should (> (car one) 0))
      (should (> (cdr one) 0))
      (should (> (car word) (car one)))
      (canvas-cairo-set-color ctx 0 0 0 1)
      (should (equal (canvas-cairo-text ctx 2 2 "Hello" "Sans 12px") word))
      (should (cl-loop for x from 2 below (+ 2 (car word))
                       thereis (cl-loop for y from 2 below (+ 2 (cdr word))
                                        thereis (/= (canvas-cairo-pixel ctx x y)
                                                    #xFFFFFFFF)))))))

(defun canvas-diagram-test--ink-in (ctx x y w h test)
  "Whether some pixel of the W by H box at X Y on CTX passes TEST."
  (cl-loop for px from x below (+ x w)
           thereis (cl-loop for py from y below (+ y h)
                            thereis (funcall test (canvas-cairo-pixel ctx px py)))))

(defun canvas-diagram-test--red-p (argb)
  "Whether ARGB is red ink: full red, little green and blue."
  (and (= (logand (ash argb -16) #xFF) #xFF)
       (< (logand (ash argb -8) #xFF) #x80) (< (logand argb #xFF) #x80)))

(defun canvas-diagram-test--dark-p (argb)
  "Whether ARGB is dark ink: every channel below a quarter of full."
  (and (< (logand (ash argb -16) #xFF) #x40)
       (< (logand (ash argb -8) #xFF) #x40) (< (logand argb #xFF) #x40)))

(ert-deftest canvas-cairo-markup-colours-its-spans-and-lets-them-go ()
  ;; GIVEN a white canvas
  ;; WHEN a word is drawn red through markup, then another word plainly in black
  ;; THEN the first carries red ink and no black, the second black ink and no
  ;;      red: the markup's colours do not linger on the layout
  (canvas-diagram-test--with-context ctx 200 40
    (canvas-cairo-clear ctx 1 1 1 1)
    (canvas-cairo-set-color ctx 0 0 0 1)
    (pcase-let ((`(,w . ,h) (canvas-cairo-markup ctx 2 2 "<span foreground=\"#ff0000\">HHHH</span>" "Sans 12px")))
      (should (canvas-diagram-test--ink-in ctx 2 2 w h #'canvas-diagram-test--red-p))
      (should-not (canvas-diagram-test--ink-in ctx 2 2 w h #'canvas-diagram-test--dark-p))
      (pcase-let ((`(,w2 . ,h2) (canvas-cairo-text ctx 100 2 "HHHH" "Sans 12px")))
        (should (canvas-diagram-test--ink-in ctx 100 2 w2 h2 #'canvas-diagram-test--dark-p))
        (should-not (canvas-diagram-test--ink-in ctx 100 2 w2 h2 #'canvas-diagram-test--red-p))))))

(ert-deftest canvas-cairo-markup-measures-like-plain-text ()
  ;; GIVEN markup that only escapes and markup that only colours
  ;; WHEN it is measured
  ;; THEN it takes the room its plain text takes, AND bad markup is an error
  (canvas-diagram-test--with-context ctx 8 8
    (should (equal (canvas-cairo-markup-size ctx "a &lt;= b &amp; c" "Sans 12px")
                   (canvas-cairo-text-size ctx "a <= b & c" "Sans 12px")))
    (should (equal (canvas-cairo-markup-size ctx "<span foreground=\"#00ff00\">Hello</span> there" "Sans 12px" 40)
                   (canvas-cairo-text-size ctx "Hello there" "Sans 12px" 40)))
    (should-error (canvas-cairo-markup-size ctx "<span>open" "Sans 12px"))
    (should-error (canvas-cairo-markup ctx 0 0 "a < b" "Sans 12px"))))

(ert-deftest canvas-cairo-text-wraps-at-a-width ()
  ;; GIVEN a sentence that does not fit in 60 pixels on one line
  ;; WHEN it is measured with and without a wrap width
  ;; THEN the wrapped version is no wider than the limit and taller than the
  ;;      unwrapped one
  (canvas-diagram-test--with-context ctx 8 8
    (let* ((text "several words that need wrapping")
           (flat (canvas-cairo-text-size ctx text "Sans 12px"))
           (wrapped (canvas-cairo-text-size ctx text "Sans 12px" 60)))
      (should (> (car flat) 60))
      (should (<= (car wrapped) 60))
      (should (> (cdr wrapped) (cdr flat))))))

(ert-deftest canvas-cairo-follows-a-resized-canvas ()
  ;; GIVEN a context on a 4x4 canvas
  ;; WHEN the spec grows to 8x8 and the canvas is cleared through the context
  ;; THEN the new far corner is painted rather than memory past the old buffer
  (let* ((spec (canvas-diagram-test--canvas 4 4))
         (ctx (canvas-cairo-context spec)))
    (unwind-protect
        (progn
          (canvas-cairo-clear ctx 1 0 0 1)
          (plist-put (cdr spec) :data-width 8)
          (plist-put (cdr spec) :data-height 8)
          (canvas-cairo-clear ctx 0 0 1 1)
          (should (= (canvas-cairo-pixel ctx 7 7) #xFF0000FF)))
      (canvas-cairo-destroy ctx))))

(ert-deftest canvas-cairo-pixel-outside-the-canvas-is-an-error ()
  ;; GIVEN a 4x4 canvas
  ;; WHEN a pixel beyond its edge is read
  ;; THEN that is an error rather than a read past the buffer
  (canvas-diagram-test--with-context ctx 4 4
    (should-error (canvas-cairo-pixel ctx 4 0))
    (should-error (canvas-cairo-pixel ctx 0 4))
    (should-error (canvas-cairo-pixel ctx -1 0))))

(ert-deftest canvas-cairo-destroyed-context-refuses-to-draw ()
  ;; GIVEN a context that has been destroyed
  ;; WHEN it is drawn on
  ;; THEN that is an error, and destroying it again is harmless
  (let ((ctx (canvas-cairo-context (canvas-diagram-test--canvas 4 4))))
    (canvas-cairo-destroy ctx)
    (should-error (canvas-cairo-clear ctx 0 0 0 1))
    (canvas-cairo-destroy ctx)))

(ert-deftest canvas-cairo-rejects-what-is-not-a-canvas-or-context ()
  ;; GIVEN things that are not a canvas spec, or not a context
  ;; WHEN they are handed to the module
  ;; THEN each is refused with an error
  (should-error (canvas-cairo-context 42))
  (should-error (canvas-cairo-context '(image :type png :file "x.png")))
  (should-error (canvas-cairo-clear "not a context" 0 0 0 1))
  (canvas-diagram-test--with-context ctx 4 4
    (should-error (canvas-cairo-move-to ctx "one" 2))
    (should-error (canvas-cairo-text ctx 0 0 'not-a-string "Sans 12px"))))

(ert-deftest canvas-cairo-flush-refreshes-the-drawn-canvas ()
  ;; GIVEN a context on a canvas
  ;; WHEN the context is flushed
  ;; THEN Emacs is asked to refresh exactly that canvas, once
  (let* ((spec (canvas-diagram-test--canvas 4 4))
         (ctx (canvas-cairo-context spec))
         (refreshed nil))
    (unwind-protect
        (cl-letf (((symbol-function 'canvas-refresh)
                   (lambda (image &optional _reload) (push image refreshed))))
          (canvas-cairo-flush ctx)
          (should (equal refreshed (list spec))))
      (canvas-cairo-destroy ctx))))

(ert-deftest canvas-cairo-reports-its-library-versions ()
  ;; GIVEN the module is loaded
  ;; THEN it can say which cairo and pango it runs on
  (should (string-match-p "cairo [0-9.]+, pango [0-9.]+" (canvas-cairo-version))))

(defun canvas-diagram-test--png-p (file)
  "Whether FILE starts with the PNG signature."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 8)
    (equal (buffer-string) "\x89PNG\r\n\x1a\n")))

(ert-deftest canvas-cairo-write-png-saves-the-canvas ()
  ;; GIVEN a canvas cleared to red
  ;; WHEN it is written to a file
  ;; THEN the file is a PNG with some content
  (let ((file (make-temp-file "canvas-cairo-test" nil ".png")))
    (unwind-protect
        (canvas-diagram-test--with-context ctx 4 4
          (canvas-cairo-clear ctx 1 0 0 1)
          (canvas-cairo-write-png ctx file)
          (should (canvas-diagram-test--png-p file))
          (should (> (file-attribute-size (file-attributes file)) 40)))
      (delete-file file))))

(ert-deftest canvas-cairo-write-png-to-a-missing-directory-is-an-error ()
  ;; GIVEN a path in a directory that does not exist
  ;; WHEN the canvas is written there
  ;; THEN that is an error rather than a silent no-op
  (canvas-diagram-test--with-context ctx 4 4
    (should-error (canvas-cairo-write-png ctx "/nonexistent-dir/x.png"))))

(defconst canvas-diagram-test--square-svg
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\" fill=\"blue\"/></svg>"
  "An SVG that is one filled square, drawn in blue.")

(ert-deftest canvas-cairo-svg-paints-the-current-colour-through-the-drawing ()
  ;; GIVEN a white canvas and red as the current colour
  ;; WHEN a blue square SVG is painted into a box
  ;; THEN the box is red, the drawing's own blue ignored, AND outside stays white
  (canvas-diagram-test--with-context ctx 20 20
    (canvas-cairo-clear ctx 1 1 1 1)
    (canvas-cairo-set-color ctx 1 0 0 1)
    (canvas-cairo-svg ctx canvas-diagram-test--square-svg 4 4 8 8)
    (should (= (canvas-cairo-pixel ctx 6 6) #xFFFF0000))
    (should (= (canvas-cairo-pixel ctx 11 11) #xFFFF0000))
    (should (= (canvas-cairo-pixel ctx 2 2) #xFFFFFFFF))
    (should (= (canvas-cairo-pixel ctx 14 14) #xFFFFFFFF))))

(ert-deftest canvas-cairo-svg-refuses-bad-data-and-an-empty-box ()
  ;; GIVEN text that is no SVG, and a box with no width
  ;; WHEN each is painted
  ;; THEN each is an error
  (canvas-diagram-test--with-context ctx 8 8
    (should-error (canvas-cairo-svg ctx "not svg at all" 0 0 4 4))
    (should-error (canvas-cairo-svg ctx canvas-diagram-test--square-svg 0 0 0 4))))

(defun canvas-diagram-test--svg (elements)
  "SVG data on a 10 by 10 viewBox that holds ELEMENTS, a string."
  (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\">" elements "</svg>"))

(defconst canvas-diagram-test--red-square-svg
  (canvas-diagram-test--svg "<rect width=\"10\" height=\"10\" fill=\"#ff0000\"/>")
  "An SVG that is one filled square, drawn in red.")

(ert-deftest canvas-cairo-svg-picture-paints-the-drawing-in-its-own-colours ()
  ;; GIVEN a black canvas and green as the current colour
  ;; WHEN a red square SVG is painted into a box in its own colours
  ;; THEN the call returns nil, the box is red, the green ignored, AND outside stays black
  (canvas-diagram-test--with-context ctx 20 20
    (canvas-cairo-clear ctx 0 0 0 1)
    (canvas-cairo-set-color ctx 0 1 0 1)
    (should-not (canvas-cairo-svg-picture ctx canvas-diagram-test--red-square-svg 4 4 8 8))
    (should (= (canvas-cairo-pixel ctx 6 6) #xFFFF0000))
    (should (= (canvas-cairo-pixel ctx 11 11) #xFFFF0000))
    (should (= (canvas-cairo-pixel ctx 2 2) #xFF000000))
    (should (= (canvas-cairo-pixel ctx 14 14) #xFF000000))))

(ert-deftest canvas-cairo-svg-picture-leaves-the-current-colour-current ()
  ;; GIVEN a black canvas and green as the current colour
  ;; WHEN a red square SVG is painted into a box in its own colours
  ;;      AND a rectangle outside the box is filled, no colour set again
  ;; THEN the filled rectangle is green
  (canvas-diagram-test--with-context ctx 20 20
    (canvas-cairo-clear ctx 0 0 0 1)
    (canvas-cairo-set-color ctx 0 1 0 1)
    (canvas-cairo-svg-picture ctx canvas-diagram-test--red-square-svg 4 4 8 8)
    (canvas-cairo-rectangle ctx 14 14 4 4)
    (canvas-cairo-fill ctx)
    (should (= (canvas-cairo-pixel ctx 16 16) #xFF00FF00))))

(ert-deftest canvas-cairo-svg-picture-keeps-each-colour-in-its-place ()
  ;; GIVEN a black canvas
  ;; WHEN an SVG with a red left half and a blue right half is painted into a box
  ;; THEN the left half of the box is red AND its right half is blue
  (canvas-diagram-test--with-context ctx 20 20
    (canvas-cairo-clear ctx 0 0 0 1)
    (canvas-cairo-svg-picture
     ctx (canvas-diagram-test--svg (concat "<rect width=\"5\" height=\"10\" fill=\"#ff0000\"/>"
                                           "<rect x=\"5\" width=\"5\" height=\"10\" fill=\"#0000ff\"/>"))
     4 4 8 8)
    (should (= (canvas-cairo-pixel ctx 5 8) #xFFFF0000))
    (should (= (canvas-cairo-pixel ctx 10 8) #xFF0000FF))))

(ert-deftest canvas-cairo-svg-picture-refuses-what-canvas-cairo-svg-refuses ()
  ;; GIVEN text that is no SVG, and a box with no width
  ;; WHEN each is painted in its own colours
  ;; THEN each is the error, with the message, that canvas-cairo-svg raises for it
  (canvas-diagram-test--with-context ctx 8 8
    (dolist (args (list (list "not svg at all" 0 0 4 4)
                        (list canvas-diagram-test--square-svg 0 0 0 4)))
      (should (equal (should-error (apply #'canvas-cairo-svg-picture ctx args))
                     (should-error (apply #'canvas-cairo-svg ctx args)))))))

;;;; A row: the smallest diagram there is

;; The tests below drive canvas-diagram through a stub package: a row
;; of boxes, each a (LABEL [:kind K] [:note N] [:icon I] [:pos P]) in
;; the spec, laid out left to right with an edge between neighbours.

(defun canvas-diagram-test--row-build (_diagram spec)
  "The nodes SPEC lists, in order."
  (mapcar (lambda (item)
            (canvas-diagram-node-create :label (car item)
                                        :kind (plist-get (cdr item) :kind)
                                        :note (plist-get (cdr item) :note)
                                        :icon (plist-get (cdr item) :icon)
                                        :pos (plist-get (cdr item) :pos)))
          spec))

(defun canvas-diagram-test--row-layout (diagram ctx)
  "Put the nodes in a row, 30 apart, the row starting at the origin."
  (let ((measure (canvas-diagram-measure ctx))
        (x 0))
    (dolist (node (canvas-diagram-model diagram))
      (canvas-diagram-size-node diagram node measure)
      (setf (canvas-diagram-node-x node) x
            (canvas-diagram-node-y node) 0)
      (setq x (+ x (canvas-diagram-node-w node) 30)))
    (canvas-diagram-model diagram)))

(defun canvas-diagram-test--row-edges (diagram ctx)
  "A straight line from each node to the next."
  (cl-loop for (from to) on (canvas-diagram-model diagram) while to
           do (canvas-cairo-move-to ctx (+ (canvas-diagram-node-x from) (canvas-diagram-node-w from))
                                    (canvas-diagram-middle-y from))
           (canvas-cairo-line-to ctx (canvas-diagram-node-x to) (canvas-diagram-middle-y to))
           (canvas-cairo-stroke ctx)))

(defun canvas-diagram-test--row-move (diagram node direction)
  "Along the row: in and next go right, out and previous left, first and last end."
  (let ((nodes (canvas-diagram-model diagram)))
    (pcase direction
      ((or 'in 'next 'next-sibling 'next-at-depth 'next-branch) (canvas-diagram-neighbour nodes node 1))
      ((or 'out 'previous 'previous-sibling 'previous-at-depth 'branch) (canvas-diagram-neighbour nodes node -1))
      ('first (car nodes))
      ('last (car (last nodes))))))

(defvar canvas-diagram-test--double-clicked nil
  "The node the stub was told a double click fell on.")

(defvar canvas-diagram-test--overlaid nil
  "What the stub's overlay was last asked to draw over: (SIZE OFFSET ZOOM SELECTED).")

(defun canvas-diagram-test--row-read-source (buffer)
  "One node per line of BUFFER, with the line's start as its position."
  (with-current-buffer buffer
    (let (spec)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties (point) (line-end-position))))
            (unless (string-blank-p line)
              (push (list line :pos (point)) spec)))
          (forward-line 1)))
      (nreverse spec))))

(canvas-diagram-define-menu canvas-diagram-test-menu
  "The stub's menu: only the shared groups."
  ["Row"
   ("r" "nothing of its own" ignore :transient t)])

(defconst canvas-diagram-test--row-callbacks
  (list :build #'canvas-diagram-test--row-build
        :layout #'canvas-diagram-test--row-layout
        :draw-edges #'canvas-diagram-test--row-edges
        :node-rgb (lambda (_d node) (if (equal (canvas-diagram-node-label node) "green")
                                        (canvas-diagram-rgb "green")
                                      (canvas-diagram-color :node)))
        :header (lambda (_d node) (concat "row: " (canvas-diagram-node-label node)))
        :card (lambda (_d node) (list (canvas-diagram-node-label node) "the row"
                                      (or (canvas-diagram-node-note node) "no note")))
        :badge (lambda (_d node) (and (equal (canvas-diagram-node-label node) "badged")
                                      (list "TODO" (canvas-diagram-rgb "red"))))
        :legend (lambda (_d) '(("row" (1.0 0.0 0.0) fill)))
        :move #'canvas-diagram-test--row-move
        :double-click (lambda (_d node) (setq canvas-diagram-test--double-clicked node))
        :overlay (lambda (_d ctx size offset zoom selected)
                   (setq canvas-diagram-test--overlaid (list size offset zoom selected))
                   ;; A dot in the view's far corner, wherever the drawing is scrolled.
                   (canvas-diagram-set-rgb ctx (canvas-diagram-rgb "red"))
                   (canvas-cairo-rectangle ctx (- (car size) 4) (- (cdr size) 4) 2 2)
                   (canvas-cairo-fill ctx))
        :read-source #'canvas-diagram-test--row-read-source
        :menu 'canvas-diagram-test-menu)
  "How the row plugs into canvas-diagram.")

(defun canvas-diagram-test--row ()
  "A fresh row diagram."
  (canvas-diagram-create :callbacks canvas-diagram-test--row-callbacks))

(defun canvas-diagram-test--laid-out (spec ctx)
  "A row diagram built from SPEC and laid out on CTX."
  (let ((diagram (canvas-diagram-test--row)))
    (setf (canvas-diagram-spec diagram) spec
          (canvas-diagram-model diagram) (canvas-diagram-test--row-build diagram spec)
          (canvas-diagram-nodes diagram) (canvas-diagram-test--row-layout diagram ctx))
    diagram))

(define-derived-mode canvas-diagram-test-mode canvas-diagram-mode "Row"
  "The stub's mode.")

(defmacro canvas-diagram-test--rendering (&rest body)
  "Run BODY with fixed font and colours, so pixels are predictable."
  `(let ((canvas-diagram-font "Sans 12px")
         (canvas-diagram-margin 10)
         (canvas-diagram-kinds '(("todo" . "red")))
         (canvas-diagram-colors '(:background "white" :node "blue"
                                  :text "black" :edge "gray"))
         (canvas-diagram-shape 'rounded)
         (canvas-diagram-spacing 'normal)
         (canvas-diagram-family nil)
         (canvas-diagram-palette "derived")
         (canvas-diagram-show-kinds t)
         (canvas-diagram-show-legend t)
         (canvas-diagram-show-icons nil)
         (canvas-diagram-paper nil))
     ,@body))

(defmacro canvas-diagram-test--in-buffer (spec size &rest body)
  "Run BODY in a diagram buffer showing the row SPEC on a canvas of SIZE."
  (declare (indent 2))
  `(canvas-diagram-test--rendering
    (with-temp-buffer
      (canvas-diagram-test-mode)
      (canvas-diagram-adopt (canvas-diagram-test--row) ,spec)
      (plist-put (cdr canvas-diagram--canvas) :data-width (car ,size))
      (plist-put (cdr canvas-diagram--canvas) :data-height (cdr ,size))
      (unwind-protect (progn ,@body)
        (canvas-diagram--release)))))

(defun canvas-diagram-test--labelled (label)
  "The node called LABEL in this buffer's diagram."
  (cl-find label (canvas-diagram-nodes-shown) :key #'canvas-diagram-node-label :test #'equal))

(defun canvas-diagram-test--selected ()
  "The label of the selected node."
  (canvas-diagram-node-label (canvas-diagram-selected)))

(defun canvas-diagram-test--inside (node)
  "A canvas pixel just inside NODE's top-left corner, at a ten pixel margin."
  (cons (+ 10 (floor (canvas-diagram-node-x node)) 3)
        (+ 10 (floor (canvas-diagram-node-y node)) 3)))

(defun canvas-diagram-test--dark-p (argb)
  "Whether ARGB is ink: every channel below a quarter of full."
  (and (< (logand (ash argb -16) #xFF) #x40)
       (< (logand (ash argb -8) #xFF) #x40)
       (< (logand argb #xFF) #x40)))

(defun canvas-diagram-test--measure (label)
  "Ten pixels per character, twenty tall: a fake text measure."
  (cons (* 10 (length label)) 20))

;;;; Geometry

(ert-deftest canvas-diagram-node-at-finds-the-box-under-a-point ()
  ;; GIVEN two boxes side by side
  ;; WHEN points inside each and in the gap between are looked up
  ;; THEN each box, and nothing, come back
  (let ((a (canvas-diagram-node-create :label "AA" :x 0 :y 0 :w 20 :h 20))
        (b (canvas-diagram-node-create :label "BB" :x 50 :y 0 :w 20 :h 20)))
    (should (eq (canvas-diagram--node-at (list a b) 55 5) b))
    (should (eq (canvas-diagram--node-at (list a b) 10 20) a))
    (should-not (canvas-diagram--node-at (list a b) 30 5))))

(ert-deftest canvas-diagram-offset-is-clamped-to-the-drawing ()
  ;; GIVEN a drawing larger than the canvas, and one smaller
  ;; WHEN an offset past either edge is clamped
  ;; THEN it stops where the drawing's far edge meets the canvas's,
  ;;      AND a small drawing never scrolls at all
  (should (equal (canvas-diagram--clamp-offset '(-5 . 900) '(500 . 400) '(300 . 200))
                 '(0 . 200)))
  (should (equal (canvas-diagram--clamp-offset '(50 . 60) '(100 . 100) '(300 . 200))
                 '(0 . 0))))

(ert-deftest canvas-diagram-hot-spots-follow-the-offset ()
  ;; GIVEN two laid-out boxes scrolled by (5, 7) with a ten pixel margin
  ;; WHEN the hot spots are made
  ;; THEN each rectangle sits at its box shifted by margin minus offset,
  ;;      is named for the click bindings, shows its label or note when
  ;;      hovered AND turns the pointer into a hand
  (let* ((canvas-diagram-margin 10)
         (a (canvas-diagram-node-create :label "Root" :x 0 :y 15 :w 40 :h 20))
         (b (canvas-diagram-node-create :label "AA" :note "a note" :x 70 :y 0 :w 20 :h 20))
         (spots (canvas-diagram--hot-spots (list a b) '(5 . 7)))
         (spot (cl-find '(rect . ((5 . 18) . (45 . 38))) spots :key #'car :test #'equal))
         (other (cl-find '(rect . ((75 . 3) . (95 . 23))) spots :key #'car :test #'equal)))
    (should (= (length spots) 2))
    (should (eq (nth 1 spot) 'canvas-diagram-node))
    (should (equal (plist-get (nth 2 spot) 'help-echo) "Root"))
    (should (eq (plist-get (nth 2 spot) 'pointer) 'hand))
    (should (equal (plist-get (nth 2 other) 'help-echo) "a note"))))

(ert-deftest canvas-diagram-zoom-scales-boxes-hot-spots-and-hits ()
  ;; GIVEN a box at zoom 2 and no scrolling
  ;; WHEN it is placed on the canvas, its hot spot made, and a point hit-tested
  ;; THEN the box is twice its size at twice its distance from the margin,
  ;;      the hot spot matches, AND a canvas point maps back to the box
  (let* ((canvas-diagram-margin 10)
         (a (canvas-diagram-node-create :label "AA" :x 70 :y 0 :w 20 :h 20))
         (nodes (list a)))
    (should (equal (canvas-diagram--canvas-box a '(0 . 0) 2.0) '(150.0 10.0 190.0 50.0)))
    (should (cl-find '(rect . ((150 . 10) . (190 . 50)))
                     (canvas-diagram--hot-spots nodes '(0 . 0) 2.0) :key #'car :test #'equal))
    (should (eq (canvas-diagram--node-at nodes
                                         (car (canvas-diagram--map-point '(160 . 20) '(0 . 0) 2.0))
                                         (cdr (canvas-diagram--map-point '(160 . 20) '(0 . 0) 2.0)))
                a))
    (let ((diagram (canvas-diagram-create :nodes nodes)))
      (should (equal (canvas-diagram--map-size diagram 2.0) (cons (+ 20 (* 2 90)) (+ 20 (* 2 20)))))
      ;; AND slack, room the edges take past the boxes right and below, is zoomed too
      (setf (canvas-diagram-slack diagram) '(5 . 3))
      (should (equal (canvas-diagram--map-size diagram 2.0) (cons (+ 20 (* 2 95)) (+ 20 (* 2 23))))))))

(ert-deftest canvas-diagram-neighbour-holds-at-the-ends ()
  ;; GIVEN a list of three
  ;; WHEN a step is taken from the middle, and past each end
  ;; THEN the middle moves AND the ends hold, as does a stranger
  (should (eq (canvas-diagram-neighbour '(a b c) 'b 1) 'c))
  (should (eq (canvas-diagram-neighbour '(a b c) 'c 1) 'c))
  (should (eq (canvas-diagram-neighbour '(a b c) 'a -1) 'a))
  (should (eq (canvas-diagram-neighbour '(a b c) 'z -1) 'z)))

;;;; Fonts and colours

(ert-deftest canvas-diagram-colours-become-markup-hex ()
  ;; GIVEN a colour triple, a face with a foreground and one without
  ;; WHEN each is asked for as markup hex
  ;; THEN the triple is #rrggbb, the face gives its colour, the bare face
  ;;      the text colour, AND markup characters are escaped
  (should (equal (canvas-diagram-hex '(1.0 0.0 0.0)) "#ff0000"))
  (should (equal (canvas-diagram-hex '(0.0 0.5 1.0)) "#0080ff"))
  (cl-letf (((symbol-function 'face-attribute)
             (lambda (face &rest _) (if (eq face 'font-lock-keyword-face) "red" 'unspecified))))
    (let ((canvas-diagram-colors '(:text "blue")))
      (should (equal (canvas-diagram-face-hex 'font-lock-keyword-face) "#ff0000"))
      (should (equal (canvas-diagram-face-hex 'font-lock-string-face) "#0000ff"))))
  (should (equal (canvas-diagram-markup-escape "a <= b & c > d") "a &lt;= b &amp; c &gt; d")))

(ert-deftest canvas-diagram-font-description-uses-the-face-pixel-size ()
  ;; GIVEN a face whose font is a 15 pixel DejaVu Sans
  ;; WHEN a pango description is derived from it
  ;; THEN the family and an absolute pixel size are used, so the drawing's
  ;;      text is the same size as the frame's regardless of DPI
  (cl-letf (((symbol-function 'face-attribute)
             (lambda (_face _attr &optional _frame _inherit) "DejaVu Sans"))
            ((symbol-function 'face-font) (lambda (&rest _) "-some-xlfd-"))
            ((symbol-function 'font-info)
             (lambda (&rest _) (vector "o" "f" 15 17 0 0 0 0 13 4 5 8 "/f.ttf" nil))))
    (should (equal (canvas-diagram--font-description 'default) "DejaVu Sans 15px"))))

(ert-deftest canvas-diagram-font-falls-back-without-a-display ()
  ;; GIVEN no font is configured and no graphical display, as in batch
  ;; WHEN the label font is asked for
  ;; THEN a plain pango description is used rather than a frame's face
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
    (let ((canvas-diagram-font nil) (canvas-diagram-family nil))
      (should (equal (canvas-diagram-font) canvas-diagram-fallback-font)))))

(ert-deftest canvas-diagram-bold-variant-goes-before-the-size ()
  ;; GIVEN a pango description with a multi-word family
  ;; WHEN its bold variant is asked for
  ;; THEN Bold is inserted between the family and the size
  (should (equal (canvas-diagram--bold "DejaVu Sans Mono 15px") "DejaVu Sans Mono Bold 15px")))

(ert-deftest canvas-diagram-face-colour-falls-back-when-unset ()
  ;; GIVEN a face whose background is unspecified, as in a batch session
  ;; WHEN its colour is asked for with a fallback
  ;; THEN the fallback's RGB triple is returned
  (cl-letf (((symbol-function 'face-attribute) (lambda (&rest _) 'unspecified)))
    (should (equal (canvas-diagram--face-rgb 'default :background "red") '(1.0 0.0 0.0)))))

(ert-deftest canvas-diagram-palette-colours-cycle-and-differ ()
  ;; GIVEN two given colour names, and none
  ;; WHEN indices 0, 1 and 2 ask for theirs
  ;; THEN the names cycle, AND derived colours are in range and differ
  (should (equal (canvas-diagram-palette-rgb 0 '("red" "green")) '(1.0 0.0 0.0)))
  (should (equal (canvas-diagram-palette-rgb 1 '("red" "green")) '(0.0 1.0 0.0)))
  (should (equal (canvas-diagram-palette-rgb 2 '("red" "green")) '(1.0 0.0 0.0)))
  (let ((canvas-diagram-palette "derived"))
    (let ((a (canvas-diagram-palette-rgb 0)) (b (canvas-diagram-palette-rgb 1)))
      (dolist (c (append a b))
        (should (<= 0.0 c 1.0)))
      (should-not (equal a b)))))

(ert-deftest canvas-diagram-palette-is-chosen-by-name ()
  ;; GIVEN a named palette of two colours
  ;; WHEN the first two colours are asked for under it, and under a name nobody has
  ;; THEN they are the palette's, AND the unknown palette is an error
  (let ((canvas-diagram-palettes '(("derived") ("two" "red" "green"))))
    (let ((canvas-diagram-palette "two"))
      (should (equal (canvas-diagram-palette-rgb 0) '(1.0 0.0 0.0)))
      (should (equal (canvas-diagram-palette-rgb 1) '(0.0 1.0 0.0))))
    (let ((canvas-diagram-palette "nope"))
      (should-error (canvas-diagram-palette-rgb 0)))))

(ert-deftest canvas-diagram-rgb-reads-x11-names-in-any-spelling ()
  ;; GIVEN an X11 colour written with a space, in capitals, and as one word
  ;; WHEN each is resolved, as in batch with no display
  ;; THEN all three are the same true colour, not a terminal's nearest one
  (let ((dark-orange (list 1.0 (/ 35980 65535.0) 0.0)))
    (should (equal (canvas-diagram-rgb "darkorange") dark-orange))
    (should (equal (canvas-diagram-rgb "dark orange") dark-orange))
    (should (equal (canvas-diagram-rgb "DarkOrange") dark-orange))))

(ert-deftest canvas-diagram-kind-colour-comes-from-the-alists ()
  ;; GIVEN "todo" configured red, "state" added by a package, and "zzz" nowhere
  ;; WHEN their outline colours are asked for
  ;; THEN todo is red, state is what the package said, AND the unknown kind
  ;;      takes the edge colour
  (let ((canvas-diagram-kinds '(("todo" . "red")))
        (canvas-diagram-extra-kinds '(("state" . "green")))
        (canvas-diagram-colors '(:edge "blue")))
    (should (equal (canvas-diagram-kind-rgb "todo") '(1.0 0.0 0.0)))
    (should (equal (canvas-diagram-kind-rgb "state") '(0.0 1.0 0.0)))
    (should (equal (canvas-diagram-kind-rgb "zzz") '(0.0 0.0 1.0)))))

(ert-deftest canvas-diagram-paper-overrides-the-theme-but-not-explicit-colours ()
  ;; GIVEN paper switched on and the theme's faces unset
  ;; WHEN the background is asked for, then again with an explicit colour
  ;; THEN paper is white, AND the explicit colour wins over paper
  (cl-letf (((symbol-function 'face-attribute) (lambda (&rest _) 'unspecified)))
    (let ((canvas-diagram-paper t) (canvas-diagram-colors nil))
      (should (equal (canvas-diagram-color :background) '(1.0 1.0 1.0)))
      (should (equal (canvas-diagram-color :text) '(0.0 0.0 0.0))))
    (let ((canvas-diagram-paper t) (canvas-diagram-colors '(:background "red")))
      (should (equal (canvas-diagram-color :background) '(1.0 0.0 0.0))))))

(ert-deftest canvas-diagram-family-keeps-the-frame-size ()
  ;; GIVEN a family chosen, with and without a display
  ;; WHEN the label font is asked for
  ;; THEN the family replaces the frame's, at the frame's pixel size,
  ;;      or the fallback's size in batch
  (let ((canvas-diagram-font nil) (canvas-diagram-family "Serif"))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'face-attribute) (lambda (&rest _) "DejaVu Sans"))
              ((symbol-function 'face-font) (lambda (&rest _) "-x-"))
              ((symbol-function 'font-info)
               (lambda (&rest _) (vector "o" "f" 15 17 0 0 0 0 13 4 5 8 "/f.ttf" nil))))
      (should (equal (canvas-diagram-font) "Serif 15px")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
      (should (equal (canvas-diagram-font) "Serif 14px")))))

(ert-deftest canvas-diagram-spacing-scales-the-padding ()
  ;; GIVEN the three spacings and a padding of 8
  ;; WHEN a length and the padding are spaced
  ;; THEN normal leaves them alone, airy widens, compact narrows
  (let ((canvas-diagram-padding 8))
    (cl-flet ((measures (spacing)
                (let ((canvas-diagram-spacing spacing))
                  (list (canvas-diagram-spaced 48) (canvas-diagram--padding)))))
      (should (equal (measures 'normal) '(48 8)))
      (cl-mapc (lambda (a n c) (should (> a n)) (should (> n c)))
               (measures 'airy) (measures 'normal) (measures 'compact)))))

(ert-deftest canvas-diagram-shape-sets-the-corner-radius ()
  ;; GIVEN a box 40 by 20
  ;; WHEN the corner is asked for under each shape
  ;; THEN square is sharp, pill is half the height, rounded the radius
  (let ((node (canvas-diagram-node-create :label "n" :w 40 :h 20))
        (canvas-diagram-radius 6))
    (let ((canvas-diagram-shape 'square)) (should (= (canvas-diagram-corner node) 0)))
    (let ((canvas-diagram-shape 'pill)) (should (= (canvas-diagram-corner node) 10.0)))
    (let ((canvas-diagram-shape 'rounded)) (should (= (canvas-diagram-corner node) 6)))))

(ert-deftest canvas-diagram-a-shape-of-its-own-sets-the-corner-of-one-box ()
  ;; GIVEN a box 40 by 20 in a drawing whose boxes are rounded
  ;; WHEN the corner is asked with a shape for that box alone
  ;; THEN that shape decides, no shape leaves the setting to decide, AND a
  ;;      shape that does not exist is an error that names it
  (let ((node (canvas-diagram-node-create :label "n" :w 40 :h 20))
        (canvas-diagram-radius 6)
        (canvas-diagram-shape 'rounded))
    (should (= (canvas-diagram-corner node 'square) 0))
    (should (= (canvas-diagram-corner node 'pill) 10.0))
    (should (= (canvas-diagram-corner node) 6))
    (should (string-search "blob" (error-message-string
                                   (should-error (canvas-diagram-corner node 'blob)))))))

(ert-deftest canvas-diagram-node-shape-callback-shapes-a-box ()
  ;; GIVEN a drawing whose `:node-shape' makes the box called "a" square and
  ;;       says nothing about "b", while the setting is pill
  ;; WHEN the corner of each box is asked through the drawing
  ;; THEN "a" is sharp and "b" keeps the setting, AND a drawing without the
  ;;      callback keeps it as well
  (let* ((a (canvas-diagram-node-create :label "a" :w 40 :h 20))
         (b (canvas-diagram-node-create :label "b" :w 40 :h 20))
         (canvas-diagram-shape 'pill)
         (shaped (canvas-diagram-create
                  :callbacks (list :node-shape
                                   (lambda (_diagram node)
                                     (and (equal (canvas-diagram-node-label node) "a") 'square)))))
         (plain (canvas-diagram-create :callbacks nil)))
    (should (= (canvas-diagram--node-corner shaped a) 0))
    (should (= (canvas-diagram--node-corner shaped b) 10.0))
    (should (= (canvas-diagram--node-corner plain a) 10.0))))

(ert-deftest canvas-diagram-the-ring-of-a-mark-follows-the-shape-of-its-box ()
  ;; GIVEN a marked box 60 by 24, in a drawing whose `:node-shape' makes it
  ;;       square, and in one that leaves it rounded
  ;; WHEN the marks are drawn
  ;; THEN the square ring has ink at the corner of the box, where the
  ;;      rounded ring leaves the paper clean
  (canvas-diagram-test--with-context ctx 200 100
    (let* ((canvas-diagram-colors (append '(:selection "red") canvas-diagram-colors))
           (canvas-diagram-shape 'rounded)
           (canvas-diagram-radius 8)
           (node (canvas-diagram-node-create :label "a" :x 40 :y 30 :w 60 :h 24))
           (square (canvas-diagram-create
                    :callbacks (list :node-shape (lambda (_diagram _node) 'square))))
           (rounded (canvas-diagram-create :callbacks nil))
           (x (round (- (canvas-diagram-node-x node) 3)))
           (y (round (- (canvas-diagram-node-y node) 3))))
      (canvas-cairo-clear ctx 1 1 1 1)
      (canvas-diagram--draw-marks square ctx (list node) 2)
      (canvas-cairo-flush ctx)
      (should (/= (canvas-cairo-pixel ctx x y) #xFFFFFFFF))
      (canvas-cairo-clear ctx 1 1 1 1)
      (canvas-diagram--draw-marks rounded ctx (list node) 2)
      (canvas-cairo-flush ctx)
      (should (= (canvas-cairo-pixel ctx x y) #xFFFFFFFF)))))

(ert-deftest canvas-diagram-legend-lists-the-packages-entries-then-the-kinds ()
  ;; GIVEN a row whose package lists one legend entry and whose nodes have a kind
  ;; WHEN the legend's entries are made
  ;; THEN the package's entry comes first, then the kind, outlined,
  ;;      AND with kinds off only the package's entry remains
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 4 4
     (let ((diagram (canvas-diagram-test--laid-out '(("a" :kind "todo") ("b")) ctx)))
       (should (equal (canvas-diagram--legend-entries diagram)
                      '(("row" (1.0 0.0 0.0) fill) ("todo" (1.0 0.0 0.0) outline))))
       (let ((canvas-diagram-show-kinds nil))
         (should (equal (canvas-diagram--legend-entries diagram) '(("row" (1.0 0.0 0.0) fill)))))))))

;;;; Rendering

(ert-deftest canvas-diagram-render-paints-boxes-edges-and-background ()
  ;; GIVEN a row of two, one of them green by the package's say
  ;; WHEN it is rendered
  ;; THEN the first box carries the node colour, the second the package's,
  ;;      the gap between them the edge colour, AND the far corner the background
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 300 200
     (let* ((canvas-diagram-colors '(:background "white" :node "blue" :text "black" :edge "red"))
            (diagram (canvas-diagram-test--laid-out '(("a") ("green")) ctx))
            (a (car (canvas-diagram-nodes diagram)))
            (g (cadr (canvas-diagram-nodes diagram))))
       (canvas-diagram--render diagram ctx '(300 . 200))
       (pcase-let ((`(,x . ,y) (canvas-diagram-test--inside a)))
         (should (= (canvas-cairo-pixel ctx x y) #xFF0000FF)))
       (pcase-let ((`(,x . ,y) (canvas-diagram-test--inside g)))
         (should (= (canvas-cairo-pixel ctx x y) #xFF00FF00)))
       (should (= (canvas-cairo-pixel ctx (+ 10 (canvas-diagram-node-w a) 15)
                                      (+ 10 (floor (canvas-diagram-middle-y a))))
                  #xFFFF0000))
       (should (= (canvas-cairo-pixel ctx 299 199) #xFFFFFFFF))))))

(ert-deftest canvas-diagram-render-outlines-a-kind-unless-kinds-are-off ()
  ;; GIVEN a node of kind "todo", configured red
  ;; WHEN the row is rendered with kinds on, then off
  ;; THEN its left edge is red, then the node colour
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 300 200
     (let* ((diagram (canvas-diagram-test--laid-out '(("a" :kind "todo")) ctx))
            (a (car (canvas-diagram-nodes diagram)))
            (x (+ 10 (round (canvas-diagram-node-x a))))
            (y (+ 10 (floor (canvas-diagram-middle-y a)))))
       (canvas-diagram--render diagram ctx '(300 . 200))
       (should (= (canvas-cairo-pixel ctx x y) #xFFFF0000))
       (should (= (canvas-cairo-pixel ctx (+ x 4) y) #xFF0000FF))
       (let ((canvas-diagram-show-kinds nil))
         (canvas-diagram--render diagram ctx '(300 . 200))
         (should (= (canvas-cairo-pixel ctx (1+ x) y) #xFF0000FF)))))))

(ert-deftest canvas-diagram-render-draws-the-legend-swatches ()
  ;; GIVEN a row with a legend entry and a kind
  ;; WHEN it is rendered on a canvas
  ;; THEN a legend sits in the bottom-left corner, its first swatch filled
  ;;      in the entry's colour, AND with the legend off that corner is background
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 300 200
     (let ((diagram (canvas-diagram-test--laid-out '(("a" :kind "todo") ("b")) ctx)))
       (canvas-diagram--render diagram ctx '(300 . 200))
       (let ((g (canvas-diagram--legend-geometry
                 ctx (canvas-diagram--legend-entries diagram) "Sans 12px" '(300 . 200))))
         (should (< (+ (plist-get g :y) (plist-get g :h)) 200))
         (pcase-let ((`(,x ,y) (canvas-diagram--legend-swatch g 0)))
           (should (= (canvas-cairo-pixel ctx (+ x 6) (+ y 6)) #xFFFF0000))))
       (let ((canvas-diagram-show-legend nil))
         (canvas-diagram--render diagram ctx '(300 . 200))
         (should (= (canvas-cairo-pixel ctx 20 185) #xFFFFFFFF)))))))

(ert-deftest canvas-diagram-export-size-makes-room-for-the-legend ()
  ;; GIVEN a row with a legend, and the legend switched off
  ;; WHEN the export size is computed
  ;; THEN the first is taller than its drawing by the legend, the second is its drawing
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 4 4
     (let ((diagram (canvas-diagram-test--laid-out '(("a") ("b")) ctx)))
       (should (> (cdr (canvas-diagram--export-size diagram ctx "Sans 12px"))
                  (cdr (canvas-diagram--map-size diagram))))
       (let ((canvas-diagram-show-legend nil))
         (should (equal (canvas-diagram--export-size diagram ctx "Sans 12px")
                        (canvas-diagram--map-size diagram))))))))

(ert-deftest canvas-diagram-popup-stays-inside-the-canvas ()
  ;; GIVEN a node whose card would hang past a small canvas's edges
  ;; WHEN the card's box is computed
  ;; THEN it is pushed back to the canvas's origin and keeps its size
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 4 4
     (let* ((diagram (canvas-diagram-test--laid-out '(("a") ("b" :note "a note")) ctx))
            (b (cadr (canvas-diagram-nodes diagram))))
       (pcase-let ((`(,x ,y ,w ,h) (canvas-diagram--popup-rect diagram ctx b "Sans 12px" '(0 . 0) '(100 . 50))))
         (should (= x 0))
         (should (= y 0))
         (should (= w canvas-diagram-popup-width))
         (should (> h 0)))))))

(ert-deftest canvas-diagram-render-with-popup-draws-the-card ()
  ;; GIVEN a node with a note and its card open
  ;; WHEN the row is rendered
  ;; THEN the card's area beside the node carries text
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 600 300
     (let* ((diagram (canvas-diagram-test--laid-out '(("a") ("b" :note "a note to read")) ctx))
            (b (cadr (canvas-diagram-nodes diagram))))
       (canvas-diagram--render diagram ctx '(600 . 300) '(0 . 0) b)
       (pcase-let ((`(,x ,y ,w ,h) (canvas-diagram--popup-rect diagram ctx b "Sans 12px" '(0 . 0) '(600 . 300))))
         (should (cl-loop for px from x below (+ x w) by 3
                          thereis (cl-loop for py from y below (+ y h) by 3
                                           thereis (canvas-diagram-test--dark-p (canvas-cairo-pixel ctx px py))))))))))

(ert-deftest canvas-diagram-thumbnail-scales-the-whole-drawing ()
  ;; GIVEN a laid-out row and a view onto part of it
  ;; WHEN a thumbnail of a given size is made over a white ground
  ;; THEN it has one pixel per cell, some of them inked,
  ;;      AND with a node selected its ring shows up too
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 4 4
     (let* ((diagram (canvas-diagram-test--laid-out '(("a") ("b")) ctx))
            (v (canvas-diagram--thumbnail diagram '(0 . 0) '(100 . 60) 40 30 #xFFFFFFFF)))
       (should (= (length v) (* 40 30)))
       (should (cl-some (lambda (px) (/= px #xFFFFFFFF)) v))
       (should-not (equal v (canvas-diagram--thumbnail diagram '(0 . 0) '(100 . 60) 40 30 #xFFFFFFFF
                                                       (car (canvas-diagram-nodes diagram)))))))))

(ert-deftest canvas-diagram-overlay-draws-in-view-coordinates ()
  ;; GIVEN a diagram whose package draws an overlay, scrolled and zoomed
  ;; WHEN it is rendered with a node selected
  ;; THEN the overlay is asked for after the drawing, with the view's size,
  ;;      offset, zoom and the selected node, AND what it draws at the
  ;;      view's corner lands there on the canvas
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 300 200
     (let* ((diagram (canvas-diagram-test--laid-out '(("a") ("b")) ctx))
            (b (cadr (canvas-diagram-nodes diagram))))
       (setq canvas-diagram-test--overlaid nil)
       (canvas-diagram--render diagram ctx '(300 . 200) '(7 . 3) nil b 1.4)
       (should (equal canvas-diagram-test--overlaid (list '(300 . 200) '(7 . 3) 1.4 b)))
       (should (= (canvas-cairo-pixel ctx 297 197) #xFFFF0000))))))

(ert-deftest canvas-diagram-module-draws-into-an-svg-or-pdf-file ()
  ;; GIVEN a context on an SVG file and one on a PDF file, 40 by 30
  ;; WHEN each is cleared and a box filled on it, and they are destroyed
  ;; THEN each file holds a drawing of its kind, the SVG in plain shapes
  ;;      with no compositing filter, the pixels of a file context cannot
  ;;      be read, AND a file of another kind is refused
  (let ((svg (make-temp-file "canvas-diagram-test" nil ".svg"))
        (pdf (make-temp-file "canvas-diagram-test" nil ".pdf")))
    (unwind-protect
        (progn
          (dolist (file (list svg pdf))
            (let ((ctx (canvas-cairo-file-context file 40 30)))
              (canvas-cairo-clear ctx 1 1 1 1)
              (canvas-cairo-set-color ctx 1 0 0 1)
              (canvas-cairo-rectangle ctx 5 5 20 10)
              (canvas-cairo-fill ctx)
              (should-error (canvas-cairo-pixel ctx 10 10))
              (canvas-cairo-destroy ctx)))
          (let ((text (with-temp-buffer (insert-file-contents svg) (buffer-string))))
            (should (string-match-p "<svg" text))
            (should (string-match-p "<path\\|<rect" text))
            (should-not (string-match-p "<filter" text)))
          (should (string-prefix-p "%PDF" (with-temp-buffer (insert-file-contents-literally pdf) (buffer-string))))
          (should-error (canvas-cairo-file-context "picture.bmp" 40 30)))
      (delete-file svg)
      (delete-file pdf))))

(ert-deftest canvas-diagram-export-writes-svg-and-pdf-by-the-file-name ()
  ;; GIVEN a row spec
  ;; WHEN it is exported to a .svg and to a .pdf
  ;; THEN each file holds a drawing of its kind with the labels in it
  (let ((svg (make-temp-file "canvas-diagram-test" nil ".svg"))
        (pdf (make-temp-file "canvas-diagram-test" nil ".pdf"))
        (canvas-diagram-font "Sans 12px"))
    (unwind-protect
        (progn
          (should (equal (canvas-diagram-export (canvas-diagram-test--row) '(("alpha") ("beta")) svg) svg))
          (should (string-match-p "<svg" (with-temp-buffer (insert-file-contents svg) (buffer-string))))
          (should (equal (canvas-diagram-export (canvas-diagram-test--row) '(("alpha") ("beta")) pdf) pdf))
          (should (string-prefix-p "%PDF" (with-temp-buffer (insert-file-contents-literally pdf) (buffer-string))))
          (should (> (file-attribute-size (file-attributes pdf)) 500)))
      (delete-file svg)
      (delete-file pdf))))

(ert-deftest canvas-diagram-write-saves-the-buffer-s-diagram-as-a-picture ()
  ;; GIVEN a diagram buffer showing a row, with a node selected
  ;; WHEN it is written to a .svg, as write-file would be
  ;; THEN the file holds the drawing, AND the buffer's own diagram, nodes
  ;;      and selection are as they were
  (let ((svg (make-temp-file "canvas-diagram-test" nil ".svg")))
    (unwind-protect
        (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
          (let ((nodes (canvas-diagram-nodes canvas-diagram--diagram))
                (b (cadr (canvas-diagram-nodes canvas-diagram--diagram))))
            (canvas-diagram--select b)
            (should (eq (key-binding (kbd "C-x C-w")) #'canvas-diagram-write))
            (should (equal (canvas-diagram-write svg) svg))
            (should (string-match-p "<svg" (with-temp-buffer (insert-file-contents svg) (buffer-string))))
            (should (eq (canvas-diagram-nodes canvas-diagram--diagram) nodes))
            (should (eq canvas-diagram--selected b))))
      (delete-file svg))))

(ert-deftest canvas-diagram-write-runs-the-package-s-own-export ()
  ;; GIVEN a diagram whose package exports its own way
  ;; WHEN the buffer is written
  ;; THEN that way is taken, with a copy of the diagram, the spec and the file
  (let ((got nil))
    (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
      (setf (canvas-diagram-callbacks canvas-diagram--diagram)
            (append (list :export (lambda (diagram spec file) (setq got (list diagram spec file)) file))
                    (canvas-diagram-callbacks canvas-diagram--diagram)))
      (should (equal (canvas-diagram-write "/tmp/nowhere.png") "/tmp/nowhere.png"))
      (should (and got (not (eq (car got) canvas-diagram--diagram))))
      (should (equal (cadr got) '(("a") ("b"))))
      (should (equal (caddr got) "/tmp/nowhere.png")))))

(ert-deftest canvas-diagram-export-writes-a-png ()
  ;; GIVEN a row spec
  ;; WHEN it is exported
  ;; THEN a PNG of some size is written, with no buffer involved
  (let ((png (make-temp-file "canvas-diagram-test" nil ".png"))
        (canvas-diagram-font "Sans 12px"))
    (unwind-protect
        (progn
          (should (equal (canvas-diagram-export (canvas-diagram-test--row) '(("a") ("b")) png) png))
          (should (canvas-diagram-test--png-p png))
          (should (> (file-attribute-size (file-attributes png)) 500)))
      (delete-file png))))

;;;; The buffer

(ert-deftest canvas-diagram-canvas-spec-is-not-auto-scaled ()
  ;; GIVEN a fresh canvas spec for a diagram
  ;; THEN it pins :scale to 1, so hot spots and clicks are in canvas pixels
  (should (equal (plist-get (cdr (canvas-diagram-make-canvas)) :scale) 1.0)))

(ert-deftest canvas-diagram-adopt-shows-the-drawing-on-its-canvas ()
  ;; GIVEN a diagram buffer
  ;; WHEN a row is adopted
  ;; THEN the buffer displays the very canvas the context draws on,
  ;;      the canvas is registered to the buffer for canvas-minimap,
  ;;      AND the keyboard is on the first node
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(200 . 100)
    (should (eq (get-text-property (point-min) 'display) canvas-diagram--canvas))
    (should (eq (gethash canvas-diagram--canvas canvas-diagram--buffers) (current-buffer)))
    (should (equal (canvas-diagram-test--selected) "a"))
    (should (equal (canvas-diagram-spec canvas-diagram--diagram) '(("a") ("b"))))))

(ert-deftest canvas-diagram-redraw-has-the-windows-updated ()
  ;; GIVEN a diagram buffer shown in a window
  ;; WHEN it is drawn again
  ;; THEN that window is marked for update, so the new pixels reach the
  ;;      screen without anything else having to change
  (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
    (let ((updated nil)
          (window (selected-window)))
      (set-window-buffer window (current-buffer))
      (cl-letf (((symbol-function 'force-window-update)
                 (lambda (&optional w) (push w updated))))
        (canvas-diagram-redraw))
      (should (memq window updated)))))

(ert-deftest canvas-diagram-scrolling-stops-at-the-drawing-edge ()
  ;; GIVEN a drawing larger than its canvas
  ;; WHEN it is scrolled far past the end and then home
  ;; THEN the offset stops where the far edge meets the canvas, then returns to zero
  (canvas-diagram-test--in-buffer '(("a long label") ("another long one") ("and a third")) '(100 . 20)
    (canvas-diagram--scroll-to '(5000 . 5000))
    (let ((map (canvas-diagram--view-extent)))
      (should (equal canvas-diagram--offset (cons (- (car map) 100) (- (cdr map) 20)))))
    (canvas-diagram-home)
    (should (equal canvas-diagram--offset '(0 . 0)))))

(ert-deftest canvas-diagram-click-toggles-the-card-and-selects ()
  ;; GIVEN a diagram buffer
  ;; WHEN a box is clicked, clicked again, and empty space is clicked
  ;; THEN its card opens, the keyboard is on it, the card closes, and stays closed
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
    (let* ((b (canvas-diagram-test--labelled "b"))
           (on-b (canvas-diagram-test--inside b)))
      (canvas-diagram--toggle-popup on-b)
      (should (eq canvas-diagram--popup b))
      (should (eq (canvas-diagram-selected) b))
      (canvas-diagram--toggle-popup on-b)
      (should-not canvas-diagram--popup)
      (canvas-diagram--toggle-popup '(299 . 199))
      (should-not canvas-diagram--popup))))

(ert-deftest canvas-diagram-return-toggles-the-selected-nodes-card ()
  ;; GIVEN the keyboard on a node
  ;; WHEN the card is toggled twice from the keyboard, then closed
  ;; THEN it opens, closes, AND closing a closed card is harmless
  (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
    (canvas-diagram-toggle-card)
    (should (eq canvas-diagram--popup (canvas-diagram-selected)))
    (canvas-diagram-toggle-card)
    (should-not canvas-diagram--popup)
    (canvas-diagram-toggle-card)
    (canvas-diagram-close-popup)
    (should-not canvas-diagram--popup)
    (canvas-diagram-close-popup)))

(ert-deftest canvas-diagram-open-callback-takes-the-place-of-the-card ()
  ;; GIVEN a diagram buffer whose package has an :open callback
  ;; WHEN RET is pressed on the first box, and the second box is clicked
  ;; THEN the callback gets each box, the keyboard is on the clicked box,
  ;;      AND no card opens
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
    (let ((opened nil))
      (setf (canvas-diagram-callbacks canvas-diagram--diagram)
            (append (list :open (lambda (_diagram node)
                                  (push (canvas-diagram-node-label node) opened)))
                    (canvas-diagram-callbacks canvas-diagram--diagram)))
      (canvas-diagram-toggle-card)
      (canvas-diagram--toggle-popup (canvas-diagram-test--inside (canvas-diagram-test--labelled "b")))
      (should (equal opened '("b" "a")))
      (should (equal (canvas-diagram-test--selected) "b"))
      (should-not canvas-diagram--popup))))

(ert-deftest canvas-diagram-keeps-every-common-canvas-key ()
  ;; GIVEN the mode map
  ;; WHEN canvas-keys is asked which common keys it binds to something else
  ;; THEN none is named: M-w is the common copy too, which copies the node
  ;;      the keyboard is on as the part a diagram copies, and the whole
  ;;      picture with a prefix, as in every canvas buffer
  ;; THEN the common keys are the canvas-keys commands, m among them: it
  ;;      shows and hides the map, and SPC opens the menu
  (let ((map (canvas-diagram-make-mode-map)))
    (should-not (canvas-keys-map-violations map))
    (pcase-dolist (`(,key . ,command)
                   '(("SPC" . canvas-keys-menu) ("W" . canvas-keys-write) ("M-w" . canvas-keys-copy-picture)
                     ("C" . canvas-keys-customize) ("w" . canvas-keys-toggle-paper)
                     ("F" . canvas-keys-cycle-family) ("l" . canvas-keys-toggle-legend)
                     ("m" . canvas-keys-toggle-minimap)
                     ("g" . revert-buffer) ("q" . quit-window)))
      (ert-info (key :prefix "Key: ")
        (should (eq (keymap-lookup map key) command))))))

(ert-deftest canvas-diagram-mouse-events-over-a-box-reach-the-same-commands ()
  ;; GIVEN the mode map, and that Emacs prefixes a mouse event over a hot
  ;;       spot with the spot's id
  ;; WHEN presses, wheel turns and a stray button are looked up with and
  ;;      without the prefix
  ;; THEN both forms of a press and a wheel turn reach the same command,
  ;;      a fast wheel turn too, a double click is the package's,
  ;;      AND a stray button over a box is swallowed
  (let ((map (canvas-diagram-make-mode-map)))
    (should (eq (lookup-key map [down-mouse-1]) #'canvas-diagram-mouse))
    (should (eq (lookup-key map [canvas-diagram-node down-mouse-1]) #'canvas-diagram-mouse))
    (should (eq (lookup-key map [canvas-diagram-node wheel-down]) #'canvas-diagram-scroll-down))
    (should (eq (lookup-key map [double-wheel-up]) #'canvas-diagram-scroll-up))
    (should (eq (lookup-key map [canvas-diagram-node triple-wheel-up]) #'canvas-diagram-scroll-up))
    (should (eq (lookup-key map [double-mouse-1]) #'canvas-diagram-double-click))
    (should (eq (lookup-key map [canvas-diagram-node double-mouse-1]) #'canvas-diagram-double-click))
    (should (eq (lookup-key map [canvas-diagram-node down-mouse-3] t) #'ignore))
    ;; Outside a box the press is `ignore' too, from the common canvas
    ;; keys, so that it does not take the button before the release opens
    ;; the menu.
    (should (eq (lookup-key map [down-mouse-3] t) #'ignore))))

(ert-deftest canvas-diagram-click-on-the-card-closes-it ()
  ;; GIVEN a diagram buffer with a card open
  ;; WHEN the card itself is clicked
  ;; THEN the card closes, even where a box lies under it
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(600 . 300)
    (canvas-diagram--toggle-popup (canvas-diagram-test--inside (canvas-diagram-test--labelled "a")))
    (should canvas-diagram--popup)
    (pcase-let ((`(,x ,y ,_ ,_) (canvas-diagram--popup-rect
                                 canvas-diagram--diagram canvas-diagram--context
                                 canvas-diagram--popup "Sans 12px" '(0 . 0) '(600 . 300))))
      (canvas-diagram--toggle-popup (cons (+ x 5) (+ y 5))))
    (should-not canvas-diagram--popup)))

(ert-deftest canvas-diagram-a-press-that-barely-moves-is-a-click ()
  ;; GIVEN a press and a release a couple of pixels apart, and one far apart
  ;; WHEN each is judged
  ;; THEN the first is a click AND the second a drag
  (let ((double-click-fuzz 3))
    (should (canvas-diagram--click-p '(10 . 10) '(12 . 11)))
    (should-not (canvas-diagram--click-p '(10 . 10) '(20 . 10)))))

(ert-deftest canvas-diagram-double-click-goes-to-the-package ()
  ;; GIVEN a diagram buffer with a card open
  ;; WHEN a double click lands on a box, and on nothing
  ;; THEN the package hears of the box, the card having closed,
  ;;      AND the empty double click is silent
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
    (let ((b (canvas-diagram-test--labelled "b")))
      (setq canvas-diagram-test--double-clicked nil)
      (canvas-diagram-toggle-card)
      (cl-letf (((symbol-function 'posn-object-x-y) (lambda (_) (canvas-diagram-test--inside b))))
        (canvas-diagram-double-click '(double-mouse-1 (nil))))
      (should (eq canvas-diagram-test--double-clicked b))
      (should-not canvas-diagram--popup)
      (setq canvas-diagram-test--double-clicked nil)
      (cl-letf (((symbol-function 'posn-object-x-y) (lambda (_) '(299 . 199))))
        (canvas-diagram-double-click '(double-mouse-1 (nil))))
      (should-not canvas-diagram-test--double-clicked))))

(ert-deftest canvas-diagram-draws-only-what-the-canvas-can-show ()
  ;; GIVEN the part of a drawing that a canvas shows, at a zoom and an offset
  ;; WHEN each box is held against that part
  ;; THEN a box inside it is drawn, and so is one that crosses its edge,
  ;;      AND a box outside it is left out, which is what keeps a drawing of
  ;;      hundreds of boxes quick to move about in
  (let ((box (lambda (x y) (canvas-diagram-node-create :label "n" :x x :y y :w 40 :h 20)))
        ;; The drawing asks with slack, since a box is drawn a little
        ;; larger than it is.
        (view (canvas-diagram--view-rect '(0 . 0) '(300 . 200) 1.0 canvas-diagram--view-slack)))
    (should (canvas-diagram--box-in-view-p (funcall box 10 10) view))
    (should (canvas-diagram--box-in-view-p (funcall box 10 195) view))
    (should (canvas-diagram--box-in-view-p (funcall box -30 10) view))
    (should-not (canvas-diagram--box-in-view-p (funcall box 10 900) view))
    (should-not (canvas-diagram--box-in-view-p (funcall box 900 10) view))
    ;; A closer zoom shows less of the drawing
    (should-not (canvas-diagram--box-in-view-p
                 (funcall box 10 180)
                 (canvas-diagram--view-rect '(0 . 0) '(300 . 200) 2.0 canvas-diagram--view-slack)))
    ;; A scrolled view shows another part of it
    (let ((down (canvas-diagram--view-rect '(0 . 400) '(300 . 200) 1.0 canvas-diagram--view-slack)))
      (should-not (canvas-diagram--box-in-view-p (funcall box 10 10) down))
      (should (canvas-diagram--box-in-view-p (funcall box 10 450) down)))))

(ert-deftest canvas-diagram-hot-spots-are-put-on-the-canvas ()
  ;; GIVEN a diagram buffer
  ;; WHEN its hot spots are synced
  ;; THEN the canvas spec carries one per node
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(300 . 200)
    (canvas-diagram--sync-hot-spots (current-buffer))
    (should (= (length (plist-get (cdr canvas-diagram--canvas) :map)) 3))))

;; `image-flush' with FRAME t frees an image from a cache that frames share,
;; but marks for a full redraw only the first frame that holds it.  A hidden
;; child frame, such as which-key-posframe's, can come first.  The frame that
;; shows the canvas then keeps a line that points at the freed image, and
;; Emacs crashes when it draws that line.

(ert-deftest canvas-diagram-flush-image-goes-through-the-frames-that-show-it ()
  ;; GIVEN a canvas that two graphic frames show
  ;; WHEN the canvas is flushed
  ;; THEN the flush goes through the first of them and not through every
  ;;      frame, AND the other one is redrawn, since the flush marks only the
  ;;      frame it goes through
  (let ((calls nil))
    (cl-letf (((symbol-function 'canvas-diagram--graphic-frames-showing)
               (lambda (_buffer) '(frame-a frame-b)))
              ((symbol-function 'image-flush)
               (lambda (spec frame) (push (list 'flush spec frame) calls)))
              ((symbol-function 'redraw-frame)
               (lambda (frame) (push (list 'redraw frame) calls))))
      (canvas-diagram-flush-image 'spec (current-buffer))
      (should (equal (nreverse calls) '((flush spec frame-a) (redraw frame-b)))))))

(ert-deftest canvas-diagram-flush-image-without-a-graphic-frame-flushes-everywhere ()
  ;; GIVEN a diagram buffer that only a text terminal frame shows, as in batch
  ;; WHEN its canvas is flushed
  ;; THEN no graphic frame shows it, AND the flush goes through every frame,
  ;;      since no frame draws the canvas
  (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
    (set-window-buffer (selected-window) (current-buffer))
    (should (get-buffer-window-list (current-buffer) nil t))
    (should-not (canvas-diagram--graphic-frames-showing (current-buffer)))
    (let ((calls nil))
      (cl-letf (((symbol-function 'image-flush) (lambda (spec frame) (push (list spec frame) calls))))
        (canvas-diagram-flush-image canvas-diagram--canvas (current-buffer))
        (should (equal calls (list (list canvas-diagram--canvas t))))))))

(ert-deftest canvas-diagram-fitting-and-hot-spots-flush-through-the-frames ()
  ;; GIVEN a diagram buffer
  ;; WHEN its canvas is fitted to a window, and its hot spots are synced
  ;; THEN both drop the old image-cache entry with `canvas-diagram-flush-image'
  (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
    (let ((flushed nil))
      (cl-letf (((symbol-function 'canvas-diagram-flush-image)
                 (lambda (spec buffer) (push (list spec buffer) flushed))))
        (canvas-diagram--fit-window (selected-window))
        (canvas-diagram--sync-hot-spots (current-buffer))
        (should (equal flushed (make-list 2 (list canvas-diagram--canvas (current-buffer)))))))))

(ert-deftest canvas-diagram-hot-spots-flush-only-when-they-change ()
  ;; GIVEN a diagram buffer whose hot spots are on its canvas
  ;; WHEN the keyboard moves to another box without scrolling, and the hot
  ;;      spots are synced again
  ;; THEN nothing is flushed, AND the canvas keeps its map
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(300 . 200)
    (canvas-diagram--sync-hot-spots (current-buffer))
    (let ((map (plist-get (cdr canvas-diagram--canvas) :map))
          (flushed 0))
      (cl-letf (((symbol-function 'canvas-diagram-flush-image)
                 (lambda (_spec _buffer) (cl-incf flushed))))
        (canvas-diagram-go (canvas-diagram-test--labelled "b"))
        (canvas-diagram--sync-hot-spots (current-buffer))
        (should (= flushed 0))
        (should (eq (plist-get (cdr canvas-diagram--canvas) :map) map))

        ;; WHEN the view scrolls, and the hot spots are synced again
        ;; THEN the canvas is flushed once, AND its map follows the offset
        (setq canvas-diagram--offset '(10 . 0))
        (canvas-diagram--sync-hot-spots (current-buffer))
        (should (= flushed 1))
        (should (equal (plist-get (cdr canvas-diagram--canvas) :map)
                       (canvas-diagram--hot-spots (canvas-diagram-nodes-shown) '(10 . 0)
                                                  canvas-diagram--zoom)))))))

(ert-deftest canvas-diagram-thumbnail-hook-serves-its-own-canvas-only ()
  ;; GIVEN a diagram buffer
  ;; WHEN canvas-minimap asks for a thumbnail of its canvas, twice, and of another image
  ;; THEN it gets the drawing's pixels, the same vector the second time, and nil for the stranger
  (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
    (let ((first (canvas-diagram-thumbnail canvas-diagram--canvas 40 30 #xFFFFFFFF)))
      (should (= (length first) 1200))
      (should (eq first (canvas-diagram-thumbnail canvas-diagram--canvas 40 30 #xFFFFFFFF)))
      (should-not (canvas-diagram-thumbnail '(image :type png :file "x.png") 40 30 0)))))

(ert-deftest canvas-diagram-header-line-is-the-packages ()
  ;; GIVEN a diagram buffer with the keyboard on a node
  ;; THEN the header line says what the package says of it
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
    (canvas-diagram--select (canvas-diagram-test--labelled "b"))
    (should (equal (canvas-diagram--header) "row: b"))
    (should (equal header-line-format '(:eval (canvas-diagram--header))))))

(ert-deftest canvas-diagram-a-build-that-signals-leaves-nothing-behind ()
  ;; GIVEN a diagram buffer with the keyboard on a node
  ;; WHEN it adopts a diagram whose `:build' signals, as a reader of a
  ;;      file that is half written does
  ;; THEN the buffer holds no diagram AND no selection
  ;;      AND the header line says nothing rather than signalling, since
  ;;      redisplay would raise the same error again and again
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
    (canvas-diagram--select (canvas-diagram-test--labelled "b"))
    (let ((broken (canvas-diagram-create
                   :callbacks (list :build (lambda (&rest _)
                                             (error "canvas-diagram-test: nothing to build"))))))
      (should-error (canvas-diagram-adopt broken '(("a"))))
      (should-not canvas-diagram--diagram)
      (should-not (canvas-diagram-selected))
      (should (equal (canvas-diagram--header) "")))))

;;;; Keyboard navigation

(ert-deftest canvas-diagram-moves-go-where-the-package-says ()
  ;; GIVEN a row of three with the keyboard on the first
  ;; WHEN it moves in twice, out once, to the last, the first
  ;; THEN it follows the row, AND a direction leading nowhere holds
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(600 . 200)
    (canvas-diagram-move-in)
    (should (equal (canvas-diagram-test--selected) "b"))
    (canvas-diagram-move-next)
    (should (equal (canvas-diagram-test--selected) "c"))
    (canvas-diagram-move-next)
    (should (equal (canvas-diagram-test--selected) "c"))
    (canvas-diagram-move-out)
    (should (equal (canvas-diagram-test--selected) "b"))
    (canvas-diagram-move-last)
    (should (equal (canvas-diagram-test--selected) "c"))
    (canvas-diagram-move-first)
    (should (equal (canvas-diagram-test--selected) "a"))
    (canvas-diagram-move-previous)
    (should (equal (canvas-diagram-test--selected) "a"))))

(ert-deftest canvas-diagram-jump-goes-to-a-node-by-name ()
  ;; GIVEN a row and a name chosen with completion
  ;; WHEN the keyboard jumps to it
  ;; THEN that node is selected, and an unknown name is a user error
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(600 . 200)
    (canvas-diagram-jump "c")
    (should (equal (canvas-diagram-test--selected) "c"))
    (should-error (canvas-diagram-jump "nowhere") :type 'user-error)))

(ert-deftest canvas-diagram-select-tells-the-package-where-the-keyboard-is ()
  ;; GIVEN a row of three, AND a :select callback that notes the label it
  ;;       is given and the label the keyboard is on at that moment
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(600 . 200)
    (let (seen)
      (canvas-diagram-test--add-callbacks
       :select (lambda (_diagram node)
                 (push (list (canvas-diagram-node-label node) (canvas-diagram-test--selected))
                       seen)))
      ;; WHEN the keyboard moves to the next node and then to the last
      (canvas-diagram-move-next)
      (canvas-diagram-move-last)
      ;; THEN the package hears of each move, once the keyboard is there
      (should (equal (reverse seen) '(("b" "b") ("c" "c"))))
      ;; WHEN the diagram is rebuilt
      (setq seen nil)
      (canvas-diagram-rebuild)
      ;; THEN the package hears of the node the keyboard stays on
      (should (equal seen '(("c" "c")))))))

(ert-deftest canvas-diagram-go-tells-the-package-of-a-move-and-of-nothing-else ()
  ;; GIVEN a row of three, AND a :go callback that notes the label it is
  ;;       given and the label the keyboard is on at that moment
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(600 . 200)
    (let (seen)
      (canvas-diagram-test--add-callbacks
       :go (lambda (_diagram node)
             (push (list (canvas-diagram-node-label node) (canvas-diagram-test--selected))
                   seen)))
      ;; WHEN the keyboard moves to the next node, and then jumps to "c" by name
      (canvas-diagram-move-next)
      (canvas-diagram-jump "c")
      ;; THEN the package hears of both, once the keyboard is there
      (should (equal (reverse seen) '(("b" "b") ("c" "c"))))
      ;; WHEN the diagram is rebuilt, and a move leads nowhere
      (setq seen nil)
      (canvas-diagram-rebuild)
      (canvas-diagram-move-next)
      ;; THEN the package hears of neither
      (should-not seen))))

(ert-deftest canvas-diagram-selection-is-ringed-on-the-canvas ()
  ;; GIVEN the keyboard on a node, with a selection colour configured
  ;; WHEN the drawing is drawn
  ;; THEN a pixel just outside the box carries that colour, AND a pixel
  ;;      further out carries its halo, blended with the ground
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
    (let* ((canvas-diagram-colors (append '(:selection "yellow") canvas-diagram-colors))
           (b (canvas-diagram-test--labelled "b"))
           (y (+ 10 (floor (canvas-diagram-middle-y b)))))
      (canvas-diagram--select b)
      (should (= (canvas-cairo-pixel canvas-diagram--context (+ 10 (round (canvas-diagram-node-x b)) -3) y)
                 #xFFFFFF00))
      (let* ((cx (+ 10 (round (canvas-diagram-middle-x b))))
             (top (+ 10 (round (canvas-diagram-node-y b))))
             (ring (canvas-cairo-pixel canvas-diagram--context cx (- top 3)))
             (halo (canvas-cairo-pixel canvas-diagram--context cx (- top 6))))
        (should (= ring #xFFFFFF00))
        (should-not (= halo #xFFFFFFFF))
        (should-not (= halo #xFFFFFF00))))))

(ert-deftest canvas-diagram-recenter-puts-the-keyboard-in-the-middle ()
  ;; GIVEN a long row in a small canvas with the keyboard on a far node
  ;; WHEN the view is recentred, as C-l would
  ;; THEN that node's box is centred on the canvas, as far as the drawing allows
  ;;      AND recenter is what the recenter keys run
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c") ("d") ("e") ("f")) '(100 . 50)
    (canvas-diagram-home)
    (canvas-diagram-set-selected (canvas-diagram-test--labelled "d"))
    (canvas-diagram-recenter)
    (pcase-let ((`(,x0 ,_ ,x1 ,_) (canvas-diagram--canvas-box (canvas-diagram-selected)
                                                              canvas-diagram--offset 1.0)))
      (should (< (abs (- (/ (+ x0 x1) 2.0) 50)) 2)))
    (should (eq (lookup-key canvas-diagram-mode-map [remap recenter-top-bottom]) #'canvas-diagram-recenter))))

(ert-deftest canvas-diagram-off-screen-selection-is-centred-a-visible-one-nudged ()
  ;; GIVEN a long row in a small canvas showing its start
  ;; WHEN the keyboard moves to a node that lies off the canvas
  ;; THEN the view centres on that node
  ;; WHEN it then moves to a neighbour that is partly in view
  ;; THEN the view only nudges it inside
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c") ("d") ("e") ("f")) '(100 . 50)
    (canvas-diagram-home)
    (let ((d (canvas-diagram-test--labelled "d")))
      (should-not (canvas-diagram--in-view-p d))
      (canvas-diagram--select d)
      (pcase-let ((`(,x0 ,_ ,x1 ,_) (canvas-diagram--canvas-box d canvas-diagram--offset 1.0)))
        (should (< (abs (- (/ (+ x0 x1) 2.0) 50)) 2))))
    (let* ((e (canvas-diagram-test--labelled "e"))
           (nudged (canvas-diagram--clamp-offset
                    (canvas-diagram--revealing-offset e canvas-diagram--offset '(100 . 50) 1.0)
                    (canvas-diagram--view-extent) '(100 . 50))))
      (should (canvas-diagram--in-view-p e))
      (canvas-diagram-move-next)
      (should (eq (canvas-diagram-selected) e))
      (should (equal canvas-diagram--offset nudged)))))

(ert-deftest canvas-diagram-point-movement-is-remapped-to-moves ()
  ;; GIVEN the mode map
  ;; WHEN the commands that move point are looked up as remaps
  ;; THEN each is a move command, so the user's own movement keys work,
  ;;      AND the plain letters do the same as their control versions
  (let ((map (canvas-diagram-make-mode-map)))
    (should (eq (lookup-key map [remap next-line]) #'canvas-diagram-move-next))
    (should (eq (lookup-key map [remap forward-char]) #'canvas-diagram-move-in))
    (should (eq (lookup-key map [remap backward-char]) #'canvas-diagram-move-out))
    (should (eq (lookup-key map [remap beginning-of-buffer]) #'canvas-diagram-move-first))
    (should (eq (lookup-key map [remap goto-line]) #'canvas-diagram-jump))
    (should (eq (lookup-key map (kbd "n")) #'canvas-diagram-move-next))
    (should (eq (lookup-key map (kbd "p")) #'canvas-diagram-move-previous))
    (should (eq (lookup-key map (kbd "f")) #'canvas-diagram-move-in))
    (should (eq (lookup-key map (kbd "b")) #'canvas-diagram-move-out))
    (should (eq (lookup-key map (kbd "^")) #'canvas-diagram-move-out))
    (should (eq (lookup-key map (kbd "M-n")) #'canvas-diagram-move-next-at-depth))
    (should (eq (lookup-key map [remap backward-up-list]) #'canvas-diagram-move-out))
    (should (eq (lookup-key map [remap down-list]) #'canvas-diagram-move-in))
    (should (eq (lookup-key map [remap forward-sexp]) #'canvas-diagram-move-next-sibling))
    (should (eq (lookup-key map [remap backward-list]) #'canvas-diagram-move-previous-sibling))
    (should (eq (lookup-key map [remap beginning-of-defun]) #'canvas-diagram-move-branch))
    (should (eq (lookup-key map [remap end-of-defun]) #'canvas-diagram-move-next-branch))
    (should (eq (lookup-key map [remap consult-goto-line]) #'canvas-diagram-jump))
    (should (eq (lookup-key map (kbd "RET")) #'canvas-diagram-toggle-card))
    (should (eq (lookup-key map (kbd "C-<return>")) #'canvas-diagram-visit-source))
    (should (eq (lookup-key map (kbd "g")) #'revert-buffer))))

;;;; Settings, zoom and the menu

(ert-deftest canvas-diagram-cycle-goes-round-the-values ()
  ;; GIVEN a setting on the middle of three values, and one on none of them
  ;; WHEN each is cycled
  ;; THEN the first moves on and wraps, the second starts from the first value
  (let ((canvas-diagram-shape 'square))
    (canvas-diagram--cycle 'canvas-diagram-shape '(rounded square pill))
    (should (eq canvas-diagram-shape 'pill))
    (canvas-diagram--cycle 'canvas-diagram-shape '(rounded square pill))
    (should (eq canvas-diagram-shape 'rounded)))
  (let ((canvas-diagram-shape 'odd))
    (canvas-diagram--cycle 'canvas-diagram-shape '(rounded square pill))
    (should (eq canvas-diagram-shape 'rounded))))

(ert-deftest canvas-diagram-changing-a-setting-relays-out-around-the-selection ()
  ;; GIVEN a diagram buffer with the keyboard on a node
  ;; WHEN the spacing is cycled to airy
  ;; THEN the node is still selected and the boxes are wider
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(600 . 300)
    (let* ((b (canvas-diagram-test--labelled "b"))
           (w (canvas-diagram-node-w b)))
      (canvas-diagram--select b)
      (canvas-diagram-cycle-spacing)
      (should (eq canvas-diagram-spacing 'airy))
      (should (eq (canvas-diagram-selected) b))
      (should (> (canvas-diagram-node-w b) w)))))

(defun canvas-diagram-test--fresh-boxes-layout (&optional without)
  "A row layout that makes new boxes every time, as a package's may.
The box labelled WITHOUT is left out."
  (lambda (diagram ctx)
    (cl-remove without
               (mapcar #'copy-canvas-diagram-node (canvas-diagram-test--row-layout diagram ctx))
               :key #'canvas-diagram-node-label :test #'equal)))

(ert-deftest canvas-diagram-relayout-keeps-the-keyboard-and-the-card-on-their-boxes ()
  ;; GIVEN a row whose layout makes new boxes every time, the keyboard on
  ;;       the second box and the card of the third open
  ;; WHEN it is laid out again, as toggling a look does
  ;; THEN the keyboard and the card are on the new boxes of those labels,
  ;;      AND the card is not left on a box of the old layout
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(600 . 300)
    (canvas-diagram-test--add-callbacks :layout (canvas-diagram-test--fresh-boxes-layout))
    (canvas-diagram-relayout)
    (canvas-diagram--select (canvas-diagram-test--labelled "b"))
    (setq canvas-diagram--popup (canvas-diagram-test--labelled "c"))
    (let ((old-card canvas-diagram--popup))
      (canvas-diagram-relayout)
      (should (equal (canvas-diagram-test--selected) "b"))
      (should (memq (canvas-diagram-selected) (canvas-diagram-nodes-shown)))
      (should (eq canvas-diagram--popup (canvas-diagram-test--labelled "c")))
      (should-not (eq canvas-diagram--popup old-card)))))

(ert-deftest canvas-diagram-relayout-closes-a-card-whose-box-is-gone ()
  ;; GIVEN a row with the keyboard on its third box and that box's card open
  ;; WHEN it is laid out again without that box
  ;; THEN the card is closed, AND the keyboard is on the first box
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(600 . 300)
    (canvas-diagram-test--add-callbacks :layout (canvas-diagram-test--fresh-boxes-layout))
    (canvas-diagram-relayout)
    (canvas-diagram--select (canvas-diagram-test--labelled "c"))
    (setq canvas-diagram--popup (canvas-diagram-test--labelled "c"))
    (canvas-diagram-test--add-callbacks :layout (canvas-diagram-test--fresh-boxes-layout "c"))
    (canvas-diagram-relayout)
    (should-not canvas-diagram--popup)
    (should (equal (canvas-diagram-test--selected) "a"))))

(ert-deftest canvas-diagram-rebuild-keeps-the-keyboard-on-its-node ()
  ;; GIVEN a diagram buffer with the keyboard on the second node
  ;; WHEN the spec gains a node and the diagram is rebuilt
  ;; THEN the new node is there, the keyboard still on its label,
  ;;      AND a node that vanished leaves the keyboard on the first
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(600 . 300)
    (canvas-diagram--select (canvas-diagram-test--labelled "b"))
    (setf (canvas-diagram-spec canvas-diagram--diagram) '(("a") ("b") ("c")))
    (canvas-diagram-rebuild)
    (should (= (length (canvas-diagram-nodes-shown)) 3))
    (should (equal (canvas-diagram-test--selected) "b"))
    (setf (canvas-diagram-spec canvas-diagram--diagram) '(("a") ("c")))
    (canvas-diagram-rebuild)
    (should (equal (canvas-diagram-test--selected) "a"))))

(defun canvas-diagram-test--canvas-centre (label)
  "The middle of the box labelled LABEL on the canvas, as it is scrolled now."
  (pcase-let ((`(,x0 ,y0 ,x1 ,y1) (canvas-diagram--canvas-box (canvas-diagram-test--labelled label)
                                                              canvas-diagram--offset canvas-diagram--zoom)))
    (cons (/ (+ x0 x1) 2.0) (/ (+ y0 y1) 2.0))))

(ert-deftest canvas-diagram-rebuild-keeps-the-keyboard-s-node-in-its-place ()
  ;; GIVEN a diagram buffer on a narrow canvas, with the keyboard on "f",
  ;;       scrolled so that "f" is off the middle of the canvas
  ;; WHEN the spec gains a wide node before "f" and the diagram is rebuilt
  ;; THEN "f" lies further right in the drawing, AND the middle of its box
  ;;      is where it was on the canvas
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c") ("d") ("e") ("f") ("g") ("h")) '(200 . 60)
    (canvas-diagram--select (canvas-diagram-test--labelled "f"))
    (canvas-diagram--scroll-by -40 0)
    (let ((x (canvas-diagram-node-x (canvas-diagram-test--labelled "f")))
          (before (canvas-diagram-test--canvas-centre "f")))
      (setf (canvas-diagram-spec canvas-diagram--diagram)
            '(("a new and rather wide node") ("a") ("b") ("c") ("d") ("e") ("f") ("g") ("h")))
      (canvas-diagram-rebuild)
      (let ((after (canvas-diagram-test--canvas-centre "f")))
        (should (> (canvas-diagram-node-x (canvas-diagram-test--labelled "f")) x))
        (should (< (abs (- (car after) (car before))) 1.0))
        (should (< (abs (- (cdr after) (cdr before))) 1.0))))))

(defun canvas-diagram-test--rebuild-as (spec)
  "Rebuild this buffer's diagram from SPEC."
  (setf (canvas-diagram-spec canvas-diagram--diagram) spec)
  (canvas-diagram-rebuild))

(ert-deftest canvas-diagram-slide-eases-out ()
  ;; GIVEN the start, the middle and the end of a slide
  ;; WHEN each is eased
  ;; THEN the start is 0, the end is 1, AND the middle is well past half way
  (should (= (canvas-diagram--ease 0.0) 0.0))
  (should (= (canvas-diagram--ease 1.0) 1.0))
  (should (= (canvas-diagram--ease 0.5) 0.875)))

(ert-deftest canvas-diagram-rebuild-slides-a-box-from-its-old-place ()
  ;; GIVEN a diagram buffer with the keyboard on "b", before "c", and a
  ;;       slide of 0.2 seconds
  (canvas-diagram-test--in-buffer '(("b") ("c")) '(600 . 60)
    (let ((canvas-diagram-animate 0.2))
      (canvas-diagram--select (canvas-diagram-test--labelled "b"))
      (let ((before (canvas-diagram-test--canvas-centre "c"))
            drawn)
        ;; WHEN a wide node comes between them and the diagram is rebuilt
        (canvas-diagram-test--rebuild-as '(("b") ("a wide new node") ("c")))
        ;; THEN a slide runs, a redraw at its start draws "c" where it was,
        ;;      AND "c" lies further right once the frame is drawn
        (should canvas-diagram--slide)
        (setf (plist-get canvas-diagram--slide :start) (float-time))
        (cl-letf (((symbol-function 'canvas-diagram--render)
                   (lambda (&rest _) (setq drawn (canvas-diagram-test--canvas-centre "c")))))
          (canvas-diagram-redraw))
        (should (< (abs (- (car drawn) (car before))) 1.0))
        (should (> (car (canvas-diagram-test--canvas-centre "c")) (+ (car before) 1.0)))))))

(ert-deftest canvas-diagram-rebuild-does-not-slide-when-off-or-when-nothing-moves ()
  ;; GIVEN a diagram buffer of "b" and "c"
  (canvas-diagram-test--in-buffer '(("b") ("c")) '(600 . 60)
    ;; WHEN it is rebuilt with a wide node before them and the slide off
    (let ((canvas-diagram-animate nil))
      (canvas-diagram-test--rebuild-as '(("a wide new node") ("b") ("c"))))
    ;; THEN no slide runs
    (should-not canvas-diagram--slide)
    ;; WHEN it is rebuilt from the same spec with the slide on
    (let ((canvas-diagram-animate 0.2))
      (canvas-diagram-test--rebuild-as '(("a wide new node") ("b") ("c"))))
    ;; THEN no slide runs either, as no box moved
    (should-not canvas-diagram--slide)))

(ert-deftest canvas-diagram-a-command-the-last-frame-or-a-release-ends-the-slide ()
  ;; GIVEN a diagram buffer with the keyboard on "b", and a slide of 0.2 seconds
  (canvas-diagram-test--in-buffer '(("b") ("c")) '(600 . 60)
    (let ((canvas-diagram-animate 0.2))
      (canvas-diagram--select (canvas-diagram-test--labelled "b"))
      ;; WHEN a rebuild starts a slide, and a command starts
      (canvas-diagram-test--rebuild-as '(("b") ("a wide new node") ("c")))
      (let ((timer (plist-get canvas-diagram--slide :timer)))
        (run-hooks 'pre-command-hook)
        ;; THEN the slide is over, AND its timer is cancelled
        (should-not canvas-diagram--slide)
        (should-not (memq timer timer-list)))
      ;; WHEN another rebuild starts a slide, and its frame comes after its time
      (canvas-diagram-test--rebuild-as '(("b") ("c")))
      (let ((timer (plist-get canvas-diagram--slide :timer)))
        (setf (plist-get canvas-diagram--slide :start) (- (float-time) 1))
        (canvas-diagram--slide-frame (current-buffer) (list timer))
        ;; THEN the slide is over, AND its timer is cancelled
        (should-not canvas-diagram--slide)
        (should-not (memq timer timer-list)))
      ;; WHEN a third rebuild starts a slide, and the buffer lets go of its diagram
      (canvas-diagram-test--rebuild-as '(("b") ("a wide new node") ("c")))
      (let ((timer (plist-get canvas-diagram--slide :timer)))
        (canvas-diagram--release)
        ;; THEN the slide is over, AND its timer is cancelled
        (should-not canvas-diagram--slide)
        (should-not (memq timer timer-list))))))

(ert-deftest canvas-diagram-a-node-slides-from-the-old-box-restore-finds-it-by ()
  ;; GIVEN a diagram buffer of "a" and "b", whose package finds "B" by the
  ;;       old key "b", and a slide of 0.2 seconds
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(600 . 60)
    (canvas-diagram-test--add-callbacks
     :restore (lambda (diagram key) (canvas-diagram--node-by-key diagram (if (equal key "b") "B" key))))
    (let ((canvas-diagram-animate 0.2)
          (before (canvas-diagram-test--canvas-centre "b")))
      ;; WHEN the spec becomes "a", a wide node and "B", and the diagram is rebuilt
      (canvas-diagram-test--rebuild-as '(("a") ("a wide new node") ("B")))
      ;; THEN "B" slides from where "b" was on the canvas, AND the new node,
      ;;      which no old key finds, does not slide
      (let ((froms (plist-get canvas-diagram--slide :froms)))
        (should (equal (cdr (assq (canvas-diagram-test--labelled "B") froms))
                       (canvas-diagram--map-point before canvas-diagram--offset canvas-diagram--zoom)))
        (should-not (assq (canvas-diagram-test--labelled "a wide new node") froms))))))

(ert-deftest canvas-diagram-zoom-steps-through-the-factors-and-keeps-the-centre ()
  ;; GIVEN a diagram buffer at natural size, scrolled into a long row
  ;; WHEN it zooms in, in again past the end, out, and back to natural size
  ;; THEN the zoom follows the factor list and stops at its end,
  ;;      AND the drawing point at the canvas's centre stays put through it
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c") ("d") ("e") ("f")) '(120 . 60)
    (canvas-diagram--scroll-to '(40 . 0))
    (let ((centre (canvas-diagram--map-point '(60 . 30) canvas-diagram--offset canvas-diagram--zoom)))
      (canvas-diagram-zoom-in)
      (should (= canvas-diagram--zoom 1.4))
      (let ((after (canvas-diagram--map-point '(60 . 30) canvas-diagram--offset canvas-diagram--zoom)))
        (should (< (abs (- (car after) (car centre))) 1.0)))
      (dotimes (_ 10) (canvas-diagram-zoom-in))
      (should (= canvas-diagram--zoom 4.0))
      (canvas-diagram-zoom-out)
      (should (= canvas-diagram--zoom 2.8))
      (canvas-diagram-zoom-reset)
      (should (= canvas-diagram--zoom 1.0)))))

(ert-deftest canvas-diagram-zoom-tells-the-package-and-can-be-set ()
  ;; GIVEN a diagram buffer whose package listens for the zoom
  ;; WHEN it zooms in, and is then set to a zoom from outside
  ;; THEN the package hears each zoom, AND the zoom asked for is the one
  ;;      it is drawn at
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(120 . 60)
    (let (heard)
      (setf (canvas-diagram-callbacks canvas-diagram--diagram)
            (append (list :zoom (lambda (_d zoom) (push zoom heard)))
                    (canvas-diagram-callbacks canvas-diagram--diagram)))
      (canvas-diagram-zoom-in)
      (canvas-diagram-zoom-to 2.0)
      (should (= (canvas-diagram-current-zoom) 2.0))
      (should (equal (nreverse heard) '(1.4 2.0))))))

(ert-deftest canvas-diagram-zoom-fit-shows-the-whole-drawing ()
  ;; GIVEN a diagram buffer whose drawing is far wider than its canvas, so
  ;;       that fitting takes a zoom below the smallest step
  ;; WHEN it zooms to fit
  ;; THEN the drawing with its margins is no larger than the canvas, from its origin,
  ;;      AND zooming in then goes to the smallest step, zooming out stays
  (canvas-diagram-test--in-buffer '(("a long label") ("another long one") ("and a third") ("more") ("and more")) '(60 . 30)
    (canvas-diagram-zoom-fit)
    (should (< canvas-diagram--zoom 0.25))
    (should (equal canvas-diagram--offset '(0 . 0)))
    (let ((extent (canvas-diagram--view-extent)))
      (should (<= (car extent) 60))
      (should (<= (cdr extent) 30)))
    (let ((fit canvas-diagram--zoom))
      (canvas-diagram-zoom-out)
      (should (= canvas-diagram--zoom fit))
      (canvas-diagram-zoom-in)
      (should (= canvas-diagram--zoom 0.25)))))

(ert-deftest canvas-diagram-the-common-zoom-keys-zoom-the-diagram ()
  ;; GIVEN a diagram buffer at its natural size
  ;; WHEN the common keys zoom in, out and back
  ;; THEN the diagram's own zoom changes each time, and 0 brings it back to 1
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(600 . 300)
    (should (= canvas-diagram--zoom 1))
    (canvas-keys-zoom-in)
    (should (> canvas-diagram--zoom 1))
    (canvas-keys-zoom-out)
    (canvas-keys-zoom-out)
    (should (< canvas-diagram--zoom 1))
    (canvas-keys-zoom-reset)
    (should (= canvas-diagram--zoom 1))
    (should-error (canvas-diagram--zoom-by-key 'sideways))))

(ert-deftest canvas-diagram-zoom-reset-keeps-the-keyboard-in-view ()
  ;; GIVEN a long row fitted into a small canvas with the keyboard on the last node
  ;; WHEN the zoom goes back to natural size
  ;; THEN the zoom is 100% AND that node's box lies within the canvas
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c") ("d") ("e") ("the far one")) '(200 . 60)
    (canvas-diagram-move-last)
    (canvas-diagram-zoom-fit)
    (canvas-diagram-zoom-reset)
    (should (= canvas-diagram--zoom 1.0))
    (pcase-let ((`(,x0 ,y0 ,x1 ,y1) (canvas-diagram--canvas-box (canvas-diagram-selected)
                                                                canvas-diagram--offset 1.0)))
      (should (>= x0 0))
      (should (>= y0 0))
      (should (<= x1 200))
      (should (<= y1 60)))))

(ert-deftest canvas-diagram-zoom-is-on-the-text-scale-keys-and-the-menu ()
  ;; GIVEN the mode map and a menu made with the shared macro
  ;; THEN the text-scale commands are remapped to zoom, +, - and 0 zoom too,
  ;;      AND the menu has the zoom keys
  (let ((map (canvas-diagram-make-mode-map)))
    (should (eq (lookup-key map [remap text-scale-increase]) #'canvas-diagram-zoom-in))
    (should (eq (lookup-key map [remap text-scale-decrease]) #'canvas-diagram-zoom-out))
    ;; +, - and 0 are the common canvas keys, and the diagram's zoom
    ;; function sends them to its own zoom.
    (should (eq (lookup-key map (kbd "+")) #'canvas-keys-zoom-in))
    (should (eq (lookup-key map (kbd "0")) #'canvas-keys-zoom-reset))
    (should (eq (lookup-key map (kbd "z")) #'canvas-diagram-zoom-fit))
    (should (eq (lookup-key map [C-wheel-up]) #'canvas-diagram-zoom-in)))
  (should (transient-get-suffix 'canvas-diagram-test-menu "+"))
  (should (transient-get-suffix 'canvas-diagram-test-menu "z")))

(ert-deftest canvas-diagram-menu-keys-work-in-the-buffer-too ()
  ;; GIVEN a menu made with the shared macro and the mode map
  ;; WHEN every shared setting key is looked up in both
  ;; THEN it runs the same command there, the package's own group comes
  ;;      first, AND the navigation letters b, f and p are not among them
  (let ((map (canvas-diagram-make-mode-map)))
    (pcase-dolist (`(,key . ,command) canvas-diagram-setting-keys)
      (let ((suffix (transient-get-suffix 'canvas-diagram-test-menu key)))
        (should suffix)
        (should (eq (plist-get (cdr suffix) :command) command))
        (should (eq (lookup-key map (kbd key)) command))))
    (should (transient-get-suffix 'canvas-diagram-test-menu "r"))
    (should (transient-get-suffix 'canvas-diagram-test-menu "i"))
    (dolist (letter '("b" "f" "p"))
      (should-not (assoc letter canvas-diagram-setting-keys)))))

(ert-deftest canvas-diagram-menu-closes-on-the-key-that-opened-it ()
  "GIVEN a menu made by `canvas-diagram-define-menu'
WHEN the key that opens it is pressed while it is up
THEN it closes, so that key toggles the menu, and `q' still closes it.

The binding has to be a suffix of the menu.  transient dispatches
keys through its own map while it is up, so a binding in the diagram
buffer never sees them, and the key reopened the menu it was meant to
close."
  (dolist (key '("SPC" "q"))
    (let ((suffix (transient-get-suffix 'canvas-diagram-test-menu key)))
      (should suffix)
      (should (eq (plist-get (cdr suffix) :command) 'transient-quit-one)))))

(defun canvas-diagram-test--quit-keys (group)
  "Return the keys in GROUP, or in its columns, that close the menu."
  (mapcan (lambda (child)
            (if (vectorp child)
                (canvas-diagram-test--quit-keys child)
              (when (eq (plist-get (cdr child) :command) 'transient-quit-one)
                (list (plist-get (cdr child) :key)))))
          (aref group 2)))

(ert-deftest canvas-diagram-menu-shows-one-way-to-close ()
  "GIVEN two keys that close the menu
WHEN the menu is drawn
THEN only one row says so, and it names both keys.

Two rows reading `close' is noise.  The second key lives in a hidden
group, which keeps the key working and takes it off the display.
transient reads `hide' on a top-level group only, so that group has to
be one: nested inside another it was drawn after all."
  (let ((shown nil)
        (hidden nil))
    (dolist (group (aref (get 'canvas-diagram-test-menu 'transient--layout) 2))
      (let ((keys (canvas-diagram-test--quit-keys group)))
        (if (plist-get (aref group 1) :hide)
            (setq hidden (append hidden keys))
          (setq shown (append shown keys)))))
    (should (equal '("q") shown))
    (should (equal '("SPC") hidden))
    (should (string-match-p "SPC"
                            (plist-get (cdr (transient-get-suffix
                                             'canvas-diagram-test-menu "q"))
                                       :description)))))

(ert-deftest canvas-diagram-menu-is-laid-out-in-rows ()
  "GIVEN the shared groups and a package's own
WHEN the menu is laid out
THEN they sit in several rows rather than one, so a menu of many groups
     stays inside the frame.

They were one row of eight columns, which ran off the right edge and
wrapped every description."
  (let ((rows (seq-remove (lambda (group) (plist-get (aref group 1) :hide))
                          (aref (get 'canvas-diagram-test-menu
                                     'transient--layout)
                                2))))
    (should (< 1 (length rows)))
    (dolist (row rows)
      (should (<= (length (aref row 2)) 4)))))

(ert-deftest canvas-diagram-menu-is-on-space-and-help-stays-on-question-mark ()
  ;; GIVEN the mode map and a diagram buffer
  ;; WHEN SPC, m and ? are looked up, and the menu is opened
  ;; THEN SPC opens the package's menu, which is a transient that stays
  ;;      up for other keys, AND m is left to canvas-keys, which shows
  ;;      and hides the map, AND ? is `special-mode''\='s own help, which
  ;;      the map now reaches as a parent of its own
  (let ((map (canvas-diagram-make-mode-map)))
    ;; SPC is the common canvas key, which calls the command the buffer
    ;; names.
    (should (eq (lookup-key map (kbd "SPC")) #'canvas-keys-menu))
    (should (eq (lookup-key map (kbd "m")) #'canvas-keys-toggle-minimap))
    (should (eq (lookup-key map (kbd "?")) #'describe-mode))
    (should (get 'canvas-diagram-test-menu 'transient--prefix))
    (should (eq (oref (get 'canvas-diagram-test-menu 'transient--prefix) transient-non-suffix)
                'transient--do-stay)))
  (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
    (let (opened)
      (cl-letf (((symbol-function 'call-interactively) (lambda (menu &rest _) (setq opened menu))))
        (canvas-diagram-menu))
      (should (eq opened 'canvas-diagram-test-menu)))))

;;;; Icons

(defmacro canvas-diagram-test--with-icons (&rest body)
  "Run BODY with a directory holding square.svg as the icon directory."
  `(let ((canvas-diagram-icon-directory (make-temp-file "canvas-diagram-icons" t)))
     (clrhash canvas-diagram--icons)
     (with-temp-file (expand-file-name "square.svg" canvas-diagram-icon-directory)
       (insert canvas-diagram-test--square-svg))
     (unwind-protect (progn ,@body)
       (clrhash canvas-diagram--icons)
       (delete-directory canvas-diagram-icon-directory t))))

(ert-deftest canvas-diagram-icon-data-comes-from-the-directory-and-is-kept ()
  ;; GIVEN an icon directory with one icon
  ;; WHEN the icon is asked for, the file removed, and it is asked for again,
  ;;      AND an icon nobody has is asked for twice
  ;; THEN the SVG text comes back both times, AND the missing one is nil
  ;;      both times without the disk being asked again
  (canvas-diagram-test--with-icons
   (let ((svg (canvas-diagram-icon-data "square")))
     (should (string-match-p "<svg" svg))
     (delete-file (expand-file-name "square.svg" canvas-diagram-icon-directory))
     (should (eq svg (canvas-diagram-icon-data "square"))))
   (should-not (canvas-diagram-icon-data "nobody-has-this"))
   (cl-letf (((symbol-function 'file-readable-p) (lambda (&rest _) (error "asked the disk"))))
     (should-not (canvas-diagram-icon-data "nobody-has-this")))))

(ert-deftest canvas-diagram-node-icon-is-its-own-or-its-kinds-unless-off ()
  ;; GIVEN nodes with an icon of their own, a kind with an icon, a kind a
  ;;       package gave an icon, and none
  ;; WHEN their icon names are asked for, with icons on and then off
  ;; THEN the own icon wins, the kind's serves, the package's too, none is
  ;;      none, AND off is off
  (let ((canvas-diagram-kind-icons '(("todo" . "square")))
        (canvas-diagram-extra-kind-icons '(("state" . "circle")))
        (own (canvas-diagram-node-create :label "a" :icon "mine" :kind "todo"))
        (kind (canvas-diagram-node-create :label "b" :kind "todo"))
        (extra (canvas-diagram-node-create :label "c" :kind "state"))
        (bare (canvas-diagram-node-create :label "d")))
    (let ((canvas-diagram-show-icons t))
      (should (equal (canvas-diagram--icon-name own) "mine"))
      (should (equal (canvas-diagram--icon-name kind) "square"))
      (should (equal (canvas-diagram--icon-name extra) "circle"))
      (should-not (canvas-diagram--icon-name bare)))
    (let ((canvas-diagram-show-icons nil))
      (should-not (canvas-diagram--icon-name kind)))))

(ert-deftest canvas-diagram-box-size-makes-room-for-an-icon ()
  ;; GIVEN a node with an icon that is on disk, one whose icon nobody
  ;;       has, and one without, icons on
  ;; WHEN their boxes are sized with a fake measure
  ;; THEN the iconed box is wider by the icon and its gap, the other two alike
  (canvas-diagram-test--with-icons
   (let* ((canvas-diagram-show-icons t)
          (with (canvas-diagram-node-create :label "Label" :icon "square"))
          (missing (canvas-diagram-node-create :label "Label" :icon "nobody-has-this"))
          (without (canvas-diagram-node-create :label "Label"))
          (a (canvas-diagram-box-size with "Label" #'canvas-diagram-test--measure))
          (m (canvas-diagram-box-size missing "Label" #'canvas-diagram-test--measure))
          (b (canvas-diagram-box-size without "Label" #'canvas-diagram-test--measure)))
     (should (= (- (car a) (car b)) (+ (canvas-diagram--icon-side 20) canvas-diagram--icon-gap)))
     (should (equal m b))
     (should (= (cdr a) (cdr b) 20)))))

(ert-deftest canvas-diagram-icon-makes-room-and-is-painted ()
  ;; GIVEN two nodes with the same label, one carrying the square icon
  ;; WHEN both are laid out and the row rendered
  ;; THEN the iconed box is wider by the icon and its gap,
  ;;      AND the icon's area carries the text colour
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-icons
    (canvas-diagram-test--with-context ctx 400 200
      (let* ((canvas-diagram-show-icons t)
             (diagram (canvas-diagram-test--laid-out '(("Label" :icon "square") ("Label")) ctx))
             (with (car (canvas-diagram-nodes diagram)))
             (without (cadr (canvas-diagram-nodes diagram))))
        (should (= (- (canvas-diagram-node-w with) (canvas-diagram-node-w without))
                   (+ (canvas-diagram--icon-side (canvas-diagram-node-h with)) canvas-diagram--icon-gap)))
        (canvas-diagram--render diagram ctx '(400 . 200))
        (should (= (canvas-cairo-pixel ctx
                                       (+ 10 (round (canvas-diagram-node-x with)) 8 3)
                                       (+ 10 (floor (canvas-diagram-middle-y with))))
                   #xFF000000)))))))

;;;; Badges

(ert-deftest canvas-diagram-box-size-makes-room-for-a-badge ()
  ;; GIVEN a node sized with a fake measure, with a badge and without
  ;; WHEN the two boxes are compared
  ;; THEN the badged one is wider by the badge's box and the gap, as tall
  (let* ((node (canvas-diagram-node-create :label "Label"))
         (with (canvas-diagram-box-size node "Label" #'canvas-diagram-test--measure "TODO"))
         (without (canvas-diagram-box-size node "Label" #'canvas-diagram-test--measure)))
    (should (= (- (car with) (car without)) (+ 40 canvas-diagram--icon-gap)))
    (should (= (cdr with) (cdr without)))))

(ert-deftest canvas-diagram-badge-makes-room-and-is-painted-before-the-label ()
  ;; GIVEN a row whose package gives its first node a red TODO badge
  ;; WHEN it is laid out and rendered
  ;; THEN the box has room for the label, the badge and the gap, AND the
  ;;      badge's left end, at the box's padding, is red
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 400 200
     (let* ((diagram (canvas-diagram-test--laid-out '(("badged") ("plain")) ctx))
            (badged (car (canvas-diagram-nodes diagram)))
            (measure (canvas-diagram-measure ctx)))
       (should (= (canvas-diagram-node-w badged)
                  (+ (car (funcall measure "badged")) (car (funcall measure "TODO")) canvas-diagram--icon-gap)))
       (should (= (canvas-diagram-node-w (cadr (canvas-diagram-nodes diagram))) (car (funcall measure "plain"))))
       (canvas-diagram--render diagram ctx '(400 . 200))
       (should (= (canvas-cairo-pixel ctx (+ 10 (round (canvas-diagram-node-x badged)) (canvas-diagram--padding) 2)
                                      (+ 10 (floor (canvas-diagram-middle-y badged))))
                  #xFFFF0000))))))

(ert-deftest canvas-diagram-legend-lists-badges-after-the-package-s-rows ()
  ;; GIVEN a row with a badged node of a kind, and the package's own row
  ;; WHEN the legend's entries are made, then rendered
  ;; THEN the badge comes once, between the package's row and the kind, AND
  ;;      its swatch is painted in its colour
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 300 200
     (let ((diagram (canvas-diagram-test--laid-out '(("badged" :kind "todo") ("b")) ctx)))
       (should (equal (canvas-diagram--legend-entries diagram)
                      '(("row" (1.0 0.0 0.0) fill) ("TODO" (1.0 0.0 0.0) badge) ("todo" (1.0 0.0 0.0) outline))))
       (canvas-diagram--render diagram ctx '(300 . 200))
       (let ((g (canvas-diagram--legend-geometry
                 ctx (canvas-diagram--legend-entries diagram) "Sans 12px" '(300 . 200))))
         (pcase-let ((`(,x ,y) (canvas-diagram--legend-swatch g 1)))
           (should (= (canvas-cairo-pixel ctx (+ x 6) (+ y 6)) #xFFFF0000))))))))

(ert-deftest canvas-diagram-legend-leaves-the-badges-to-a-package-that-explains-them ()
  ;; GIVEN a row with a badged node, whose package lists a badge row of
  ;;       its own after its fill row
  ;; WHEN the legend's entries are made
  ;; THEN the package's rows come as they are, AND no row comes for the
  ;;      badge text in use
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 300 200
     (let ((diagram (canvas-diagram-test--laid-out '(("badged") ("b")) ctx))
           (rows '(("row" (1.0 0.0 0.0) fill) ("to do" (1.0 0.0 0.0) badge))))
       (setf (canvas-diagram-callbacks diagram)
             (append (list :legend (lambda (_d) rows)) (canvas-diagram-callbacks diagram)))
       (should (equal (canvas-diagram--legend-entries diagram) rows))))))

(ert-deftest canvas-diagram-front-boxes-are-drawn-last-over-the-package-s-backdrop ()
  ;; GIVEN a row of three, drawn first as it is, and then with a package
  ;;       that puts "b" in front and draws a backdrop of its own
  ;; WHEN each is drawn
  ;; THEN the first draws the boxes in their order, AND the second draws
  ;;      "a" and "c", then the backdrop for "b", then "b"
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 400 100
     (let ((diagram (canvas-diagram-test--laid-out '(("a") ("b") ("c")) ctx))
           drawn)
       (cl-letf (((symbol-function 'canvas-diagram--draw-node)
                  (lambda (_diagram _ctx node &rest _) (push (canvas-diagram-node-label node) drawn))))
         (canvas-diagram--draw-all diagram ctx "Sans 12px")
         (should (equal (nreverse drawn) '("a" "b" "c")))
         (setq drawn nil)
         (setf (canvas-diagram-callbacks diagram)
               (append (list :front (lambda (d) (list (cadr (canvas-diagram-nodes d))))
                             :draw-front (lambda (_d _ctx nodes)
                                           (push (cons 'backdrop (mapcar #'canvas-diagram-node-label nodes))
                                                 drawn)))
                       (canvas-diagram-callbacks diagram)))
         (canvas-diagram--draw-all diagram ctx "Sans 12px")
         (should (equal (nreverse drawn) '("a" "c" (backdrop "b") "b"))))))))

(ert-deftest canvas-diagram-draw-over-comes-after-every-box ()
  ;; GIVEN a row of three with "b" in front, and a package that draws
  ;;       over the boxes
  ;; WHEN it is drawn
  ;; THEN what the package draws over comes after every box, the front
  ;;      one included
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 400 100
     (let ((diagram (canvas-diagram-test--laid-out '(("a") ("b") ("c")) ctx))
           drawn)
       (cl-letf (((symbol-function 'canvas-diagram--draw-node)
                  (lambda (_diagram _ctx node &rest _) (push (canvas-diagram-node-label node) drawn))))
         (setf (canvas-diagram-callbacks diagram)
               (append (list :front (lambda (d) (list (cadr (canvas-diagram-nodes d))))
                             :draw-over (lambda (_d _ctx) (push 'over drawn)))
                       (canvas-diagram-callbacks diagram)))
         (canvas-diagram--draw-all diagram ctx "Sans 12px")
         (should (equal (nreverse drawn) '("a" "c" "b" over))))))))

(ert-deftest canvas-diagram-ink-contrasts-with-its-ground ()
  ;; GIVEN a light ground and a dark one
  ;; WHEN the ink for each is asked for
  ;; THEN it is black on the light one AND white on the dark one
  (should (equal (canvas-diagram-ink-on '(1.0 0.84 0.0)) '(0.0 0.0 0.0)))
  (should (equal (canvas-diagram-ink-on '(0.18 0.55 0.34)) '(1.0 1.0 1.0))))

;;;; The minimap's clicks and the source

(ert-deftest canvas-diagram-picture-click-centres-the-view ()
  ;; GIVEN a drawing wider than its canvas, drawn once for the minimap
  ;; WHEN the minimap is clicked at its far corner, then at its origin,
  ;;      then on some other image
  ;; THEN the view goes to the drawing's far corner, back to its origin,
  ;;      AND the other image is not the diagram's business
  ;;      AND a click on a fitted drawing zooms in around the point clicked
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c") ("d") ("e") ("the far one")) '(120 . 60)
    (canvas-diagram-thumbnail canvas-diagram--canvas 40 30 #xFFFFFFFF)
    (should (canvas-diagram-picture-click canvas-diagram--canvas 1.0 1.0))
    (let ((map (canvas-diagram--view-extent)))
      (should (equal canvas-diagram--offset (cons (- (car map) 120) (max 0 (- (cdr map) 60))))))
    (should (canvas-diagram-picture-click canvas-diagram--canvas 0.0 0.0))
    (should (equal canvas-diagram--offset '(0 . 0)))
    (should-not (canvas-diagram-picture-click '(image :type png :file "x.png") 0.5 0.5))
    (canvas-diagram-zoom-fit)
    (should (< canvas-diagram--zoom 1.0))
    (canvas-diagram-thumbnail canvas-diagram--canvas 40 30 #xFFFFFFFF)
    (should (canvas-diagram-picture-click canvas-diagram--canvas 1.0 1.0))
    (should (= canvas-diagram--zoom 1.0))
    (let ((map (canvas-diagram--view-extent)))
      (should (equal canvas-diagram--offset (cons (- (car map) 120) (max 0 (- (cdr map) 60))))))))

(defmacro canvas-diagram-test--following (text &rest body)
  "Run BODY in a diagram buffer following a source buffer holding TEXT.
`source' names the source buffer there."
  (declare (indent 1))
  `(canvas-diagram-test--rendering
    (with-temp-buffer
      (insert ,text)
      (let ((source (current-buffer)))
        (with-temp-buffer
          (canvas-diagram-test-mode)
          (canvas-diagram-adopt (canvas-diagram-test--row) (canvas-diagram-test--row-read-source source))
          (plist-put (cdr canvas-diagram--canvas) :data-width 300)
          (plist-put (cdr canvas-diagram--canvas) :data-height 200)
          (canvas-diagram--follow source)
          (unwind-protect (progn ,@body)
            (canvas-diagram--release)))))))

(ert-deftest canvas-diagram-refresh-rereads-the-source-on-demand ()
  ;; GIVEN a diagram following a buffer that has just gained a line
  ;; WHEN it is refreshed by hand, before the pause after typing
  ;; THEN it has the new node, AND g is `revert-buffer', which
  ;;      `revert-buffer-function' sends to `canvas-diagram-refresh'
  (canvas-diagram-test--following "a\nb\n"
    (with-current-buffer source
      (let ((inhibit-modification-hooks t))
        (goto-char (point-max))
        (insert "c\n")))
    (canvas-diagram-refresh)
    (should (= (length (canvas-diagram-nodes-shown)) 3))
    (should (eq (lookup-key canvas-diagram-mode-map (kbd "g")) #'revert-buffer))
    (should (eq revert-buffer-function #'canvas-diagram-refresh))))

(ert-deftest canvas-diagram-follows-its-source-buffer ()
  ;; GIVEN a diagram of a buffer that follows it
  ;; WHEN a line is added to the buffer and the pause after typing passes
  ;; THEN the diagram has the new node, the keyboard still on the first,
  ;;      AND once it stops following, a further change is not seen
  (canvas-diagram-test--following "a\nb\n"
    (let ((diagram-buffer (current-buffer)))
      (with-current-buffer source
        (goto-char (point-max))
        (insert "c\n"))
      (should canvas-diagram--source-timer)
      (canvas-diagram--refresh-from-source diagram-buffer)
      (should (= (length (canvas-diagram-nodes-shown)) 3))
      (should (equal (canvas-diagram-test--selected) "a"))
      (canvas-diagram--unfollow)
      (with-current-buffer source
        (goto-char (point-max))
        (insert "d\n"))
      (should-not canvas-diagram--source-timer)
      (should-not (with-current-buffer source canvas-diagram--follower)))))

(defvar smear-cursor-mode nil)
(defvar pulsar-mode nil)

(ert-deftest canvas-diagram-pulse-uses-the-feature-that-is-on ()
  ;; GIVEN smear-cursor's pulse, pulsar's, or neither switched on
  ;; WHEN the default pulse runs
  ;; THEN it calls smear-cursor's, then pulsar's, AND nothing with neither
  (let ((called nil))
    (cl-letf (((symbol-function 'smear-cursor-pulse-line) (lambda () (setq called 'smear)))
              ((symbol-function 'pulsar-pulse-line) (lambda () (setq called 'pulsar))))
      (let ((smear-cursor-mode t) (pulsar-mode t))
        (canvas-diagram--pulse-line)
        (should (eq called 'smear)))
      (let ((smear-cursor-mode nil) (pulsar-mode t))
        (canvas-diagram--pulse-line)
        (should (eq called 'pulsar)))
      (setq called nil)
      (let ((smear-cursor-mode nil) (pulsar-mode nil))
        (canvas-diagram--pulse-line)
        (should-not called)))))

(ert-deftest canvas-diagram-going-to-a-node-moves-point-in-the-source ()
  ;; GIVEN a diagram that follows a buffer, with positions
  ;; WHEN the keyboard goes to the second node and then a box is clicked
  ;; THEN point in the source lands on that node's line each time
  ;;      AND, the source being in a window, its line is pulsed there
  (canvas-diagram-test--following "a\nb\nc\n"
    (set-window-buffer (selected-window) source)
    (let* ((pulsed nil)
           (canvas-diagram-pulse-function
            (lambda () (push (cons (current-buffer) (point)) pulsed))))
      (canvas-diagram-jump "b")
      (should (= (with-current-buffer source (point)) 3))
      (canvas-diagram--toggle-popup (canvas-diagram-test--inside (canvas-diagram-test--labelled "c")))
      (should (= (with-current-buffer source (point)) 5))
      (should (equal pulsed (list (cons source 5) (cons source 3)))))))

(ert-deftest canvas-diagram-a-node-can-come-from-a-file-of-its-own ()
  ;; GIVEN a diagram following one buffer, and nodes placed three ways: in
  ;;       that buffer, in another buffer, and in a file
  ;; WHEN the place of each is asked for
  ;; THEN a number is a place in the buffer followed, a buffer and a number
  ;;      is a place in that buffer, AND a file counts once it is open, or
  ;;      when opening it is allowed, which is what a drawing read from a
  ;;      file that includes others needs
  (let* ((followed (generate-new-buffer " canvas-diagram-test-source"))
         (other (generate-new-buffer " canvas-diagram-test-other"))
         (file (make-temp-file "canvas-diagram-test" nil ".txt" "one\ntwo\nthree\n")))
    (unwind-protect
        (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
          (setq canvas-diagram--source followed)
          (let ((here (canvas-diagram-node-create :label "here" :pos 5))
                (there (canvas-diagram-node-create :label "there" :pos (cons other 3)))
                (filed (canvas-diagram-node-create :label "filed" :pos (cons file 9)))
                (nowhere (canvas-diagram-node-create :label "nowhere")))
            (should (equal (canvas-diagram--place here) (cons followed 5)))
            (should (equal (canvas-diagram--place there) (cons other 3)))
            (should-not (canvas-diagram--place nowhere))
            ;; the file is not open, so following it passively finds nothing
            (should-not (canvas-diagram--place filed))
            ;; going there opens it
            (let ((place (canvas-diagram--place filed t)))
              (should (bufferp (car place)))
              (should (equal (buffer-file-name (car place)) file))
              (should (= (cdr place) 9))
              (kill-buffer (car place)))))
      (kill-buffer followed)
      (kill-buffer other)
      (delete-file file))))

(ert-deftest canvas-diagram-can-open-the-file-a-node-came-from ()
  ;; GIVEN a node that came from a file which is not open, and the followed
  ;;       buffer shown in a window
  ;; WHEN the keyboard lands on that node
  ;; THEN nothing happens while `canvas-diagram-open-source' is nil
  ;;      AND with it on the file is opened, point goes to the place in it,
  ;;      and the window that showed the followed buffer shows that file, so
  ;;      the window beside the drawing holds the file the box came from
  (let ((file (make-temp-file "canvas-diagram-test" nil ".txt" "one\ntwo\nthree\n")))
    (unwind-protect
        (canvas-diagram-test--following "a\nb\n"
          (let ((node (canvas-diagram-node-create :label "elsewhere" :pos (cons file 5)))
                (window (selected-window)))
            (set-window-buffer window source)
            (let ((canvas-diagram-open-source nil))
              (canvas-diagram--goto-source node)
              (should-not (get-file-buffer file))
              (should (eq (window-buffer window) source)))
            (let ((canvas-diagram-open-source t)
                  (canvas-diagram-pulse-function nil))
              (canvas-diagram--goto-source node)
              (let ((opened (get-file-buffer file)))
                (should opened)
                (should (= (with-current-buffer opened (point)) 5))
                (should (eq (window-buffer window) opened))
                ;; walking back to a node of the followed buffer brings it back
                (canvas-diagram--goto-source
                 (canvas-diagram-node-create :label "home" :pos 3))
                (should (eq (window-buffer window) source))
                (set-window-buffer window source)
                (kill-buffer opened)))))
      (delete-file file))))

(ert-deftest canvas-diagram-lends-only-a-window-of-its-own-frame ()
  ;; GIVEN a window
  ;; WHEN it is held against a frame
  ;; THEN it counts on that frame, and on none when no frame is asked for,
  ;;      AND it does not count on another frame: a drawing that lent a window
  ;;      on a frame the reader has left must borrow again here
  (should (canvas-diagram--window-on (selected-window) (selected-frame)))
  (should (canvas-diagram--window-on (selected-window) nil))
  (should-not (canvas-diagram--window-on (selected-window) 'another-frame))
  (should-not (canvas-diagram--window-on nil nil)))

(ert-deftest canvas-diagram-keeps-its-own-window-on-the-file-of-the-box ()
  ;; GIVEN a drawing whose neighbour window holds the followed buffer, and a
  ;;       node from a file that is already shown in some other window
  ;; WHEN the keyboard lands on that node
  ;; THEN the neighbour window shows that file too, rather than the drawing
  ;;      leaving it on the file before and pointing at a window elsewhere
  (let ((file (make-temp-file "canvas-diagram-test" nil ".txt" "one\ntwo\nthree\n")))
    (unwind-protect
        (canvas-diagram-test--following "a\nb\n"
          (let* ((canvas-diagram-open-source t)
                 (canvas-diagram-pulse-function nil)
                 (elsewhere (find-file-noselect file))
                 (neighbour (selected-window))
                 (far (split-window)))
            (set-window-buffer neighbour source)
            (set-window-buffer far elsewhere)
            (canvas-diagram--goto-source
             (canvas-diagram-node-create :label "elsewhere" :pos (cons file 5)))
            (should (eq (window-buffer neighbour) elsewhere))
            (canvas-diagram--goto-source (canvas-diagram-node-create :label "home" :pos 3))
            (should (eq (window-buffer neighbour) source))
            (delete-window far)
            (kill-buffer elsewhere)))
      (delete-file file))))

(ert-deftest canvas-diagram-visiting-the-source-selects-it-at-the-node ()
  ;; GIVEN a diagram following a buffer, the keyboard on the second node
  ;; WHEN the source is visited
  ;; THEN the selected window shows the source with point on that line, pulsed
  ;;      AND a diagram that follows nothing refuses
  (canvas-diagram-test--following "a\nb\n"
    (let* ((pulsed nil)
           (canvas-diagram-pulse-function (lambda () (setq pulsed (point)))))
      (canvas-diagram-set-selected (canvas-diagram-test--labelled "b"))
      (canvas-diagram-visit-source)
      (should (eq (window-buffer (selected-window)) source))
      (should (= (with-current-buffer source (point)) 3))
      (should (= pulsed 3))
      (canvas-diagram--unfollow)
      (should-error (canvas-diagram-visit-source) :type 'user-error))))

;;;; Copying a node

(defmacro canvas-diagram-test--copying (&rest body)
  "Run BODY with a kill ring of its own, the system clipboard left alone."
  `(let ((kill-ring nil) (kill-ring-yank-pointer nil) (interprogram-cut-function nil))
     ,@body))

(defun canvas-diagram-test--add-callbacks (&rest callbacks)
  "Put CALLBACKS before those of this buffer's diagram."
  (setf (canvas-diagram-callbacks canvas-diagram--diagram)
        (append callbacks (canvas-diagram-callbacks canvas-diagram--diagram))))

(ert-deftest canvas-diagram-node-content-is-the-package-s-else-label-and-note ()
  ;; GIVEN a row whose first node has a note and whose second has none
  ;; WHEN their content is asked for, then with a package's :content
  ;; THEN it is the label and the note, the second's body nil, AND then
  ;;      whatever the package says
  (canvas-diagram-test--in-buffer '(("a" :note "the note") ("b")) '(200 . 60)
    (should (equal (canvas-diagram-node-content canvas-diagram--diagram (canvas-diagram-test--labelled "a"))
                   '("a" "the note")))
    (should (equal (canvas-diagram-node-content canvas-diagram--diagram (canvas-diagram-test--labelled "b"))
                   '("b" nil)))
    (canvas-diagram-test--add-callbacks :content (lambda (_d node) (list (upcase (canvas-diagram-node-label node)) "own")))
    (should (equal (canvas-diagram-node-content canvas-diagram--diagram (canvas-diagram-test--labelled "b"))
                   '("B" "own")))))

(ert-deftest canvas-diagram-copying-puts-a-part-of-the-node-on-the-kill-ring ()
  ;; GIVEN a row, the keyboard on a node with a note
  ;; WHEN its header, its body and all of it are copied
  ;; THEN each lands on the kill ring, all of it being the header, a blank
  ;;      line and the body
  (canvas-diagram-test--copying
   (canvas-diagram-test--in-buffer '(("a" :note "the note") ("b")) '(200 . 60)
     (canvas-diagram-set-selected (canvas-diagram-test--labelled "a"))
     (canvas-diagram-copy-header)
     (should (equal (current-kill 0) "a"))
     (canvas-diagram-copy-body)
     (should (equal (current-kill 0) "the note"))
     (canvas-diagram-copy-node)
     (should (equal (current-kill 0) "a\n\nthe note")))))

(ert-deftest canvas-diagram-m-w-copies-the-node-and-with-a-prefix-the-whole-diagram ()
  ;; GIVEN a row, the keyboard on a node with a note
  ;; WHEN M-w is pressed, and then with a prefix
  ;; THEN the first copies the node's text, AND the second copies the whole
  ;;      diagram as a PNG, as a prefix does in every canvas buffer
  (canvas-diagram-test--copying
   (canvas-diagram-test--in-buffer '(("a" :note "the note") ("b")) '(200 . 60)
     (canvas-diagram-set-selected (canvas-diagram-test--labelled "a"))
     (let ((copied nil))
       (cl-letf (((symbol-function 'kill-ring-images-copy)
                  (lambda (type bytes) (setq copied (cons type bytes)))))
         (call-interactively #'canvas-keys-copy-picture)
         (should (equal (current-kill 0) "a\n\nthe note"))
         (should-not copied)
         (let ((current-prefix-arg '(4)))
           (call-interactively #'canvas-keys-copy-picture))
         (should (eq (car copied) 'image/png))
         (should (string-prefix-p "\211PNG" (cdr copied))))))))

(ert-deftest canvas-diagram-copying-what-a-node-lacks-refuses ()
  ;; GIVEN a row, the keyboard on a node without a note
  ;; WHEN all of it is copied, then its body, then with no node selected
  ;; THEN all of it is the header alone, AND the body and the missing node
  ;;      are user errors that leave the kill ring as it was
  (canvas-diagram-test--copying
   (canvas-diagram-test--in-buffer '(("a" :note "the note") ("b")) '(200 . 60)
     (canvas-diagram-set-selected (canvas-diagram-test--labelled "b"))
     (canvas-diagram-copy-node)
     (should (equal (current-kill 0) "b"))
     (should-error (canvas-diagram-copy-body) :type 'user-error)
     (canvas-diagram-set-selected nil)
     (should-error (canvas-diagram-copy-header) :type 'user-error)
     (should (equal kill-ring '("b"))))))

(ert-deftest canvas-diagram-copying-the-source-asks-the-package ()
  ;; GIVEN a diagram following a buffer, its package giving source text
  ;; WHEN each part is copied from the source, with the prefix argument or
  ;;      by the source command
  ;; THEN the package is asked for that part of the node in the source buffer
  (canvas-diagram-test--copying
   (canvas-diagram-test--following "a\nb\n"
     (canvas-diagram-test--add-callbacks
      :source-text (lambda (_d node part buffer)
                     (format "%s of %s in %s" part (canvas-diagram-node-label node) (buffer-name buffer))))
     (canvas-diagram-set-selected (canvas-diagram-test--labelled "b"))
     (canvas-diagram-copy-header t)
     (should (equal (current-kill 0) (format "header of b in %s" (buffer-name source))))
     (canvas-diagram-copy-body t)
     (should (equal (current-kill 0) (format "body of b in %s" (buffer-name source))))
     (canvas-diagram-copy-node t)
     (should (equal (current-kill 0) (format "all of b in %s" (buffer-name source))))
     (kill-new "other")
     (canvas-diagram-copy-source)
     (should (equal (current-kill 0) (format "all of b in %s" (buffer-name source)))))))

(ert-deftest canvas-diagram-copying-the-source-refuses-without-one ()
  ;; GIVEN a diagram following a buffer, its package giving no source text
  ;; WHEN the source is copied, then with a package that finds none for the
  ;;      node, then once the diagram follows nothing
  ;; THEN each is a user error, AND the kill ring stays empty
  (canvas-diagram-test--copying
   (canvas-diagram-test--following "a\nb\n"
     (should-error (canvas-diagram-copy-source) :type 'user-error)
     (canvas-diagram-test--add-callbacks :source-text (lambda (&rest _) nil))
     (should-error (canvas-diagram-copy-source) :type 'user-error)
     (canvas-diagram-test--add-callbacks :source-text (lambda (&rest _) "text"))
     (canvas-diagram--unfollow)
     (should-error (canvas-diagram-copy-source) :type 'user-error)
     (should-not kill-ring))))

(ert-deftest canvas-diagram-copy-keys-are-in-the-buffer-and-the-menu ()
  ;; GIVEN the mode map and a menu made with the shared macro
  ;; WHEN the copy keys are looked up
  ;; THEN M-w runs the common copy here, whatever command a user's own M-w
  ;;      runs, so does any key for `kill-ring-save', AND the menu's Copy
  ;;      group has all of it, the header, the body, the source and the
  ;;      whole picture
  (should (eq (lookup-key (canvas-diagram-make-mode-map) (kbd "M-w")) #'canvas-keys-copy-picture))
  (should (eq (lookup-key (canvas-diagram-make-mode-map) [remap kill-ring-save]) #'canvas-keys-copy-picture))
  (pcase-dolist (`(,key . ,command) '(("y y" . canvas-diagram-copy-node) ("y h" . canvas-diagram-copy-header)
                                      ("y b" . canvas-diagram-copy-body) ("y s" . canvas-diagram-copy-source)
                                      ("y p" . canvas-keys-copy-whole-picture)))
    (let ((suffix (transient-get-suffix 'canvas-diagram-test-menu key)))
      (should suffix)
      (should (eq (plist-get (cdr suffix) :command) command)))))

(defvar embark-target-finders)
(defvar embark-keymap-alist)

(ert-deftest canvas-diagram-embark-targets-the-keyboard-s-node ()
  ;; GIVEN a diagram buffer with the keyboard on a node, and a plain buffer
  ;; WHEN embark looks for a target in each, and embark is loaded
  ;; THEN the node is a target in the diagram only, its keymap copies its
  ;;      parts, AND loading embark registers both
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(200 . 60)
    (canvas-diagram-set-selected (canvas-diagram-test--labelled "b"))
    (should (equal (canvas-diagram-embark-target) '(canvas-diagram-node . "b"))))
  (with-temp-buffer
    (should-not (canvas-diagram-embark-target)))
  (pcase-dolist (`(,key . ,command) '(("w" . canvas-diagram-copy-node) ("h" . canvas-diagram-copy-header)
                                      ("b" . canvas-diagram-copy-body) ("s" . canvas-diagram-copy-source)))
    (should (eq (keymap-lookup canvas-diagram-embark-map key) command)))
  (let ((embark-target-finders nil) (embark-keymap-alist nil))
    (provide 'embark)
    (should (memq #'canvas-diagram-embark-target embark-target-finders))
    (should (equal (alist-get 'canvas-diagram-node embark-keymap-alist)
                   '(canvas-diagram-embark-map canvas-diagram--node-actions-map)))
    (should (equal (alist-get 'canvas-diagram-marked embark-keymap-alist)
                   '(canvas-diagram-embark-marked-map canvas-diagram--marked-actions-map)))))

(defvar canvas-diagram-test--actions-map (define-keymap "v" #'ignore)
  "Actions that a test names by the variable that holds them.")

(defun canvas-diagram-test--always (_buffer) "True of any buffer." t)
(defun canvas-diagram-test--never (_buffer) "True of no buffer." nil)

(ert-deftest canvas-diagram-node-actions-apply-by-mode-and-by-function ()
  ;; GIVEN actions for the test mode, for org-mode, for a function that
  ;;       holds, for one that does not, and for the test mode held in a
  ;;       variable, each condition one of `buffer-match-p\='s
  ;; WHEN the keyboard's node becomes embark's target in a test diagram
  ;; THEN the actions embark reads beside the copying keys are those of the
  ;;      test mode, of the variable and of the true function, and not the
  ;;      others: a package offers actions only where they make sense
  (let ((canvas-diagram-node-actions
         `(((derived-mode . canvas-diagram-test-mode) . ,(define-keymap "x" #'ignore))
           ((derived-mode . org-mode) . ,(define-keymap "y" #'ignore))
           (canvas-diagram-test--always . ,(define-keymap "z" #'ignore))
           (canvas-diagram-test--never . ,(define-keymap "q" #'ignore))
           ((derived-mode . canvas-diagram-test-mode) . canvas-diagram-test--actions-map))))
    (canvas-diagram-test--in-buffer '(("a")) '(200 . 60)
      (canvas-diagram-set-selected (canvas-diagram-test--labelled "a"))
      (should (canvas-diagram-embark-target))
      (dolist (key '("x" "z" "v"))
        (should (eq (keymap-lookup canvas-diagram--node-actions-map key) #'ignore)))
      (dolist (key '("y" "q"))
        (should-not (keymap-lookup canvas-diagram--node-actions-map key))))))

(ert-deftest canvas-diagram-marked-actions-apply-to-the-marked-boxes ()
  ;; GIVEN actions on the marked boxes for the test mode
  ;; WHEN the marked boxes become embark's target
  ;; THEN those actions are offered, and none of the keyboard's node's
  (let ((canvas-diagram-node-actions
         `(((derived-mode . canvas-diagram-test-mode) . ,(define-keymap "x" #'ignore))))
        (canvas-diagram-marked-actions
         `(((derived-mode . canvas-diagram-test-mode) . ,(define-keymap "m" #'ignore)))))
    (canvas-diagram-test--in-buffer '(("a") ("b")) '(200 . 60)
      (canvas-diagram-set-selected (canvas-diagram-test--labelled "a"))
      (canvas-diagram-toggle-mark)
      (should (canvas-diagram-embark-marked-target))
      (should (eq (keymap-lookup canvas-diagram--marked-actions-map "m") #'ignore))
      (should-not (keymap-lookup canvas-diagram--marked-actions-map "x")))))

(ert-deftest canvas-diagram-an-action-that-is-no-keymap-is-an-error ()
  ;; GIVEN an entry whose actions are a string, a mistake in a setting
  ;; WHEN the keyboard's node becomes embark's target
  ;; THEN it is an error that names the entry, not an action that is missed
  (let ((canvas-diagram-node-actions '(((derived-mode . canvas-diagram-test-mode) . "x"))))
    (canvas-diagram-test--in-buffer '(("a")) '(200 . 60)
      (canvas-diagram-set-selected (canvas-diagram-test--labelled "a"))
      (should (string-search "canvas-diagram-test-mode"
                             (error-message-string (should-error (canvas-diagram-embark-target))))))))

(ert-deftest canvas-diagram-show-gives-the-buffer-the-caller-s-directory ()
  ;; GIVEN a diagram shown from one directory, and shown again in the same
  ;;       buffer from another
  ;; WHEN the buffer's directory is read after each
  ;; THEN it is the directory it was last shown from, so that what acts on
  ;;      the diagram acts in the project it was shown for
  (canvas-diagram-test--rendering
    (let ((buffer nil))
      (unwind-protect
          (progn
            ;; Each show comes from a buffer of its own, as the server's
            ;; evaluation comes from its buffer: a `let' of the directory
            ;; in the diagram buffer would put the old one back on its way
            ;; out.
            (with-temp-buffer
              (setq default-directory "/tmp/")
              (setq buffer (canvas-diagram-show "*canvas-diagram-test-show*" #'canvas-diagram-test-mode
                                                (canvas-diagram-test--row) '(("a")))))
            (should (equal (buffer-local-value 'default-directory buffer) "/tmp/"))
            (with-temp-buffer
              (setq default-directory "/")
              (canvas-diagram-show "*canvas-diagram-test-show*" #'canvas-diagram-test-mode
                                   (canvas-diagram-test--row) '(("a"))))
            (should (equal (buffer-local-value 'default-directory buffer) "/")))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (canvas-diagram--release))
          (kill-buffer buffer))))))

;;;; Code blocks in a source

(ert-deftest canvas-diagram-code-blocks-are-found-by-their-language ()
  ;; GIVEN a buffer with a markdown fence of mermaid, a ~~~ fence naming it
  ;;       in braces, an org source block in capitals, a python fence, and
  ;;       a mermaid fence never closed
  ;; WHEN its mermaid blocks are asked for, and its python and mermaid ones
  ;; THEN the three closed mermaid blocks come back in order, each from the
  ;;      first line of its code to the start of its closing line, AND the
  ;;      python block joins them when asked for, the unclosed one never
  (with-temp-buffer
    (insert "# Title\n```mermaid\ngraph TD\nA-->B\n```\ntext\n~~~{mermaid}\nmindmap\n  root\n~~~\n"
            "#+BEGIN_SRC mermaid :file x.png\nstateDiagram\n#+END_SRC\n```python\nprint(1)\n```\n"
            "```mermaid\nflowchart LR\n")
    (let ((blocks (canvas-diagram-code-blocks '("mermaid"))))
      (should (equal (mapcar (lambda (b) (buffer-substring-no-properties (car b) (cdr b))) blocks)
                     '("graph TD\nA-->B\n" "mindmap\n  root\n" "stateDiagram\n")))
      (should (= (car (car blocks)) (1+ (length "# Title\n```mermaid\n")))))
    (should (= (length (canvas-diagram-code-blocks '("python" "mermaid"))) 4))
    (should-not (canvas-diagram-code-blocks '("plantuml")))))

(ert-deftest canvas-diagram-text-lines-know-where-they-begin ()
  ;; GIVEN a text of three lines, the last empty, beginning at position 10
  ;; WHEN it is split into lines
  ;; THEN each comes with the buffer position it begins at
  (should (equal (canvas-diagram-text-lines "ab\ncde\n" 10) '(("ab" . 10) ("cde" . 13) ("" . 17)))))

(ert-deftest canvas-diagram-the-region-point-is-in ()
  ;; GIVEN two regions, and one
  ;; WHEN the region at a position is asked for, inside one, outside both,
  ;;      and anywhere when there is only one
  ;; THEN it is the region holding the position, a user error when several
  ;;      hold none, AND the only one otherwise
  (let ((regions '((10 . 20) (30 . 40))))
    (should (equal (canvas-diagram-region-at regions 35) '(30 . 40)))
    (should (equal (canvas-diagram-region-at regions 20) '(10 . 20)))
    (should-error (canvas-diagram-region-at regions 25) :type 'user-error)
    (should (equal (canvas-diagram-region-at '((10 . 20)) 99) '(10 . 20)))))

(ert-deftest canvas-diagram-a-region-reader-follows-its-region ()
  ;; GIVEN a buffer of two bracketed regions, and a reader of the second,
  ;;       READ giving a region's text and signalling on a bang
  ;; WHEN text goes in before the region, then into it, then a bang, then
  ;;      the region goes
  ;; THEN the reader still reads the second region, sees its new text,
  ;;      reads nil while READ signals, saying why, AND nil once it is gone
  (with-temp-buffer
    (insert "[one] [two]")
    (let* ((regions (lambda ()
                      (save-excursion
                        (goto-char (point-min))
                        (let (found)
                          (while (re-search-forward "\\[\\([^]]*\\)\\]" nil t)
                            (push (cons (match-beginning 1) (match-end 1)) found))
                          (nreverse found)))))
           (read (lambda (region)
                   (let ((text (buffer-substring-no-properties (car region) (cdr region))))
                     (when (string-search "!" text) (error "bang in %s" text))
                     text)))
           (reader (canvas-diagram-region-reader (copy-marker (car (cadr (funcall regions)))) regions read)))
      (goto-char (point-min))
      (insert "before ")
      (should (equal (funcall reader (current-buffer)) "two"))
      (search-forward "[tw")
      (insert "-")
      (should (equal (funcall reader (current-buffer)) "tw-o"))
      (insert "!")
      (let (said)
        (cl-letf (((symbol-function 'message) (lambda (&rest args) (setq said (apply #'format args)))))
          (should-not (funcall reader (current-buffer)))
          (should (string-search "bang" said))))
      (erase-buffer)
      (should-not (funcall reader (current-buffer))))))

;;;; The package

(defun canvas-diagram-test--library (name)
  "The source file of library NAME."
  (let ((file (locate-library (concat name ".el"))))
    (should file)
    file))

(ert-deftest canvas-diagram-package-headers-describe-the-package ()
  ;; GIVEN the library as it is published
  ;; WHEN package.el reads its headers
  ;; THEN it finds the name, a version, a summary, a URL, AND the
  ;;      requirements a canvas and the menus need
  (with-temp-buffer
    (insert-file-contents (canvas-diagram-test--library "canvas-diagram"))
    (let ((info (package-buffer-info)))
      (should (equal (package-desc-name info) 'canvas-diagram))
      (should (version-list-<= '(0 1) (package-desc-version info)))
      (should-not (equal (package-desc-summary info) "No description available."))
      (should (string-prefix-p "https://" (cdr (assq :url (package-desc-extras info)))))
      (let* ((reqs (package-desc-reqs info))
             (wanted (cadr (assq 'emacs reqs))))
        ;; The Emacs asked for must be one this very Emacs satisfies:
        ;; a requirement no built Emacs meets is uninstallable.
        (should (version-list-<= '(32) wanted))
        (should (version-list-<= wanted (version-to-list emacs-version)))
        (should (assq 'transient reqs))))))

(ert-deftest canvas-diagram-package-names-its-author-and-licence ()
  ;; GIVEN the library, published under the GPL alongside shipit and the
  ;;       other canvas packages
  ;; WHEN its headers and leading comments are read
  ;; THEN it names an author, holds the copyright the way they all do,
  ;;      AND carries a Commentary section and the licence notice
  (with-temp-buffer
    (insert-file-contents (canvas-diagram-test--library "canvas-diagram"))
    (should (string-match-p "[^ ]" (or (lm-header "author") "")))
    (should (save-excursion
              (goto-char (point-min))
              (re-search-forward "^;; Copyright (C) [0-9-]+ canvas-diagram contributors$"
                                 nil t)))
    (should (lm-commentary-start))
    (should (save-excursion (re-search-forward "GNU General Public License" nil t)))))

(ert-deftest canvas-diagram-licence-file-is-the-whole-gpl ()
  ;; GIVEN a package that says it is GPL-3.0-or-later
  ;; WHEN the LICENSE file beside it is read
  ;; THEN it is the licence itself, not a summary pointing elsewhere
  (let ((license (expand-file-name
                  "LICENSE" (file-name-directory
                             (canvas-diagram-test--library "canvas-diagram")))))
    (should (file-readable-p license))
    (with-temp-buffer
      (insert-file-contents license)
      (should (save-excursion (re-search-forward "TERMS AND CONDITIONS" nil t)))
      (should (save-excursion (re-search-forward "Version 3, 29 June 2007" nil t))))))

;;;; Nodes with rows

(ert-deftest canvas-diagram-a-node-of-rows-is-as-tall-as-they-need ()
  ;; GIVEN a node with a label and three rows of its own
  ;; WHEN it is sized for a canvas
  ;; THEN its box is as wide as the widest of them and tall enough for the
  ;;      label and every row, AND a node with no rows keeps the size of
  ;;      its label alone
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 4 4
     (let* ((measure (canvas-diagram-measure ctx))
            (diagram (canvas-diagram-create))
            (plain (canvas-diagram-node-create :label "Fifo"))
            (rowed (canvas-diagram-node-create :label "Fifo" :rows '("clk : in std_logic"
                                                                     "data : in byte"
                                                                     "full : out std_logic"))))
       (canvas-diagram-size-node diagram plain measure)
       (canvas-diagram-size-node diagram rowed measure)
       (should (> (canvas-diagram-node-w rowed) (canvas-diagram-node-w plain)))
       (should (> (canvas-diagram-node-h rowed) (* 3 (canvas-diagram-node-h plain))))))))

(ert-deftest canvas-diagram-a-row-of-a-node-has-a-place-to-join ()
  ;; GIVEN a node of three rows, sized and put at a place
  ;; WHEN the place to join a row is asked for, on the left and on the right
  ;; THEN each lies on the edge of the box at the height of that row, the
  ;;      rows in order down the box, AND a row the node does not have is
  ;;      an error
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 4 4
     (let* ((measure (canvas-diagram-measure ctx))
            (diagram (canvas-diagram-create))
            (node (canvas-diagram-node-create :label "Fifo" :rows '("clk" "data" "full"))))
       (canvas-diagram-size-node diagram node measure)
       (setf (canvas-diagram-node-x node) 100 (canvas-diagram-node-y node) 50)
       (let ((left (canvas-diagram-row-anchor node "data" 'left))
             (right (canvas-diagram-row-anchor node "data" 'right))
             (first (canvas-diagram-row-anchor node "clk" 'left))
             (last (canvas-diagram-row-anchor node "full" 'left)))
         (should (= (car left) 100))
         (should (= (car right) (+ 100 (canvas-diagram-node-w node))))
         (should (= (cdr left) (cdr right)))
         (should (< (cdr first) (cdr left) (cdr last)))
         (should (< (cdr last) (+ 50 (canvas-diagram-node-h node))))
         (should-error (canvas-diagram-row-anchor node "nothing" 'left)))))))

(ert-deftest canvas-diagram-the-rows-of-a-node-are-written-under-its-label ()
  ;; GIVEN a node of two rows drawn on a canvas
  ;; WHEN the picture is read down the left of its box
  ;; THEN there is ink at the label and at each row, so the rows are
  ;;      written one under the other inside the box
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 300 200
     (let* ((measure (canvas-diagram-measure ctx))
            (diagram (canvas-diagram-create))
            (node (canvas-diagram-node-create :label "Fifo" :rows '("clk" "data"))))
       (canvas-diagram-size-node diagram node measure)
       (setf (canvas-diagram-node-x node) 20 (canvas-diagram-node-y node) 20)
       (apply #'canvas-cairo-clear ctx (append (canvas-diagram-color :background) '(1)))
       (canvas-diagram--draw-node diagram ctx node (canvas-diagram-font))
       (canvas-cairo-flush ctx)
       (let ((inked (lambda (y) (cl-loop for x from 22 below (+ 20 (canvas-diagram-node-w node))
                                         thereis (/= (canvas-cairo-pixel ctx x y)
                                                     (canvas-cairo-pixel ctx 2 2))))))
         (should (funcall inked (round (cdr (canvas-diagram-row-anchor node "clk" 'left)))))
         (should (funcall inked (round (cdr (canvas-diagram-row-anchor node "data" 'left))))))))))

(defun canvas-diagram-test--inked-p (pixel)
  "Whether PIXEL, ARGB32, carries ink of the selection colour, which the
tests set to red: more red than blue, whatever the antialiasing left."
  (> (logand (ash pixel -16) #xFF) (+ 40 (logand pixel #xFF))))

;;;; A set of marked nodes

(ert-deftest canvas-diagram-nodes-are-marked-and-unmarked-by-their-keys ()
  ;; GIVEN a diagram of three boxes in a buffer
  ;; WHEN the keyboard's box is marked, then another, then the first again
  ;; THEN the marked boxes are those still marked, in reading order, and
  ;;      nothing is marked once they are all let go
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(400 . 300)
   (let ((nodes (canvas-diagram-nodes canvas-diagram--diagram)))
     (should-not (canvas-diagram-marked-nodes))
     (canvas-diagram-set-selected (nth 0 nodes))
     (canvas-diagram-toggle-mark)
     (canvas-diagram-set-selected (nth 2 nodes))
     (canvas-diagram-toggle-mark)
     (should (equal (canvas-diagram-marked-nodes) (list (nth 0 nodes) (nth 2 nodes))))
     (should (canvas-diagram-marked-p (nth 0 nodes)))
     (should-not (canvas-diagram-marked-p (nth 1 nodes)))
     (canvas-diagram-set-selected (nth 0 nodes))
     (canvas-diagram-toggle-mark)
     (should (equal (canvas-diagram-marked-nodes) (list (nth 2 nodes))))
     (canvas-diagram-unmark-all)
     (should-not (canvas-diagram-marked-nodes)))))

(ert-deftest canvas-diagram-a-mark-outlives-a-rebuild ()
  ;; GIVEN a diagram with a marked box
  ;; WHEN the diagram is built again, its boxes new objects of the same
  ;;      names
  ;; THEN the box of that name is marked still, because a mark is held by
  ;;      the key of a box and not by the object
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(400 . 300)
   (let ((marked (nth 1 (canvas-diagram-nodes canvas-diagram--diagram))))
     (canvas-diagram-set-selected marked)
     (canvas-diagram-toggle-mark)
     (canvas-diagram-rebuild)
     (should (equal (mapcar #'canvas-diagram-node-label (canvas-diagram-marked-nodes))
                    (list (canvas-diagram-node-label marked)))))))

(ert-deftest canvas-diagram-a-marked-box-is-ringed-as-well ()
  ;; GIVEN a diagram drawn with one box marked and the keyboard on another
  ;; WHEN the picture is read around the marked box
  ;; THEN there is ink of the selection colour around it, so a marked box
  ;;      is seen without moving the keyboard to it
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 400 300
     (let* ((canvas-diagram-colors (append '(:selection "red") canvas-diagram-colors))
            (diagram (canvas-diagram-test--laid-out '(("a") ("b") ("c")) ctx))
            (nodes (canvas-diagram-nodes diagram))
            (marked (nth 1 nodes)))
       (apply #'canvas-cairo-clear ctx (append (canvas-diagram-color :background) '(1)))
       (canvas-diagram--draw-all diagram ctx (canvas-diagram-font))
       (canvas-diagram--draw-marks diagram ctx (list marked) 2)
       (canvas-cairo-flush ctx)
       (let ((ringed (lambda (node)
                       (cl-loop for x from (max 0 (- (round (canvas-diagram-node-x node)) 3))
                                below (+ (round (canvas-diagram-node-x node)) 3)
                                thereis (canvas-diagram-test--inked-p
                                         (canvas-cairo-pixel ctx x (round (canvas-diagram-middle-y node))))))))
         (should (funcall ringed marked))
         (should-not (funcall ringed (nth 2 nodes))))))))

(ert-deftest canvas-diagram-the-marked-boxes-are-copied-together ()
  ;; GIVEN a diagram with two boxes marked
  ;; WHEN the copy key is pressed
  ;; THEN the text of both is on the kill ring, one to a line, in reading
  ;;      order, AND with no mark at all the keyboard's box alone is copied
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(400 . 300)
    (let ((nodes (canvas-diagram-nodes canvas-diagram--diagram)))
      (canvas-diagram-set-selected (nth 2 nodes))
      (canvas-diagram-toggle-mark)
      (canvas-diagram-set-selected (nth 0 nodes))
      (canvas-diagram-toggle-mark)
      (canvas-diagram-copy-node)
      (should (equal (current-kill 0) "a\nc"))
      (canvas-diagram-unmark-all)
      (canvas-diagram-set-selected (nth 1 nodes))
      (canvas-diagram-copy-node)
      (should (equal (current-kill 0) "b")))))

(ert-deftest canvas-diagram-embark-offers-the-marked-boxes ()
  ;; GIVEN a diagram with two boxes marked
  ;; WHEN embark asks the buffer what it holds
  ;; THEN the marked boxes are a target of their own, named by their
  ;;      labels, AND with nothing marked there is no such target
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(400 . 300)
    (let ((nodes (canvas-diagram-nodes canvas-diagram--diagram)))
      (should-not (canvas-diagram-embark-marked-target))
      (canvas-diagram-set-selected (nth 0 nodes))
      (canvas-diagram-toggle-mark)
      (canvas-diagram-set-selected (nth 1 nodes))
      (canvas-diagram-toggle-mark)
      (should (equal (canvas-diagram-embark-marked-target) '(canvas-diagram-marked . "a, b"))))))

(ert-deftest canvas-diagram-loading-the-file-again-fills-the-keymap-buffers-use ()
  ;; GIVEN the keymap every diagram buffer shares, holding a key it does
  ;;       not bind
  ;; WHEN it is filled again, as loading the file does
  ;; THEN it is the same map object, so that a buffer already open follows,
  ;;      the stray key is gone, AND the keys of a diagram are in it
  (let ((map canvas-diagram-mode-map))
    (define-key map (kbd "<f9>") #'ignore)
    (should (eq (canvas-diagram-fill-mode-map map) map))
    (should-not (lookup-key map (kbd "<f9>")))
    (should (eq (lookup-key map (kbd "C-SPC")) #'canvas-diagram-toggle-mark))
    (should (eq (lookup-key map (kbd "z")) #'canvas-diagram-zoom-fit))
    (should (keymapp (lookup-key map [canvas-diagram-node])))))

(ert-deftest canvas-diagram-a-box-from-before-rows-existed-is-taken-as-holding-none ()
  ;; GIVEN a box as an older version of this file made it, without the
  ;;       slot that holds rows, which a session that loaded the file again
  ;;       may still be holding
  ;; WHEN its rows are asked for, and it is sized
  ;; THEN it holds none and it is sized as a plain box, rather than failing
  ;;      with a slot that is out of range
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 4 4
     (let ((old (record 'canvas-diagram-node "Backlog" nil nil nil nil 0 0 0 0))
           (measure (canvas-diagram-measure ctx))
           (diagram (canvas-diagram-create)))
       (should-not (canvas-diagram--rows old))
       (canvas-diagram-size-node diagram old measure)
       (should (> (canvas-diagram-node-w old) 0))))))

(ert-deftest canvas-diagram-selection-tints-the-box-it-is-on ()
  "GIVEN the keyboard on one box
WHEN the boxes are filled
THEN that one is tinted towards the selection colour and the others are
     not, so the ring is not the only thing marking it.

A ring on its own is easy to lose in a drawing of many boxes."
  (let* ((diagram (canvas-diagram-create
                   :callbacks (list :node-rgb (lambda (&rest _) '(0.0 0.0 0.0)))))
         (here (canvas-diagram-node-create :label "here"))
         (there (canvas-diagram-node-create :label "there"))
         (canvas-diagram-colors '(:selection "white"))
         (canvas-diagram-selection-tint 0.5))
    (should (equal '(0.5 0.5 0.5) (canvas-diagram--node-fill diagram here here)))
    (should (equal '(0.0 0.0 0.0) (canvas-diagram--node-fill diagram there here)))))

(ert-deftest canvas-diagram-mark-tints-the-box-as-well-as-ringing-it ()
  "GIVEN a marked box
WHEN it is filled
THEN its fill is tinted too, not only its border.

The ring alone is drawn in the selection colour at low alpha, which on
a white cursor is a grey border and easy to miss."
  (let* ((diagram (canvas-diagram-create
                   :callbacks (list :node-rgb (lambda (&rest _) '(0.0 0.0 0.0)))))
         (marked (canvas-diagram-node-create :label "marked"))
         (plain (canvas-diagram-node-create :label "plain"))
         (canvas-diagram-colors '(:selection "white"))
         (canvas-diagram-mark-tint 0.5)
         (canvas-diagram-selection-tint 0.5))
    (cl-letf (((symbol-function 'canvas-diagram-marked-p)
               (lambda (node) (eq node marked))))
      (should (equal '(0.5 0.5 0.5) (canvas-diagram--node-fill diagram marked nil)))
      (should (equal '(0.0 0.0 0.0) (canvas-diagram--node-fill diagram plain nil)))
      ;; Marked and under the keyboard: both tints pull, so it still
      ;; stands out from the boxes that are only marked.
      (should (equal '(1.0 1.0 1.0)
                     (canvas-diagram--node-fill diagram marked marked))))))

(ert-deftest canvas-diagram-mark-tint-of-zero-leaves-the-fill-alone ()
  "GIVEN a tint of zero for marks
WHEN a marked box is filled
THEN its fill is untouched, so the ring is the only sign again."
  (let* ((diagram (canvas-diagram-create
                   :callbacks (list :node-rgb (lambda (&rest _) '(0.2 0.4 0.6)))))
         (node (canvas-diagram-node-create :label "marked"))
         (canvas-diagram-mark-tint 0))
    (cl-letf (((symbol-function 'canvas-diagram-marked-p) (lambda (_) t)))
      (should (equal '(0.2 0.4 0.6) (canvas-diagram--node-fill diagram node nil))))))

(ert-deftest canvas-diagram-selection-tint-of-zero-leaves-the-fill-alone ()
  "GIVEN a tint of zero
WHEN the box the keyboard is on is filled
THEN its fill is untouched, so the ring is the only mark again."
  (let* ((diagram (canvas-diagram-create
                   :callbacks (list :node-rgb (lambda (&rest _) '(0.2 0.4 0.6)))))
         (node (canvas-diagram-node-create :label "here"))
         (canvas-diagram-selection-tint 0))
    (should (equal '(0.2 0.4 0.6) (canvas-diagram--node-fill diagram node node)))))

(ert-deftest canvas-diagram-tinted-box-keeps-its-text-readable ()
  "GIVEN a tinted box, whose fill the package did not choose
WHEN its text is set
THEN the ink follows that fill, while every other box takes the text
     colour."
  (let ((canvas-diagram-colors '(:text "red")))
    (should (equal '(1.0 1.0 1.0) (canvas-diagram--node-ink '(0.0 0.0 0.0) t)))
    (should (equal '(0.0 0.0 0.0) (canvas-diagram--node-ink '(1.0 1.0 1.0) t)))
    (should (equal (canvas-diagram-color :text)
                   (canvas-diagram--node-ink '(0.0 0.0 0.0) nil)))))

(ert-deftest canvas-diagram-blend-walks-from-one-colour-to-the-other ()
  "GIVEN two colours
WHEN they are blended
THEN 0 gives the first, 1 the second, and a half the midpoint."
  (should (equal '(0.0 0.0 0.0) (canvas-diagram-blend '(0.0 0.0 0.0) '(1.0 1.0 1.0) 0)))
  (should (equal '(1.0 1.0 1.0) (canvas-diagram-blend '(0.0 0.0 0.0) '(1.0 1.0 1.0) 1)))
  (should (equal '(0.5 0.25 0.0) (canvas-diagram-blend '(1.0 0.5 0.0) '(0.0 0.0 0.0) 0.5))))

(ert-deftest canvas-diagram-marks-every-box-and-lets-them-all-go ()
  "GIVEN a drawing of three boxes
WHEN every box is marked and then let go
THEN all three are marked, and then none is."
  (canvas-diagram-test--with-context ctx 400 300
    (with-temp-buffer
      (setq-local canvas-diagram--diagram
                  (canvas-diagram-test--laid-out '(("a") ("b") ("c")) ctx))
      (cl-letf (((symbol-function 'canvas-diagram-redraw) #'ignore))
        (canvas-diagram-mark-all)
        (should (equal 3 (length (canvas-diagram-marked-nodes))))
        (should (cl-every #'canvas-diagram-marked-p
                          (canvas-diagram-nodes-shown)))
        (canvas-diagram-unmark-all)
        (should (null (canvas-diagram-marked-nodes)))))))

(ert-deftest canvas-diagram-marking-has-keys-and-menu-entries ()
  "GIVEN the mark, which had a key to toggle one box and nothing else
WHEN the keys and the menu are read
THEN marking every box and letting them all go are on keys of their own
     and in the menu."
  (dolist (pair '(("C-SPC" . canvas-diagram-toggle-mark)
                  ("M" . canvas-diagram-mark-all)
                  ("U" . canvas-diagram-unmark-all)))
    (should (eq (cdr pair) (lookup-key canvas-diagram-mode-map (kbd (car pair)))))
    (let ((suffix (transient-get-suffix 'canvas-diagram-test-menu (car pair))))
      (should suffix)
      (should (eq (cdr pair) (plist-get (cdr suffix) :command))))))

(ert-deftest canvas-diagram-menu-columns-line-up-across-rows ()
  "GIVEN a menu of several rows, each sized to its own widest entry
WHEN the menu is laid out
THEN every row is given the same least column widths, so the rows line
     up rather than each starting where its own content ends."
  (should (equal canvas-diagram-menu-column-widths
                 (oref (get 'canvas-diagram-test-menu 'transient--prefix)
                       column-widths))))

(ert-deftest canvas-diagram-one-question-asks-whether-a-box-is-in-view ()
  ;; GIVEN a box at a known place, and the view of a canvas that stops just
  ;;       short of it
  ;; WHEN the view is asked for with slack and without it
  ;; THEN the box reaches the view with slack and not without, which is why
  ;;      the drawing asks with slack and the scrolling asks without
  (let ((node (canvas-diagram-node-create :label "far" :x 104 :y 0 :w 40 :h 20)))
    (should (canvas-diagram--box-in-view-p
             node (canvas-diagram--view-rect '(10 . 10) '(100 . 100) 1.0 canvas-diagram--view-slack)))
    (should-not (canvas-diagram--box-in-view-p
                 node (canvas-diagram--view-rect '(10 . 10) '(100 . 100) 1.0)))))

(ert-deftest canvas-diagram-a-marked-box-out-of-view-costs-nothing ()
  ;; GIVEN marked boxes, one of them far outside the view
  ;; WHEN the marks are drawn for that view
  ;; THEN only the ones the canvas can show are drawn, as the boxes
  ;;      themselves are
  (canvas-diagram-test--rendering
   (canvas-diagram-test--with-context ctx 200 100
     (let* ((near (canvas-diagram-node-create :label "near" :x 10 :y 10 :w 40 :h 20))
            (far (canvas-diagram-node-create :label "far" :x 4000 :y 10 :w 40 :h 20))
            (view (canvas-diagram--view-rect '(0 . 0) '(200 . 100) 1.0 canvas-diagram--view-slack)))
       (should (equal (canvas-diagram--marks-in-view (list near far) view) (list near)))))))

;;; canvas-diagram-tests.el ends here

;;;; Images

(defconst canvas-diagram-test--fixtures
  (expand-file-name "fixtures"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The directory of the test fixtures.")

(defun canvas-diagram-test--fixture (name)
  "The fixture file NAME."
  (expand-file-name name canvas-diagram-test--fixtures))

(ert-deftest canvas-cairo-image-fills-its-box ()
  ;; GIVEN a canvas cleared to blue AND a red PNG of 4 by 4 pixels
  ;; WHEN the PNG is painted into the 2 by 2 box at (1,1)
  ;; THEN the pixels in the box are red AND those outside are still blue
  (canvas-diagram-test--with-context ctx 4 4
    (canvas-cairo-clear ctx 0 0 1 1)
    (canvas-cairo-image ctx (canvas-diagram-test--fixture "red-4x4.png") 1 1 2 2)
    (should (= (canvas-cairo-pixel ctx 1 1) #xFFFF0000))
    (should (= (canvas-cairo-pixel ctx 2 2) #xFFFF0000))
    (should (= (canvas-cairo-pixel ctx 0 0) #xFF0000FF))
    (should (= (canvas-cairo-pixel ctx 3 3) #xFF0000FF))))

(ert-deftest canvas-cairo-image-refuses-a-file-it-cannot-read ()
  ;; GIVEN a context AND a file that holds no image
  ;; WHEN that file is painted
  ;; THEN the module signals an error
  (canvas-diagram-test--with-context ctx 4 4
    (let ((err (should-error
                (canvas-cairo-image ctx
                                    (canvas-diagram-test--fixture "not-an-image.txt")
                                    0 0 2 2))))
      ;; The message must come from the module, so that a missing
      ;; function cannot make this test pass.
      (should (string-match-p "canvas-cairo: image" (format "%S" err))))))

(ert-deftest canvas-cairo-image-refuses-an-empty-box ()
  ;; GIVEN a context AND a readable PNG
  ;; WHEN the box has no width
  ;; THEN the module signals an error
  (canvas-diagram-test--with-context ctx 4 4
    (let ((err (should-error
                (canvas-cairo-image ctx
                                    (canvas-diagram-test--fixture "red-4x4.png")
                                    0 0 0 2))))
      (should (string-match-p "canvas-cairo: image box" (format "%S" err))))))

(defun canvas-diagram-test--reddish-p (argb)
  "Non-nil when ARGB is opaque and close to red.
A JPEG is lossy, so the exact value differs from #xFFFF0000."
  (let ((a (ash argb -24))
        (r (logand (ash argb -16) 255))
        (g (logand (ash argb -8) 255))
        (b (logand argb 255)))
    (and (= a 255) (> r 200) (< g 60) (< b 60))))

(ert-deftest canvas-cairo-image-reads-a-jpeg ()
  ;; GIVEN a canvas cleared to blue AND a red JPEG
  ;; WHEN the JPEG is painted over the whole canvas
  ;; THEN the pixels are close to red, because a JPEG is lossy
  (canvas-diagram-test--with-context ctx 4 4
    (canvas-cairo-clear ctx 0 0 1 1)
    (canvas-cairo-image ctx (canvas-diagram-test--fixture "red-4x4.jpg") 0 0 4 4)
    (should (canvas-diagram-test--reddish-p (canvas-cairo-pixel ctx 1 1)))
    (should (canvas-diagram-test--reddish-p (canvas-cairo-pixel ctx 2 2)))))

(ert-deftest canvas-cairo-image-reads-a-gif ()
  ;; GIVEN a canvas cleared to blue AND a red GIF
  ;; WHEN the GIF is painted over the whole canvas
  ;; THEN every pixel is opaque red
  (canvas-diagram-test--with-context ctx 4 4
    (canvas-cairo-clear ctx 0 0 1 1)
    (canvas-cairo-image ctx (canvas-diagram-test--fixture "red-4x4.gif") 0 0 4 4)
    (should (= (canvas-cairo-pixel ctx 0 0) #xFFFF0000))
    (should (= (canvas-cairo-pixel ctx 3 3) #xFFFF0000))))

;;;; Folding

(defconst canvas-diagram-test--tree
  '("root" ("a" ("a1") ("a2" ("a2x"))) ("b" ("b1")) ("c"))
  "A tree of four levels for the folding tests.  Each label is its key.")

(defvar canvas-diagram-test--fold-start nil
  "What the :fold-start of the tree stub gives.")

(defun canvas-diagram-test--fold-tree (item)
  "The fold tree of ITEM, a (LABEL . CHILDREN) of the stub's tree."
  (cons (car item) (mapcar #'canvas-diagram-test--fold-tree (cdr item))))

(defun canvas-diagram-test--tree-item (item label)
  "The item of the tree ITEM whose label is LABEL, or nil."
  (if (equal (car item) label)
      item
    (cl-some (lambda (child) (canvas-diagram-test--tree-item child label)) (cdr item))))

(defun canvas-diagram-test--tree-rows (item depth)
  "The (LABEL . DEPTH) of ITEM and of the items shown below it."
  (cons (cons (car item) depth)
        (and (cdr item)
             (not (canvas-diagram-folded-p (car item) depth))
             (mapcan (lambda (child) (canvas-diagram-test--tree-rows child (1+ depth)))
                     (cdr item)))))

(defun canvas-diagram-test--tree-layout (diagram ctx)
  "A fresh box for each shown item of DIAGRAM's tree, one below the other."
  (let ((measure (canvas-diagram-measure ctx))
        (y 0))
    (mapcar (lambda (row)
              (let ((node (canvas-diagram-node-create :label (car row))))
                (canvas-diagram-size-node diagram node measure)
                (setf (canvas-diagram-node-x node) (* 20 (cdr row))
                      (canvas-diagram-node-y node) y)
                (setq y (+ y (canvas-diagram-node-h node) 4))
                node))
            (canvas-diagram-test--tree-rows (canvas-diagram-model diagram) 0))))

(defconst canvas-diagram-test--tree-callbacks
  (list :build (lambda (_diagram spec) spec)
        :layout #'canvas-diagram-test--tree-layout
        :draw-edges #'ignore
        :move (lambda (diagram node direction)
                (canvas-diagram-neighbour (canvas-diagram-nodes diagram) node
                                          (if (eq direction 'previous) -1 1)))
        :fold-trees (lambda (diagram node)
                      (let ((model (canvas-diagram-model diagram)))
                        (if node
                            (mapcar #'canvas-diagram-test--fold-tree
                                    (cdr (canvas-diagram-test--tree-item model (canvas-diagram-node-label node))))
                          (list (canvas-diagram-test--fold-tree model)))))
        :fold-start (lambda (_diagram) canvas-diagram-test--fold-start))
  "How the tree stub plugs into canvas-diagram.")

(define-derived-mode canvas-diagram-test-tree-mode canvas-diagram-mode "Tree"
  "The mode of the tree stub.")

(defmacro canvas-diagram-test--in-tree (spec &rest body)
  "Run BODY in a buffer of the tree stub showing SPEC."
  (declare (indent 1))
  `(canvas-diagram-test--rendering
    (with-temp-buffer
      (canvas-diagram-test-tree-mode)
      (canvas-diagram-adopt (canvas-diagram-create :callbacks canvas-diagram-test--tree-callbacks) ,spec)
      (plist-put (cdr canvas-diagram--canvas) :data-width 400)
      (plist-put (cdr canvas-diagram--canvas) :data-height 400)
      (unwind-protect (progn ,@body)
        (canvas-diagram--release)))))

(defun canvas-diagram-test--shown-labels ()
  "The labels of the boxes this buffer shows, in reading order."
  (mapcar #'canvas-diagram-node-label (canvas-diagram-nodes-shown)))

(defun canvas-diagram-test--select-label (label)
  "Put the keyboard on the shown box LABEL."
  (canvas-diagram-set-selected (canvas-diagram-test--labelled label)))

(ert-deftest canvas-diagram-fold-rule-lets-a-fold-win-over-the-levels ()
  ;; GIVEN a tree shown at two levels
  ;; WHEN the rule is asked at each depth, before and after "a" is opened
  ;; THEN the top is open and the second level folded, AND the fold of "a" wins
  (let ((canvas-diagram-test--fold-start '(:levels 2)))
    (canvas-diagram-test--in-tree canvas-diagram-test--tree
      (should-not (canvas-diagram-folded-p "root" 0))
      (should (canvas-diagram-folded-p "a" 1))
      (canvas-diagram-set-fold "a" 'open)
      (should-not (canvas-diagram-folded-p "a" 1))
      (should (canvas-diagram-folded-p "b" 1)))))

(ert-deftest canvas-diagram-fold-toggle-folds-and-unfolds-the-box ()
  ;; GIVEN the whole tree shown, the keyboard on "a"
  ;; WHEN TAB is pressed twice, and then on the leaf "c"
  ;; THEN "a" hides its children, shows them again, AND the leaf is a user error
  (canvas-diagram-test--in-tree canvas-diagram-test--tree
    (canvas-diagram-test--select-label "a")
    (canvas-diagram-toggle-fold)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "b" "b1" "c")))
    (should (equal (canvas-diagram-test--selected) "a"))
    (canvas-diagram-toggle-fold)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "a2x" "b" "b1" "c")))
    (canvas-diagram-test--select-label "c")
    (should-error (canvas-diagram-toggle-fold) :type 'user-error)))

(ert-deftest canvas-diagram-fold-cycle-goes-folded-children-folded-all-open ()
  ;; GIVEN the whole tree shown, the keyboard on "a"
  ;; WHEN C-<tab> is pressed three times
  ;; THEN "a" folds, then opens with "a2" folded, then opens all below it
  (canvas-diagram-test--in-tree canvas-diagram-test--tree
    (canvas-diagram-test--select-label "a")
    (canvas-diagram-cycle-fold)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "b" "b1" "c")))
    (canvas-diagram-cycle-fold)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "b" "b1" "c")))
    (canvas-diagram-cycle-fold)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "a2x" "b" "b1" "c")))))

(ert-deftest canvas-diagram-fold-levels-cycle-to-the-height-and-drop-folds ()
  ;; GIVEN the whole tree shown, with "b" folded by hand
  ;; WHEN <backtab> is pressed four times
  ;; THEN one, two and three levels show, then all, AND the fold of "b" is gone
  (canvas-diagram-test--in-tree canvas-diagram-test--tree
    (canvas-diagram-test--select-label "b")
    (canvas-diagram-toggle-fold)
    (canvas-diagram-cycle-levels)
    (should (equal (canvas-diagram-test--shown-labels) '("root")))
    (canvas-diagram-cycle-levels)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "b" "c")))
    (canvas-diagram-cycle-levels)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "b" "b1" "c")))
    (canvas-diagram-cycle-levels)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "a2x" "b" "b1" "c")))))

(ert-deftest canvas-diagram-fold-digits-show-levels-of-the-box-and-of-the-diagram ()
  ;; GIVEN the whole tree shown, the keyboard on "a"
  ;; WHEN 2 is pressed, and then M-2
  ;; THEN two levels of "a" show, AND then two levels of the diagram, with
  ;;      the keyboard on "a"
  (canvas-diagram-test--in-tree canvas-diagram-test--tree
    (canvas-diagram-test--select-label "a")
    (canvas-diagram-show-level-2)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "b" "b1" "c")))
    (canvas-diagram-show-all-level-2)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "b" "c")))
    (should (equal (canvas-diagram-test--selected) "a"))))

(ert-deftest canvas-diagram-fold-brackets-show-fewer-and-more-levels ()
  ;; GIVEN the whole tree shown
  ;; WHEN [ is pressed twice, and then ] twice
  ;; THEN three, then two levels show, AND then three, then all
  (canvas-diagram-test--in-tree canvas-diagram-test--tree
    (canvas-diagram-shallower)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "b" "b1" "c")))
    (canvas-diagram-shallower)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "b" "c")))
    (canvas-diagram-deeper)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "b" "b1" "c")))
    (canvas-diagram-deeper)
    (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "a2x" "b" "b1" "c")))))

(ert-deftest canvas-diagram-fold-moves-the-keyboard-to-the-nearest-shown-box-above ()
  ;; GIVEN the whole tree shown, the keyboard on "a2x"
  ;; WHEN M-1 shows one level
  ;; THEN the keyboard is on "root", the nearest shown box above "a2x"
  (canvas-diagram-test--in-tree canvas-diagram-test--tree
    (canvas-diagram-test--select-label "a2x")
    (canvas-diagram-show-all-level-1)
    (should (equal (canvas-diagram-test--selected) "root"))))

(ert-deftest canvas-diagram-fold-start-comes-once-and-a-rebuild-keeps-the-folds ()
  ;; GIVEN a tree that starts at two levels with "a" open
  ;; WHEN "b" is opened, the diagram rebuilt, and then the buffer shown anew
  ;; THEN the start shows, the rebuild keeps "b" open, AND the new show starts again
  (let ((canvas-diagram-test--fold-start '(:levels 2 :open ("a"))))
    (canvas-diagram-test--in-tree canvas-diagram-test--tree
      (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "b" "c")))
      (canvas-diagram-set-fold "b" 'open)
      (canvas-diagram-rebuild)
      (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "b" "b1" "c")))
      (canvas-diagram-test-tree-mode)
      (canvas-diagram-adopt (canvas-diagram-create :callbacks canvas-diagram-test--tree-callbacks)
                            canvas-diagram-test--tree)
      (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "b" "c"))))))

(ert-deftest canvas-diagram-fold-unfold-to-opens-every-box-above ()
  ;; GIVEN a tree shown at one level
  ;; WHEN it unfolds to "a2x" and lays out again
  ;; THEN "a2x" shows, with the boxes above it, AND "b" stays folded
  (let ((canvas-diagram-test--fold-start '(:levels 1)))
    (canvas-diagram-test--in-tree canvas-diagram-test--tree
      (canvas-diagram-unfold-to "a2x")
      (canvas-diagram-relayout)
      (should (equal (canvas-diagram-test--shown-labels) '("root" "a" "a1" "a2" "a2x" "b" "c"))))))

(ert-deftest canvas-diagram-fold-signals-what-it-cannot-do ()
  ;; GIVEN a row diagram, which does not fold, a tree with a key twice, a
  ;;       tree whose start opens an unknown key, and a tree asked for no levels
  ;; WHEN each is shown, and a fold command runs in the row and the last tree
  ;; THEN the row is a user error, AND the trees are errors that name the key
  (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
    (should-error (canvas-diagram-toggle-fold) :type 'user-error)
    (should-not (canvas-diagram-folds-p)))
  (should (string-search "\"x\"" (error-message-string
                                  (should-error (canvas-diagram-test--in-tree '("root" ("a" ("x")) ("b" ("x"))))))))
  (let ((canvas-diagram-test--fold-start '(:open ("nowhere"))))
    (should (string-search "nowhere" (error-message-string
                                      (should-error (canvas-diagram-test--in-tree canvas-diagram-test--tree))))))
  (canvas-diagram-test--in-tree canvas-diagram-test--tree
    (should-error (canvas-diagram-show-all-level 0) :type 'error)))

;;;; Flying the eye to the box the keyboard reached

(defvar smear-cursor-mode)

(defun canvas-diagram-test--picture-rect (node)
  "NODE's box as it is drawn now, [X Y W H] in pixels of the picture."
  (pcase-let ((`(,x0 ,y0 ,x1 ,y1) (canvas-diagram--canvas-box
                                   node canvas-diagram--offset canvas-diagram--zoom)))
    (vector x0 y0 (- x1 x0) (- y1 y0))))

(defmacro canvas-diagram-test--flying (flown &rest body)
  "Run BODY with the fly function recording its boxes in FLOWN, a list of (FROM TO)."
  (declare (indent 1))
  `(let* ((,flown nil)
          (canvas-diagram-fly-function (lambda (from to) (push (list from to) ,flown))))
     ,@body))

(ert-deftest canvas-diagram-go-flies-the-eye-from-the-box-left-to-the-box-reached ()
  ;; GIVEN a row of three on a canvas too narrow for all of them, the
  ;;       keyboard on the first
  ;; WHEN the keyboard goes to the third, which scrolls the view
  ;; THEN the fly function gets the first box where it was drawn before
  ;;      the scroll, AND the third where it is drawn after it
  (canvas-diagram-test--in-buffer '(("a") ("b") ("c")) '(60 . 100)
    (canvas-diagram-test--flying flown
      (let ((a (canvas-diagram-test--labelled "a"))
            (c (canvas-diagram-test--labelled "c")))
        (canvas-diagram--select a)
        (let ((from (canvas-diagram-test--picture-rect a)))
          (canvas-diagram-go c)
          (should-not (equal from (canvas-diagram-test--picture-rect a)))
          (should (equal (list (list from (canvas-diagram-test--picture-rect c))) flown)))))))

(ert-deftest canvas-diagram-go-to-the-box-the-keyboard-is-on-flies-nothing ()
  ;; GIVEN a row, the keyboard on its first box
  ;; WHEN the keyboard goes to that same box
  ;; THEN nothing flies
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
    (canvas-diagram-test--flying flown
      (let ((a (canvas-diagram-test--labelled "a")))
        (canvas-diagram--select a)
        (canvas-diagram-go a)
        (should-not flown)))))

(ert-deftest canvas-diagram-go-flies-smear-cursor-while-it-is-on ()
  ;; GIVEN a row shown in a window, and smear-cursor on, then off
  ;; WHEN the keyboard goes to the second box each time
  ;; THEN smear-cursor flies over the picture, the buffer's one character,
  ;;      in that window while it is on, AND not while it is off
  (canvas-diagram-test--in-buffer '(("a") ("b")) '(300 . 200)
    (let ((calls nil)
          (a (canvas-diagram-test--labelled "a"))
          (b (canvas-diagram-test--labelled "b")))
      (cl-letf (((symbol-function 'smear-cursor-fly-in-picture)
                 (lambda (&rest args) (push args calls)))
                ((symbol-function 'get-buffer-window) (lambda (&rest _) 'a-window)))
        (let ((smear-cursor-mode t))
          (canvas-diagram--select a)
          (canvas-diagram-go b)
          (should (equal (list (list (point-min) (canvas-diagram-test--picture-rect a)
                                     (canvas-diagram-test--picture-rect b) 'a-window))
                         calls)))
        (setq calls nil)
        (let ((smear-cursor-mode nil))
          (canvas-diagram--select a)
          (canvas-diagram-go b)
          (should-not calls))))))

(ert-deftest canvas-diagram-page-keys-page-under-pixel-scrolling ()
  ;; GIVEN a diagram buffer, AND pixel-scroll-precision-mode on, whose own
  ;;       map binds the page keys to its own scroll commands
  ;; WHEN the page keys and C-v and M-v are looked up
  ;; THEN the page keys page through the diagram as C-v and M-v do,
  ;;      rather than scroll the window over its one line
  (require 'pixel-scroll)
  (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
    (let ((pixel-scroll-precision-mode t))
      (pcase-dolist (`(,key ,command) '(("<next>" canvas-diagram-page-down)
                                        ("C-v" canvas-diagram-page-down)
                                        ("<prior>" canvas-diagram-page-up)
                                        ("M-v" canvas-diagram-page-up)))
        (should (eq (key-binding (kbd key)) command))))))

(ert-deftest canvas-diagram-fold-keys-fall-through-in-a-diagram-that-does-not-fold ()
  ;; GIVEN a tree buffer and a row buffer
  ;; WHEN the fold keys are looked up in each
  ;; THEN the tree runs the fold commands, AND the row runs none of them
  (canvas-diagram-test--in-tree canvas-diagram-test--tree
    (should (canvas-diagram-folds-p))
    (pcase-dolist (`(,key ,command) '(("TAB" canvas-diagram-toggle-fold) ("C-<tab>" canvas-diagram-cycle-fold)
                                      ("<backtab>" canvas-diagram-cycle-levels) ("1" canvas-diagram-show-level-1)
                                      ("M-1" canvas-diagram-show-all-level-1) ("[" canvas-diagram-shallower)
                                      ("]" canvas-diagram-deeper)))
      (should (eq (key-binding (kbd key)) command))))
  (canvas-diagram-test--in-buffer '(("a")) '(300 . 200)
    (pcase-dolist (`(,key . ,command) canvas-diagram--fold-keys)
      (should-not (eq (key-binding (kbd key)) command)))))

(ert-deftest canvas-diagram-fold-menu-group-shows-only-where-boxes-fold ()
  ;; GIVEN the menu of the row stub
  ;; WHEN its TAB suffix and the condition of its groups are looked up
  ;; THEN the menu holds the fold command, AND one group shows only when
  ;;      the diagram folds
  (should (eq (plist-get (cdr (transient-get-suffix 'canvas-diagram-test-menu "TAB")) :command)
              'canvas-diagram-toggle-fold))
  (should (cl-some (lambda (group) (eq (plist-get (aref group 1) :if) 'canvas-diagram-folds-p))
                   (aref (get 'canvas-diagram-test-menu 'transient--layout) 2))))

(ert-deftest canvas-diagram-fold-export-without-a-buffer-takes-the-start ()
  ;; GIVEN a tree that starts at one level, and no diagram buffer
  ;; WHEN it is exported to a PNG
  ;; THEN the export lays out only the top box, as a new view would show it
  (let ((canvas-diagram-test--fold-start '(:levels 1))
        (diagram (canvas-diagram-create :callbacks canvas-diagram-test--tree-callbacks))
        (file (make-temp-file "tree" nil ".png")))
    (unwind-protect
        (canvas-diagram-test--rendering
         (with-temp-buffer
           (canvas-diagram-export diagram canvas-diagram-test--tree file))
         (should (equal (mapcar #'canvas-diagram-node-label (canvas-diagram-nodes diagram)) '("root"))))
      (delete-file file))))

(defun canvas-diagram-test--tree-callbacks-without (label)
  "The callbacks of the tree stub, with fold trees that leave out LABEL."
  (let ((trees (plist-get canvas-diagram-test--tree-callbacks :fold-trees)))
    (append (list :fold-trees
                  (lambda (diagram node)
                    (cl-labels ((drop (tree)
                                  (cons (car tree)
                                        (mapcar #'drop (cl-remove label (cdr tree) :key #'car :test #'equal)))))
                      (mapcar #'drop (funcall trees diagram node)))))
            canvas-diagram-test--tree-callbacks)))

(ert-deftest canvas-diagram-fold-moves-the-keyboard-back-from-a-hidden-box-outside-the-trees ()
  ;; GIVEN a tree whose fold trees leave out the leaf "a2x", with the
  ;;       keyboard on "a2x"
  ;; WHEN M-2 hides "a2x"
  ;; THEN the keyboard goes back in reading order to the nearest shown box, "a"
  (canvas-diagram-test--rendering
   (with-temp-buffer
     (canvas-diagram-test-tree-mode)
     (canvas-diagram-adopt (canvas-diagram-create :callbacks (canvas-diagram-test--tree-callbacks-without "a2x"))
                           canvas-diagram-test--tree)
     (unwind-protect
         (progn
           (canvas-diagram-test--select-label "a2x")
           (canvas-diagram-show-all-level-2)
           (should (equal (canvas-diagram-test--selected) "a")))
       (canvas-diagram--release)))))

(ert-deftest canvas-diagram-fold-keeps-the-keyboard-on-a-shown-box-outside-the-trees ()
  ;; GIVEN a tree whose fold trees leave out the leaf "a1", with the
  ;;       keyboard on "a1"
  ;; WHEN [ shows one level fewer, and "a1" still shows
  ;; THEN the keyboard stays on "a1"
  (canvas-diagram-test--rendering
   (with-temp-buffer
     (canvas-diagram-test-tree-mode)
     (canvas-diagram-adopt (canvas-diagram-create :callbacks (canvas-diagram-test--tree-callbacks-without "a1"))
                           canvas-diagram-test--tree)
     (unwind-protect
         (progn
           (canvas-diagram-test--select-label "a1")
           (canvas-diagram-shallower)
           (should (member "a1" (canvas-diagram-test--shown-labels)))
           (should (equal (canvas-diagram-test--selected) "a1")))
       (canvas-diagram--release)))))

(ert-deftest canvas-diagram-a-setting-reads-as-every-canvas-setting-does ()
  ;; GIVEN a setting of the diagram at another value than a fresh Emacs
  ;;       would have
  ;; WHEN its menu description is written
  ;; THEN it carries the star of canvas-keys, so every canvas menu in the
  ;;      family marks a changed setting the same way
  (let ((canvas-diagram-spacing 'airy))
    (should (equal (canvas-diagram-setting "spacing" 'canvas-diagram-spacing)
                   (canvas-keys-setting "spacing" 'canvas-diagram-spacing)))
    (should (string-search "*" (canvas-diagram-setting "spacing" 'canvas-diagram-spacing)))))
