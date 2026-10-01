;;; canvas-palette-tests.el --- tests -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'canvas-palette)

(defun canvas-palette-test--rgb (hex)
  "HEX as (R G B); an error when it is no colour."
  (or (canvas-diagram-rgb hex) (error "Not a colour: %s" hex)))

(defun canvas-palette-test--rounds-to (value expected places)
  "Whether VALUE shows as EXPECTED with PLACES decimals."
  (<= (abs (- value expected)) (+ (/ 0.5 (expt 10.0 places)) 1e-9)))

(defmacro canvas-palette-test--with-theme-hooks (&rest body)
  "Run BODY with no subscribers and no theme hook functions, bound for BODY."
  (declare (indent 0))
  `(let ((canvas-palette-changed-functions nil)
         (enable-theme-functions nil)
         (disable-theme-functions nil))
     ,@body))

;;;; The colour science

(ert-deftest canvas-palette-delta-e-matches-the-dataviz-validator ()
  ;; GIVEN colour pairs whose delta E the dataviz validator reported
  ;; WHEN canvas-palette computes it with no simulation, or as a protan,
  ;;      deutan or tritan reader sees it
  ;; THEN each shows as the validator's number with one decimal
  (dolist (case '(("#eb6834" "#2a78d6" protan 24.7)
                  ("#eb6834" "#2a78d6" tritan 32.7)
                  ("#eb6834" "#2a78d6" nil 33.6)
                  ("#d95926" "#3987e5" protan 26.8)
                  ("#d95926" "#3987e5" nil 31.8)
                  ("#32cd32" "#ff8c00" deutan 3.8)
                  ("#556b2f" "#a0522d" protan 2.8)
                  ("#556b2f" "#a0522d" nil 13.9)))
    (pcase-let ((`(,a ,b ,kind ,expected) case))
      (should (canvas-palette-test--rounds-to
               (canvas-palette--delta-e (canvas-palette-test--rgb a) (canvas-palette-test--rgb b) kind)
               expected 1)))))

(ert-deftest canvas-palette-oklch-matches-the-dataviz-validator ()
  ;; GIVEN colours whose OKLCH lightness or chroma the dataviz validator reported
  ;; WHEN canvas-palette computes their OKLCH
  ;; THEN each shows as the validator's number with three decimals
  (should (canvas-palette-test--rounds-to (car (canvas-palette--oklch (canvas-palette-test--rgb "#ff8c00"))) 0.751 3))
  (should (canvas-palette-test--rounds-to (car (canvas-palette--oklch (canvas-palette-test--rgb "#ffd700"))) 0.887 3))
  (should (canvas-palette-test--rounds-to (cadr (canvas-palette--oklch (canvas-palette-test--rgb "#2a4e6f"))) 0.070 3)))

(ert-deftest canvas-palette-contrast-matches-the-dataviz-validator ()
  ;; GIVEN colours on surfaces whose WCAG contrast the dataviz validator reported
  ;; WHEN canvas-palette computes the contrast
  ;; THEN each shows as the validator's number with two decimals
  (should (canvas-palette-test--rounds-to
           (canvas-palette--contrast (canvas-palette-test--rgb "#1baf7a") (canvas-palette-test--rgb "#ffffff")) 2.82 2))
  (should (canvas-palette-test--rounds-to
           (canvas-palette--contrast (canvas-palette-test--rgb "#2a4e6f") (canvas-palette-test--rgb "#000000")) 2.42 2)))

;;;; The checks

