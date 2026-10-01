;;; canvas-palette.el --- Colours for numbered things on an Emacs canvas -*- lexical-binding: t -*-

;; Copyright (C) 2026 canvas-diagram contributors

;; Author: Daskeladden
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0.50"))
;; Keywords: multimedia, faces
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

;; The faces canvas-series-1 to canvas-series-8, canvas-grid, canvas-axis
;; and canvas-reference are the theme API.  canvas-palette resolves them
;; for a dark or a light background, gives each series slot a marker
;; shape and a dash pattern, tells subscribers about theme changes, and
;; checks the colours for colour blindness and contrast.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'canvas-cairo)
(require 'canvas-diagram)

;;;; The colour science

(defconst canvas-palette--machado
  '((protan (0.152286 1.052583 -0.204868) (0.114503 0.786281 0.099216) (-0.003882 -0.048116 1.051998))
    (deutan (0.367322 0.860646 -0.227968) (0.280085 0.672501 0.047413) (-0.011820 0.042940 0.968881))
    (tritan (1.255528 -0.076749 -0.178779) (-0.078411 0.930809 0.147602) (0.004733 0.691367 0.303900)))
  "Colour-blind simulation of Machado et al. (2009), severity 1.0, linear RGB.")

(defun canvas-palette--dot (row values)
  "The dot product of the three numbers ROW and VALUES."
  (+ (* (nth 0 row) (nth 0 values)) (* (nth 1 row) (nth 1 values)) (* (nth 2 row) (nth 2 values))))

(defun canvas-palette--linear (channel)
  "The sRGB CHANNEL, 0 to 1, as linear light."
  (if (<= channel 0.04045)
      (/ channel 12.92)
    (expt (/ (+ channel 0.055) 1.055) 2.4)))

(defun canvas-palette--linear-rgb (rgb)
  "RGB, (R G B) in sRGB, as linear light."
  (mapcar #'canvas-palette--linear rgb))

(defun canvas-palette--cbrt (x)
  "The real cube root of X."
  (if (< x 0) (- (expt (- x) (/ 1.0 3))) (expt x (/ 1.0 3))))

(defun canvas-palette--oklab-from-linear (linear)
  "The OKLab (L A B) of the LINEAR light (R G B), after Ottosson."
  (let ((lms (list (canvas-palette--cbrt (canvas-palette--dot '(0.4122214708 0.5363325363 0.0514459929) linear))
                   (canvas-palette--cbrt (canvas-palette--dot '(0.2119034982 0.6806995451 0.1073969566) linear))
                   (canvas-palette--cbrt (canvas-palette--dot '(0.0883024619 0.2817188376 0.6299787005) linear)))))
    (list (canvas-palette--dot '(0.2104542553 0.7936177850 -0.0040720468) lms)
          (canvas-palette--dot '(1.9779984951 -2.4285922050 0.4505937099) lms)
          (canvas-palette--dot '(0.0259040371 0.7827717662 -0.8086757660) lms))))

(defun canvas-palette--simulate (linear kind)
  "The LINEAR light (R G B) as a reader with the colour blindness KIND sees it."
  (mapcar (lambda (row) (max 0.0 (min 1.0 (canvas-palette--dot row linear))))
          (or (alist-get kind canvas-palette--machado)
              (error "canvas-palette: no colour blindness is called %S" kind))))

(defun canvas-palette--delta-e (rgb1 rgb2 &optional kind)
  "100 times the OKLab distance of RGB1 and RGB2, as KIND sees them when given."
  (let* ((linear1 (canvas-palette--linear-rgb rgb1))
         (linear2 (canvas-palette--linear-rgb rgb2))
         (lab1 (canvas-palette--oklab-from-linear (if kind (canvas-palette--simulate linear1 kind) linear1)))
         (lab2 (canvas-palette--oklab-from-linear (if kind (canvas-palette--simulate linear2 kind) linear2))))
    (* 100 (sqrt (apply #'+ (cl-mapcar (lambda (a b) (expt (- a b) 2)) lab1 lab2))))))

(defun canvas-palette--oklch (rgb)
  "The OKLCH lightness and chroma of RGB, as (L C)."
  (pcase-let ((`(,l ,a ,b) (canvas-palette--oklab-from-linear (canvas-palette--linear-rgb rgb))))
    (list l (sqrt (+ (* a a) (* b b))))))

(defun canvas-palette--luminance (rgb)
  "The WCAG relative luminance of RGB."
  (canvas-palette--dot '(0.2126 0.7152 0.0722) (canvas-palette--linear-rgb rgb)))

(defun canvas-palette--contrast (rgb1 rgb2)
  "The WCAG contrast ratio of RGB1 and RGB2."
  (let ((l1 (canvas-palette--luminance rgb1))
        (l2 (canvas-palette--luminance rgb2)))
    (/ (+ (max l1 l2) 0.05) (+ (min l1 l2) 0.05))))

;;;; The faces

(defconst canvas-palette--slots
  '((:dark "#3987e5" :light "#2a78d6" :shape circle :dash [])
    (:dark "#d95926" :light "#eb6834" :shape square :dash [6 3])
    (:dark "#199e70" :light "#1baf7a" :shape triangle :dash [1 3])
    (:dark "#c98500" :light "#eda100" :shape diamond :dash [6 3 1 3])
    (:dark "#d55181" :light "#e87ba4" :shape cross :dash [10 4])
    (:dark "#008300" :light "#008300" :shape plus :dash [3 3])
    (:dark "#9085e9" :light "#4a3aa7" :shape down :dash [6 3 1 3 1 3])
    (:dark "#e66767" :light "#e34948" :shape pentagon :dash [1 6]))
  "The default colours, marker shape and dash of each series slot, in order.")

(defconst canvas-palette-slot-count (length canvas-palette--slots)
  "The number of series slots.")

(defconst canvas-palette--chrome
  '((grid "#2c2c2a" "#e1e0d9")
    (axis "#383835" "#c3c2b7")
    (reference "#898781" "#898781"))
  "The default dark and light colours of the chrome faces.")

(defun canvas-palette--face-spec (dark light)
  "A face spec with the foreground DARK on dark backgrounds and LIGHT on others."
  `((((background dark)) :foreground ,dark) (t :foreground ,light)))

(defun canvas-palette--series-face (n)
  "The face of series slot N, counted from 0."
  (intern (format "canvas-series-%d" (1+ n))))

(cl-loop for slot in canvas-palette--slots
         for n from 0
         do (custom-declare-face (canvas-palette--series-face n)
                                 (canvas-palette--face-spec (plist-get slot :dark) (plist-get slot :light))
                                 (format "Series slot %d of canvas drawings." (1+ n))
                                 :group 'canvas-diagram))

(pcase-dolist (`(,key ,dark ,light) canvas-palette--chrome)
  (custom-declare-face (intern (format "canvas-%s" key))
                       (canvas-palette--face-spec dark light)
                       (format "The %s of canvas drawings." key)
                       :group 'canvas-diagram))

;;;; Resolving a face

(defun canvas-palette-background ()
  "The background canvas drawings are on now: `light' on paper, else the frame's."
  (if canvas-diagram-paper 'light (frame-parameter nil 'background-mode)))

(defun canvas-palette--assert-background (background)
  "An error unless BACKGROUND is `dark' or `light'."
  (unless (memq background '(dark light))
    (error "canvas-palette: BACKGROUND is dark or light, not %S" background)))

(defun canvas-palette--background-requirement-p (requirement)
  "Whether the display REQUIREMENT of a face spec entry names a background."
  (eq (car-safe requirement) 'background))

(defun canvas-palette--names-background-p (spec)
  "Whether a display requirement of the face SPEC names a background."
  (seq-some (lambda (entry)
              (and (listp (car entry))
                   (seq-some #'canvas-palette--background-requirement-p (car entry))))
            spec))

(defun canvas-palette--display-matches-p (display background)
  "Whether the DISPLAY of a face spec entry matches on BACKGROUND.
A background requirement matches BACKGROUND, every other one the frame."
  (or (eq display t)
      (and (seq-every-p (lambda (requirement) (memq background (cdr requirement)))
                        (seq-filter #'canvas-palette--background-requirement-p display))
           (face-spec-set-match-display
            (seq-remove #'canvas-palette--background-requirement-p display)
            (selected-frame)))))

(defun canvas-palette--entry-attributes (entry)
  "The attributes of the face spec ENTRY, in either spec format."
  (let ((attributes (cdr entry)))
    (if (cdr attributes) attributes (car attributes))))

(defun canvas-palette--choose (spec background)
  "SPEC chosen for BACKGROUND the way `face-spec-choose' chooses.
Return a list of one attribute plist, or nil when nothing in SPEC applies."
  (let ((defaults nil))
    (catch 'chosen
      (dolist (entry spec)
        (let ((attributes (canvas-palette--entry-attributes entry)))
          (cond ((eq (car entry) 'default) (setq defaults attributes))
                ((canvas-palette--display-matches-p (car entry) background)
                 (throw 'chosen (list (append defaults attributes)))))))
      (and defaults (list defaults)))))

(defun canvas-palette--choose-named (spec background)
  "SPEC chosen for BACKGROUND, when SPEC names a background at all."
  (and (canvas-palette--names-background-p spec)
       (canvas-palette--choose spec background)))

(defun canvas-palette--spec-attributes (face background)
  "FACE's attributes on BACKGROUND, in the order `face-spec-recalc' sets them.
A later copy of an attribute wins over an earlier one."
  (let ((themed (mapcan (lambda (entry) (canvas-palette--choose-named (cadr entry) background))
                        (reverse (get face 'theme-face)))))
    (apply #'append
           (append (or themed (canvas-palette--choose (face-default-spec face) background))
                   (canvas-palette--choose-named (get face 'face-override-spec) background)))))

(defun canvas-palette--specified (attributes attribute)
  "The last ATTRIBUTE in the plist ATTRIBUTES, nil if absent or `unspecified'."
  (let ((value (car (last (cl-loop for (key setting) on attributes by #'cddr
                                   when (eq key attribute) collect setting)))))
    (unless (eq value 'unspecified) value)))

(defun canvas-palette--spec-foreground (face background path)
  "FACE's foreground on BACKGROUND from its specs, or nil.
It follows `face-alias' and :inherit.  PATH holds the faces on the way
to FACE, the nearest first."
  (when (memq face path)
    (error "canvas-palette: faces inherit in a loop: %s"
           (mapconcat #'symbol-name (reverse (cons face path)) " -> ")))
  (if-let* ((alias (get face 'face-alias)))
      (canvas-palette--spec-foreground alias background (cons face path))
    (let ((attributes (canvas-palette--spec-attributes face background)))
      (or (canvas-palette--specified attributes :foreground)
          (seq-some (lambda (parent) (canvas-palette--spec-foreground parent background (cons face path)))
                    (ensure-list (canvas-palette--specified attributes :inherit)))))))

(defun canvas-palette--foreground-value (face background)
  "FACE's foreground on BACKGROUND: Emacs's own on the frame's background."
  (if (eq background (frame-parameter nil 'background-mode))
      (face-attribute face :foreground nil t)
    (canvas-palette--spec-foreground face background nil)))

(defun canvas-palette--foreground (face background)
  "FACE's foreground on BACKGROUND as (R G B)."
  (canvas-palette--assert-background background)
  (let ((foreground (canvas-palette--foreground-value face background)))
    (when (memq foreground '(nil unspecified))
      (error "canvas-palette: face %S has no foreground for a %s background" face background))
    (or (canvas-diagram-rgb foreground)
        (error "canvas-palette: face %S has foreground %S, which is not a colour" face foreground))))

;;;; Slots

(defun canvas-palette-series (n &optional background)
  "Slot N, below `canvas-palette-slot-count', on BACKGROUND or the current one.
Return (:rgb RGB :shape SHAPE :dash DASHES)."
  (unless (and (integerp n) (<= 0 n) (< n canvas-palette-slot-count))
    (error "canvas-palette: series slot %S is not an integer from 0 to %d" n (1- canvas-palette-slot-count)))
  (let ((slot (nth n canvas-palette--slots)))
    (list :rgb (canvas-palette--foreground (canvas-palette--series-face n)
                                           (or background (canvas-palette-background)))
          :shape (plist-get slot :shape)
          :dash (plist-get slot :dash))))

(defun canvas-palette-chrome (key &optional background)
  "The colour of the chrome KEY, `grid', `axis' or `reference', as (R G B)."
  (unless (assq key canvas-palette--chrome)
    (error "canvas-palette: chrome is grid, axis or reference, not %S" key))
  (canvas-palette--foreground (intern (format "canvas-%s" key)) (or background (canvas-palette-background))))

;;;; Markers

(defconst canvas-palette--marker-line-width 2
  "The width in pixels of the lines of the cross and plus markers.")

(defun canvas-palette--fill-polygon (ctx points)
  "Fill the polygon through POINTS, each (X . Y), on CTX."
  (canvas-cairo-new-path ctx)
  (canvas-cairo-move-to ctx (caar points) (cdar points))
  (dolist (point (cdr points))
    (canvas-cairo-line-to ctx (car point) (cdr point)))
  (canvas-cairo-close-path ctx)
  (canvas-cairo-fill ctx))

(defun canvas-palette--stroke-lines (ctx lines)
  "Stroke LINES, each ((X1 . Y1) (X2 . Y2)), solid on CTX.
The lines are `canvas-palette--marker-line-width' wide."
  (canvas-cairo-save ctx)
  (canvas-cairo-set-dash ctx [])
  (canvas-cairo-set-line-width ctx canvas-palette--marker-line-width)
  (canvas-cairo-new-path ctx)
  (pcase-dolist (`((,x1 . ,y1) (,x2 . ,y2)) lines)
    (canvas-cairo-move-to ctx x1 y1)
    (canvas-cairo-line-to ctx x2 y2))
  (canvas-cairo-stroke ctx)
  (canvas-cairo-restore ctx))

(defun canvas-palette--pentagon-points (x y radius)
  "The five corners of a regular pentagon of RADIUS around X Y, a corner up."
  (cl-loop for i below 5
           collect (let ((angle (- (* i (/ (* 2 float-pi) 5)) (/ float-pi 2))))
                     (cons (+ x (* radius (cos angle))) (+ y (* radius (sin angle)))))))

(defun canvas-palette--marker-radius (size)
  "The radius of a marker SIZE wide; an error unless SIZE can be drawn."
  (let ((radius (and (numberp size) (/ size 2.0))))
    (unless (and radius (< radius 1.0e+INF) (>= size canvas-palette--marker-line-width))
      (error "canvas-palette: marker size %S is not a finite number of %s or more"
             size canvas-palette--marker-line-width))
    radius))

(defun canvas-palette-draw-marker (ctx shape x y size)
  "Draw SHAPE centred on X Y inside a SIZE by SIZE box, in CTX's current colour.
Drawing a marker discards the current path of CTX."
  (let ((r (canvas-palette--marker-radius size)))
    (pcase shape
      ('circle
       (canvas-cairo-new-path ctx)
       (canvas-cairo-arc ctx x y r 0 (* 2 float-pi))
       (canvas-cairo-fill ctx))
      ('square
       (canvas-palette--fill-polygon ctx (list (cons (- x r) (- y r)) (cons (+ x r) (- y r))
                                               (cons (+ x r) (+ y r)) (cons (- x r) (+ y r)))))
      ('triangle
       (canvas-palette--fill-polygon ctx (list (cons x (- y r)) (cons (+ x r) (+ y r)) (cons (- x r) (+ y r)))))
      ('down
       (canvas-palette--fill-polygon ctx (list (cons (- x r) (- y r)) (cons (+ x r) (- y r)) (cons x (+ y r)))))
      ('diamond
       (canvas-palette--fill-polygon ctx (list (cons x (- y r)) (cons (+ x r) y) (cons x (+ y r)) (cons (- x r) y))))
      ('pentagon
       (canvas-palette--fill-polygon ctx (canvas-palette--pentagon-points x y r)))
      ('cross
       (let ((reach (- r (/ canvas-palette--marker-line-width 2.0 (sqrt 2)))))
         (canvas-palette--stroke-lines
          ctx (list (list (cons (- x reach) (- y reach)) (cons (+ x reach) (+ y reach)))
                    (list (cons (+ x reach) (- y reach)) (cons (- x reach) (+ y reach)))))))
      ('plus
       (canvas-palette--stroke-lines ctx (list (list (cons x (- y r)) (cons x (+ y r)))
                                               (list (cons (- x r) y) (cons (+ x r) y)))))
      (_ (error "canvas-palette: no marker shape is called %S" shape)))
    nil))

;;;; The checks

(defconst canvas-palette--bands '((dark 0.48 0.67) (light 0.43 0.77))
  "The OKLCH lightness a series colour keeps on each background.")

(defconst canvas-palette--chroma-floor 0.10
  "The OKLCH chroma below which a colour reads as grey.")

(defconst canvas-palette--cvd-target 8.0
  "The colour-blind delta E that passes.")

(defconst canvas-palette--cvd-floor 6.0
  "The colour-blind delta E below which the check fails.")

(defconst canvas-palette--normal-floor 15.0
  "The delta E below which readers with full colour vision mix two colours up.")

(defconst canvas-palette--contrast-min 3.0
  "The WCAG contrast below which a mark needs labels beside it.")

(defun canvas-palette--assert-rgb (rgb)
  "An error unless RGB is (R G B), three numbers each from 0 to 1."
  (unless (and (eql (proper-list-p rgb) 3)
               (seq-every-p (lambda (channel) (and (numberp channel) (<= 0 channel 1))) rgb))
    (error "canvas-palette: a colour is (R G B), each from 0 to 1, not %S" rgb)))

(defun canvas-palette--hex-list (rgbs)
  "RGBS as #rrggbb, separated by spaces."
  (mapconcat #'canvas-diagram-hex rgbs " "))

(defun canvas-palette--pairs (count pairs)
  "The index pairs of COUNT colours: `adjacent' neighbours, or `all' pairs."
  (pcase pairs
    ('adjacent (cl-loop for i below (1- count) collect (cons i (1+ i))))
    ('all (cl-loop for i below count
                   append (cl-loop for j from (1+ i) below count collect (cons i j))))
    (_ (error "canvas-palette: PAIRS is adjacent or all, not %S" pairs))))

(defun canvas-palette--band (background)
  "The lightness band (LOW HIGH) for BACKGROUND."
  (canvas-palette--assert-background background)
  (alist-get background canvas-palette--bands))

(defun canvas-palette--check-band (rgbs background)
  "The `band' result of RGBS: their OKLCH lightness for BACKGROUND."
  (pcase-let* ((`(,low ,high) (canvas-palette--band background))
               (outside (seq-remove (lambda (rgb) (<= low (car (canvas-palette--oklch rgb)) high)) rgbs)))
    (list 'band (if outside 'fail 'pass)
          (if outside
              (format "outside L %.2f to %.2f: %s" low high (canvas-palette--hex-list outside))
            (format "all %d inside L %.2f to %.2f" (length rgbs) low high)))))

(defun canvas-palette--check-chroma (rgbs)
  "The `chroma' result of RGBS: their OKLCH chroma against the floor."
  (let ((grey (seq-filter (lambda (rgb) (< (cadr (canvas-palette--oklch rgb)) canvas-palette--chroma-floor)) rgbs)))
    (list 'chroma (if grey 'fail 'pass)
          (if grey
              (format "below %.2f: %s" canvas-palette--chroma-floor (canvas-palette--hex-list grey))
            (format "all %d at %.2f or more" (length rgbs) canvas-palette--chroma-floor)))))

(defun canvas-palette--worst-pair (rgbs pairs kinds)
  "The smallest delta E of PAIRS of RGBS over KINDS, as (DELTA KIND RGB1 RGB2)."
  (let ((worst nil))
    (dolist (kind kinds worst)
      (dolist (pair pairs)
        (let* ((rgb1 (nth (car pair) rgbs))
               (rgb2 (nth (cdr pair) rgbs))
               (delta (canvas-palette--delta-e rgb1 rgb2 kind)))
          (when (or (null worst) (< delta (car worst)))
            (setq worst (list delta kind rgb1 rgb2))))))))

(defun canvas-palette--check-cvd (rgbs pairs)
  "The `cvd' result of the PAIRS of RGBS for protan and deutan readers."
  (pcase-let* ((`(,delta ,kind ,rgb1 ,rgb2) (canvas-palette--worst-pair rgbs pairs '(protan deutan)))
               (tritan (car (canvas-palette--worst-pair rgbs pairs '(tritan)))))
    (list 'cvd
          (cond ((>= delta canvas-palette--cvd-target) 'pass)
                ((>= delta canvas-palette--cvd-floor) 'floor)
                (t 'fail))
          (format "worst %s and %s, %s %.1f, tritan %.1f"
                  (canvas-diagram-hex rgb1) (canvas-diagram-hex rgb2) kind delta tritan))))

(defun canvas-palette--check-normal (rgbs pairs)
  "The `normal' result of the PAIRS of RGBS for full colour vision."
  (pcase-let ((`(,delta ,_ ,rgb1 ,rgb2) (canvas-palette--worst-pair rgbs pairs '(nil))))
    (list 'normal (if (>= delta canvas-palette--normal-floor) 'pass 'fail)
          (format "worst %s and %s, %.1f" (canvas-diagram-hex rgb1) (canvas-diagram-hex rgb2) delta))))

(defun canvas-palette--check-contrast (rgbs surface)
  "The `contrast' result of RGBS against the SURFACE colour."
  (let ((low (seq-filter (lambda (rgb) (< (canvas-palette--contrast rgb surface) canvas-palette--contrast-min)) rgbs)))
    (list 'contrast (if low 'relief 'pass)
          (if low
              (format "below %g:1 on %s: %s" canvas-palette--contrast-min (canvas-diagram-hex surface)
                      (mapconcat (lambda (rgb) (format "%s %.2f" (canvas-diagram-hex rgb) (canvas-palette--contrast rgb surface)))
                                 low " "))
            (format "all %d at %g:1 or more on %s"
                    (length rgbs) canvas-palette--contrast-min (canvas-diagram-hex surface))))))

(defun canvas-palette-validate (rgbs surface background &optional pairs)
  "Check the colours RGBS against the SURFACE colour for BACKGROUND.
RGBS is a list of at least two (R G B), BACKGROUND `dark' or `light',
PAIRS `adjacent', the default, or `all'.  Return a list of
\(CHECK STATE DETAIL) for `band', `chroma', `cvd', `normal' and
`contrast', and last (ok BOOLEAN nil)."
  (mapc #'canvas-palette--assert-rgb (cons surface rgbs))
  (when (< (length rgbs) 2)
    (error "canvas-palette: checking needs two colours or more, not %d" (length rgbs)))
  (let* ((index-pairs (canvas-palette--pairs (length rgbs) (or pairs 'adjacent)))
         (results (list (canvas-palette--check-band rgbs background)
                        (canvas-palette--check-chroma rgbs)
                        (canvas-palette--check-cvd rgbs index-pairs)
                        (canvas-palette--check-normal rgbs index-pairs)
                        (canvas-palette--check-contrast rgbs surface))))
    (append results
            (list (list 'ok (not (seq-some (lambda (result) (eq (nth 1 result) 'fail)) results)) nil)))))

;;;; Theme changes

(defvar canvas-palette-changed-functions nil
  "Functions called with the theme after a theme is enabled or disabled.
Add one with `canvas-palette-subscribe', which also watches the themes.")

(defvar canvas-palette--warned-themes nil
  "The themes whose series faces were checked in this session.")

(defun canvas-palette--assert-function (function)
  "An error unless FUNCTION is a function."
  (unless (functionp function)
    (error "canvas-palette: a subscriber is a function, not %S" function)))

(defun canvas-palette-subscribe (function)
  "Call FUNCTION with the theme after every theme change."
  (canvas-palette--assert-function function)
  (add-hook 'canvas-palette-changed-functions function)
  (add-hook 'enable-theme-functions #'canvas-palette--theme-enabled 90)
  (add-hook 'disable-theme-functions #'canvas-palette--theme-disabled 90))

(defun canvas-palette-unsubscribe (function)
  "Stop calling FUNCTION on theme changes; stop watching themes after the last one."
  (canvas-palette--assert-function function)
  (remove-hook 'canvas-palette-changed-functions function)
  (unless canvas-palette-changed-functions
    (remove-hook 'enable-theme-functions #'canvas-palette--theme-enabled)
    (remove-hook 'disable-theme-functions #'canvas-palette--theme-disabled)))

(defun canvas-palette--series-rgbs (background)
  "The eight series colours on BACKGROUND, in slot order."
  (cl-loop for n below canvas-palette-slot-count collect (plist-get (canvas-palette-series n background) :rgb)))

(defun canvas-palette-surface (background)
  "The surface colour, as (R G B), that a drawing on BACKGROUND uses.
It is the frame's background colour when the frame's background mode is
BACKGROUND and that colour resolves.  Otherwise it is black for `dark'
and white for `light'."
  (canvas-palette--assert-background background)
  (let ((frame-rgb (canvas-diagram-rgb (face-background 'default nil t))))
    (cond ((and frame-rgb (eq background (frame-parameter nil 'background-mode))) frame-rgb)
          ((eq background 'dark) '(0.0 0.0 0.0))
          (t '(1.0 1.0 1.0)))))

(defun canvas-palette--subset-results (rgbs surface background)
  "The results of RGBS as neighbours and of their first three in all pairs.
Each is (PAIRS CHECK STATE DETAIL), the summaries (PAIRS ok BOOLEAN nil) too."
  (cl-loop for (subset . pairs) in (list (cons rgbs 'adjacent) (cons (seq-take rgbs 3) 'all))
           append (mapcar (lambda (result) (cons pairs result))
                          (canvas-palette-validate subset surface background pairs))))

(defun canvas-palette--failures (rgbs surface background)
  "The failing `canvas-palette--subset-results' of RGBS as warning lines."
  (cl-loop for (pairs check state detail) in (canvas-palette--subset-results rgbs surface background)
           when (eq state 'fail)
           collect (format "%s, %s pairs: %s" check pairs detail)))

(defun canvas-palette--face-list (rgbs)
  "The series faces with their colours RGBS, in slot order."
  (string-join (cl-loop for rgb in rgbs
                        for n from 0
                        collect (format "%s %s" (canvas-palette--series-face n) (canvas-diagram-hex rgb)))
               ", "))

(defun canvas-palette--warning-text (theme background failures rgbs)
  "The warning that the series RGBS fail FAILURES on BACKGROUND after THEME."
  (format (concat "After theme %s was enabled, the canvas-series faces fail "
                  "the colour checks on a %s background:\n%s\nFaces: %s\n"
                  "M-x canvas-palette-check gives the full report.")
          theme background (string-join failures "\n") (canvas-palette--face-list rgbs)))

(defun canvas-palette--warn-once (theme)
  "Warn once in the session when THEME's series faces fail the checks."
  (unless (memq theme canvas-palette--warned-themes)
    (let* ((background (frame-parameter nil 'background-mode))
           (rgbs (canvas-palette--series-rgbs background))
           (failures (canvas-palette--failures rgbs (canvas-palette-surface background) background)))
      (when failures
        (display-warning 'canvas-palette (canvas-palette--warning-text theme background failures rgbs))))
    (push theme canvas-palette--warned-themes)))

(defun canvas-palette--theme-enabled (theme)
  "Check THEME once, then tell the subscribers."
  (unless (eq theme 'user)
    (canvas-palette--warn-once theme))
  (run-hook-with-args 'canvas-palette-changed-functions theme))

(defun canvas-palette--theme-disabled (theme)
  "Tell the subscribers that THEME is gone."
  (run-hook-with-args 'canvas-palette-changed-functions theme))

;;;; The report

(defun canvas-palette--report-section (background surface)
  "The report lines of the series faces on BACKGROUND over SURFACE, as a string."
  (let ((rgbs (canvas-palette--series-rgbs background)))
    (string-join
     (cons (format "The %s background, on %s, slots %s:"
                   background (canvas-diagram-hex surface) (canvas-palette--hex-list rgbs))
           (cl-loop for (pairs check state detail) in (canvas-palette--subset-results rgbs surface background)
                    unless (eq check 'ok)
                    collect (format "  %-8s %-8s %-6s %s" pairs check state detail)))
     "\n")))

(defun canvas-palette--report ()
  "The report text: dark on the frame's dark surface, light on white."
  (concat (canvas-palette--report-section 'dark (canvas-palette-surface 'dark))
          "\n\n"
          (canvas-palette--report-section 'light '(1.0 1.0 1.0))
          "\n"))

;;;###autoload
(defun canvas-palette-check ()
  "Report the colour checks of the series faces, on dark and on light."
  (interactive)
  (let ((report (canvas-palette--report)))
    (with-current-buffer (get-buffer-create "*canvas-palette-check*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert report))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer)))))

(provide 'canvas-palette)
;;; canvas-palette.el ends here