(defconst canvas-palette-test--dark-defaults
  '("#3987e5" "#d95926" "#199e70" "#c98500" "#d55181" "#008300" "#9085e9" "#e66767"))

(defconst canvas-palette-test--light-defaults
  '("#2a78d6" "#eb6834" "#1baf7a" "#eda100" "#e87ba4" "#008300" "#4a3aa7" "#e34948"))

(defun canvas-palette-test--state (results check)
  "The state of CHECK in RESULTS."
  (nth 1 (assq check results)))

(ert-deftest canvas-palette-validate-passes-the-dark-defaults-on-black ()
  ;; GIVEN the dark default series colours and a black surface
  ;; WHEN they are checked as neighbours, and the first three in all pairs
  ;; THEN every check passes
  (let ((rgbs (mapcar #'canvas-palette-test--rgb canvas-palette-test--dark-defaults))
        (black '(0.0 0.0 0.0)))
    (dolist (results (list (canvas-palette-validate rgbs black 'dark 'adjacent)
                           (canvas-palette-validate (seq-take rgbs 3) black 'dark 'all)))
      (dolist (check '(band chroma cvd normal contrast))
        (should (eq (canvas-palette-test--state results check) 'pass)))
      (should (eq (canvas-palette-test--state results 'ok) t)))))

(ert-deftest canvas-palette-validate-passes-the-light-defaults-on-white-with-relief ()
  ;; GIVEN the light default series colours and a white surface
  ;; WHEN they are checked as neighbours
  ;; THEN every colour check passes
  ;;      AND contrast asks for relief, because aqua, yellow and magenta are below 3:1
  (let ((results (canvas-palette-validate (mapcar #'canvas-palette-test--rgb canvas-palette-test--light-defaults)
                                          '(1.0 1.0 1.0) 'light)))
    (dolist (check '(band chroma cvd normal))
      (should (eq (canvas-palette-test--state results check) 'pass)))
    (should (eq (canvas-palette-test--state results 'contrast) 'relief))
    (should (eq (canvas-palette-test--state results 'ok) t))))

(ert-deftest canvas-palette-validate-fails-the-vivid-palette-for-colour-blind-readers ()
  ;; GIVEN the vivid palette of canvas-diagram on a black surface
  ;; WHEN it is checked as neighbours
  ;; THEN the colour-blind check fails and the result is not ok
  (let ((results (canvas-palette-validate
                  (mapcar #'canvas-palette-test--rgb
                          '("#1e90ff" "#ff8c00" "#32cd32" "#ba55d3" "#dc143c" "#ffd700" "#00ced1" "#ff69b4"))
                  '(0.0 0.0 0.0) 'dark)))
    (should (eq (canvas-palette-test--state results 'cvd) 'fail))
    (should (eq (canvas-palette-test--state results 'ok) nil))))

(ert-deftest canvas-palette-validate-refuses-input-it-cannot-check ()
  ;; GIVEN two colours
  ;; WHEN it is asked to check one colour, an unknown background or an unknown pair list
  ;; THEN each is an error whose message names what it cannot check
  (let ((rgbs '((1.0 0.0 0.0) (0.0 0.0 1.0))))
    (let ((err (should-error (canvas-palette-validate (list (car rgbs)) '(0.0 0.0 0.0) 'dark))))
      (should (string-search "not 1" (cadr err))))
    (let ((err (should-error (canvas-palette-validate rgbs '(0.0 0.0 0.0) 'grey))))
      (should (string-search "grey" (cadr err))))
    (let ((err (should-error (canvas-palette-validate rgbs '(0.0 0.0 0.0) 'dark 'some))))
      (should (string-search "some" (cadr err))))))

(ert-deftest canvas-palette-validate-refuses-a-colour-that-is-not-rgb ()
  ;; GIVEN a triple with 255 in it, a four-element list and a string
  ;; WHEN each is checked as a series colour, and as the surface
  ;; THEN each is an error whose message shows the bad value
  (let ((black '(0.0 0.0 0.0)))
    (dolist (bad '((1.0 255 0.0) (0.0 0.0 0.0 1.0) "#ff0000"))
      (let ((err (should-error (canvas-palette-validate (list bad black) black 'dark))))
        (should (string-search (format "%S" bad) (cadr err))))
      (let ((err (should-error (canvas-palette-validate (list black black) bad 'dark))))
        (should (string-search (format "%S" bad) (cadr err)))))))

;;;; Faces and slots

(defface canvas-palette-test-face
  '((((background dark)) :foreground "#3987e5") (t :foreground "#2a78d6"))
  "A face with a dark and a light branch, for the tests."
  :group 'canvas-diagram)

(defface canvas-palette-test-inherit
  '((t :inherit canvas-palette-test-face))
  "A face that inherits its colour, for the tests."
  :group 'canvas-diagram)

(defface canvas-palette-test-bad
  '((t :foreground "not-a-colour"))
  "A face whose colour does not resolve, for the tests."
  :group 'canvas-diagram)

(defface canvas-palette-test-no-colour
  '((t :weight bold))
  "A face with no colour, for the tests."
  :group 'canvas-diagram)

(defface canvas-palette-test-inherit-list
  '((t :inherit (canvas-palette-test-no-colour canvas-palette-test-face canvas-palette-test-bad)))
  "A face that inherits no colour, then a colour, then a bad colour, for the tests."
  :group 'canvas-diagram)

(defmacro canvas-palette-test--with-theme (theme faces &rest body)
  "Run BODY with THEME enabled, setting FACES; disable and forget it afterwards."
  (declare (indent 2))
  `(unwind-protect
       (progn
         (custom-declare-theme ',theme ',(intern (format "%s-theme" theme)))
         (apply #'custom-theme-set-faces ',theme ',faces)
         (enable-theme ',theme)
         ,@body)
     (disable-theme ',theme)
     (setq custom-known-themes (delq ',theme custom-known-themes))
     (setplist ',theme nil)))

(defun canvas-palette-test--face-state (face)
  "FACE's override spec, modified flag and attributes for new frames."
  (list (get face 'face-override-spec) (get face 'face-modified) (face-all-attributes face t)))

(defun canvas-palette-test--restore-face (face state)
  "Give FACE back the STATE of `canvas-palette-test--face-state' on every frame.
`internal-make-lisp-face' clears the attributes for new frames.  Setting
them to `unspecified' instead would hide the default spec from the next
theme change."
  (pcase-let ((`(,override ,modified ,attributes) state))
    (put face 'face-override-spec override)
    (internal-make-lisp-face face)
    (pcase-dolist (`(,attribute . ,value) attributes)
      (unless (eq value 'unspecified)
        (set-face-attribute face t attribute value)))
    (dolist (frame (frame-list))
      (face-spec-recalc face frame))
    (put face 'face-modified modified)))

(defmacro canvas-palette-test--restoring-face (face &rest body)
  "Run BODY, then give FACE back the state it had before."
  (declare (indent 1))
  (let ((state (make-symbol "state")))
    `(let ((,state (canvas-palette-test--face-state ,face)))
       (unwind-protect (progn ,@body)
         (canvas-palette-test--restore-face ,face ,state)))))

(ert-deftest canvas-palette-foreground-takes-the-branch-of-the-background ()
  ;; GIVEN a face with a dark and a light branch, and a face that inherits it
  ;; WHEN each is resolved for a dark and for a light background
  ;; THEN the dark background gets the dark colour
  ;;      AND the light background gets the light colour, through the inheritance too
  (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'dark) (canvas-palette-test--rgb "#3987e5")))
  (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#2a78d6")))
  (should (equal (canvas-palette--foreground 'canvas-palette-test-inherit 'light) (canvas-palette-test--rgb "#2a78d6"))))

(ert-deftest canvas-palette-foreground-uses-a-plain-theme-spec-only-on-the-frame-background ()
  ;; GIVEN a theme that gives the face one colour with no background branch, in batch where the frame is dark
  ;; WHEN the face is resolved for a dark and for a light background
  ;; THEN the dark background gets the theme's colour
  ;;      AND the light background gets the face's own light colour
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-theme canvas-palette-test-plain
        ((canvas-palette-test-face ((t :foreground "#123456"))))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'dark) (canvas-palette-test--rgb "#123456")))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#2a78d6"))))))

(ert-deftest canvas-palette-foreground-uses-a-theme-branch-for-its-background ()
  ;; GIVEN a theme that gives the face a colour for light backgrounds only
  ;; WHEN the face is resolved for a light and for a dark background
  ;; THEN the light background gets the theme's colour
  ;;      AND the dark background gets the face's own dark colour
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-theme canvas-palette-test-light
        ((canvas-palette-test-face ((((background light)) :foreground "#abcdef"))))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#abcdef")))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'dark) (canvas-palette-test--rgb "#3987e5"))))))

(ert-deftest canvas-palette-foreground-follows-the-precedence-of-the-themes ()
  ;; GIVEN a dark frame, a lower theme that gives the face #0000ff with no background branch,
  ;;       and a higher theme that gives it #ff0000 for light backgrounds only
  ;; WHEN the face is resolved for a dark and for a light background
  ;; THEN the dark background gets the lower theme's #0000ff, as Emacs shows the face
  ;;      AND the light background gets the higher theme's #ff0000
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-theme canvas-palette-test-lower
        ((canvas-palette-test-face ((t :foreground "#0000ff"))))
      (canvas-palette-test--with-theme canvas-palette-test-higher
          ((canvas-palette-test-face ((((background light)) :foreground "#ff0000"))))
        (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'dark) (canvas-palette-test--rgb "#0000ff")))
        (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#ff0000")))))))

(ert-deftest canvas-palette-foreground-merges-the-themes-on-the-other-background ()
  ;; GIVEN a dark frame and three themes that each give the face a light branch:
  ;;       the lowest #00ff00, the middle one #ff0000 and the highest only a bold weight
  ;; WHEN the face is resolved for a light background
  ;; THEN it gets the middle theme's #ff0000, because every theme merges and a later one wins
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-theme canvas-palette-test-lowest
        ((canvas-palette-test-face ((((background light)) :foreground "#00ff00"))))
      (canvas-palette-test--with-theme canvas-palette-test-middle
          ((canvas-palette-test-face ((((background light)) :foreground "#ff0000"))))
        (canvas-palette-test--with-theme canvas-palette-test-highest
            ((canvas-palette-test-face ((((background light)) :weight bold))))
          (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light)
                         (canvas-palette-test--rgb "#ff0000"))))))))

(ert-deftest canvas-palette-foreground-takes-a-t-branch-after-a-background-branch ()
  ;; GIVEN a dark frame and a theme that gives the face #111111 for dark backgrounds and #222222 otherwise
  ;; WHEN the face is resolved for a light and for a dark background
  ;; THEN the light background gets the theme's #222222
  ;;      AND the dark background gets the theme's #111111
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-theme canvas-palette-test-dark-then-t
        ((canvas-palette-test-face ((((background dark)) :foreground "#111111") (t :foreground "#222222"))))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#222222")))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'dark) (canvas-palette-test--rgb "#111111"))))))

(ert-deftest canvas-palette-foreground-takes-the-last-copy-of-a-repeated-attribute ()
  ;; GIVEN a dark frame and a theme whose dark and light branches each set :foreground twice
  ;; WHEN the face is resolved for a dark and for a light background
  ;; THEN the dark background gets the second dark colour, as Emacs shows the face
  ;;      AND the light background gets the second light colour, because a later copy wins as in face-spec-choose
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-theme canvas-palette-test-repeated
        ((canvas-palette-test-face ((((background dark)) :foreground "#101010" :foreground "#202020")
                                    (((background light)) :foreground "#303030" :foreground "#404040"))))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'dark) (canvas-palette-test--rgb "#202020")))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#404040"))))))

(ert-deftest canvas-palette-foreground-follows-a-face-alias ()
  ;; GIVEN a dark frame, an alias of canvas-series-1,
  ;;       and a theme that makes the test face inherit the alias on dark and on light backgrounds
  ;; WHEN the test face is resolved for a dark and for a light background
  ;; THEN each background gets the colour of canvas-series-1
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (unwind-protect
        (progn
          (put 'canvas-palette-test-series-alias 'face-alias 'canvas-series-1)
          (canvas-palette-test--with-theme canvas-palette-test-alias
              ((canvas-palette-test-face ((((background dark)) :inherit canvas-palette-test-series-alias)
                                          (((background light)) :inherit canvas-palette-test-series-alias))))
            (dolist (background '(dark light))
              (should (equal (canvas-palette--foreground 'canvas-palette-test-face background)
                             (canvas-palette--foreground 'canvas-series-1 background))))))
      (setplist 'canvas-palette-test-series-alias nil))))

(ert-deftest canvas-palette-foreground-checks-the-other-display-requirements-on-the-frame ()
  ;; GIVEN a dark frame and a theme that gives the face #abcdef for light backgrounds
  ;;       with more colours than any display has, and #fedcba for light backgrounds
  ;; WHEN the face is resolved for a light background
  ;; THEN it gets #fedcba, because the frame fails the colour requirement of the first branch
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-theme canvas-palette-test-min-colors
        ((canvas-palette-test-face ((((background light) (min-colors 1000000000000)) :foreground "#abcdef")
                                    (((background light)) :foreground "#fedcba"))))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#fedcba"))))))

(ert-deftest canvas-palette-foreground-merges-a-default-entry-like-face-spec-choose ()
  ;; GIVEN a dark frame and a theme whose specs open with a default entry of #0a0a0a:
  ;;       the face then has only a bold weight for light backgrounds,
  ;;       and the inheriting face has #0b0b0b for light backgrounds
  ;; WHEN both faces are resolved for a light background
  ;; THEN the face gets the default entry's #0a0a0a
  ;;      AND the inheriting face gets its light #0b0b0b, which wins over the default entry
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-theme canvas-palette-test-default-entry
        ((canvas-palette-test-face ((default :foreground "#0a0a0a") (((background light)) :weight bold)))
         (canvas-palette-test-inherit ((default :foreground "#0a0a0a") (((background light)) :foreground "#0b0b0b"))))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#0a0a0a")))
      (should (equal (canvas-palette--foreground 'canvas-palette-test-inherit 'light) (canvas-palette-test--rgb "#0b0b0b"))))))

(ert-deftest canvas-palette-foreground-counts-set-face-attribute-only-on-the-frame-background ()
  ;; GIVEN a dark frame and a face whose foreground set-face-attribute made #ff00ff
  ;; WHEN the face is resolved for a dark and for a light background
  ;; THEN the dark background gets #ff00ff, as Emacs shows the face
  ;;      AND the light background gets the face's own #2a78d6, because set-face-attribute writes no spec
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--restoring-face 'canvas-palette-test-face
    (set-face-attribute 'canvas-palette-test-face nil :foreground "#ff00ff")
    (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'dark) (canvas-palette-test--rgb "#ff00ff")))
    (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#2a78d6")))))

(ert-deftest canvas-palette-foreground-counts-face-spec-set-like-a-theme ()
  ;; GIVEN a dark frame and a face that face-spec-set gave #aa0000 for dark and #00aa00 for light backgrounds
  ;; WHEN the face is resolved for a dark and for a light background
  ;; THEN the dark background gets #aa0000
  ;;      AND the light background gets #00aa00
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--restoring-face 'canvas-palette-test-face
    (face-spec-set 'canvas-palette-test-face '((((background dark)) :foreground "#aa0000")
                                               (((background light)) :foreground "#00aa00")))
    (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'dark) (canvas-palette-test--rgb "#aa0000")))
    (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#00aa00")))
    ;; WHEN face-spec-set gives the face #0000aa with no background branch instead
    ;; THEN the dark background gets #0000aa
    ;;      AND the light background gets the face's own #2a78d6
    (face-spec-set 'canvas-palette-test-face '((t :foreground "#0000aa")))
    (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'dark) (canvas-palette-test--rgb "#0000aa")))
    (should (equal (canvas-palette--foreground 'canvas-palette-test-face 'light) (canvas-palette-test--rgb "#2a78d6")))))

(ert-deftest canvas-palette-foreground-tries-each-face-of-an-inherit-list ()
  ;; GIVEN a dark frame and a face that inherits a face with no colour and then the test face
  ;; WHEN it is resolved for a dark and for a light background
  ;; THEN each background gets the test face's colour for it
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (should (equal (canvas-palette--foreground 'canvas-palette-test-inherit-list 'dark) (canvas-palette-test--rgb "#3987e5")))
  (should (equal (canvas-palette--foreground 'canvas-palette-test-inherit-list 'light) (canvas-palette-test--rgb "#2a78d6"))))

(ert-deftest canvas-palette-foreground-names-an-inheritance-loop ()
  ;; GIVEN a dark frame and a theme that makes the test face inherit, on light backgrounds,
  ;;       the face that inherits the test face
  ;; WHEN the test face is resolved for a light background
  ;; THEN it is an error that names both faces of the loop
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-theme canvas-palette-test-loop
        ((canvas-palette-test-face ((((background light)) :inherit canvas-palette-test-inherit))))
      (let ((err (should-error (canvas-palette--foreground 'canvas-palette-test-face 'light))))
        (should (string-search "canvas-palette-test-face" (cadr err)))
        (should (string-search "canvas-palette-test-inherit" (cadr err)))
        (should (string-search "loop" (cadr err)))))))

(ert-deftest canvas-palette-foreground-names-a-face-whose-colour-does-not-resolve ()
  ;; GIVEN a face whose foreground is not a colour
  ;; WHEN it is resolved
  ;; THEN the error names the face and the value
  (let ((err (should-error (canvas-palette--foreground 'canvas-palette-test-bad 'dark))))
    (should (string-match-p "canvas-palette-test-bad" (cadr err)))
    (should (string-match-p "not-a-colour" (cadr err)))))

(ert-deftest canvas-palette-series-gives-colour-shape-and-dash ()
  ;; GIVEN the default series faces
  ;; WHEN the first slot is asked for on a dark background and the last on a light one
  ;; THEN each has the colour, the shape and the dash of the table in the design
  (should (equal (canvas-palette-series 0 'dark)
                 (list :rgb (canvas-palette-test--rgb "#3987e5") :shape 'circle :dash [])))
  (should (equal (canvas-palette-series 7 'light)
                 (list :rgb (canvas-palette-test--rgb "#e34948") :shape 'pentagon :dash [1 6]))))

(ert-deftest canvas-palette-series-refuses-slots-outside-the-palette ()
  ;; GIVEN the eight series slots
  ;; WHEN a slot below 0, above 7, a float or a string is asked for
  ;; THEN each is an error whose message shows the bad slot, because a ninth colour cannot pass the checks
  ;;      AND canvas-palette-slot-count gives the eight slots
  (dolist (n '(-1 8 1.5 "0"))
    (let ((err (should-error (canvas-palette-series n 'dark))))
      (should (string-search (format "%S" n) (cadr err)))))
  (should (= canvas-palette-slot-count 8)))

(ert-deftest canvas-palette-chrome-gives-the-chrome-colours ()
  ;; GIVEN the default chrome faces
  ;; WHEN the grid is asked for on a dark background and the axis on a light one
  ;; THEN each has the colour of the table in the design
  ;;      AND an unknown key is an error whose message names the key and the chrome keys
  (should (equal (canvas-palette-chrome 'grid 'dark) (canvas-palette-test--rgb "#2c2c2a")))
  (should (equal (canvas-palette-chrome 'axis 'light) (canvas-palette-test--rgb "#c3c2b7")))
  (let ((err (should-error (canvas-palette-chrome 'border 'dark))))
    (should (string-search "border" (cadr err)))
    (should (string-search "grid, axis or reference" (cadr err)))))

(ert-deftest canvas-palette-series-and-chrome-refuse-a-background-they-do-not-know ()
  ;; GIVEN the default series and chrome faces, and the frame
  ;; WHEN a series slot is asked for on the misspelt background drak
  ;;      AND the grid is asked for on the string "dark" instead of the symbol
  ;;      AND the frame's surface is asked for on drak
  ;; THEN each is an error whose message shows the bad background
  (let ((err (should-error (canvas-palette-series 0 'drak))))
    (should (string-search (format "%S" 'drak) (cadr err))))
  (let ((err (should-error (canvas-palette-chrome 'grid "dark"))))
    (should (string-search (format "%S" "dark") (cadr err))))
  (let ((err (should-error (canvas-palette-surface 'drak))))
    (should (string-search (format "%S" 'drak) (cadr err)))))

(ert-deftest canvas-palette-background-follows-paper-and-the-frame ()
  ;; GIVEN batch Emacs, whose frame is dark
  ;; WHEN the background is asked for with paper off and with paper on
  ;; THEN paper off gives dark AND paper on gives light
  (let ((canvas-diagram-paper nil))
    (should (eq (canvas-palette-background) 'dark)))
  (let ((canvas-diagram-paper t))
    (should (eq (canvas-palette-background) 'light))))

(ert-deftest canvas-palette-surface-is-white-for-light-on-a-dark-frame ()
  ;; GIVEN batch Emacs, whose frame is dark
  ;; WHEN the surface is asked for on a light background
  ;; THEN it is white, because the frame's background is for dark drawings
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (should (equal (canvas-palette-surface 'light) '(1.0 1.0 1.0))))

;;;; Markers

(defmacro canvas-palette-test--with-context (var w h &rest body)
  "Run BODY with VAR bound to a context on a fresh W by H canvas."
  (declare (indent 3))
  `(let ((,var (canvas-cairo-context (list 'image :type 'canvas :id (make-symbol "palette-test")
                                           :data-width ,w :data-height ,h))))
     (unwind-protect (progn ,@body)
       (canvas-cairo-destroy ,var))))

(defconst canvas-palette-test--marker-pixels
  '((circle ((10 . 11)) ((9 . 9)))
    (square ((9 . 9) (20 . 20)) ())
    (triangle ((10 . 19)) ((10 . 10)))
    (diamond ((12 . 12)) ((10 . 10)))
    (cross ((10 . 10)) ((14 . 10)))
    (plus ((9 . 14)) ((12 . 12)))
    (down ((10 . 10)) ((10 . 19)))
    (pentagon ((15 . 10)) ((15 . 20))))
  "Each marker shape, 12 pixels wide at 15 15, with (X . Y) pixels of its box.
First the pixels it paints, then the pixels it leaves black.  The square
fills its box, so it leaves none black.")

(ert-deftest canvas-palette-draw-marker-stays-inside-its-box ()
  ;; GIVEN a black 30 by 30 canvas and a white colour
  ;; WHEN each marker shape is drawn 12 pixels wide at the centre
  ;; THEN the centre pixel is painted
  ;;      AND every pixel of the ring just outside the box, rows and columns 8 and 21, stays black
  ;;      AND the pixels of the box that the shape paints are painted and those it leaves black stay black,
  ;;      chosen so that no shape passes with the drawing of another
  (pcase-dolist (`(,shape ,painted ,black) canvas-palette-test--marker-pixels)
    (canvas-palette-test--with-context ctx 30 30
      (canvas-cairo-clear ctx 0 0 0 1)
      (canvas-cairo-set-color ctx 1 1 1 1)
      (canvas-palette-draw-marker ctx shape 15 15 12)
      (should (/= (canvas-cairo-pixel ctx 15 15) #xFF000000))
      (dotimes (i 14)
        (dolist (xy (list (cons (+ 8 i) 8) (cons (+ 8 i) 21) (cons 8 (+ 8 i)) (cons 21 (+ 8 i))))
          (should (= (canvas-cairo-pixel ctx (car xy) (cdr xy)) #xFF000000))))
      (dolist (xy painted)
        (should (/= (canvas-cairo-pixel ctx (car xy) (cdr xy)) #xFF000000)))
      (dolist (xy black)
        (should (= (canvas-cairo-pixel ctx (car xy) (cdr xy)) #xFF000000))))))

(ert-deftest canvas-palette-draw-marker-refuses-an-unknown-shape ()
  ;; GIVEN a context
  ;; WHEN a shape with no drawing is asked for: hexagon, and star, which the pentagon replaced
  ;; THEN each is an error that names the shape
  (canvas-palette-test--with-context ctx 10 10
    (dolist (shape '(hexagon star))
      (let ((err (should-error (canvas-palette-draw-marker ctx shape 5 5 6))))
        (should (string-search (symbol-name shape) (cadr err)))))))

(ert-deftest canvas-palette-draw-marker-refuses-a-size-that-is-not-a-finite-positive-number ()
  ;; GIVEN a context
  ;; WHEN a circle is asked for with the size 0, -4, the string "12", infinity,
  ;;      10 to the power 400, whose radius is infinite, or 1, below the line width
  ;; THEN each is an error whose message shows the bad size
  (canvas-palette-test--with-context ctx 10 10
    (dolist (size (list 0 -4 "12" 1.0e+INF (expt 10 400) 1))
      (let ((err (should-error (canvas-palette-draw-marker ctx 'circle 5 5 size))))
        (should (string-search (format "marker size %S " size) (cadr err)))))))

(ert-deftest canvas-palette-draw-marker-strokes-solid-on-a-dashed-context ()
  ;; GIVEN a black 30 by 30 canvas, a white colour and a dash of 1 on and 5 off
  ;; WHEN plus and cross are drawn 12 pixels wide at the centre
  ;; THEN every pixel of the two rows under the horizontal arm of plus is painted,
  ;;      from 1 pixel inside the left end to 1 pixel inside the right end
  (canvas-palette-test--with-context ctx 30 30
    (canvas-cairo-clear ctx 0 0 0 1)
    (canvas-cairo-set-color ctx 1 1 1 1)
    (canvas-cairo-set-dash ctx [1 5])
    (canvas-palette-draw-marker ctx 'plus 15 15 12)
    (canvas-palette-draw-marker ctx 'cross 15 15 12)
    (dolist (y '(14 15))
      (dolist (x (number-sequence 10 19))
        (should (/= (canvas-cairo-pixel ctx x y) #xFF000000))))
    ;; WHEN the canvas is cleared and a line is stroked from 9 to 21 along row 15
    ;; THEN the line still has the dash: x 9 is painted and x 12, in the first gap, stays black
    (canvas-cairo-clear ctx 0 0 0 1)
    (canvas-cairo-new-path ctx)
    (canvas-cairo-move-to ctx 9 15)
    (canvas-cairo-line-to ctx 21 15)
    (canvas-cairo-stroke ctx)
    (should (/= (canvas-cairo-pixel ctx 9 15) #xFF000000))
    (should (= (canvas-cairo-pixel ctx 12 15) #xFF000000))))

;;;; Theme changes

(ert-deftest canvas-palette-subscribers-hear-theme-changes-until-they-leave ()
  ;; GIVEN a subscriber that records the themes it hears about
  ;; WHEN a theme is enabled and disabled, the subscriber leaves, and the theme is enabled again
  ;; THEN it hears the theme twice while subscribed
  ;;      AND nothing after it left
  ;;      AND canvas-palette no longer watches the themes
  (canvas-palette-test--with-theme-hooks
    (let* ((heard nil)
           (listener (lambda (theme) (push theme heard)))
           (canvas-palette--warned-themes '(canvas-palette-test-quiet)))
      (canvas-palette-subscribe listener)
      (unwind-protect
          (canvas-palette-test--with-theme canvas-palette-test-quiet ())
        (canvas-palette-unsubscribe listener))
      (should (= (seq-count (lambda (theme) (eq theme 'canvas-palette-test-quiet)) heard) 2))
      (setq heard nil)
      (canvas-palette-test--with-theme canvas-palette-test-quiet ())
      (should-not heard)
      (should-not (memq #'canvas-palette--theme-enabled enable-theme-functions))
      (should-not (memq #'canvas-palette--theme-disabled disable-theme-functions)))))

(ert-deftest canvas-palette-watches-themes-until-the-last-subscriber-leaves ()
  ;; GIVEN two subscribers that record the themes they hear about, each with its own tag,
  ;;       because remove-hook finds a subscriber by equal and compiled closures of the same code are equal
  ;; WHEN the first one leaves and a theme is enabled
  ;; THEN the second one still hears the theme
  ;;      AND the first one does not
  ;;      AND canvas-palette still watches the themes
  (canvas-palette-test--with-theme-hooks
    (let* ((heard nil)
           (first (lambda (theme) (push (cons 'first theme) heard)))
           (second (lambda (theme) (push (cons 'second theme) heard)))
           (canvas-palette--warned-themes '(canvas-palette-test-quiet)))
      (canvas-palette-subscribe first)
      (canvas-palette-subscribe second)
      (unwind-protect
          (progn
            (canvas-palette-unsubscribe first)
            (canvas-palette-test--with-theme canvas-palette-test-quiet ())
            (should (member '(second . canvas-palette-test-quiet) heard))
            (should-not (assq 'first heard))
            (should (memq #'canvas-palette--theme-enabled enable-theme-functions))
            (should (memq #'canvas-palette--theme-disabled disable-theme-functions))
            ;; WHEN the second one leaves too
            ;; THEN canvas-palette no longer watches the themes
            (canvas-palette-unsubscribe second)
            (should-not (memq #'canvas-palette--theme-enabled enable-theme-functions))
            (should-not (memq #'canvas-palette--theme-disabled disable-theme-functions)))
        (canvas-palette-unsubscribe second)))))

(ert-deftest canvas-palette-warns-once-about-a-theme-whose-series-fail ()
  ;; GIVEN a theme that gives the first two series lime green and dark orange
  ;; WHEN the theme is enabled twice in one session while a package is subscribed
  ;; THEN exactly one canvas-palette warning comes
  ;;      AND it names the theme and the colour-blind check
  ;;      AND it says the faces fail after the theme was enabled, since they can come from elsewhere
  ;;      AND it names each series face with its colour, so the colours in the checks map to faces
  (canvas-palette-test--with-theme-hooks
    (let ((warnings nil)
          (canvas-palette--warned-themes nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type message &rest _) (push (cons type message) warnings))))
        (canvas-palette-subscribe #'ignore)
        (unwind-protect
            (dotimes (_ 2)
              (canvas-palette-test--with-theme canvas-palette-test-loud
                  ((canvas-series-1 ((t :foreground "#32cd32")))
                   (canvas-series-2 ((t :foreground "#ff8c00"))))))
          (canvas-palette-unsubscribe #'ignore)))
      (should (= (length warnings) 1))
      (should (eq (car (car warnings)) 'canvas-palette))
      (should (string-match-p "canvas-palette-test-loud" (cdr (car warnings))))
      (should (string-match-p "cvd" (cdr (car warnings))))
      (should (string-prefix-p "After theme canvas-palette-test-loud was enabled, the canvas-series faces fail"
                               (cdr (car warnings))))
      (should (string-search "canvas-series-1 #32cd32" (cdr (car warnings))))
      (should (string-search "canvas-series-2 #ff8c00" (cdr (car warnings)))))))

(ert-deftest canvas-palette-raises-on-every-enable-of-a-theme-whose-series-do-not-resolve ()
  ;; GIVEN a theme whose first series face inherits bold, which has no foreground
  ;; WHEN the theme is enabled twice in one session while a package is subscribed
  ;; THEN each enable is an error that names canvas-series-1
  ;;      AND the theme is not recorded as checked
  (canvas-palette-test--with-theme-hooks
    (let ((canvas-palette--warned-themes nil))
      (canvas-palette-subscribe #'ignore)
      (unwind-protect
          (dotimes (_ 2)
            (let ((err (should-error (canvas-palette-test--with-theme canvas-palette-test-broken
                                         ((canvas-series-1 ((t :inherit bold))))))))
              (should (string-search "face canvas-series-1 has no foreground" (cadr err)))))
        (canvas-palette-unsubscribe #'ignore))
      (should-not (memq 'canvas-palette-test-broken canvas-palette--warned-themes)))))

(ert-deftest canvas-palette-checks-a-theme-after-the-theme-functions-of-the-user ()
  ;; GIVEN a user function in enable-theme-functions that records the themes,
  ;;       added before a package subscribes
  ;; WHEN a theme whose first series face inherits bold, which has no foreground, is enabled
  ;; THEN enabling it is an error that names canvas-series-1
  ;;      AND the user function heard the theme all the same
  (canvas-palette-test--with-theme-hooks
    (let ((heard nil)
          (canvas-palette--warned-themes nil))
      (add-hook 'enable-theme-functions (lambda (theme) (push theme heard)))
      (canvas-palette-subscribe #'ignore)
      (unwind-protect
          (let ((err (should-error (canvas-palette-test--with-theme canvas-palette-test-broken
                                       ((canvas-series-1 ((t :inherit bold))))))))
            (should (string-search "face canvas-series-1 has no foreground" (cadr err))))
        (canvas-palette-unsubscribe #'ignore))
      (should (memq 'canvas-palette-test-broken heard)))))

(ert-deftest canvas-palette-subscribe-and-unsubscribe-refuse-what-is-not-a-function ()
  ;; GIVEN a symbol that names no function, and theme hooks that this test binds for itself
  ;; WHEN the symbol is subscribed, and when it is unsubscribed
  ;; THEN each is an error whose message names the symbol
  (canvas-palette-test--with-theme-hooks
    (dolist (call '(canvas-palette-subscribe canvas-palette-unsubscribe))
      (let ((err (should-error (funcall call 'no-such-function-anywhere))))
        (should (string-search "no-such-function-anywhere" (cadr err)))))))

;;;; The report

(defmacro canvas-palette-test--with-report (&rest body)
  "Run BODY, then kill the buffer of canvas-palette-check."
  (declare (indent 0))
  `(unwind-protect
       (progn ,@body)
     (kill-buffer (get-buffer-create "*canvas-palette-check*"))))

(defun canvas-palette-test--report-text ()
  "Run canvas-palette-check and return the text of its buffer."
  (canvas-palette-check)
  (with-current-buffer "*canvas-palette-check*"
    (buffer-string)))

(defun canvas-palette-test--default-background (hex)
  "A `face-background' with HEX for the default face, real for other faces."
  (let ((face-background-of (symbol-function 'face-background)))
    (lambda (face &rest args)
      (if (eq face 'default) hex (apply face-background-of face args)))))

(ert-deftest canvas-palette-check-reports-both-backgrounds ()
  ;; GIVEN the default series faces
  ;; WHEN canvas-palette-check runs
  ;; THEN its buffer reports the dark and the light background with every check
  ;;      AND no check of the defaults fails
  ;;      AND point is at the start of the report
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-report
      (let ((text (canvas-palette-test--report-text)))
        (dolist (word '("dark background" "light background" "band" "chroma" "cvd" "normal" "contrast"))
          (should (string-match-p (regexp-quote word) text)))
        (should-not (string-match-p "\\_<fail\\_>" text))
        (with-current-buffer "*canvas-palette-check*"
          (should (= (point) (point-min))))))))

(ert-deftest canvas-palette-check-reports-dark-on-the-frame-background-and-light-on-white ()
  ;; GIVEN batch Emacs, whose frame is dark, and a default face whose background is #101010
  ;; WHEN canvas-palette-check runs
  ;; THEN the dark background is checked on #101010
  ;;      AND the light background is checked on #ffffff
  (should (eq (frame-parameter nil 'background-mode) 'dark))
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-report
      (let ((text (cl-letf (((symbol-function 'face-background) (canvas-palette-test--default-background "#101010")))
                    (canvas-palette-test--report-text))))
        (should (string-search "The dark background, on #101010" text))
        (should (string-search "The light background, on #ffffff" text))))))

(ert-deftest canvas-palette-check-reports-light-on-white-on-a-light-frame ()
  ;; GIVEN a light frame whose default face has the background #f0f0e8,
  ;;       so that the frame's light surface is #f0f0e8
  ;; WHEN canvas-palette-check runs
  ;; THEN the light background is checked on #ffffff all the same, as the design says
  (let ((frame-parameter-of (symbol-function 'frame-parameter)))
    (canvas-palette-test--with-theme-hooks
      (canvas-palette-test--with-report
        (let ((text (cl-letf (((symbol-function 'frame-parameter)
                               (lambda (frame parameter)
                                 (if (eq parameter 'background-mode) 'light (funcall frame-parameter-of frame parameter))))
                              ((symbol-function 'face-background) (canvas-palette-test--default-background "#f0f0e8")))
                      (should (equal (canvas-palette-surface 'light) (canvas-palette-test--rgb "#f0f0e8")))
                      (canvas-palette-test--report-text))))
          (should (string-search "The light background, on #ffffff" text)))))))

(ert-deftest canvas-palette-check-keeps-the-last-report-when-a-face-does-not-resolve ()
  ;; GIVEN a report of the default series faces in the report buffer
  ;; WHEN a theme makes canvas-series-1 inherit bold, which has no foreground,
  ;;      AND canvas-palette-check runs again
  ;; THEN the check is an error that names canvas-series-1
  ;;      AND the buffer still holds the first report
  (canvas-palette-test--with-theme-hooks
    (canvas-palette-test--with-report
      (let ((first-report (canvas-palette-test--report-text)))
        (canvas-palette-test--with-theme canvas-palette-test-unresolved
            ((canvas-series-1 ((t :inherit bold))))
          (let ((err (should-error (canvas-palette-check))))
            (should (string-search "face canvas-series-1 has no foreground" (cadr err)))))
        (with-current-buffer "*canvas-palette-check*"
          (should (equal (buffer-string) first-report)))))))

;;; canvas-palette-tests.el ends here
