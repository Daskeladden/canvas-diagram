;;; canvas-diagram.el --- Diagrams of boxes on an Emacs canvas -*- lexical-binding: t -*-

;; Copyright (C) 2026 canvas-diagram contributors

;; Author: Daskeladden
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0.50") (transient "0.7.0") (canvas-keys "0.1.0"))
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

;; What a mind map, a state machine and any other diagram of labelled
;; boxes share, drawn on an Emacs 32 canvas by the canvas-cairo module:
;; boxes with icons, kinds and colours, a legend and a card, a ring on
;; the node the keyboard is on, a canvas the size of its window scrolled
;; and zoomed over the drawing, the mouse, the keys that move point
;; remapped to move between nodes, canvas-minimap's picture of the whole
;; and a click on it, a source buffer followed as it is edited and
;; visited from a node, a menu of looks, export to a PNG.
;;
;; A package supplies a `canvas-diagram' with callbacks: how to build
;; its model from a spec, lay the nodes out, draw the edges, and move
;; from one node to another.  Everything else is here.
;;
;; This is a prototype.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'transient)
(require 'canvas-cairo)
(require 'canvas-keys)

(defgroup canvas-diagram nil
  "Diagrams of boxes on a canvas."
  :group 'multimedia)

(defcustom canvas-diagram-font nil
  "Pango font description for labels, such as \"Noto Sans 14px\".
nil means the frame's default face, at its pixel size."
  :type '(choice (const nil) string))

(defcustom canvas-diagram-family nil
  "Font family for the labels, at the frame's size; nil for the frame's.
`canvas-diagram-font' takes precedence when set."
  :type '(choice (const nil) string))

(defcustom canvas-diagram-colors nil
  "Plist of colour names for :background, :node, :text, :edge and :selection.
Any that is missing is taken from the frame's faces."
  :type '(choice (const nil) plist))

(defcustom canvas-diagram-palettes
  '(("derived")
    ("vivid" "dodger blue" "dark orange" "lime green" "medium orchid"
     "crimson" "gold" "dark turquoise" "hot pink")
    ("earth" "sienna" "dark olive green" "steel blue" "goldenrod"
     "indian red" "cadet blue" "peru" "slate gray")
    ("mono" "gray60"))
  "Named palettes for numbered things, branches say: (NAME COLOUR...).
A name without colours derives hues from the background."
  :type '(alist :key-type string :value-type (repeat string)))

(defcustom canvas-diagram-palette "derived"
  "The palette in use, a name in `canvas-diagram-palettes'."
  :type 'string)

(defcustom canvas-diagram-kinds
  '(("todo" . "dark orange") ("done" . "sea green") ("risk" . "red")
    ("idea" . "medium purple") ("question" . "gold") ("next" . "steel blue")
    ("function" . "royal blue") ("method" . "royal blue") ("class" . "dark cyan")
    ("struct" . "dark cyan") ("type" . "teal") ("variable" . "dark khaki")
    ("constant" . "dark khaki") ("module" . "slate gray") ("macro" . "orchid"))
  "Alist of node kinds and the colour of the outline that marks them.
A kind not listed here, nor in `canvas-diagram-extra-kinds', is
outlined in the edge colour."
  :type '(alist :key-type string :value-type string))

(defvar canvas-diagram-extra-kinds nil
  "Kinds a package adds to `canvas-diagram-kinds', as (KIND . COLOUR).")

(defcustom canvas-diagram-selection-tint 0.3
  "How far the box the keyboard is on is tinted towards the selection colour.
0 leaves its fill alone, so the ring around it is the only mark; 1
fills it with the selection colour outright.  A ring on its own is
easy to lose in a drawing of many boxes."
  :type 'number)

(defcustom canvas-diagram-menu-column-widths '(26 34 34 38)
  "Least width of each menu column, in characters.
transient sizes a row's columns to the widest thing in that row, so
rows of different content do not line up.  These are minimums it
applies to every row, which lines the rows up as long as nothing is
wider.  nil leaves each row to size itself."
  :type '(repeat integer))

(defcustom canvas-diagram-mark-tint 0.25
  "How far a marked box is tinted towards the selection colour.
0 leaves its fill alone, so the ring around it is the only sign it is
marked.  A marked box the keyboard is also on takes both tints, so it
still stands out from the boxes that are only marked."
  :type 'number)

(defcustom canvas-diagram-kind-width 3
  "Width of the outline marking a node's kind, in pixels."
  :type 'integer)

(defcustom canvas-diagram-kind-icons
  '(("todo" . "material:checkbox-blank-outline") ("done" . "material:check")
    ("risk" . "material:alert") ("idea" . "material:lightbulb")
    ("question" . "material:help-circle") ("next" . "material:arrow-right")
    ("function" . "material:function-variant") ("method" . "material:function-variant")
    ("class" . "material:cube-outline") ("struct" . "material:cube-outline")
    ("type" . "material:shape-outline") ("variable" . "material:variable")
    ("constant" . "material:variable") ("module" . "material:package-variant")
    ("macro" . "material:cog-outline"))
  "Alist of node kinds and the icon their boxes carry.
Icons are COLLECTION:NAME as svg-lib knows them, or a file's name."
  :type '(alist :key-type string :value-type string))

(defvar canvas-diagram-extra-kind-icons nil
  "Icons a package adds to `canvas-diagram-kind-icons', as (KIND . ICON).")

(defcustom canvas-diagram-show-kinds t
  "Whether a node's kind outlines its box and is listed in the legend."
  :type 'boolean)

(defcustom canvas-diagram-show-legend t
  "Whether the legend is drawn."
  :type 'boolean)

(defcustom canvas-diagram-show-icons t
  "Whether nodes carry icons: their own, or their kind's."
  :type 'boolean)

(defcustom canvas-diagram-icon-directory nil
  "Directory of NAME.svg files to take icons from, or nil.
An icon named COLLECTION:NAME is looked for as COLLECTION_NAME.svg,
as svg-lib caches it; svg-lib fetches it when it is nowhere."
  :type '(choice (const nil) directory))

(defcustom canvas-diagram-paper nil
  "Whether to draw dark ink on white paper rather than in the theme's colours."
  :type 'boolean)

(defcustom canvas-diagram-shape 'rounded
  "The boxes: `rounded' corners, `square' ones, or a `pill'."
  :type '(choice (const rounded) (const square) (const pill)))

(defcustom canvas-diagram-spacing 'normal
  "How far apart things sit: `compact', `normal' or `airy'."
  :type '(choice (const compact) (const normal) (const airy)))

(defcustom canvas-diagram-padding 8
  "Pixels between a label and the edge of its box."
  :type 'integer)

(defcustom canvas-diagram-margin 10
  "Pixels around the whole drawing."
  :type 'integer)

(defcustom canvas-diagram-radius 6
  "Corner radius of a node's box, in pixels."
  :type 'integer)

(defcustom canvas-diagram-popup-width 300
  "Width of the card a click on a box opens, in pixels."
  :type 'integer)

(defcustom canvas-diagram-scroll-step 40
  "Pixels an arrow key moves the view."
  :type 'integer)

(defcustom canvas-diagram-animate 0.2
  "Seconds the boxes take to slide to their new places after a rebuild.
nil draws them there at once.  Any command ends a slide."
  :type '(choice (const :tag "No slide" nil) number))

(defcustom canvas-diagram-open-source nil
  "Whether walking onto a node from another file opens that file.
A node can come from a file other than the one the diagram follows.  nil
follows such a node only once its file is open.  t opens it, without the
hooks a visit runs, and shows it in the window holding the followed
buffer, so that the window beside the drawing holds the file the box
came from."
  :type 'boolean)

(defcustom canvas-diagram-pulse-function #'canvas-diagram--pulse-line
  "Function that draws the eye to the source line a node led to.
Called with the source's window selected and point on that line.  The
default pulses with whichever pulse the user has on, smear-cursor's or
pulsar's, and with neither does nothing.  nil never pulses."
  :type '(choice (const nil) function))

(defcustom canvas-diagram-fly-function #'canvas-diagram--fly-smear
  "Function that draws the eye from the box the keyboard left to the next.
Called in the diagram buffer with the two boxes as [X Y W H] vectors in
pixels of the picture, each where it is drawn: the box left as it was
before the view scrolled, the box reached as it is after.  The default
flies smear-cursor\\='s cursor from one to the other while smear-cursor is
on, and with it off does nothing.  nil never flies."
  :type '(choice (const nil) function))

(defconst canvas-diagram--paper-colors
  '(:background "white" :node "gray88" :text "black" :edge "gray45"
    :selection "dodger blue")
  "The colours of `canvas-diagram-paper'.")

(defconst canvas-diagram--spacings '((compact . 0.6) (normal . 1.0) (airy . 1.6))
  "Factor on gaps and padding for each `canvas-diagram-spacing'.")

(defconst canvas-diagram--zooms '(0.25 0.35 0.5 0.7 1.0 1.4 2.0 2.8 4.0)
  "The zoom factors, in order.")

;;;; Nodes and diagrams

(cl-defstruct (canvas-diagram-node (:constructor canvas-diagram-node-create))
  "A box of a drawing: its LABEL, its KIND, its NOTE, its ICON, the POS it
was read from, its place X and Y and its size W and H, and the ROWS it
holds under its label, each a line of text that an edge can join."
  label kind note icon pos (x 0) (y 0) (w 0) (h 0) rows)

(cl-defstruct (canvas-diagram (:constructor canvas-diagram-create))
  "A drawing: its MODEL built from SPEC, the NODES laid out, and the
package's CALLBACKS, a plist:
  :build (diagram spec) -> model
  :layout (diagram ctx) -> nodes, positioned, in reading order
  :draw-edges (diagram ctx)   in drawing coordinates
  :front (diagram) -> nodes   optional: the boxes drawn last, over the rest
  :draw-front (diagram ctx nodes)   optional: a backdrop for the front
    boxes NODES, drawn after the other boxes and before them
  :draw-over (diagram ctx)   optional: drawn after every box, such as
    lines that must stay in sight where they cross a box
  :zoom (diagram zoom)   optional: the diagram is now drawn at ZOOM
  :draw-trail (diagram ctx node width)   optional, behind the ring
  :node-rgb (diagram node) -> (R G B)   optional
  :node-shape (diagram node) -> `rounded', `square' or `pill'   optional:
    the shape of that one box, else `canvas-diagram-shape' decides
  :node-text (diagram node) -> string   optional
  :badge (diagram node) -> (TEXT RGB)   optional: a pill saying TEXT,
    filled with RGB, before the label, and a row of the legend
  :header (diagram node) -> string   optional
  :card (diagram node) -> (TITLE PATH BODY)   optional
  :content (diagram node) -> (HEADER BODY)   optional: what copying the
    node copies, BODY nil for none; the label and the note without it
  :source-text (diagram node part buffer) -> string or nil   optional:
    PART, `header', `body' or `all', of the text NODE came from in
    BUFFER, the buffer the diagram follows
  :legend (diagram) -> ((LABEL RGB STYLE)...)   optional, before the badges
    and the kinds; a row of STYLE badge leaves out the rows of the badges
  :move (diagram node direction) -> node or nil
  :node-key (diagram node) -> key   optional, default the label
  :restore (diagram key) -> node or nil   optional
  :double-click (diagram node)   optional
  :open (diagram node)   optional: RET and a click on a box give the box
    to the package, which opens it, in place of the card
  :select (diagram node)   optional: the keyboard is on NODE, after a move,
    a rebuild or a relayout, and the view is drawn
  :go (diagram node)   optional: a move or a jump by name put the keyboard
    on NODE, never a rebuild or a relayout
  :overlay (diagram ctx size offset zoom selected)   optional: draw over
    the view in canvas coordinates, after the drawing and the legend
  :read-source (buffer) -> spec   optional, for following a buffer
  :menu   a transient prefix, optional
  :export (diagram spec file)   optional: how `canvas-diagram-write'
    draws the buffer's diagram into a file, in place of
    `canvas-diagram-export' on a copy of the diagram
SLACK is how far, in drawing units, what is drawn reaches past the
boxes to the right and below, as (RIGHT . BOTTOM); a layout whose
edges bow, loop or carry labels sets it, and shifts its boxes for what
reaches past them to the left and above."
  model spec nodes callbacks (slack '(0 . 0)))

(defun canvas-diagram--call (diagram key &rest args)
  "Call DIAGRAM's KEY callback with ARGS, or return nil without one."
  (when-let* ((fn (plist-get (canvas-diagram-callbacks diagram) key)))
    (apply fn args)))

(defun canvas-diagram--has (diagram key)
  "Whether DIAGRAM has a KEY callback."
  (and (plist-get (canvas-diagram-callbacks diagram) key) t))

(defun canvas-diagram--node-text (diagram node)
  "What NODE's box says."
  (or (canvas-diagram--call diagram :node-text diagram node)
      (canvas-diagram-node-label node)))

(defun canvas-diagram--node-key (diagram node)
  "What identifies NODE across rebuilds."
  (if (canvas-diagram--has diagram :node-key)
      (canvas-diagram--call diagram :node-key diagram node)
    (canvas-diagram-node-label node)))

(defun canvas-diagram--node-by-key (diagram key)
  "The node of DIAGRAM whose key is KEY, or nil."
  (cl-find key (canvas-diagram-nodes diagram)
           :key (lambda (n) (canvas-diagram--node-key diagram n)) :test #'equal))

(defun canvas-diagram--restore (diagram key)
  "The node of DIAGRAM that KEY names, after a rebuild, or nil."
  (if (canvas-diagram--has diagram :restore)
      (canvas-diagram--call diagram :restore diagram key)
    (canvas-diagram--node-by-key diagram key)))

(defun canvas-diagram-neighbour (nodes node step)
  "The node STEP places from NODE in NODES, or NODE at either end."
  (let ((i (+ (or (cl-position node nodes) 0) step)))
    (if (< -1 i (length nodes)) (nth i nodes) node)))

;;;; Fonts and colours

(defconst canvas-diagram-fallback-font "Sans 14px"
  "The label font when there is no frame to take one from.")

(defun canvas-diagram--font-description (face &optional family)
  "Pango description of FACE's font: its family, or FAMILY, at its pixel size.
An absolute size keeps the drawing's text the size of the frame's text
whatever DPI pango assumes."
  (format "%s %dpx"
          (or family (face-attribute face :family nil 'default))
          (aref (font-info (face-font face)) 2)))

(defun canvas-diagram-font ()
  "The label font: `canvas-diagram-font', else the default face's, in
`canvas-diagram-family' when that is set.  Without a graphical display,
as in batch, the fallback."
  (or canvas-diagram-font
      (if (display-graphic-p)
          (canvas-diagram--font-description 'default canvas-diagram-family)
        (if canvas-diagram-family
            (replace-regexp-in-string "^.* " (concat canvas-diagram-family " ")
                                      canvas-diagram-fallback-font)
          canvas-diagram-fallback-font))))

(defun canvas-diagram--bold (font)
  "FONT's bold variant: \"Sans 12px\" becomes \"Sans Bold 12px\"."
  (let ((size (string-match "[^ ]+$" font)))
    (concat (substring font 0 size) "Bold " (substring font size))))

(defun canvas-diagram-rgb (name)
  "NAME's colour as (R G B), each 0 to 1; nil when NAME is no colour.
X11 names and #RRGGBB are resolved without a display, which also keeps
`color-values' from approximating them to a terminal palette.  X11
ignores case and spaces in a name, so \"dark orange\" is \"DarkOrange\"."
  (let ((values (and (stringp name)
                     (or (tty-color-standard-values (downcase (string-replace " " "" name)))
                         (color-values name)))))
    (and values (mapcar (lambda (v) (/ v 65535.0)) values))))

(defun canvas-diagram-hex (rgb)
  "RGB, (R G B) each 0 to 1, as #rrggbb, for pango markup."
  (apply #'format "#%02x%02x%02x"
         (mapcar (lambda (v) (round (* 255 (max 0.0 (min 1.0 v))))) rgb)))

(defun canvas-diagram-face-hex (face &optional fallback)
  "FACE's foreground as #rrggbb for pango markup; FALLBACK, an (R G B),
or the text colour when it has none."
  (canvas-diagram-hex (or (canvas-diagram-rgb (face-attribute face :foreground nil t))
                          fallback
                          (canvas-diagram-color :text))))

(defun canvas-diagram-markup-escape (text)
  "TEXT with &, < and > escaped, so pango markup takes it as text."
  (replace-regexp-in-string "[&<>]"
                            (lambda (m) (pcase m ("&" "&amp;") ("<" "&lt;") (_ "&gt;")))
                            text t t))

(defun canvas-diagram--face-rgb (face attribute fallback)
  "FACE's ATTRIBUTE colour as (R G B), or FALLBACK's when it is unset."
  (or (canvas-diagram-rgb (face-attribute face attribute nil t))
      (canvas-diagram-rgb fallback)
      (error "canvas-diagram: %S is not a colour" fallback)))

(defun canvas-diagram-color (key)
  "(R G B) for KEY: from `canvas-diagram-colors', else the paper's when
`canvas-diagram-paper' is on, else from the faces."
  (or (canvas-diagram-rgb (plist-get canvas-diagram-colors key))
      (and canvas-diagram-paper
           (canvas-diagram-rgb (plist-get canvas-diagram--paper-colors key)))
      (pcase key
        (:background (canvas-diagram--face-rgb 'default :background "white"))
        (:node (canvas-diagram--face-rgb 'highlight :background "gray80"))
        (:text (canvas-diagram--face-rgb 'default :foreground "black"))
        (:edge (canvas-diagram--face-rgb 'shadow :foreground "gray50"))
        (:selection (canvas-diagram--face-rgb 'cursor :background "gold"))
        (_ (error "canvas-diagram: no colour is called %S" key)))))

(defun canvas-diagram-set-rgb (ctx rgb &optional alpha)
  "Draw on CTX in RGB from now on, at ALPHA or else opaque."
  (apply #'canvas-cairo-set-color ctx (append rgb (list (or alpha 1)))))

(defun canvas-diagram--argb-rgb (argb)
  "(R G B), each 0 to 1, of the ARGB32 pixel value ARGB."
  (mapcar (lambda (shift) (/ (logand (ash argb shift) 255) 255.0)) '(-16 -8 0)))

(defconst canvas-diagram--hues '(0.58 0.08 0.35 0.83 0.0 0.14 0.5 0.7)
  "Hues of the derived palette: blue, orange, green, purple, red,
yellow, teal, violet.")

(defun canvas-diagram--dark-p ()
  "Whether the background is dark, so that fills must be too."
  (< (apply #'+ (canvas-diagram-color :background)) 1.5))

(defun canvas-diagram--palette-names ()
  "Colour names of the palette in use; nil when the hues are derived."
  (cdr (or (assoc canvas-diagram-palette canvas-diagram-palettes)
           (error "canvas-diagram: no palette is called %S" canvas-diagram-palette))))

(defun canvas-diagram-palette-rgb (index &optional names)
  "(R G B) number INDEX of the palette, cycled; NAMES instead when given."
  (let ((names (or names (canvas-diagram--palette-names))))
    (if names
        (let ((name (nth (mod index (length names)) names)))
          (or (canvas-diagram-rgb name)
              (error "canvas-diagram: %S is not a colour" name)))
      (let ((hue (nth (mod index (length canvas-diagram--hues)) canvas-diagram--hues)))
        (if (canvas-diagram--dark-p)
            (color-hsl-to-rgb hue 0.45 0.3)
          (color-hsl-to-rgb hue 0.6 0.82))))))

(defun canvas-diagram--kind-color-name (kind)
  "The colour name configured for KIND, or nil."
  (or (cdr (assoc kind canvas-diagram-kinds))
      (cdr (assoc kind canvas-diagram-extra-kinds))))

(defun canvas-diagram-kind-rgb (kind)
  "(R G B) outlining the boxes of KIND; the edge colour for an unknown one."
  (or (canvas-diagram-rgb (canvas-diagram--kind-color-name kind))
      (canvas-diagram-color :edge)))

(defun canvas-diagram--spacing-factor ()
  "How much wider than the base `canvas-diagram-spacing' spreads things."
  (or (alist-get canvas-diagram-spacing canvas-diagram--spacings)
      (error "canvas-diagram: no spacing is called %S" canvas-diagram-spacing)))

(defun canvas-diagram-spaced (pixels)
  "PIXELS scaled by the current spacing, rounded."
  (round (* pixels (canvas-diagram--spacing-factor))))

(defun canvas-diagram--padding ()
  "Pixels between a label and its box, at the current spacing."
  (canvas-diagram-spaced canvas-diagram-padding))

;;;; Icons

(defvar canvas-diagram--icons (make-hash-table :test 'equal)
  "Icon name -> its SVG text, or `none' for one that could not be had.")

(defconst canvas-diagram--icon-gap 5
  "Pixels between an icon and its label.")

(defun canvas-diagram--icon-file (name)
  "The SVG file of the icon NAME that is on disk, or nil.
NAME.svg in `canvas-diagram-icon-directory', a colon as an underscore,
else the same in svg-lib's cache."
  (let ((file (concat (replace-regexp-in-string ":" "_" name) ".svg")))
    (cl-find-if #'file-readable-p
                (delq nil (list (and canvas-diagram-icon-directory
                                     (expand-file-name file canvas-diagram-icon-directory))
                                (and (boundp 'svg-lib-icons-dir)
                                     (expand-file-name file svg-lib-icons-dir)))))))

(defun canvas-diagram--fetch-icon (name)
  "Have svg-lib fetch the icon NAME, a COLLECTION:NAME, into its cache.
The file, or nil with a message when that cannot be done."
  (require 'svg-lib nil t)
  (when (and (fboundp 'svg-lib--icon-get-data)
             (string-match "\\`\\([^:]+\\):\\(.+\\)\\'" name))
    (condition-case err
        (progn
          (svg-lib--icon-get-data (match-string 1 name) (match-string 2 name))
          (canvas-diagram--icon-file name))
      (error (message "canvas-diagram: icon %s: %s" name (error-message-string err))
             nil))))

(defun canvas-diagram-icon-data (name)
  "The SVG text of the icon NAME, or nil when there is none to be had.
NAME is COLLECTION:NAME as svg-lib knows it, or a file\\='s name, as in
`canvas-diagram-kind-icons'.  A package that draws its own icons with
`canvas-cairo-svg' finds them here.  Looked up once; the answer is kept."
  (let ((known (gethash name canvas-diagram--icons)))
    (cond ((stringp known) known)
          ((eq known 'none) nil)
          (t (let* ((file (or (canvas-diagram--icon-file name)
                              (canvas-diagram--fetch-icon name)))
                    (data (and file (with-temp-buffer
                                      (insert-file-contents file)
                                      (buffer-string)))))
               (puthash name (or data 'none) canvas-diagram--icons)
               data)))))

(defun canvas-diagram--kind-icon-name (kind)
  "The icon configured for KIND, or nil."
  (or (cdr (assoc kind canvas-diagram-kind-icons))
      (cdr (assoc kind canvas-diagram-extra-kind-icons))))

(defun canvas-diagram--icon-name (node)
  "The icon NODE carries: its own, else its kind's; nil when icons are off."
  (and canvas-diagram-show-icons
       (or (canvas-diagram-node-icon node)
           (canvas-diagram--kind-icon-name (canvas-diagram-node-kind node)))))

(defun canvas-diagram--icon (node)
  "The SVG text of NODE's icon, or nil."
  (when-let* ((name (canvas-diagram--icon-name node)))
    (canvas-diagram-icon-data name)))

(defun canvas-diagram--icon-side (h)
  "Side of the icon in a box H tall: the height of its text."
  (- h (* 2 (canvas-diagram--padding))))

(defun canvas-diagram--icon-room (node h)
  "Width NODE's icon and the gap after it take in a box H tall; 0 without one."
  (if (canvas-diagram--icon node)
      (+ (canvas-diagram--icon-side h) canvas-diagram--icon-gap)
    0))

;;;; Badges

(defun canvas-diagram--badge (diagram node)
  "NODE's badge in DIAGRAM, (TEXT RGB), as the package gives it, or nil."
  (canvas-diagram--call diagram :badge diagram node))

(defun canvas-diagram--badge-room (badge measure)
  "Width a badge saying BADGE and the gap after it take, MEASURE sizing
it as the text of a box; 0 for no badge."
  (if badge
      (+ (car (funcall measure badge)) canvas-diagram--icon-gap)
    0))

(defun canvas-diagram-ink-on (rgb)
  "Black or white, as (R G B), whichever reads better on RGB."
  (pcase-let ((`(,r ,g ,b) rgb))
    (if (> (+ (* 0.299 r) (* 0.587 g) (* 0.114 b)) 0.6)
        '(0.0 0.0 0.0)
      '(1.0 1.0 1.0))))

;;;; Geometry

(defun canvas-diagram-middle-x (node)
  "The drawing X halfway across NODE's box."
  (+ (canvas-diagram-node-x node) (/ (canvas-diagram-node-w node) 2.0)))

(defun canvas-diagram-middle-y (node)
  "The drawing Y halfway down NODE's box."
  (+ (canvas-diagram-node-y node) (/ (canvas-diagram-node-h node) 2.0)))

(defun canvas-diagram-measure (ctx)
  "Function giving a box's (W . H) on CTX for a text: the text plus padding."
  (let ((font (canvas-diagram-font))
        (pad (* 2 (canvas-diagram--padding))))
    (lambda (text)
      (let ((size (canvas-cairo-text-size ctx text font)))
        (cons (+ (car size) pad) (+ (cdr size) pad))))))

(defun canvas-diagram--rows (node)
  "The rows NODE holds.  A box built by an older version of this file has
no slot for them, and a session that loaded the file again may still
hold such boxes, so they are taken as holding none."
  (and (> (length node) (cl-struct-slot-offset 'canvas-diagram-node 'rows))
       (canvas-diagram-node-rows node)))

(defun canvas-diagram-row-height (node measure)
  "How tall one of NODE's rows stands, as MEASURE gives it."
  (cdr (funcall measure (or (car (canvas-diagram--rows node)) "Ag"))))

(defun canvas-diagram--rows-size (node measure)
  "(W . H) the rows of NODE need below its label: the widest of them, and
a line for each.  (0 . 0) for a node that holds none."
  (if-let* ((rows (canvas-diagram--rows node)))
      (cons (apply #'max (mapcar (lambda (row) (car (funcall measure row))) rows))
            (* (length rows) (canvas-diagram-row-height node measure)))
    (cons 0 0)))

(defun canvas-diagram-box-size (node text measure &optional badge)
  "(W . H) of NODE's box: what MEASURE says TEXT needs, with room for its
icon, for a badge saying BADGE when given, and for the rows it holds."
  (let ((size (funcall measure text))
        (rows (canvas-diagram--rows-size node measure)))
    (cons (max (+ (car size) (canvas-diagram--icon-room node (cdr size))
                  (canvas-diagram--badge-room badge measure))
               (car rows))
          (+ (cdr size) (cdr rows)))))

(defun canvas-diagram-size-node (diagram node measure)
  "Give NODE the box MEASURE says its text needs, with room for its icon
and its badge."
  (let ((size (canvas-diagram-box-size node (canvas-diagram--node-text diagram node) measure
                                       (car (canvas-diagram--badge diagram node)))))
    (setf (canvas-diagram-node-w node) (car size)
          (canvas-diagram-node-h node) (cdr size))))

(defun canvas-diagram-row-anchor (node row side)
  "The place (X . Y) at which an edge joins ROW of NODE, SIDE being `left'
or `right'.  It lies on that edge of the box, halfway down the row.  A
row the node does not hold is an error, and so is any other SIDE."
  (let ((index (or (cl-position row (canvas-diagram--rows node) :test #'equal)
                   (error "canvas-diagram: %S holds no row %S" (canvas-diagram-node-label node) row)))
        (rows (length (canvas-diagram--rows node))))
    (cons (pcase side
            ('left (canvas-diagram-node-x node))
            ('right (+ (canvas-diagram-node-x node) (canvas-diagram-node-w node)))
            (other (error "canvas-diagram: a row joins on the left or the right, not %S" other)))
          (+ (canvas-diagram-node-y node) (canvas-diagram--rows-top node rows)
             (* (+ index 0.5) (canvas-diagram--row-step node rows))))))

(defun canvas-diagram--row-step (node rows)
  "How far apart NODE's ROWS stand, from the room below its label."
  (/ (float (- (canvas-diagram-node-h node) (canvas-diagram--rows-top node rows))) (max 1 rows)))

(defun canvas-diagram--rows-top (node rows)
  "The y within NODE at which its ROWS start: below its label."
  (if (zerop rows) 0 (/ (float (canvas-diagram-node-h node)) (1+ rows))))

(defun canvas-diagram--bounds (nodes)
  "(WIDTH . HEIGHT) of the drawing the laid-out NODES make."
  (let ((right 0) (bottom 0))
    (dolist (n nodes)
      (setq right (max right (+ (canvas-diagram-node-x n) (canvas-diagram-node-w n)))
            bottom (max bottom (+ (canvas-diagram-node-y n) (canvas-diagram-node-h n)))))
    (cons right bottom)))

(defun canvas-diagram--map-size (diagram &optional zoom)
  "(W . H) of DIAGRAM's drawing with its margins, in canvas pixels at ZOOM.
The drawing is its boxes, plus the slack its edges take beyond them."
  (let* ((b (canvas-diagram--bounds (canvas-diagram-nodes diagram)))
         (slack (canvas-diagram-slack diagram))
         (zoom (or zoom 1.0))
         (m (* 2 canvas-diagram-margin)))
    (cons (+ (ceiling (* zoom (+ (car b) (car slack)))) m)
          (+ (ceiling (* zoom (+ (cdr b) (cdr slack)))) m))))

(defun canvas-diagram--node-at (nodes x y)
  "The node of NODES whose box holds the drawing point X Y, or nil."
  (cl-find-if (lambda (n)
                (and (<= (canvas-diagram-node-x n) x
                         (+ (canvas-diagram-node-x n) (canvas-diagram-node-w n)))
                     (<= (canvas-diagram-node-y n) y
                         (+ (canvas-diagram-node-y n) (canvas-diagram-node-h n)))))
              nodes))

(defun canvas-diagram--clamp-offset (offset map size)
  "OFFSET kept so that a canvas of SIZE stays within a MAP, both (W . H)."
  (cons (max 0 (min (car offset) (- (car map) (car size))))
        (max 0 (min (cdr offset) (- (cdr map) (cdr size))))))

(defun canvas-diagram--map-point (xy offset &optional zoom)
  "The drawing point under canvas pixel XY when scrolled by OFFSET at ZOOM."
  (let ((zoom (or zoom 1.0)))
    (cons (/ (+ (car xy) (car offset) (- canvas-diagram-margin)) zoom)
          (/ (+ (cdr xy) (cdr offset) (- canvas-diagram-margin)) zoom))))

(defun canvas-diagram--canvas-box (node offset &optional zoom)
  "NODE's box on the canvas, (X0 Y0 X1 Y1), scrolled by OFFSET at ZOOM."
  (let* ((zoom (or zoom 1.0))
         (x0 (+ (* zoom (canvas-diagram-node-x node)) canvas-diagram-margin (- (car offset))))
         (y0 (+ (* zoom (canvas-diagram-node-y node)) canvas-diagram-margin (- (cdr offset)))))
    (list x0 y0
          (+ x0 (* zoom (canvas-diagram-node-w node)))
          (+ y0 (* zoom (canvas-diagram-node-h node))))))

(defun canvas-diagram--hot-spots (nodes offset &optional zoom)
  "Image map of NODES' boxes on a canvas scrolled by OFFSET at ZOOM.
Hovering a box shows its note, or its label; the pointer becomes a
hand; a click arrives as `canvas-diagram-node' prefixed."
  (mapcar (lambda (n)
            (pcase-let* ((`(,bx0 ,by0 ,bx1 ,by1) (canvas-diagram--canvas-box n offset zoom))
                         (x0 (round bx0)) (y0 (round by0)) (x1 (round bx1)) (y1 (round by1)))
              `((rect . ((,x0 . ,y0) . (,x1 . ,y1)))
                canvas-diagram-node
                (help-echo ,(or (canvas-diagram-node-note n) (canvas-diagram-node-label n))
                           pointer hand))))
          nodes))

;;;; Drawing

(defun canvas-diagram-rounded-rect (ctx x y w h r)
  "Make a path for a W by H rectangle at X Y with corners of radius R."
  (let ((half (/ float-pi 2)))
    (canvas-cairo-new-path ctx)
    (canvas-cairo-arc ctx (+ x w (- r)) (+ y r) r (- half) 0)
    (canvas-cairo-arc ctx (+ x w (- r)) (+ y h (- r)) r 0 half)
    (canvas-cairo-arc ctx (+ x r) (+ y h (- r)) r half float-pi)
    (canvas-cairo-arc ctx (+ x r) (+ y r) r float-pi (* 3 half))
    (canvas-cairo-close-path ctx)))

(defun canvas-diagram--card (ctx x y w h)
  "A card at X Y of W by H: the background, nearly opaque, with an edge."
  (canvas-diagram-rounded-rect ctx x y w h canvas-diagram-radius)
  (canvas-diagram-set-rgb ctx (canvas-diagram-color :background) 0.94)
  (canvas-cairo-fill ctx t)
  (canvas-diagram-set-rgb ctx (canvas-diagram-color :edge))
  (canvas-cairo-set-line-width ctx 1)
  (canvas-cairo-stroke ctx))

(defun canvas-diagram-corner (node &optional shape)
  "Radius of NODE's corners for SHAPE, else for `canvas-diagram-shape'."
  (pcase (or shape canvas-diagram-shape)
    ('square 0)
    ('pill (/ (min (canvas-diagram-node-w node) (canvas-diagram-node-h node)) 2.0))
    ('rounded canvas-diagram-radius)
    (other (error "canvas-diagram: %S is no shape of a box" other))))

(defun canvas-diagram--node-corner (diagram node)
  "Radius of NODE's corners, in the shape the package gives it, else the setting."
  (canvas-diagram-corner node (canvas-diagram--call diagram :node-shape diagram node)))

(defun canvas-diagram--node-rgb (diagram node)
  "(R G B) filling NODE's box: the package's choice, else the node colour."
  (or (canvas-diagram--call diagram :node-rgb diagram node)
      (canvas-diagram-color :node)))

(defun canvas-diagram--draw-badge (ctx badge x y h font)
  "Draw BADGE, (TEXT RGB), as a pill H tall at X Y, its TEXT centred in
FONT made bold, in the ink that reads on RGB.  Return the pill's width,
the room a measure of CTX gives the text."
  (pcase-let* ((`(,text ,rgb) badge)
               (w (car (funcall (canvas-diagram-measure ctx) text)))
               (bold (canvas-diagram--bold font))
               (text-w (car (canvas-cairo-text-size ctx text bold))))
    (canvas-diagram-rounded-rect ctx x y w h (/ h 2.0))
    (canvas-diagram-set-rgb ctx rgb)
    (canvas-cairo-fill ctx)
    (canvas-diagram-set-rgb ctx (canvas-diagram-ink-on rgb))
    (canvas-cairo-text ctx (+ x (/ (- w text-w) 2.0)) y text bold)
    w))

(defun canvas-diagram-blend (a b fraction)
  "Return the colour FRACTION of the way from A to B, both (R G B)."
  (cl-mapcar (lambda (from to) (+ from (* fraction (- to from)))) a b))

(defun canvas-diagram--node-tint (node selected)
  "How far NODE's fill moves towards the selection colour.
A marked box and the box the keyboard is on, SELECTED, each pull it,
and a box that is both is pulled by both."
  (min 1.0
       (+ (if (canvas-diagram-marked-p node) canvas-diagram-mark-tint 0)
          (if (and selected (eq node selected)) canvas-diagram-selection-tint 0))))

(defun canvas-diagram--node-fill (diagram node selected)
  "Return the colour NODE's box is filled with.
A marked box and the box the keyboard is on, SELECTED, are tinted
towards the selection colour; a ring on its own is easy to lose in a
drawing of many boxes."
  (let ((rgb (canvas-diagram--node-rgb diagram node))
        (tint (canvas-diagram--node-tint node selected)))
    (if (> tint 0)
        (canvas-diagram-blend rgb (canvas-diagram-color :selection) tint)
      rgb)))

(defun canvas-diagram--node-ink (fill tinted)
  "Return the colour NODE's text is set in, on a box filled with FILL.
Every box takes the text colour, except the TINTED one: its fill is
the only one the package did not choose, so it is the only one whose
ink has to follow the fill to stay readable."
  (if tinted
      (canvas-diagram-ink-on fill)
    (canvas-diagram-color :text)))

(defun canvas-diagram--draw-node (diagram ctx node font &optional selected)
  "Fill NODE's box, outline it for its kind, set its icon, badge and text.
NODE is tinted when it is SELECTED, the box the keyboard is on."
  (let* ((x (canvas-diagram-node-x node))
         (y (canvas-diagram-node-y node))
         (kind (and canvas-diagram-show-kinds (canvas-diagram-node-kind node)))
         (pad (canvas-diagram--padding))
         (tinted (> (canvas-diagram--node-tint node selected) 0))
         (fill (canvas-diagram--node-fill diagram node selected))
         (ink (canvas-diagram--node-ink fill tinted)))
    (canvas-diagram-rounded-rect ctx x y (canvas-diagram-node-w node)
                                 (canvas-diagram-node-h node)
                                 (canvas-diagram--node-corner diagram node))
    (canvas-diagram-set-rgb ctx fill)
    (canvas-cairo-fill ctx kind)
    (when kind
      (canvas-diagram-set-rgb ctx (canvas-diagram-kind-rgb kind))
      (canvas-cairo-set-line-width ctx canvas-diagram-kind-width)
      (canvas-cairo-stroke ctx))
    (canvas-diagram-set-rgb ctx ink)
    (let ((dx 0)
          (line-h (- (canvas-diagram-node-h node) (* 2 pad))))
      (when-let* ((svg (canvas-diagram--icon node)))
        (let ((side (canvas-diagram--icon-side (canvas-diagram-node-h node))))
          (canvas-cairo-svg ctx svg (+ x pad) (+ y pad) side side)
          (setq dx (+ side canvas-diagram--icon-gap))))
      (when-let* ((badge (canvas-diagram--badge diagram node)))
        (setq dx (+ dx (canvas-diagram--draw-badge ctx badge (+ x pad dx) (+ y pad) line-h font)
                    canvas-diagram--icon-gap))
        (canvas-diagram-set-rgb ctx ink))
      (canvas-cairo-text ctx (+ x pad dx) (+ y pad) (canvas-diagram--node-text diagram node) font))
    (canvas-diagram--draw-rows ctx node font)))

(defun canvas-diagram--draw-rows (ctx node font)
  "Write the rows NODE holds under its label on CTX, one to a line, with a
line drawn above the first of them."
  (when-let* ((rows (canvas-diagram--rows node))
              (count (length rows))
              (pad (canvas-diagram--padding))
              (top (+ (canvas-diagram-node-y node) (canvas-diagram--rows-top node count)))
              (step (canvas-diagram--row-step node count)))
    (canvas-diagram-set-rgb ctx (canvas-diagram-color :edge))
    (canvas-cairo-set-line-width ctx 1)
    (canvas-cairo-new-path ctx)
    (canvas-cairo-move-to ctx (canvas-diagram-node-x node) top)
    (canvas-cairo-line-to ctx (+ (canvas-diagram-node-x node) (canvas-diagram-node-w node)) top)
    (canvas-cairo-stroke ctx)
    (canvas-diagram-set-rgb ctx (canvas-diagram-color :text))
    (cl-loop for row in rows
             for i from 0
             do (canvas-cairo-text ctx (+ (canvas-diagram-node-x node) pad) (+ top (* i step)) row font))))

(defun canvas-diagram--marks-in-view (nodes view)
  "The NODES of VIEW the canvas can show; all of them without a VIEW."
  (if view (cl-remove-if-not (lambda (node) (canvas-diagram--box-in-view-p node view)) nodes) nodes))

(defun canvas-diagram--draw-marks (diagram ctx nodes &optional width)
  "Ring NODES, the marked boxes, on CTX, WIDTH pixels wide, in the colour
of the selection but lighter, so that a marked box is seen without the
keyboard on it.  Their fill is tinted as well; see
`canvas-diagram-mark-tint'."
  (let ((rgb (canvas-diagram-color :selection)))
    (dolist (node nodes)
      (canvas-diagram--selection-path ctx node (canvas-diagram--call diagram :node-shape diagram node))
      (canvas-diagram-set-rgb ctx rgb 0.6)
      (canvas-cairo-set-line-width ctx (or width 2))
      (canvas-cairo-stroke ctx))))

(defconst canvas-diagram--view-slack 8
  "Drawing units a box may reach past the view and still be drawn.
A box is drawn a little larger than it is: its outline, its ring and the
kind around it.")

(defun canvas-diagram--view-rect (offset size zoom &optional slack)
  "The part of the drawing a canvas of SIZE shows at OFFSET and ZOOM,
as (LEFT TOP RIGHT BOTTOM) in drawing coordinates.  SLACK, none by
default, widens it on every side: the drawing asks with slack, since a
box is drawn a little larger than it is, and the scrolling asks without,
since a box that only just reaches the edge is one to nudge into view."
  (let ((left (/ (- (car offset) canvas-diagram-margin) (float zoom)))
        (top (/ (- (cdr offset) canvas-diagram-margin) (float zoom)))
        (slack (or slack 0)))
    (list (- left slack)
          (- top slack)
          (+ left (/ (car size) (float zoom)) slack)
          (+ top (/ (cdr size) (float zoom)) slack))))

(defun canvas-diagram--box-in-view-p (node view)
  "Whether NODE's box reaches VIEW, (LEFT TOP RIGHT BOTTOM)."
  (let ((x (canvas-diagram-node-x node))
        (y (canvas-diagram-node-y node)))
    (and (> (+ x (canvas-diagram-node-w node)) (nth 0 view))
         (< x (nth 2 view))
         (> (+ y (canvas-diagram-node-h node)) (nth 1 view))
         (< y (nth 3 view)))))

(defun canvas-diagram--draw-all (diagram ctx font &optional selected view)
  "Draw DIAGRAM's edges and boxes on CTX, in drawing coordinates.
SELECTED, the box the keyboard is on, is drawn tinted.  With VIEW, the
part of the drawing the canvas shows, a box outside it is left undrawn:
it would fall outside the canvas anyway, and a drawing of hundreds of
boxes is only quick to move about in when the ones out of sight cost
nothing.  The boxes the package puts in front with `:front' come last,
over the backdrop that its `:draw-front' draws for them, and what its
`:draw-over' draws comes after every box."
  (canvas-diagram-set-rgb ctx (canvas-diagram-color :edge))
  (canvas-cairo-set-line-width ctx 2)
  (canvas-diagram--call diagram :draw-edges diagram ctx)
  (let* ((front (canvas-diagram--call diagram :front diagram))
         (back (cl-remove-if (lambda (node) (memq node front)) (canvas-diagram-nodes diagram))))
    (canvas-diagram--draw-nodes diagram ctx back font selected view)
    (when front
      (canvas-diagram--call diagram :draw-front diagram ctx front)
      (canvas-diagram--draw-nodes diagram ctx front font selected view)))
  (canvas-diagram--call diagram :draw-over diagram ctx))

(defun canvas-diagram--draw-nodes (diagram ctx nodes font selected view)
  "Draw the boxes of NODES of DIAGRAM on CTX, with SELECTED tinted; with
VIEW, only those that reach it."
  (dolist (node nodes)
    (when (or (null view) (canvas-diagram--box-in-view-p node view))
      (canvas-diagram--draw-node diagram ctx node font selected))))

(defun canvas-diagram--selection-path (ctx node &optional shape)
  "Make the path of the ring around NODE's box, which has SHAPE."
  (let ((gap 3))
    (canvas-diagram-rounded-rect ctx
                                 (- (canvas-diagram-node-x node) gap)
                                 (- (canvas-diagram-node-y node) gap)
                                 (+ (canvas-diagram-node-w node) (* 2 gap))
                                 (+ (canvas-diagram-node-h node) (* 2 gap))
                                 (+ (canvas-diagram-corner node shape) gap))))

(defun canvas-diagram--draw-selection (ctx node &optional width shape)
  "Ring NODE's box, which has SHAPE, to show the keyboard is on it, WIDTH
pixels wide, with a soft halo around the ring so the eye finds it in a
large drawing."
  (let ((width (or width 3))
        (rgb (canvas-diagram-color :selection)))
    (canvas-diagram--selection-path ctx node shape)
    (canvas-diagram-set-rgb ctx rgb 0.3)
    (canvas-cairo-set-line-width ctx (* 3 width))
    (canvas-cairo-stroke ctx t)
    (canvas-diagram-set-rgb ctx rgb)
    (canvas-cairo-set-line-width ctx width)
    (canvas-cairo-stroke ctx)))

;;;; The legend

(defconst canvas-diagram--swatch 12
  "Side of a legend swatch, in pixels.")

(defun canvas-diagram--kinds-in (nodes)
  "Kinds used by NODES, in order of first appearance."
  (let (kinds)
    (dolist (n nodes)
      (when-let* ((k (canvas-diagram-node-kind n)))
        (unless (member k kinds) (push k kinds))))
    (nreverse kinds)))

(defun canvas-diagram--badges-in (diagram)
  "The badges of DIAGRAM's nodes shown, (TEXT RGB) each, once each by
TEXT, in order of first appearance."
  (let (badges)
    (dolist (n (canvas-diagram-nodes diagram))
      (when-let* ((badge (canvas-diagram--badge diagram n)))
        (unless (assoc (car badge) badges)
          (push badge badges))))
    (nreverse badges)))

(defun canvas-diagram--badge-rows (diagram own)
  "The legend rows of the badges in use in DIAGRAM, `badge', less any that
OWN, the package's rows, names; none when OWN has a badge row, as the
package then explains its badges itself."
  (unless (cl-some (lambda (row) (eq (nth 2 row) 'badge)) own)
    (mapcar (lambda (b) (list (car b) (cadr b) 'badge))
            (cl-remove-if (lambda (b) (assoc (car b) own)) (canvas-diagram--badges-in diagram)))))

(defun canvas-diagram--legend-entries (diagram)
  "Rows of the legend, each (LABEL RGB STYLE): the package's own, then
the badges in use, `badge', unless the package explains its badges, then
the kinds in use, `outline', less any the package explained already.  nil
when there is nothing to explain."
  (let ((own (canvas-diagram--call diagram :legend diagram)))
    (append own
            (canvas-diagram--badge-rows diagram own)
            (when canvas-diagram-show-kinds
              (mapcar (lambda (k) (list k (canvas-diagram-kind-rgb k) 'outline))
                      (cl-remove-if (lambda (k) (assoc k own))
                                    (canvas-diagram--kinds-in (canvas-diagram-nodes diagram))))))))

(defun canvas-diagram--legend-geometry (ctx entries font size)
  "Where the legend for ENTRIES goes on a canvas of SIZE, as a plist.
:x :y :w :h is its box, in the bottom-left corner; :row-h its row
height.  nil without entries."
  (when entries
    (let* ((pad canvas-diagram-padding)
           (row-h (+ 4 (cdr (canvas-cairo-text-size ctx "Ag" font))))
           (text-w (apply #'max (mapcar (lambda (e) (car (canvas-cairo-text-size ctx (car e) font)))
                                        entries)))
           (w (+ pad canvas-diagram--swatch pad text-w pad))
           (h (+ pad (* row-h (length entries)) pad)))
      (list :x canvas-diagram-margin :y (- (cdr size) canvas-diagram-margin h)
            :w w :h h :row-h row-h))))

(defun canvas-diagram--legend-row (geometry i)
  "The (X Y) where row I of the legend at GEOMETRY starts."
  (list (+ (plist-get geometry :x) canvas-diagram-padding)
        (+ (plist-get geometry :y) canvas-diagram-padding
           (* i (plist-get geometry :row-h)))))

(defun canvas-diagram--legend-swatch (geometry i)
  "The (X Y) of the swatch on row I of the legend at GEOMETRY."
  (pcase-let ((`(,x ,y) (canvas-diagram--legend-row geometry i)))
    (list x (+ y (/ (- (plist-get geometry :row-h) canvas-diagram--swatch) 2)))))

(defun canvas-diagram--swatch (ctx x y rgb style)
  "A swatch at X Y: a square filled with RGB for STYLE `fill', a round
one for `badge', or a square outlined in it for `outline'."
  (let ((s canvas-diagram--swatch))
    (canvas-diagram-rounded-rect ctx x y s s (if (eq style 'badge) (/ s 2.0) 2))
    (canvas-diagram-set-rgb ctx rgb)
    (if (memq style '(fill badge))
        (canvas-cairo-fill ctx)
      (canvas-cairo-set-line-width ctx canvas-diagram-kind-width)
      (canvas-cairo-stroke ctx))))

(defun canvas-diagram--draw-legend (ctx entries font size)
  "Draw the legend for ENTRIES in the bottom-left corner of a canvas of SIZE."
  (when-let* ((g (canvas-diagram--legend-geometry ctx entries font size)))
    (canvas-diagram--card ctx (plist-get g :x) (plist-get g :y)
                          (plist-get g :w) (plist-get g :h))
    (let ((i 0))
      (dolist (entry entries)
        (pcase-let ((`(,label ,rgb ,style) entry)
                    (`(,x ,y) (canvas-diagram--legend-row g i))
                    (`(,sx ,sy) (canvas-diagram--legend-swatch g i)))
          (canvas-diagram--swatch ctx sx sy rgb style)
          (canvas-diagram-set-rgb ctx (canvas-diagram-color :text))
          (canvas-cairo-text ctx (+ x canvas-diagram--swatch canvas-diagram-padding)
                             (+ y 2) label font))
        (setq i (1+ i))))))

;;;; The card

(defun canvas-diagram-card-text (diagram node)
  "The card's (TITLE PATH BODY) for NODE: the package's, else the label and note."
  (or (canvas-diagram--call diagram :card diagram node)
      (list (canvas-diagram-node-label node) ""
            (or (canvas-diagram-node-note node) "No note."))))

(defun canvas-diagram--popup-rect (diagram ctx node font offset size &optional zoom)
  "Box (X Y W H) of NODE's card on a canvas of SIZE scrolled by OFFSET at ZOOM.
It hangs to the right of the box, pushed back inside the canvas."
  (pcase-let* ((`(,title ,path ,body) (canvas-diagram-card-text diagram node))
               (pad canvas-diagram-padding)
               (w canvas-diagram-popup-width)
               (inner (- w (* 2 pad)))
               (h (+ pad
                     (cdr (canvas-cairo-text-size ctx title (canvas-diagram--bold font) inner))
                     (cdr (canvas-cairo-text-size ctx path font inner))
                     4
                     (cdr (canvas-cairo-text-size ctx body font inner))
                     pad))
               (`(,_ ,y ,x1 ,_) (canvas-diagram--canvas-box node offset zoom))
               (x (+ x1 10)))
    (list (max 0 (min x (- (car size) w)))
          (max 0 (min y (- (cdr size) h)))
          w h)))

(defun canvas-diagram--draw-popup (diagram ctx node font offset size &optional zoom)
  "Draw NODE's card beside its box, in canvas coordinates."
  (pcase-let* ((`(,title ,path ,body) (canvas-diagram-card-text diagram node))
               (`(,x ,y ,w ,h) (canvas-diagram--popup-rect diagram ctx node font offset size zoom))
               (pad canvas-diagram-padding)
               (inner (- w (* 2 pad)))
               (ty (+ y pad)))
    (canvas-diagram--card ctx x y w h)
    (canvas-diagram-set-rgb ctx (canvas-diagram-color :text))
    (cl-incf ty (cdr (canvas-cairo-text ctx (+ x pad) ty title (canvas-diagram--bold font) inner)))
    (canvas-diagram-set-rgb ctx (canvas-diagram-color :edge))
    (cl-incf ty (+ 4 (cdr (canvas-cairo-text ctx (+ x pad) ty path font inner))))
    (canvas-diagram-set-rgb ctx (canvas-diagram-color :text))
    (canvas-cairo-text ctx (+ x pad) ty body font inner)))

;;;; Rendering

(defun canvas-diagram--render (diagram ctx size &optional offset popup selected zoom)
  "Draw DIAGRAM on CTX, a canvas of SIZE, and show it.
The drawing is scrolled by OFFSET and drawn at ZOOM, POPUP's card is
open, SELECTED's box is ringed, and the legend sits in the corner."
  (let ((font (canvas-diagram-font))
        (offset (or offset '(0 . 0)))
        (zoom (or zoom 1.0)))
    (apply #'canvas-cairo-clear ctx (append (canvas-diagram-color :background) '(1)))
    (canvas-cairo-save ctx)
    (canvas-cairo-translate ctx (- canvas-diagram-margin (car offset))
                            (- canvas-diagram-margin (cdr offset)))
    (canvas-cairo-scale ctx zoom zoom)
    (canvas-diagram--draw-all diagram ctx font selected
                              (canvas-diagram--view-rect offset size zoom canvas-diagram--view-slack))
    (canvas-diagram--draw-marks diagram ctx (canvas-diagram--marks-in-view
                                     (canvas-diagram-marked-nodes)
                                     (canvas-diagram--view-rect offset size zoom canvas-diagram--view-slack))
                                (/ 2.0 zoom))
    (when selected
      (canvas-diagram--call diagram :draw-trail diagram ctx selected (/ 3.0 zoom))
      (canvas-diagram--draw-selection ctx selected (/ 3.0 zoom)
                                      (canvas-diagram--call diagram :node-shape diagram selected)))
    (canvas-cairo-restore ctx)
    (when popup
      (canvas-diagram--draw-popup diagram ctx popup font offset size zoom))
    (when canvas-diagram-show-legend
      (canvas-diagram--draw-legend ctx (canvas-diagram--legend-entries diagram) font size))
    (canvas-diagram--call diagram :overlay diagram ctx size offset zoom selected)
    (canvas-cairo-flush ctx)))

(defun canvas-diagram--export-size (diagram ctx font)
  "(W . H) of a canvas holding all of DIAGRAM and its legend."
  (let* ((map (canvas-diagram--map-size diagram))
         (g (and canvas-diagram-show-legend
                 (canvas-diagram--legend-geometry
                  ctx (canvas-diagram--legend-entries diagram) font '(1 . 1)))))
    (if g
        (cons (max (car map) (+ (plist-get g :w) (* 2 canvas-diagram-margin)))
              (+ (cdr map) (plist-get g :h) canvas-diagram-margin))
      map)))

(defun canvas-diagram--thumb-fit (map w h)
  "How a MAP (W . H) fits centred in a W by H box: (SCALE OX OY)."
  (let ((scale (min (/ (float w) (car map)) (/ (float h) (cdr map)))))
    (list scale
          (/ (- w (* scale (car map))) 2.0)
          (/ (- h (* scale (cdr map))) 2.0))))

(defun canvas-diagram--viewport (ctx offset size scale &optional zoom)
  "Tint and outline the SIZE view at OFFSET, both in canvas pixels at ZOOM,
on CTX drawn at SCALE over the drawing with its margins."
  (let ((zoom (or zoom 1.0))
        (m canvas-diagram-margin))
    ;; The margins are not zoomed; what lies between them is.
    (canvas-cairo-rectangle ctx (+ m (/ (- (car offset) m) zoom)) (+ m (/ (- (cdr offset) m) zoom))
                            (/ (car size) zoom) (/ (cdr size) zoom)))
  (canvas-diagram-set-rgb ctx (canvas-diagram-color :text) 0.12)
  (canvas-cairo-fill ctx t)
  (canvas-diagram-set-rgb ctx (canvas-diagram-color :text) 0.6)
  (canvas-cairo-set-line-width ctx (/ 2.0 scale))
  (canvas-cairo-stroke ctx))

(defun canvas-diagram--thumbnail (diagram offset size w h bg &optional selected zoom)
  "Pixels of the whole DIAGRAM scaled into W by H over BG, as a vector.
The part a canvas of SIZE shows when scrolled by OFFSET at ZOOM is
tinted and outlined, as a minimap's viewport is, and SELECTED's box is
ringed."
  (let* ((canvas (list 'image :type 'canvas :id (make-symbol "canvas-diagram-thumb")
                       :data-width w :data-height h :scale 1.0))
         (ctx (canvas-cairo-context canvas)))
    (pcase-let ((`(,scale ,ox ,oy) (canvas-diagram--thumb-fit
                                    (canvas-diagram--map-size diagram) w h)))
      (unwind-protect
          (progn
            (apply #'canvas-cairo-clear ctx (append (canvas-diagram--argb-rgb bg) '(1)))
            (canvas-cairo-save ctx)
            (canvas-cairo-translate ctx ox oy)
            (canvas-cairo-scale ctx scale scale)
            (canvas-cairo-save ctx)
            (canvas-cairo-translate ctx canvas-diagram-margin canvas-diagram-margin)
            (canvas-diagram--draw-all diagram ctx (canvas-diagram-font))
            (when selected
              ;; Two device pixels, whatever the scale, or it would vanish.
              (canvas-diagram--draw-selection ctx selected (/ 2.0 scale)
                                              (canvas-diagram--call diagram :node-shape diagram selected)))
            (canvas-cairo-restore ctx)
            (canvas-diagram--viewport ctx offset size scale zoom)
            (canvas-cairo-restore ctx)
            (canvas-cairo-pixels ctx 0 0 w h))
        (canvas-cairo-destroy ctx)))))

;;;; Export

(defun canvas-diagram-make-canvas ()
  "A one-pixel canvas spec, grown to its window later.
:scale 1 keeps Emacs from scaling it with the font, so hot spots and
clicks stay in canvas pixels."
  (list 'image :type 'canvas :id (make-symbol "canvas-diagram")
        :data-width 1 :data-height 1 :scale 1.0))

(defun canvas-diagram--file-format (file)
  "What FILE is to hold, by its name: `png', `svg' or `pdf'; an error for
any other name."
  (pcase (downcase (or (file-name-extension file) ""))
    ("png" 'png)
    ("svg" 'svg)
    ("pdf" 'pdf)
    (other (error "canvas-diagram: cannot write %s as a picture; use .png, .svg or .pdf"
                  (if (string-empty-p other) "a file without an extension" (concat "." other))))))

(defun canvas-diagram--lay-out-for-export (diagram spec ctx)
  "Build DIAGRAM from SPEC and lay it out on CTX: (W . H) of the whole picture.
Outside a diagram buffer, the folds are those DIAGRAM starts with."
  (setf (canvas-diagram-spec diagram) spec
        (canvas-diagram-model diagram) (canvas-diagram--call diagram :build diagram spec))
  (canvas-diagram--start-folds)
  (setf (canvas-diagram-nodes diagram) (canvas-diagram--call diagram :layout diagram ctx))
  (canvas-diagram--export-size diagram ctx (canvas-diagram-font)))

(defun canvas-diagram--write-png (diagram canvas ctx size file)
  "Draw DIAGRAM, laid out, SIZE large on CANVAS through CTX and write the
pixels to FILE."
  (plist-put (cdr canvas) :data-width (car size))
  (plist-put (cdr canvas) :data-height (cdr size))
  (canvas-diagram--render diagram ctx size)
  (canvas-cairo-write-png ctx file))

(defun canvas-diagram--write-vector (diagram size file)
  "Draw DIAGRAM, laid out, SIZE large into FILE, an SVG or a PDF by its name."
  (let ((ctx (canvas-cairo-file-context file (car size) (cdr size))))
    (unwind-protect (canvas-diagram--render diagram ctx size)
      (canvas-cairo-destroy ctx))))

(defvar canvas-diagram--diagram)

(defun canvas-diagram-export (diagram spec file)
  "Build DIAGRAM from SPEC, draw it whole into FILE and return FILE: a PNG,
an SVG or a PDF by FILE's name.  No buffer or frame is needed, so this
works in batch.  Outside a diagram buffer, the export draws the folds
that DIAGRAM starts with; in one, the folds of that buffer."
  (if canvas-diagram--diagram
      (canvas-diagram--export diagram spec file)
    (with-temp-buffer
      (setq canvas-diagram--diagram diagram)
      (canvas-diagram--export diagram spec file))))

(defun canvas-diagram--export (diagram spec file)
  "Draw DIAGRAM, built from SPEC, whole into FILE; FILE."
  (let* ((format (canvas-diagram--file-format file))
         (canvas (canvas-diagram-make-canvas))
         (ctx (canvas-cairo-context canvas)))
    (unwind-protect
        (let ((size (canvas-diagram--lay-out-for-export diagram spec ctx)))
          (if (eq format 'png)
              (canvas-diagram--write-png diagram canvas ctx size (expand-file-name file))
            (canvas-diagram--write-vector diagram size (expand-file-name file))))
      (canvas-cairo-destroy ctx))
    file))

(defun canvas-diagram--write-default ()
  "The file this buffer's picture is offered to be written to: the
buffer's name without its stars, as a PNG."
  (concat (string-trim (buffer-name) "\\*+" "\\*+") ".png"))

(defun canvas-diagram-write (file)
  "Write this buffer's diagram to FILE, a PNG, an SVG or a PDF by its name,
and return FILE.  The whole drawing is drawn afresh with the looks in
force here; the buffer is left as it is.  A package with an :export
callback writes its own way."
  (interactive (list (read-file-name "Write the diagram to (.png, .svg or .pdf): "
                                     nil nil nil (canvas-diagram--write-default))))
  (unless canvas-diagram--diagram (user-error "canvas-diagram: no diagram in this buffer"))
  (canvas-diagram--file-format file)
  (let ((copy (copy-canvas-diagram canvas-diagram--diagram))
        (spec (canvas-diagram-spec canvas-diagram--diagram)))
    (if (canvas-diagram--has copy :export)
        (canvas-diagram--call copy :export copy spec file)
      (canvas-diagram-export copy spec file))
    (message "Wrote %s" file)
    file))

;;;; The buffer

(defvar-local canvas-diagram--diagram nil
  "The diagram this buffer shows.")

(defvar-local canvas-diagram--canvas nil
  "The canvas image spec shown in this buffer.")

(defvar-local canvas-diagram--context nil
  "The drawing context of this buffer's canvas.")

(defvar-local canvas-diagram--offset '(0 . 0)
  "The canvas pixels the view is scrolled by, at the current zoom.")

(defvar-local canvas-diagram--zoom 1.0
  "Canvas pixels per drawing unit.")

(defvar-local canvas-diagram--popup nil
  "The node whose card is open, or nil.")

(defvar-local canvas-diagram--selected nil
  "The node the keyboard is on.")

(defvar-local canvas-diagram--marked nil
  "The keys of the boxes that are marked, newest first.  A mark is held by
the key of a box, not by the box itself, so that it outlives a rebuild.")

(defvar-local canvas-diagram--thumb nil
  "The last thumbnail handed to canvas-minimap, as (KEY . PIXELS).")

(defvar-local canvas-diagram--thumb-box nil
  "(W . H) of the box canvas-minimap last drew this diagram in.")

(defvar-local canvas-diagram--source nil
  "The buffer this diagram follows, or nil.")

(defvar-local canvas-diagram--source-timer nil
  "Timer that rereads the source once typing there pauses.")

(defvar-local canvas-diagram--follower nil
  "In a source buffer: the diagram buffer following it, or nil.")

(defvar-local canvas-diagram--spots-timer nil
  "Timer that puts the hot spots on the canvas once scrolling pauses.")

(defvar-local canvas-diagram--slide nil
  "The running slide, or nil: a plist of its :start time, its :time in
seconds, its frame :timer, and its :froms, ((NODE . CENTRE)...), the
drawing point each sliding node's middle comes from.")

(defvar canvas-diagram--buffers (make-hash-table :test 'eq :weakness 'key)
  "Canvas spec -> the buffer showing it.")

(defun canvas-diagram-nodes-shown ()
  "The nodes of this buffer's diagram, in reading order."
  (canvas-diagram-nodes canvas-diagram--diagram))

(defun canvas-diagram-selected ()
  "The node the keyboard is on."
  canvas-diagram--selected)

(defun canvas-diagram-marked-p (node)
  "Whether NODE is marked.
Nothing is marked where there is no buffer holding a diagram, which is
what an export is; the drawing asks this for every box it fills."
  (and canvas-diagram--marked
       canvas-diagram--diagram
       (member (canvas-diagram--node-key canvas-diagram--diagram node)
               canvas-diagram--marked)
       t))

(defun canvas-diagram-marked-nodes ()
  "The marked boxes of this buffer's diagram, in reading order."
  (when canvas-diagram--diagram
    (cl-remove-if-not #'canvas-diagram-marked-p (canvas-diagram-nodes canvas-diagram--diagram))))

(defun canvas-diagram-toggle-mark ()
  "Mark the box the keyboard is on, or let it go when it is marked."
  (interactive)
  (let* ((node (or (canvas-diagram-selected) (user-error "canvas-diagram: no box here")))
         (key (canvas-diagram--node-key canvas-diagram--diagram node)))
    (setq canvas-diagram--marked
          (if (member key canvas-diagram--marked)
              (delete key canvas-diagram--marked)
            (cons key canvas-diagram--marked)))
    (canvas-diagram-redraw)))

(defun canvas-diagram-mark-all ()
  "Mark every box in the drawing."
  (interactive)
  (setq canvas-diagram--marked
        (mapcar (lambda (node)
                  (canvas-diagram--node-key canvas-diagram--diagram node))
                (canvas-diagram-nodes-shown)))
  (canvas-diagram-redraw)
  (message "Marked %d" (length canvas-diagram--marked)))

(defun canvas-diagram-unmark-all ()
  "Let every marked box go."
  (interactive)
  (let ((n (length canvas-diagram--marked)))
    (setq canvas-diagram--marked nil)
    (canvas-diagram-redraw)
    (when (called-interactively-p 'interactive)
      (message "Let %d go" n))))

(defun canvas-diagram-quit ()
  "Let the marked boxes go, and then quit as `keyboard-quit' does
anywhere else."
  (interactive)
  (canvas-diagram-unmark-all)
  (keyboard-quit))

(defun canvas-diagram-set-selected (node)
  "Put the keyboard on NODE without redrawing; a relayout will."
  (setq canvas-diagram--selected node))

(defun canvas-diagram-current-model ()
  "The model of this buffer's diagram."
  (canvas-diagram-model canvas-diagram--diagram))

(defun canvas-diagram--canvas-size ()
  "(W . H) of this buffer's canvas."
  (let ((plist (cdr canvas-diagram--canvas)))
    (cons (plist-get plist :data-width) (plist-get plist :data-height))))

(defun canvas-diagram--view-extent ()
  "(W . H) of the drawing with its margins, in canvas pixels at the zoom."
  (canvas-diagram--map-size canvas-diagram--diagram canvas-diagram--zoom))

(defun canvas-diagram--release ()
  "Let go of this buffer's context, canvas, timers, source and selection.
The keyboard is on a node of the diagram being let go, so it goes too;
a build that signals afterwards leaves the buffer with neither."
  (canvas-diagram--unfollow)
  (canvas-diagram--end-slide)
  (when canvas-diagram--spots-timer
    (cancel-timer canvas-diagram--spots-timer)
    (setq canvas-diagram--spots-timer nil))
  (setq canvas-diagram--selected nil)
  (when canvas-diagram--context
    (canvas-cairo-destroy canvas-diagram--context)
    (remhash canvas-diagram--canvas canvas-diagram--buffers)
    (setq canvas-diagram--context nil
          canvas-diagram--canvas nil
          canvas-diagram--diagram nil)))

(defun canvas-diagram-adopt (diagram spec)
  "Make DIAGRAM, built from SPEC, this buffer's; show it on a fresh canvas.
The canvas is not sized yet; `canvas-diagram--fit-window' does that."
  (canvas-diagram--release)
  (let* ((canvas (canvas-diagram-make-canvas))
         (ctx (canvas-cairo-context canvas)))
    (setf (canvas-diagram-spec diagram) spec
          (canvas-diagram-model diagram) (canvas-diagram--call diagram :build diagram spec))
    (setq canvas-diagram--diagram diagram
          canvas-diagram--canvas canvas
          canvas-diagram--context ctx
          canvas-diagram--offset '(0 . 0)
          canvas-diagram--zoom 1.0
          canvas-diagram--popup nil
          canvas-diagram--thumb nil)
    (puthash canvas (current-buffer) canvas-diagram--buffers)
    (canvas-diagram--start-folds)
    (setf (canvas-diagram-nodes diagram) (canvas-diagram--call diagram :layout diagram ctx))
    (setq canvas-diagram--selected (car (canvas-diagram-nodes diagram)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      ;; `propertize' keeps the spec `eq': the canvas is keyed on it.
      (insert (propertize "#" 'display canvas)))))

(defun canvas-diagram--graphic-frames-showing (buffer)
  "The graphic frames with a window on BUFFER, each once."
  (seq-filter #'display-graphic-p
              (delete-dups (mapcar #'window-frame (get-buffer-window-list buffer nil t)))))

(defun canvas-diagram-flush-image (spec buffer)
  "Drop SPEC, the canvas that BUFFER shows, from the image cache.
Frames share an image cache, but `image-flush' with FRAME t marks for a
full redraw only the first frame that holds SPEC.  A hidden child frame,
such as which-key-posframe's, can come first.  The frame that shows SPEC
then keeps a line that points at the freed image, and Emacs crashes when
it draws that line.  So the flush goes through a frame that shows BUFFER,
and the other frames that show it are redrawn.  Without such a frame, no
frame draws SPEC, and the flush goes through every frame."
  (pcase (canvas-diagram--graphic-frames-showing buffer)
    ('nil (image-flush spec t))
    (`(,first . ,others)
     (image-flush spec first)
     (mapc #'redraw-frame others))))

(defun canvas-diagram--fit-window (window)
  "Size this buffer's canvas to WINDOW's body; keep the offset within the drawing."
  (let ((w (max 1 (window-body-width window t)))
        (h (max 1 (window-body-height window t))))
    ;; A changed size is a new image-cache key; drop the entry of the old
    ;; one first.  The pixels live with the spec, not with the entry.
    (canvas-diagram-flush-image canvas-diagram--canvas (current-buffer))
    (plist-put (cdr canvas-diagram--canvas) :data-width w)
    (plist-put (cdr canvas-diagram--canvas) :data-height h)
    (setq canvas-diagram--offset
          (canvas-diagram--clamp-offset canvas-diagram--offset (canvas-diagram--view-extent) (cons w h)))))

(defun canvas-diagram--show-update ()
  "Have every window showing this buffer redrawn at the next redisplay.
`canvas-refresh' paints the canvas into the frame's back buffer, and
the buffer is flipped onto the screen only when redisplay updates the
frame.  A change to the canvas alone gives it no reason to."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (force-window-update window)))

(defun canvas-diagram-redraw ()
  "Draw the diagram at the current offset with the open card, and tell the minimap.
While a slide runs, its boxes are drawn on their way."
  (canvas-diagram--as-shown
   (lambda ()
     (canvas-diagram--render canvas-diagram--diagram canvas-diagram--context
                             (canvas-diagram--canvas-size)
                             canvas-diagram--offset canvas-diagram--popup
                             canvas-diagram--selected canvas-diagram--zoom)))
  (canvas-diagram--show-update)
  (setq canvas-diagram--thumb nil)
  (canvas-diagram--picture-changed)
  (canvas-diagram--schedule-hot-spots))

(defun canvas-diagram--schedule-hot-spots ()
  "Put the hot spots on the canvas once scrolling has paused.
Each change of :map is a new image-cache key, so it is not done per step."
  (when canvas-diagram--spots-timer
    (cancel-timer canvas-diagram--spots-timer))
  (setq canvas-diagram--spots-timer
        (run-with-idle-timer 0.2 nil #'canvas-diagram--sync-hot-spots (current-buffer))))

(defun canvas-diagram--sync-hot-spots (buffer)
  "Put BUFFER's hot spots, for the current offset, on its canvas."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq canvas-diagram--spots-timer nil)
      (when canvas-diagram--canvas
        (canvas-diagram--put-map (canvas-diagram--hot-spots (canvas-diagram-nodes-shown)
                                                            canvas-diagram--offset
                                                            canvas-diagram--zoom))))))

(defun canvas-diagram--put-map (spots)
  "Make SPOTS the map of this buffer's canvas, unless the map is equal already.
A new map is a new image-cache key, so the old entry is flushed first, and
the flush redraws the frame.  A move that does not scroll leaves the map as
it was, and then nothing is flushed."
  (unless (equal spots (plist-get (cdr canvas-diagram--canvas) :map))
    (canvas-diagram-flush-image canvas-diagram--canvas (current-buffer))
    (plist-put (cdr canvas-diagram--canvas) :map spots)))

(defun canvas-diagram--window-resized (window)
  "Fit the canvas to WINDOW again when its body changed size."
  (when (and canvas-diagram--diagram
             (not (equal (canvas-diagram--canvas-size)
                         (cons (window-body-width window t) (window-body-height window t)))))
    (canvas-diagram--fit-window window)
    (canvas-diagram-redraw)))

(defun canvas-diagram-relayout ()
  "Lay the diagram out again after its model or a setting changed; keep
the keyboard's node in view.
A layout can make new nodes, so the keyboard and the open card are found
again by key, as a rebuild finds them.  Their keys are taken before the
layout, while the package still knows the old nodes.  The keyboard goes
to the first node when its own is gone, and a card whose node is gone
closes."
  (let* ((diagram canvas-diagram--diagram)
         (selected-key (and canvas-diagram--selected
                            (canvas-diagram--node-key diagram canvas-diagram--selected)))
         (popup-key (and canvas-diagram--popup
                         (canvas-diagram--node-key diagram canvas-diagram--popup))))
    (setf (canvas-diagram-nodes diagram)
          (canvas-diagram--call diagram :layout diagram canvas-diagram--context))
    (setq canvas-diagram--popup (and popup-key (canvas-diagram--restore diagram popup-key))
          canvas-diagram--selected (or (and selected-key
                                            (canvas-diagram--restore diagram selected-key))
                                       (car (canvas-diagram-nodes-shown))))
    (canvas-diagram--select canvas-diagram--selected)))

(defun canvas-diagram--screen-centre (node)
  "The canvas point at the middle of NODE's box, as the canvas is scrolled now."
  (let ((centre (canvas-diagram--box-centre node)))
    (cons (- (car centre) (car canvas-diagram--offset))
          (- (cdr centre) (cdr canvas-diagram--offset)))))

(defun canvas-diagram--anchor (node point)
  "Scroll so that the middle of NODE's box is at the canvas POINT, as near
as the drawing allows."
  (let ((centre (canvas-diagram--box-centre node)))
    (setq canvas-diagram--offset
          (canvas-diagram--clamp-offset (cons (round (- (car centre) (car point)))
                                              (round (- (cdr centre) (cdr point))))
                                        (canvas-diagram--view-extent)
                                        (canvas-diagram--canvas-size)))))

(defun canvas-diagram--screen-centres (diagram)
  "Each node of DIAGRAM by its key, with the canvas point at the middle of
its box as the canvas is scrolled now: ((KEY . POINT)...)."
  (mapcar (lambda (node)
            (cons (canvas-diagram--node-key diagram node) (canvas-diagram--screen-centre node)))
          (canvas-diagram-nodes diagram)))

;;;;; Sliding the boxes after a rebuild

(defconst canvas-diagram--frame-time (/ 1.0 60)
  "Seconds between the frames of a slide.")

(defun canvas-diagram--ease (progress)
  "PROGRESS of a slide, 0 to 1, eased out: quick at first, gentle at the end."
  (- 1 (expt (- 1 progress) 3)))

(defun canvas-diagram--drawing-centre (node)
  "The drawing point at the middle of NODE's box."
  (cons (+ (canvas-diagram-node-x node) (/ (canvas-diagram-node-w node) 2.0))
        (+ (canvas-diagram-node-y node) (/ (canvas-diagram-node-h node) 2.0))))

(defun canvas-diagram--key-finder (diagram)
  "A function of a diagram and a key that finds the node of DIAGRAM with
that key, through a table made once; the first node of a key wins."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (node (reverse (canvas-diagram-nodes diagram)))
      (puthash (canvas-diagram--node-key diagram node) node table))
    (lambda (_diagram key) (gethash key table))))

(defun canvas-diagram--froms-by (diagram centres find froms)
  "FROMS, with each node that FIND, called with DIAGRAM and a key of
CENTRES, finds and FROMS lacks, and the drawing point its middle slides
from: the canvas point of that key, as the canvas is scrolled now."
  (dolist (centre centres froms)
    (when-let* ((node (funcall find diagram (car centre)))
                ((not (assq node froms))))
      (push (cons node (canvas-diagram--map-point (cdr centre) canvas-diagram--offset canvas-diagram--zoom))
            froms))))

(defun canvas-diagram--moved-p (from)
  "Whether the node of FROM, (NODE . CENTRE), lies half a pixel or more
away from CENTRE."
  (let ((now (canvas-diagram--drawing-centre (car from))))
    (or (>= (abs (- (car now) (cadr from))) 0.5)
        (>= (abs (- (cdr now) (cddr from))) 0.5))))

(defun canvas-diagram--slide-froms (diagram centres)
  "The nodes of DIAGRAM that slide after a rebuild, with the drawing point
each one's middle slides from: ((NODE . CENTRE)...).  CENTRES hold the
canvas points of the old nodes by key.  A node slides from the place of
its own key, else from that of the first lost key that `:restore' finds
it by; a node that lies where it was does not slide."
  (let* ((finder (canvas-diagram--key-finder diagram))
         (lost (cl-remove-if (lambda (centre) (funcall finder diagram (car centre))) centres)))
    (cl-remove-if-not #'canvas-diagram--moved-p
                      (canvas-diagram--froms-by diagram lost #'canvas-diagram--restore
                                                (canvas-diagram--froms-by diagram centres finder nil)))))

(defun canvas-diagram--place-sliding (froms eased)
  "Put the middle of each node of FROMS, ((NODE . CENTRE)...), EASED of
the way from CENTRE to its place; return the places to put back:
\((NODE X Y)...)."
  (mapcar (lambda (from)
            (let* ((node (car from))
                   (x (canvas-diagram-node-x node))
                   (y (canvas-diagram-node-y node))
                   (x0 (- (cadr from) (/ (canvas-diagram-node-w node) 2.0)))
                   (y0 (- (cddr from) (/ (canvas-diagram-node-h node) 2.0))))
              (setf (canvas-diagram-node-x node) (+ x0 (* eased (- x x0)))
                    (canvas-diagram-node-y node) (+ y0 (* eased (- y y0))))
              (list node x y)))
          froms))

(defun canvas-diagram--put-back (places)
  "Put each node of PLACES, ((NODE X Y)...), back at X Y."
  (pcase-dolist (`(,node ,x ,y) places)
    (setf (canvas-diagram-node-x node) x
          (canvas-diagram-node-y node) y)))

(defun canvas-diagram--slide-progress ()
  "How far the running slide is, 0 to 1."
  (min 1.0 (/ (- (float-time) (plist-get canvas-diagram--slide :start))
              (plist-get canvas-diagram--slide :time))))

(defun canvas-diagram--as-shown (fn)
  "The value of FN, called with the boxes of a running slide where they
show now; they go back to their places afterwards."
  (let ((places (and canvas-diagram--slide
                     (canvas-diagram--place-sliding (plist-get canvas-diagram--slide :froms)
                                                    (canvas-diagram--ease (canvas-diagram--slide-progress))))))
    (unwind-protect (funcall fn)
      (canvas-diagram--put-back places))))

(defun canvas-diagram--start-slide (froms)
  "Slide the nodes of FROMS, ((NODE . CENTRE)...), from CENTRE to their
places over `canvas-diagram-animate' seconds, a frame at a time.  A command
ends the slide."
  (when (and froms (numberp canvas-diagram-animate) (> canvas-diagram-animate 0))
    (let ((cell (list nil)))
      (setcar cell (run-at-time canvas-diagram--frame-time canvas-diagram--frame-time
                                #'canvas-diagram--slide-frame (current-buffer) cell))
      (setq canvas-diagram--slide (list :start (float-time) :time canvas-diagram-animate
                                        :froms froms :timer (car cell)))
      (add-hook 'pre-command-hook #'canvas-diagram--finish-slide nil t))))

(defun canvas-diagram--end-slide ()
  "End the running slide, if any, with each box in its place."
  (when canvas-diagram--slide
    (cancel-timer (plist-get canvas-diagram--slide :timer))
    (setq canvas-diagram--slide nil)
    (remove-hook 'pre-command-hook #'canvas-diagram--finish-slide t)))

(defun canvas-diagram--finish-slide ()
  "End the running slide, if any, and draw each box in its place."
  (when canvas-diagram--slide
    (canvas-diagram--end-slide)
    (canvas-diagram-redraw)))

(defun canvas-diagram--slide-frame (buffer cell)
  "Draw the next frame of the slide in BUFFER, or end the slide once its
time is up.  CELL holds the frame timer, which stops once BUFFER or its
slide is gone."
  (if (not (buffer-live-p buffer))
      (cancel-timer (car cell))
    (with-current-buffer buffer
      (cond ((not (and canvas-diagram--slide canvas-diagram--context)) (cancel-timer (car cell)))
            ((>= (canvas-diagram--slide-progress) 1.0) (canvas-diagram--finish-slide))
            (t (canvas-diagram-redraw))))))

;;;;; Rebuilding

(defun canvas-diagram--rebuild-model (diagram)
  "Build DIAGRAM's model again from its spec, and lay it out."
  (setf (canvas-diagram-model diagram)
        (canvas-diagram--call diagram :build diagram (canvas-diagram-spec diagram)))
  (setf (canvas-diagram-nodes diagram)
        (canvas-diagram--call diagram :layout diagram canvas-diagram--context)))

(defun canvas-diagram-rebuild ()
  "Build the model again from the spec and lay it out.
The keyboard stays on its node, which keeps its place on the canvas as far
as the drawing allows, or goes to the one the package says is nearest.  The
other boxes slide from where they showed to their new places."
  (let* ((diagram canvas-diagram--diagram)
         (old canvas-diagram--selected)
         (key (and old (canvas-diagram--node-key diagram old)))
         (centres (canvas-diagram--as-shown (lambda () (canvas-diagram--screen-centres diagram))))
         (place (and old (canvas-diagram--as-shown (lambda () (canvas-diagram--screen-centre old))))))
    (canvas-diagram--end-slide)
    (canvas-diagram--rebuild-model diagram)
    (let ((restored (and key (canvas-diagram--restore diagram key))))
      (when restored
        (canvas-diagram--anchor restored place))
      (setq canvas-diagram--popup nil
            canvas-diagram--selected (or restored (car (canvas-diagram-nodes diagram)))
            canvas-diagram--offset (canvas-diagram--offset-for canvas-diagram--selected))
      (canvas-diagram--start-slide (canvas-diagram--slide-froms diagram centres))
      (canvas-diagram--select canvas-diagram--selected))))

;;;; Scrolling and zooming

(defun canvas-diagram--scroll-to (offset)
  "Show the drawing from OFFSET, kept within it; redraw if that moved."
  (let ((new (canvas-diagram--clamp-offset offset (canvas-diagram--view-extent)
                                           (canvas-diagram--canvas-size))))
    (unless (equal new canvas-diagram--offset)
      (setq canvas-diagram--offset new)
      (canvas-diagram-redraw))))

(defun canvas-diagram--scroll-by (dx dy)
  "Move the view DX right and DY down."
  (canvas-diagram--scroll-to (cons (+ (car canvas-diagram--offset) dx)
                                   (+ (cdr canvas-diagram--offset) dy))))

(defun canvas-diagram-scroll-left ()
  "Move the view left by a step."
  (interactive)
  (canvas-diagram--scroll-by (- canvas-diagram-scroll-step) 0))

(defun canvas-diagram-scroll-right ()
  "Move the view right by a step."
  (interactive)
  (canvas-diagram--scroll-by canvas-diagram-scroll-step 0))

(defun canvas-diagram-scroll-up ()
  "Move the view up by a step."
  (interactive)
  (canvas-diagram--scroll-by 0 (- canvas-diagram-scroll-step)))

(defun canvas-diagram-scroll-down ()
  "Move the view down by a step."
  (interactive)
  (canvas-diagram--scroll-by 0 canvas-diagram-scroll-step))

(defun canvas-diagram-page-down ()
  "Move the view down by most of a canvas."
  (interactive)
  (canvas-diagram--scroll-by 0 (round (* 0.8 (cdr (canvas-diagram--canvas-size))))))

(defun canvas-diagram-page-up ()
  "Move the view up by most of a canvas."
  (interactive)
  (canvas-diagram--scroll-by 0 (- (round (* 0.8 (cdr (canvas-diagram--canvas-size)))))))

(defun canvas-diagram-home ()
  "Show the drawing from its top-left corner."
  (interactive)
  (canvas-diagram--scroll-to '(0 . 0)))

(defun canvas-diagram--centred-offset (point)
  "The offset that puts the canvas POINT in the middle of the canvas."
  (let ((size (canvas-diagram--canvas-size)))
    (cons (round (- (car point) (/ (car size) 2.0)))
          (round (- (cdr point) (/ (cdr size) 2.0))))))

(defun canvas-diagram--zoom-to (zoom)
  "Draw at ZOOM canvas pixels per unit, keeping the centre where it is."
  (let* ((size (canvas-diagram--canvas-size))
         (old canvas-diagram--zoom)
         (m canvas-diagram-margin)
         (cx (+ (car canvas-diagram--offset) (/ (car size) 2.0)))
         (cy (+ (cdr canvas-diagram--offset) (/ (cdr size) 2.0))))
    (setq canvas-diagram--zoom zoom)
    ;; The margins are not zoomed; what lies between them is.
    (setq canvas-diagram--offset
          (canvas-diagram--clamp-offset
           (cons (round (- (+ m (* (/ zoom old) (- cx m))) (/ (car size) 2.0)))
                 (round (- (+ m (* (/ zoom old) (- cy m))) (/ (cdr size) 2.0))))
           (canvas-diagram--view-extent) size))
    (canvas-diagram-redraw)
    (canvas-diagram--call canvas-diagram--diagram :zoom canvas-diagram--diagram zoom)))

(defun canvas-diagram-zoom-to (zoom)
  "Draw this buffer's diagram at ZOOM, keeping the centre where it is.
For a package that zooms one diagram as another one zooms."
  (canvas-diagram--zoom-to zoom))

(defun canvas-diagram-current-zoom ()
  "The zoom this buffer's diagram is drawn at."
  canvas-diagram--zoom)

(defun canvas-diagram--zoom-step (step)
  "The next factor of `canvas-diagram--zooms' above the current zoom, or
below it when STEP is negative; the current zoom when there is none.
A fit leaves the zoom between the factors, so nearness is what counts."
  (let ((zoom canvas-diagram--zoom))
    (or (if (> step 0)
            (cl-find-if (lambda (z) (> z (+ zoom 0.001))) canvas-diagram--zooms)
          (cl-find-if (lambda (z) (< z (- zoom 0.001))) (reverse canvas-diagram--zooms)))
        zoom)))

(defun canvas-diagram-zoom-in ()
  "Draw larger."
  (interactive)
  (canvas-diagram--zoom-to (canvas-diagram--zoom-step 1)))

(defun canvas-diagram-zoom-out ()
  "Draw smaller."
  (interactive)
  (canvas-diagram--zoom-to (canvas-diagram--zoom-step -1)))

(defun canvas-diagram-zoom-reset ()
  "Draw at natural size, the keyboard's node kept in view."
  (interactive)
  (canvas-diagram--zoom-to 1.0)
  (canvas-diagram--select canvas-diagram--selected))

(defun canvas-diagram-zoom-fit ()
  "Draw the whole diagram as large as the canvas holds, however small that is."
  (interactive)
  (let* ((size (canvas-diagram--canvas-size))
         (map (canvas-diagram--map-size canvas-diagram--diagram))
         (m (* 2 canvas-diagram-margin))
         (fit (min (/ (- (car size) m) (float (max 1 (- (car map) m))))
                   (/ (- (cdr size) m) (float (max 1 (- (cdr map) m)))))))
    (canvas-diagram--zoom-to (max 0.02 (min (car (last canvas-diagram--zooms)) fit)))
    (canvas-diagram--scroll-to '(0 . 0))))

(defun canvas-diagram--zoom-by-key (what)
  "Zoom this buffer's diagram WHAT: `in', `out' or `reset', to the natural
size.  It is the diagram's `canvas-keys-zoom-function'."
  (pcase what
    ('in (canvas-diagram-zoom-in))
    ('out (canvas-diagram-zoom-out))
    ('reset (canvas-diagram-zoom-reset))
    (_ (error "canvas-diagram: a zoom is in, out or reset, not %S" what))))

(defun canvas-diagram-zoom-adjust ()
  "Zoom in, out or back to natural size by the key that ran this: + or =, -, 0."
  (interactive)
  (pcase last-command-event
    ((or ?+ ?=) (canvas-diagram-zoom-in))
    (?- (canvas-diagram-zoom-out))
    (?0 (canvas-diagram-zoom-reset))
    (_ (canvas-diagram-zoom-in))))

;;;; Selection

(defun canvas-diagram--revealing-coordinate (lo hi offset extent room)
  "OFFSET along one axis, moved so that LO to HI shows within EXTENT.
ROOM pixels are left to spare."
  (cond ((< (- lo offset) room) (round (- lo room)))
        ((> (- hi offset) (- extent room)) (round (- (+ hi room) extent)))
        (t offset)))

(defun canvas-diagram--revealing-offset (node offset size &optional zoom)
  "OFFSET moved the least that puts NODE's box on a canvas of SIZE at ZOOM.
Some room is left around the box."
  (pcase-let* ((room 24)
               (`(,x0 ,y0 ,x1 ,y1) (canvas-diagram--canvas-box node '(0 . 0) zoom)))
    (cons (canvas-diagram--revealing-coordinate x0 x1 (car offset) (car size) room)
          (canvas-diagram--revealing-coordinate y0 y1 (cdr offset) (cdr size) room))))

(defun canvas-diagram--in-view-p (node)
  "Whether any of NODE's box shows on the canvas as it is scrolled now.
It asks `canvas-diagram--box-in-view-p', the same question the drawing
asks, but without slack: a box that only just reaches the edge is one to
nudge into view."
  (canvas-diagram--box-in-view-p node (canvas-diagram--view-rect canvas-diagram--offset
                                                                 (canvas-diagram--canvas-size)
                                                                 canvas-diagram--zoom)))

(defun canvas-diagram--box-centre (node)
  "The canvas point at the middle of NODE's box, unscrolled."
  (pcase-let ((`(,x0 ,y0 ,x1 ,y1) (canvas-diagram--canvas-box node '(0 . 0) canvas-diagram--zoom)))
    (cons (/ (+ x0 x1) 2.0) (/ (+ y0 y1) 2.0))))

(defun canvas-diagram--offset-for (node)
  "The offset that shows NODE, kept within the drawing."
  (canvas-diagram--clamp-offset (canvas-diagram--offset-showing node)
                                (canvas-diagram--view-extent)
                                (canvas-diagram--canvas-size)))

(defun canvas-diagram--offset-showing (node)
  "The offset to show NODE: nudged into view when some of it shows already,
centred on it when it lies off the canvas, as point is recentred when
it leaves the window."
  (if (canvas-diagram--in-view-p node)
      (canvas-diagram--revealing-offset node canvas-diagram--offset
                                        (canvas-diagram--canvas-size) canvas-diagram--zoom)
    (canvas-diagram--centred-offset (canvas-diagram--box-centre node))))

(defun canvas-diagram--select (node)
  "Put the keyboard on NODE, bring it into view and redraw; then tell the
package through its `:select' callback."
  (setq canvas-diagram--selected node)
  (setq canvas-diagram--offset (canvas-diagram--offset-for node))
  (canvas-diagram-redraw)
  (canvas-diagram--call canvas-diagram--diagram :select canvas-diagram--diagram node))

(defun canvas-diagram-recenter ()
  "Put the keyboard's node in the middle of the view, as `recenter' does point."
  (interactive)
  (canvas-diagram--scroll-to
   (canvas-diagram--centred-offset (canvas-diagram--box-centre canvas-diagram--selected))))

(defun canvas-diagram--pulse-line ()
  "Pulse the line point is on with the pulse feature that is on, if any."
  (cond ((and (bound-and-true-p smear-cursor-mode) (fboundp 'smear-cursor-pulse-line))
         (smear-cursor-pulse-line))
        ((and (bound-and-true-p pulsar-mode) (fboundp 'pulsar-pulse-line))
         (pulsar-pulse-line))))

(defun canvas-diagram--place-buffer (where open)
  "The buffer WHERE names: itself, or the file it is, when that is open.
With OPEN, a file that is not open is visited, without the hooks a visit
runs: a drawing opens such a file while the keyboard walks, and a hook
that draws in turn would fight it."
  (cond ((bufferp where) where)
        ((not (stringp where)) nil)
        (open (let ((find-file-hook nil)) (find-file-noselect where)))
        (t (get-file-buffer where))))

(defun canvas-diagram--place (node &optional open)
  "Where NODE came from, as (BUFFER . POS), or nil when that is nowhere.
NODE\='s `pos\=' is a place in the buffer the diagram follows, or a cons of
a buffer or a file and a place in it, for a node that came from another
file than the one followed.  Such a file counts when it is open; with
OPEN it is visited."
  (let ((pos (canvas-diagram-node-pos node)))
    (cond ((integerp pos)
           (and (buffer-live-p canvas-diagram--source) (cons canvas-diagram--source pos)))
          ((consp pos)
           (let ((buffer (canvas-diagram--place-buffer (car pos) open)))
             (and (buffer-live-p buffer) (cons buffer (cdr pos))))))))

(defvar-local canvas-diagram--lent-window nil
  "The window this drawing shows the files its nodes came from in.
The window the followed buffer was in, once a node from another file has
borrowed it, so that a node of the followed buffer brings it back there.")

(defun canvas-diagram--window-on (window frame)
  "WINDOW, when it lives on FRAME.  With FRAME nil, wherever it lives."
  (and (window-live-p window)
       (or (null frame) (eq (window-frame window) frame))
       window))

(defun canvas-diagram--source-window ()
  "The window this drawing shows the files its nodes came from in.
The one it borrowed before, while that lives on the drawing\='s own
frame, else the window the followed buffer is in, on that frame before
any other.  A window on another frame is no use: the reader is looking
at this one."
  (let ((frame (when-let* ((mine (get-buffer-window (current-buffer) t)))
                 (window-frame mine))))
    (or (canvas-diagram--window-on canvas-diagram--lent-window frame)
        (and (buffer-live-p canvas-diagram--source)
             (or (and frame (get-buffer-window canvas-diagram--source frame))
                 (get-buffer-window canvas-diagram--source t))))))

(defun canvas-diagram--lend-window (buffer)
  "Show BUFFER in the window this drawing shows its files in, and give it.
nil when it has no such window.  A file of its own that is open
elsewhere is shown here as well: the window beside a drawing holds the
file of the box the keyboard is on."
  (when-let* ((window (canvas-diagram--source-window)))
    (unless (eq (window-buffer window) buffer)
      (set-window-buffer window buffer))
    (setq canvas-diagram--lent-window window)
    window))

(defun canvas-diagram--goto-source (node)
  "Put point where NODE came from, if that is known.
The buffer\='s window, when it has one, shows the place; it is not
selected.  The line is then pulsed by `canvas-diagram-pulse-function'.
With `canvas-diagram-open-source', a node from another file has that
file opened, and the window holding the followed buffer shows it."
  (when-let* ((place (canvas-diagram--place node canvas-diagram-open-source))
              (source (car place)))
    (with-current-buffer source
      (goto-char (min (cdr place) (point-max))))
    (when-let* ((window (or (and canvas-diagram-open-source
                                 (canvas-diagram--lend-window source))
                            (get-buffer-window source t))))
      (set-window-point window (with-current-buffer source (point)))
      (with-selected-window window
        (unless (pos-visible-in-window-p)
          (recenter))
        (when canvas-diagram-pulse-function
          (funcall canvas-diagram-pulse-function))))))

(defun canvas-diagram--source-place (node)
  "Where NODE came from, (BUFFER . POS), the buffer this diagram follows or
another file NODE names.  That file is visited.  A user error when the
diagram follows nothing, or NODE came from nowhere."
  (or (and node (canvas-diagram--place node t))
      (if (buffer-live-p canvas-diagram--source)
          (user-error "canvas-diagram: %s has no place to go to"
                      (if node (canvas-diagram-node-label node) "the keyboard"))
        (user-error "canvas-diagram: this diagram follows no buffer"))))

(defun canvas-diagram-visit-source ()
  "Go to the source buffer, at the line the keyboard's node came from.
The source's window is selected, made if there is none, and the line
pulsed."
  (interactive)
  (pcase-let ((`(,source . ,pos) (canvas-diagram--source-place canvas-diagram--selected)))
    (pop-to-buffer source)
    (goto-char (min pos (point-max)))
    (when canvas-diagram-pulse-function
      (funcall canvas-diagram-pulse-function))))

;;;; Copying a node

(defun canvas-diagram-node-content (diagram node)
  "NODE's content in DIAGRAM, what copying it copies, as (HEADER BODY):
the package's :content, else its label and its note.  BODY is nil when
there is none."
  (or (canvas-diagram--call diagram :content diagram node)
      (list (canvas-diagram-node-label node) (canvas-diagram-node-note node))))

(defun canvas-diagram--content-part (diagram node part)
  "PART of NODE's content in DIAGRAM: its `header', its `body', or `all'
of it, the header, a blank line and the body; nil for an empty part."
  (pcase-let* ((`(,header ,body) (canvas-diagram-node-content diagram node))
               (body (and body (not (string-empty-p body)) body)))
    (pcase part
      ('header header)
      ('body body)
      ('all (if body (concat header "\n\n" body) header))
      (_ (error "canvas-diagram: a node has no part %S" part)))))

(defun canvas-diagram--source-part (diagram node part)
  "PART of the text NODE came from, in the buffer DIAGRAM follows, as the
package's :source-text gives it; nil when it gives none.  A package
without one is a user error."
  (unless (canvas-diagram--has diagram :source-text)
    (user-error "canvas-diagram: this diagram cannot copy the source of its nodes"))
  (canvas-diagram--call diagram :source-text diagram node part (car (canvas-diagram--source-place node))))

(defun canvas-diagram--copy-marked (part source)
  "Put PART of every marked node on the kill ring, one to a line, in
reading order; how many were copied."
  (let* ((nodes (canvas-diagram-marked-nodes))
         (texts (delq nil (mapcar (lambda (node)
                                    (let ((text (if source
                                                    (canvas-diagram--source-part canvas-diagram--diagram node part)
                                                  (canvas-diagram--content-part canvas-diagram--diagram node part))))
                                      (unless (or (null text) (string-empty-p text)) text)))
                                  nodes))))
    (unless texts
      (user-error "canvas-diagram: the marked boxes have no %s" (if (eq part 'all) "text" part)))
    (kill-new (string-join texts "\n"))
    (message "Copied %d boxes" (length texts))
    (length texts)))

(defun canvas-diagram--copy (part source)
  "Put PART of the marked nodes on the kill ring, one to a line, or of the
keyboard's node when none is marked: `header', `body' or `all', from the
text it came from in the source with SOURCE, else from its content.  No
node, or an empty part, is a user error."
  (if (canvas-diagram-marked-nodes)
      (canvas-diagram--copy-marked part source)
    (canvas-diagram--copy-one part source)))

(defun canvas-diagram--copy-one (part source)
  "Put PART of the keyboard's node on the kill ring."
  (let* ((node (or canvas-diagram--selected (user-error "canvas-diagram: no node to copy")))
         (label (canvas-diagram-node-label node))
         (text (if source
                   (canvas-diagram--source-part canvas-diagram--diagram node part)
                 (canvas-diagram--content-part canvas-diagram--diagram node part))))
    (unless (and text (not (string-empty-p text)))
      (user-error "canvas-diagram: %s has no %s%s" label
                  (if (eq part 'all) "text" part) (if source " in the source" "")))
    (kill-new text)
    (message "Copied %s«%s»%s" (pcase part ('header "the header of ") ('body "the body of ") (_ ""))
             label (if source " from the source" ""))))

(defun canvas-diagram-copy-node (&optional source)
  "Copy the keyboard's node, its header and its body.  With SOURCE, the
prefix argument, copy the text it came from in the buffer followed."
  (interactive "P")
  (canvas-diagram--copy 'all source))

(defun canvas-diagram-copy-header (&optional source)
  "Copy the header of the keyboard's node.  With SOURCE, the prefix
argument, copy its header in the buffer followed."
  (interactive "P")
  (canvas-diagram--copy 'header source))

(defun canvas-diagram-copy-body (&optional source)
  "Copy the body of the keyboard's node.  With SOURCE, the prefix
argument, copy its body in the buffer followed."
  (interactive "P")
  (canvas-diagram--copy 'body source))

(defun canvas-diagram-copy-source ()
  "Copy the text the keyboard's node came from in the buffer followed."
  (interactive)
  (canvas-diagram--copy 'all t))

;;;; Embark

(defcustom canvas-diagram-node-actions nil
  "Actions on the keyboard's node of a diagram, beyond copying, by where
they apply: a list of (CONDITION . KEYMAP).  CONDITION is a condition of
`buffer-match-p\=' on the diagram buffer, such as
\=(derived-mode . canvas-mindmap-mode), a function of the buffer, or an
`and\=' of both.  KEYMAP is a keymap, or a variable that holds one, whose
commands act on the keyboard's node.  `embark-act\=' offers the actions of
every entry whose condition holds, beside the copying keys of
`canvas-diagram-embark-map\=', which win a key that both bind.  Embark
answers the first question a command asks in the minibuffer with the
node's label; a command that asks for something else needs an entry in
`embark-target-injection-hooks\=' with `embark--ignore-target\='."
  :type '(alist :key-type sexp :value-type (choice variable sexp)))

(defcustom canvas-diagram-marked-actions nil
  "Actions on the marked boxes of a diagram, by where they apply, as
`canvas-diagram-node-actions\=' has them; the commands act on
`canvas-diagram-marked-nodes\='.  They sit beside the keys of
`canvas-diagram-embark-marked-map\=', which win."
  :type '(alist :key-type sexp :value-type (choice variable sexp)))

(defvar canvas-diagram--node-actions-map (make-sparse-keymap)
  "The actions of `canvas-diagram-node-actions\=' that hold where embark
last found the keyboard's node.  Embark reads this variable right after
the target is found, so it holds the actions of that buffer.")

(defvar canvas-diagram--marked-actions-map (make-sparse-keymap)
  "The actions of `canvas-diagram-marked-actions\=' that hold where embark
last found marked boxes.")

(defun canvas-diagram--actions-keymap (condition keymap)
  "KEYMAP, or the keymap the variable KEYMAP holds; an error that names
CONDITION, the entry's, when it is no keymap."
  (let ((map (if (and (symbolp keymap) (boundp keymap)) (symbol-value keymap) keymap)))
    (unless (keymapp map)
      (error "canvas-diagram: the actions for %S are no keymap: %S" condition keymap))
    map))

(defun canvas-diagram--actions-map (entries)
  "One keymap of the actions of ENTRIES, each (CONDITION . KEYMAP), whose
CONDITION holds for this buffer."
  (make-composed-keymap
   (cl-loop for (condition . keymap) in entries
            when (buffer-match-p condition (current-buffer))
            collect (canvas-diagram--actions-keymap condition keymap))))

(defun canvas-diagram-embark-target ()
  "The keyboard's node as an embark target in a diagram buffer,
\(canvas-diagram-node . LABEL); nil in any other buffer.  The actions of
`canvas-diagram-node-actions\=' that hold here are gathered for embark."
  (when-let* (((derived-mode-p 'canvas-diagram-mode))
              (node canvas-diagram--selected))
    (setq canvas-diagram--node-actions-map (canvas-diagram--actions-map canvas-diagram-node-actions))
    (cons 'canvas-diagram-node (canvas-diagram-node-label node))))

(defun canvas-diagram-embark-marked-target ()
  "The marked boxes as an embark target in a diagram buffer,
\(canvas-diagram-marked . LABELS); nil when none is marked.  The actions
of `canvas-diagram-marked-actions\=' that hold here are gathered."
  (when-let* (((derived-mode-p 'canvas-diagram-mode))
              (nodes (canvas-diagram-marked-nodes)))
    (setq canvas-diagram--marked-actions-map (canvas-diagram--actions-map canvas-diagram-marked-actions))
    (cons 'canvas-diagram-marked
          (mapconcat #'canvas-diagram-node-label nodes ", "))))

(defvar-keymap canvas-diagram-embark-marked-map
  :doc "Embark's actions on the marked boxes of a diagram.  A package adds
actions of its own through `canvas-diagram-marked-actions\='."
  "w" #'canvas-diagram-copy-node
  "u" #'canvas-diagram-unmark-all)

(defvar-keymap canvas-diagram-embark-map
  :doc "Embark's actions on the keyboard's node in a diagram.  A prefix
argument before an action copies from the source."
  "w" #'canvas-diagram-copy-node
  "h" #'canvas-diagram-copy-header
  "b" #'canvas-diagram-copy-body
  "s" #'canvas-diagram-copy-source)

(with-eval-after-load 'embark
  (defvar embark-target-finders)
  (defvar embark-keymap-alist)
  (add-to-list 'embark-target-finders #'canvas-diagram-embark-target)
  (add-to-list 'embark-target-finders #'canvas-diagram-embark-marked-target)
  ;; The actions a package adds where they apply come second, so that the
  ;; copying keys win a key that both bind.
  (setf (alist-get 'canvas-diagram-node embark-keymap-alist)
        '(canvas-diagram-embark-map canvas-diagram--node-actions-map)
        (alist-get 'canvas-diagram-marked embark-keymap-alist)
        '(canvas-diagram-embark-marked-map canvas-diagram--marked-actions-map)))

(declare-function smear-cursor-fly-in-picture "smear-cursor"
                  (pos from to &optional window))
(defvar smear-cursor-mode)

(defun canvas-diagram--picture-rect (node)
  "NODE's box as it is drawn now, as [X Y W H] in pixels of the picture."
  (pcase-let ((`(,x0 ,y0 ,x1 ,y1) (canvas-diagram--canvas-box
                                   node canvas-diagram--offset canvas-diagram--zoom)))
    (vector x0 y0 (- x1 x0) (- y1 y0))))

(defun canvas-diagram--fly-smear (from to)
  "Fly smear-cursor\\='s cursor from FROM to TO, boxes of the picture, if it is on.
The keyboard moves inside the picture, the buffer\\='s one character, so
point never moves and smear-cursor cannot see the move by itself."
  (when-let* (((bound-and-true-p smear-cursor-mode))
              ((fboundp 'smear-cursor-fly-in-picture))
              (window (get-buffer-window (current-buffer))))
    (smear-cursor-fly-in-picture (point-min) from to window)))

(defun canvas-diagram--fly (from node)
  "Draw the eye from FROM, the box the keyboard left, to NODE\\='s box.
Nothing flies without FROM, or when the keyboard stayed where it was."
  (when (and canvas-diagram-fly-function from)
    (let ((to (canvas-diagram--picture-rect node)))
      (unless (equal from to)
        (funcall canvas-diagram-fly-function from to)))))

(defun canvas-diagram-go (node)
  "Move the keyboard to NODE and point in the source to where it came from;
then tell the package through its `:go' callback.  The moves and the jump
by name come here, a rebuild or a relayout does not.  The way from the
box left to NODE is drawn by `canvas-diagram-fly-function'."
  (let ((from (and canvas-diagram--selected
                   (canvas-diagram--picture-rect canvas-diagram--selected))))
    (canvas-diagram--select node)
    (canvas-diagram--fly from node))
  (canvas-diagram--goto-source node)
  (canvas-diagram--call canvas-diagram--diagram :go canvas-diagram--diagram node))

(defun canvas-diagram--move (direction)
  "Move the keyboard where the package says DIRECTION leads, if anywhere."
  (when-let* ((node (canvas-diagram--call canvas-diagram--diagram :move canvas-diagram--diagram
                                          canvas-diagram--selected direction)))
    (unless (eq node canvas-diagram--selected)
      (canvas-diagram-go node))))

(defmacro canvas-diagram--define-moves (&rest moves)
  "Define a move command per (NAME DIRECTION DOC) in MOVES."
  `(progn
     ,@(mapcar (lambda (move)
                 (pcase-let ((`(,name ,direction ,doc) move))
                   `(defun ,name ()
                      ,doc
                      (interactive)
                      (canvas-diagram--move ',direction))))
               moves)))

(canvas-diagram--define-moves
 (canvas-diagram-move-in in "Move into the node: to a child, or where the package says forward leads.")
 (canvas-diagram-move-out out "Move out of the node: to its parent, or where back leads.")
 (canvas-diagram-move-next next "Move to the next node in reading order.")
 (canvas-diagram-move-previous previous "Move to the previous node in reading order.")
 (canvas-diagram-move-next-at-depth next-at-depth "Move down among the nodes at the same depth.")
 (canvas-diagram-move-previous-at-depth previous-at-depth "Move up among the nodes at the same depth.")
 (canvas-diagram-move-next-sibling next-sibling "Move to the next node under the same parent.")
 (canvas-diagram-move-previous-sibling previous-sibling "Move to the previous node under the same parent.")
 (canvas-diagram-move-branch branch "Move to the top-level branch, or the previous one.")
 (canvas-diagram-move-next-branch next-branch "Move to the next top-level branch.")
 (canvas-diagram-move-first first "Move to the first node.")
 (canvas-diagram-move-last last "Move to the last node."))

(defun canvas-diagram-jump (label)
  "Move to the node called LABEL, chosen with completion."
  (interactive
   (list (completing-read "Node: "
                          (mapcar #'canvas-diagram-node-label (canvas-diagram-nodes-shown))
                          nil t)))
  (canvas-diagram-go
   (or (cl-find label (canvas-diagram-nodes-shown)
                :key #'canvas-diagram-node-label :test #'equal)
       (user-error "canvas-diagram: no node is called %s" label))))

;;;; The card and the mouse

(defun canvas-diagram--on-popup-p (xy)
  "Whether canvas pixel XY lies on the open card."
  (and canvas-diagram--popup
       (pcase-let ((`(,x ,y ,w ,h) (canvas-diagram--popup-rect
                                    canvas-diagram--diagram canvas-diagram--context
                                    canvas-diagram--popup (canvas-diagram-font)
                                    canvas-diagram--offset (canvas-diagram--canvas-size)
                                    canvas-diagram--zoom)))
         (and (<= x (car xy) (+ x w)) (<= y (cdr xy) (+ y h))))))

(defun canvas-diagram-node-at-pixel (xy)
  "The node whose box holds canvas pixel XY, or nil."
  (let ((p (canvas-diagram--map-point xy canvas-diagram--offset canvas-diagram--zoom)))
    (canvas-diagram--node-at (canvas-diagram-nodes-shown) (car p) (cdr p))))

(defun canvas-diagram--open (node)
  "Draw the keyboard on NODE, and give NODE to the package's `:open'."
  (canvas-diagram-redraw)
  (canvas-diagram--call canvas-diagram--diagram :open canvas-diagram--diagram node))

(defun canvas-diagram--toggle-popup (xy)
  "Open the card of the box at canvas pixel XY, or close the open one.
A click on the card itself, or on nothing, closes it.  A package with an
`:open' callback gets the box instead of a card."
  (let ((node (and (not (canvas-diagram--on-popup-p xy))
                   (canvas-diagram-node-at-pixel xy))))
    (when node
      (setq canvas-diagram--selected node)
      (canvas-diagram--goto-source node))
    (if (and node (canvas-diagram--has canvas-diagram--diagram :open))
        (canvas-diagram--open node)
      (setq canvas-diagram--popup (and node (not (eq node canvas-diagram--popup)) node))
      (canvas-diagram-redraw))))

(defun canvas-diagram-toggle-card ()
  "Open the selected node's card, or close it if it is open.
A package with an `:open' callback gets the node instead of a card."
  (interactive)
  (if (canvas-diagram--has canvas-diagram--diagram :open)
      (canvas-diagram--open canvas-diagram--selected)
    (setq canvas-diagram--popup
          (unless (eq canvas-diagram--popup canvas-diagram--selected)
            canvas-diagram--selected))
    (canvas-diagram-redraw)))

(defun canvas-diagram-close-popup ()
  "Close the open card."
  (interactive)
  (when canvas-diagram--popup
    (setq canvas-diagram--popup nil)
    (canvas-diagram-redraw)))

(defun canvas-diagram--click-p (from to)
  "Whether a press at FROM released at TO is a click rather than a drag.
A hand is never quite still, so `double-click-fuzz' pixels are allowed."
  (and (<= (abs (- (car from) (car to))) double-click-fuzz)
       (<= (abs (- (cdr from) (cdr to))) double-click-fuzz)))

(defun canvas-diagram-mouse (event)
  "Drag to pan; a click that does not turn into a drag toggles the card
of the box under it."
  (interactive "e")
  (let ((start (posn-object-x-y (event-start event)))
        (from canvas-diagram--offset)
        (dragging nil)
        ev)
    (when start
      (track-mouse
        (while (progn (setq ev (read-event))
                      (mouse-movement-p ev))
          (when-let* ((xy (posn-object-x-y (event-start ev))))
            (unless (and (not dragging) (canvas-diagram--click-p start xy))
              (setq dragging t)
              (canvas-diagram--scroll-to (cons (+ (car from) (- (car start) (car xy)))
                                               (+ (cdr from) (- (cdr start) (cdr xy)))))))))
      (unless dragging
        (canvas-diagram--toggle-popup start)))))

(defun canvas-diagram-double-click (event)
  "Hand the box under a double click to the package, if it wants it."
  (interactive "e")
  (when-let* ((xy (posn-object-x-y (event-start event)))
              (node (canvas-diagram-node-at-pixel xy)))
    (when (canvas-diagram--has canvas-diagram--diagram :double-click)
      (setq canvas-diagram--popup nil)
      (canvas-diagram--call canvas-diagram--diagram :double-click canvas-diagram--diagram node))))

;;;; Following the source

(defun canvas-diagram--follow (source)
  "Have this buffer follow SOURCE: redraw as it changes."
  (canvas-diagram--unfollow)
  (setq canvas-diagram--source source)
  (let ((follower (current-buffer)))
    (with-current-buffer source
      (setq canvas-diagram--follower follower)
      (add-hook 'after-change-functions #'canvas-diagram--source-changed nil t))))

(defun canvas-diagram--unfollow ()
  "Stop following the source, if any."
  (when canvas-diagram--source-timer
    (cancel-timer canvas-diagram--source-timer)
    (setq canvas-diagram--source-timer nil))
  (when (buffer-live-p canvas-diagram--source)
    (with-current-buffer canvas-diagram--source
      (remove-hook 'after-change-functions #'canvas-diagram--source-changed t)
      (setq canvas-diagram--follower nil)))
  (setq canvas-diagram--source nil))

(defun canvas-diagram--source-changed (&rest _)
  "In a source buffer: have the diagram following it reread it once typing pauses."
  (when-let* ((follower canvas-diagram--follower)
              ((buffer-live-p follower)))
    (with-current-buffer follower
      (when canvas-diagram--source-timer
        (cancel-timer canvas-diagram--source-timer))
      (setq canvas-diagram--source-timer
            (run-with-idle-timer 0.3 nil #'canvas-diagram--refresh-from-source follower)))))

(defun canvas-diagram--refresh-from-source (buffer &optional always)
  "Read BUFFER's source again and rebuild when its spec changed, or in
any case when ALWAYS."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq canvas-diagram--source-timer nil)
      (when (buffer-live-p canvas-diagram--source)
        (let ((spec (canvas-diagram--call canvas-diagram--diagram :read-source canvas-diagram--source)))
          (when (and spec (or always (not (equal spec (canvas-diagram-spec canvas-diagram--diagram)))))
            (setf (canvas-diagram-spec canvas-diagram--diagram) spec)
            (canvas-diagram-rebuild)))))))

(defun canvas-diagram-refresh (&rest _)
  "Read the source again, if there is one, and draw afresh.
Bound to the key that reverts a buffer, and to `revert-buffer' itself."
  (interactive)
  (if (buffer-live-p canvas-diagram--source)
      (canvas-diagram--refresh-from-source (current-buffer) t)
    (canvas-diagram-rebuild)))

;;;;; Code blocks in a source

(defconst canvas-diagram--block-open-re
  (concat "^[ \t]*\\(?:\\(?1:```+\\|~~~+\\)[ \t]*{?\\(?2:[[:alnum:]_+-]+\\)"
          "\\|#\\+begin_src[ \t]+\\(?2:[[:alnum:]_+-]+\\)\\)[^\n]*\n")
  "The line that opens a code block: a markdown fence, its fence group 1,
or an org source block; its language group 2.")

(defun canvas-diagram--block-close-re (fence)
  "The line that closes a code block opened by FENCE, a markdown fence, as
long or longer; or an org source block's when FENCE is nil."
  (if fence
      (format "^[ \t]*%s%s*[ \t]*$" (regexp-quote fence) (regexp-quote (substring fence 0 1)))
    "^[ \t]*#\\+end_src\\_>"))

(defun canvas-diagram-code-blocks (languages)
  "The code blocks of the current buffer in one of LANGUAGES, such as
\(\"mermaid\"): markdown fences and org source blocks, in order, as
\((START . END)...), from where the first line of code begins to where
the closing line does.  A block never closed is left out."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) blocks)
      (while (re-search-forward canvas-diagram--block-open-re nil t)
        (let ((fence (match-string 1))
              (language (match-string 2))
              (start (point)))
          (when (and (re-search-forward (canvas-diagram--block-close-re fence) nil t)
                     (member-ignore-case language languages))
            (push (cons start (match-beginning 0)) blocks))))
      (nreverse blocks))))

;;;;; Diagrams in regions of a source

(defun canvas-diagram-text-lines (text offset)
  "TEXT's lines as (LINE . POS), POS the buffer position each begins at,
TEXT itself beginning at OFFSET: a region's text as its reader reads it,
each node then placed where it is written."
  (let ((pos offset) lines)
    (dolist (line (split-string text "\n"))
      (push (cons line pos) lines)
      (cl-incf pos (1+ (length line))))
    (nreverse lines)))

(defun canvas-diagram-region-at (regions pos)
  "The region of REGIONS, (START . END) each, that POS is in, else the only
one.  POS outside all of several is a user error."
  (or (cl-find-if (lambda (r) (<= (car r) pos (cdr r))) regions)
      (and (null (cdr regions)) (car regions))
      (user-error "canvas-diagram: put point in the diagram to draw, one of the %d here" (length regions))))

(defun canvas-diagram-region-reader (marker regions read)
  "A function of a buffer reading what READ makes of the region of it that
MARKER is in, for following it: REGIONS is a function of no arguments
listing the regions of the current buffer, READ one of a region giving
a spec.  It reads nil when no region holds MARKER any more, or when
READ signals, the trouble then said and the last drawing staying."
  (lambda (buffer)
    (with-current-buffer buffer
      (when-let* ((region (cl-find-if (lambda (r) (<= (car r) marker (cdr r))) (funcall regions))))
        (condition-case err
            (funcall read region)
          (error (message "%s" (error-message-string err)) nil))))))

;;;; The minimap

(defun canvas-diagram-thumbnail (image w h bg)
  "The diagram shown on IMAGE scaled into W by H over BG, for canvas-minimap.
nil for an image that is not a diagram's canvas.  The pixels are kept
until the view moves or the diagram is drawn again."
  (when-let* ((buffer (gethash image canvas-diagram--buffers))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (setq canvas-diagram--thumb-box (cons w h))
      (let ((key (list w h bg canvas-diagram--offset (canvas-diagram--canvas-size)
                       canvas-diagram--selected canvas-diagram--zoom)))
        (unless (equal (car canvas-diagram--thumb) key)
          (setq canvas-diagram--thumb
                (cons key (canvas-diagram--thumbnail canvas-diagram--diagram canvas-diagram--offset
                                                     (canvas-diagram--canvas-size) w h bg
                                                     canvas-diagram--selected
                                                     canvas-diagram--zoom))))
        (cdr canvas-diagram--thumb)))))

(defun canvas-diagram--thumb-point (fx fy)
  "The point at fractions FX FY across the box the diagram was last drawn in,
in canvas pixels of the drawing with its margins, at the current zoom."
  (pcase-let* ((`(,w . ,h) canvas-diagram--thumb-box)
               (`(,scale ,ox ,oy) (canvas-diagram--thumb-fit
                                   (canvas-diagram--map-size canvas-diagram--diagram) w h))
               (m canvas-diagram-margin)
               (zoom canvas-diagram--zoom))
    (cons (+ m (* zoom (- (/ (- (* fx w) ox) scale) m)))
          (+ m (* zoom (- (/ (- (* fy h) oy) scale) m))))))

(defun canvas-diagram--fits-p ()
  "Whether the whole drawing, at the current zoom, lies within the canvas."
  (let ((extent (canvas-diagram--view-extent))
        (size (canvas-diagram--canvas-size)))
    (and (<= (car extent) (car size)) (<= (cdr extent) (cdr size)))))

(defun canvas-diagram-picture-click (image fx fy)
  "Centre the view on the point at FX FY of canvas-minimap's picture of IMAGE.
When the whole drawing is already in view, as after a fit, the click
zooms to natural size around that point instead.  Non-nil when IMAGE
is a diagram's canvas, so the click is taken."
  (when-let* ((buffer (gethash image canvas-diagram--buffers))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (when canvas-diagram--thumb-box
        (when (canvas-diagram--fits-p)
          (canvas-diagram--zoom-to 1.0))
        (canvas-diagram--scroll-to
         (canvas-diagram--centred-offset (canvas-diagram--thumb-point fx fy))))
      t)))

(defun canvas-diagram--picture-changed ()
  "Tell canvas-minimap, when it is loaded, that this buffer's picture changed."
  (when (fboundp 'canvas-minimap-picture-changed)
    (canvas-minimap-picture-changed (current-buffer))))

(with-eval-after-load 'canvas-minimap
  (add-hook 'canvas-minimap-thumbnail-functions #'canvas-diagram-thumbnail)
  (add-hook 'canvas-minimap-picture-click-functions #'canvas-diagram-picture-click))

;;;; Folding

(defvar-local canvas-diagram--folds nil
  "The folds of this buffer: a table from the key of a box to `open' or
`folded', or nil for none yet.")

(defvar-local canvas-diagram--levels nil
  "How many levels of this buffer's diagram show, or nil for all.")

(defvar-local canvas-diagram--folds-started nil
  "Whether this buffer took the folds its diagram starts with.")

(defun canvas-diagram-folds-p ()
  "Whether this buffer's diagram folds: it has a `:fold-trees' callback."
  (and canvas-diagram--diagram (canvas-diagram--has canvas-diagram--diagram :fold-trees)))

(defun canvas-diagram-folded-p (key depth)
  "Whether the box of KEY, DEPTH levels below the top, hides its children.
The fold of KEY wins.  Without one, the box is folded when the levels
are a number and DEPTH is at least the levels minus 1."
  (pcase (and canvas-diagram--folds (gethash key canvas-diagram--folds))
    ('folded t)
    ('open nil)
    (_ (and canvas-diagram--levels (>= depth (1- canvas-diagram--levels))))))

(defun canvas-diagram-set-fold (key how)
  "Set the fold of KEY to HOW, `open' or `folded'."
  (unless (memq how '(open folded))
    (error "canvas-diagram: a fold is open or folded, not %S" how))
  (puthash key how (or canvas-diagram--folds
                       (setq canvas-diagram--folds (make-hash-table :test #'equal)))))

(defun canvas-diagram--fold-trees (node)
  "The fold trees under NODE, or at the top when NODE is nil."
  (canvas-diagram--call canvas-diagram--diagram :fold-trees canvas-diagram--diagram node))

(defun canvas-diagram--check-trees (trees)
  "TREES, when no key occurs twice in them; else an error that names the key."
  (let ((seen (make-hash-table :test #'equal)))
    (cl-labels ((walk (tree)
                  (when (gethash (car tree) seen)
                    (error "canvas-diagram: the key %S occurs twice in the fold trees" (car tree)))
                  (puthash (car tree) t seen)
                  (mapc #'walk (cdr tree))))
      (mapc #'walk trees))
    trees))

(defun canvas-diagram--top-trees ()
  "The fold trees of this buffer's diagram, checked."
  (canvas-diagram--check-trees (canvas-diagram--fold-trees nil)))

(defun canvas-diagram--tree-path (trees key)
  "The keys from the top of TREES down to KEY, or nil when no tree holds KEY."
  (cl-some (lambda (tree)
             (if (equal (car tree) key)
                 (list key)
               (when-let* ((path (canvas-diagram--tree-path (cdr tree) key)))
                 (cons (car tree) path))))
           trees))

(defun canvas-diagram--path-to (key)
  "The keys from the top down to KEY; an error when no fold tree holds KEY."
  (or (canvas-diagram--tree-path (canvas-diagram--top-trees) key)
      (error "canvas-diagram: no fold tree holds the key %S" key)))

(defun canvas-diagram--height (trees)
  "The number of levels of the deepest of TREES."
  (if trees
      (1+ (apply #'max (mapcar (lambda (tree) (canvas-diagram--height (cdr tree))) trees)))
    0))

(defun canvas-diagram-unfold-to (key)
  "Open every box above KEY, so that the box of KEY shows."
  (dolist (above (butlast (canvas-diagram--path-to key)))
    (canvas-diagram-set-fold above 'open)))

(defun canvas-diagram--start-folds ()
  "Take the folds this buffer's diagram starts with, once.
The `:fold-start' callback gives (:levels N :open KEYS)."
  (when (and (canvas-diagram-folds-p) (not canvas-diagram--folds-started))
    (setq canvas-diagram--folds-started t)
    (let ((start (canvas-diagram--call canvas-diagram--diagram :fold-start canvas-diagram--diagram))
          (trees (canvas-diagram--top-trees)))
      (canvas-diagram--check-levels (plist-get start :levels))
      (setq canvas-diagram--levels (plist-get start :levels))
      (dolist (key (plist-get start :open))
        (unless (canvas-diagram--tree-path trees key)
          (error "canvas-diagram: the fold start opens the key %S, which no fold tree holds" key))
        (canvas-diagram-set-fold key 'open)))))

(defun canvas-diagram--check-levels (levels)
  "LEVELS, when it is nil or at least 1; else an error."
  (when (and levels (< levels 1))
    (error "canvas-diagram: levels start at 1, not %s" levels))
  levels)

;;;;; The fold commands

(defun canvas-diagram--need-folds ()
  "Make sure that this buffer's diagram folds; a user error otherwise."
  (unless (canvas-diagram-folds-p)
    (user-error "canvas-diagram: this diagram does not fold")))

(defun canvas-diagram--fold-tree-at-keyboard ()
  "The fold tree of the box at the keyboard, which must have children."
  (canvas-diagram--need-folds)
  (let* ((node (or canvas-diagram--selected (user-error "canvas-diagram: no box is selected")))
         (children (canvas-diagram--fold-trees node)))
    (unless children
      (user-error "canvas-diagram: %s has nothing to fold" (canvas-diagram-node-label node)))
    (cons (canvas-diagram--node-key canvas-diagram--diagram node) children)))

(defun canvas-diagram--keyboard-keys ()
  "The keys to put the keyboard back on after a refold, the best first.
They are the key of its box, the keys above it in the fold trees, and the
keys of the boxes before it in reading order, for a box no tree holds."
  (let* ((diagram canvas-diagram--diagram)
         (selected canvas-diagram--selected)
         (key (and selected (canvas-diagram--node-key diagram selected))))
    (and key
         (append (list key)
                 (reverse (canvas-diagram--tree-path (canvas-diagram--top-trees) key))
                 (mapcar (lambda (node) (canvas-diagram--node-key diagram node))
                         (cdr (memq selected (reverse (canvas-diagram-nodes diagram)))))))))

(defun canvas-diagram--refold ()
  "Lay the diagram out again after its folds changed.
The keyboard stays on its box while that box shows, even a box that no
fold tree holds.  Else it goes to the nearest shown box above it, or
before it in reading order."
  (let ((diagram canvas-diagram--diagram)
        (keys (canvas-diagram--keyboard-keys)))
    (setf (canvas-diagram-nodes diagram)
          (canvas-diagram--call diagram :layout diagram canvas-diagram--context))
    (canvas-diagram--select (or (cl-some (lambda (key) (canvas-diagram--node-by-key diagram key)) keys)
                                (car (canvas-diagram-nodes diagram))))))

(defun canvas-diagram-toggle-fold ()
  "Fold the box at the keyboard, or unfold it."
  (interactive)
  (let* ((key (car (canvas-diagram--fold-tree-at-keyboard)))
         (depth (1- (length (canvas-diagram--path-to key)))))
    (canvas-diagram-set-fold key (if (canvas-diagram-folded-p key depth) 'open 'folded))
    (canvas-diagram--refold)))

(defun canvas-diagram--keys-below (tree)
  "The keys of the boxes with children below TREE, not TREE's own."
  (cl-loop for child in (cdr tree)
           when (cdr child) collect (car child)
           append (canvas-diagram--keys-below child)))

(defun canvas-diagram--fold-all (keys how)
  "Set the fold of each of KEYS to HOW."
  (dolist (key keys)
    (canvas-diagram-set-fold key how)))

(defun canvas-diagram--children-folded-p (tree depth)
  "Whether each child of TREE, a box at DEPTH, that has children is folded."
  (cl-every (lambda (child)
              (or (null (cdr child)) (canvas-diagram-folded-p (car child) (1+ depth))))
            (cdr tree)))

(defun canvas-diagram-cycle-fold ()
  "Cycle the fold of the box at the keyboard as magit cycles a section.
The box goes from folded, to open with its children folded, to open
with everything below it open."
  (interactive)
  (let* ((tree (canvas-diagram--fold-tree-at-keyboard))
         (key (car tree))
         (depth (1- (length (canvas-diagram--path-to key)))))
    (cond ((canvas-diagram-folded-p key depth)
           (canvas-diagram--fold-all (canvas-diagram--keys-below tree) 'folded)
           (canvas-diagram-set-fold key 'open))
          ((canvas-diagram--children-folded-p tree depth)
           (canvas-diagram--fold-all (canvas-diagram--keys-below tree) 'open))
          (t (canvas-diagram-set-fold key 'folded)))
    (canvas-diagram--refold)))

(defun canvas-diagram-show-level (levels)
  "Show LEVELS levels of the box at the keyboard, its own level the first."
  (interactive "p")
  (canvas-diagram--check-levels levels)
  (cl-labels ((walk (tree relative)
                (when (cdr tree)
                  (canvas-diagram-set-fold (car tree) (if (>= relative (1- levels)) 'folded 'open))
                  (dolist (child (cdr tree))
                    (walk child (1+ relative))))))
    (walk (canvas-diagram--fold-tree-at-keyboard) 0))
  (canvas-diagram--refold))

(defun canvas-diagram--set-levels (levels)
  "Show LEVELS levels of the diagram, or all for nil, and drop the folds."
  (canvas-diagram--need-folds)
  (setq canvas-diagram--levels (canvas-diagram--check-levels levels)
        canvas-diagram--folds nil)
  (canvas-diagram--refold))

(defun canvas-diagram-show-all-level (levels)
  "Show LEVELS levels of the diagram, and drop the folds set by hand."
  (interactive "p")
  (canvas-diagram--set-levels levels))

(defun canvas-diagram--diagram-height ()
  "The number of levels of this buffer's diagram."
  (canvas-diagram--height (canvas-diagram--top-trees)))

(defun canvas-diagram-cycle-levels ()
  "Cycle the levels of the diagram as magit cycles all sections.
One level, two, and so on up to the height, then all, then one again.
The folds set by hand go."
  (interactive)
  (canvas-diagram--need-folds)
  (let ((levels canvas-diagram--levels))
    (canvas-diagram--set-levels (cond ((null levels) 1)
                                      ((>= (1+ levels) (canvas-diagram--diagram-height)) nil)
                                      (t (1+ levels))))))

(defun canvas-diagram-shallower ()
  "Show one level fewer of the diagram, never fewer than one."
  (interactive)
  (canvas-diagram--need-folds)
  (canvas-diagram--set-levels
   (max 1 (1- (or canvas-diagram--levels (canvas-diagram--diagram-height))))))

(defun canvas-diagram-deeper ()
  "Show one level more of the diagram; past its height, show all of it."
  (interactive)
  (canvas-diagram--need-folds)
  (when canvas-diagram--levels
    (let ((next (1+ canvas-diagram--levels)))
      (canvas-diagram--set-levels (and (< next (canvas-diagram--diagram-height)) next)))))

(defmacro canvas-diagram--define-level-commands ()
  "Define the commands that the digits 1 to 4 and their meta forms run."
  `(progn
     ,@(cl-loop for n from 1 to 4
                collect `(defun ,(intern (format "canvas-diagram-show-level-%d" n)) ()
                           ,(format "Show %d level%s of the box at the keyboard." n (if (= n 1) "" "s"))
                           (interactive)
                           (canvas-diagram-show-level ,n))
                collect `(defun ,(intern (format "canvas-diagram-show-all-level-%d" n)) ()
                           ,(format "Show %d level%s of the diagram." n (if (= n 1) "" "s"))
                           (interactive)
                           (canvas-diagram-show-all-level ,n)))))

(canvas-diagram--define-level-commands)

(defconst canvas-diagram--fold-keys
  (append '(("TAB" . canvas-diagram-toggle-fold) ("<tab>" . canvas-diagram-toggle-fold)
            ("C-<tab>" . canvas-diagram-cycle-fold) ("<backtab>" . canvas-diagram-cycle-levels)
            ("[" . canvas-diagram-shallower) ("]" . canvas-diagram-deeper))
          (cl-loop for n from 1 to 4
                   collect (cons (format "%d" n) (intern (format "canvas-diagram-show-level-%d" n)))
                   collect (cons (format "M-%d" n) (intern (format "canvas-diagram-show-all-level-%d" n)))))
  "The fold keys of a diagram, as magit folds its sections.")

(defun canvas-diagram--fold-filter (command)
  "COMMAND when this buffer's diagram folds; else nil, so its key falls through."
  (and (canvas-diagram-folds-p) command))

(defun canvas-diagram--bind-folds (map)
  "Bind the fold keys in MAP, each only for a diagram that folds."
  (pcase-dolist (`(,key . ,command) canvas-diagram--fold-keys)
    (define-key map (kbd key) `(menu-item "" ,command :filter canvas-diagram--fold-filter))))

;;;; Settings

(defun canvas-diagram--cycle (symbol values)
  "Set SYMBOL to the value after its current one in VALUES, round and round."
  (let ((i (cl-position (symbol-value symbol) values :test #'equal)))
    (set symbol (nth (mod (1+ (or i -1)) (length values)) values))))

(defmacro canvas-diagram-define-setting (name symbol values doc)
  "Define NAME, a command cycling SYMBOL through VALUES and laying out
again, with DOC."
  `(defun ,name ()
     ,doc
     (interactive)
     (canvas-diagram--cycle ',symbol ,values)
     (when canvas-diagram--diagram
       (canvas-diagram-relayout))))

(canvas-diagram-define-setting canvas-diagram-cycle-shape canvas-diagram-shape
  '(rounded square pill) "Round, square or pill the boxes.")
(canvas-diagram-define-setting canvas-diagram-cycle-spacing canvas-diagram-spacing
  '(compact normal airy) "Pack or spread the boxes.")
(canvas-diagram-define-setting canvas-diagram-cycle-family canvas-diagram-family
  '(nil "Sans" "Serif" "Monospace") "Set the labels in the frame's font, or a generic family.")
(canvas-diagram-define-setting canvas-diagram-cycle-palette canvas-diagram-palette
  (mapcar #'car canvas-diagram-palettes) "Colour from the next palette.")
(canvas-diagram-define-setting canvas-diagram-toggle-kinds canvas-diagram-show-kinds
  '(t nil) "Show or hide the outlines that mark kinds.")
(canvas-diagram-define-setting canvas-diagram-toggle-legend canvas-diagram-show-legend
  '(t nil) "Show or hide the legend.")
(canvas-diagram-define-setting canvas-diagram-toggle-paper canvas-diagram-paper
  '(nil t) "Draw on white paper, or in the theme's colours.")
(canvas-diagram-define-setting canvas-diagram-toggle-icons canvas-diagram-show-icons
  '(t nil) "Show or hide the icons on the boxes.")

(defun canvas-diagram-setting (label symbol &optional nil-label)
  "Menu description of SYMBOL's setting: LABEL, then its value.
nil reads as NIL-LABEL, or off; t as on, and a star marks a value that a
fresh Emacs would not have.  It is `canvas-keys-setting', so that every
canvas menu in the family reads the same way."
  (canvas-keys-setting label symbol nil-label))

(defun canvas-diagram-customize ()
  "Open Customize for the diagram settings, to keep a choice made in the menu.
A package's own group is a subgroup, reached from there."
  (interactive)
  (customize-group 'canvas-diagram))

(defun canvas-diagram-menu ()
  "Open the package's menu of looks.
The menu binds the same key to closing itself, so the key toggles it.
That binding has to live in the menu: transient dispatches keys
through its own map while it is up, so this command never sees them."
  (interactive)
  (if-let* ((menu (plist-get (canvas-diagram-callbacks canvas-diagram--diagram) :menu)))
      (call-interactively menu)
    (user-error "canvas-diagram: this diagram has no menu")))

(defmacro canvas-diagram-define-menu (name doc &rest groups)
  "Define NAME, a transient of the diagram's looks, with DOC.
GROUPS, the package's own, make the first row.  The shared groups for
zoom, boxes, colours, icons, copying and the drawing follow in rows of
their own, so a menu of many groups stays inside the frame instead of
running off its right edge."
  `(transient-define-prefix ,name ()
     ,doc
     :transient-non-suffix 'transient--do-stay
     :column-widths canvas-diagram-menu-column-widths
     [,@groups]
     [:if canvas-diagram-folds-p
      ["Folds"
       ("TAB" "fold or unfold the box" canvas-diagram-toggle-fold :transient t)
       ("C-<tab>" "cycle the fold of the box" canvas-diagram-cycle-fold :transient t)
       ("<backtab>" "cycle the levels" canvas-diagram-cycle-levels :transient t)
       ("[" "one level fewer" canvas-diagram-shallower :transient t)
       ("]" "one level more" canvas-diagram-deeper :transient t)]]
     [["Zoom"
       ("+" canvas-keys-zoom-in :transient t
        :description (lambda () (format "%-10s %d%%" "zoom in" (round (* 100 canvas-diagram--zoom)))))
       ("-" canvas-keys-zoom-out :transient t :description "zoom out")
       ("0" canvas-keys-zoom-reset :transient t :description "natural size")
       ("z" canvas-diagram-zoom-fit :transient t :description "fit the whole drawing")]
      ["Boxes"
       ("B" canvas-diagram-cycle-shape :transient t
        :description (lambda () (canvas-diagram-setting "boxes" 'canvas-diagram-shape)))
       ("s" canvas-diagram-cycle-spacing :transient t
        :description (lambda () (canvas-diagram-setting "spacing" 'canvas-diagram-spacing)))
       ("F" canvas-diagram-cycle-family :transient t
        :description (lambda () (canvas-diagram-setting "font" 'canvas-diagram-family "frame")))]
      ["Colours and icons"
       ("P" canvas-diagram-cycle-palette :transient t
        :description (lambda () (canvas-diagram-setting "palette" 'canvas-diagram-palette)))
       ("k" canvas-diagram-toggle-kinds :transient t
        :description (lambda () (canvas-diagram-setting "kinds" 'canvas-diagram-show-kinds)))
       ("l" canvas-diagram-toggle-legend :transient t
        :description (lambda () (canvas-diagram-setting "legend" 'canvas-diagram-show-legend)))
       ("w" canvas-diagram-toggle-paper :transient t
        :description (lambda () (canvas-diagram-setting "paper" 'canvas-diagram-paper)))
       ("i" canvas-diagram-toggle-icons :transient t
        :description (lambda () (canvas-diagram-setting "icons" 'canvas-diagram-show-icons)))]]
     [["Copy"
       ("y y" "the node" canvas-diagram-copy-node)
       ("y h" "its header" canvas-diagram-copy-header)
       ("y b" "its body" canvas-diagram-copy-body)
       ("y s" "its source text" canvas-diagram-copy-source)
       ("y p" "the picture" canvas-keys-copy-whole-picture)]
      ["Marks"
       ("C-SPC" canvas-diagram-toggle-mark :transient t
        :description "mark this box, or let it go")
       ("M" canvas-diagram-mark-all :transient t
        :description "mark every box")
       ("U" canvas-diagram-unmark-all :transient t
        :description (lambda ()
                       (format "%-10s %d marked" "let go"
                               (length (canvas-diagram-marked-nodes)))))]
      ["The drawing"
       ("W" "write as PNG, SVG or PDF" canvas-keys-write)
       ("C" "customize, to keep" canvas-keys-customize)
       ("q" "close, or SPC" transient-quit-one)]]
     ;; The key that opened the menu closes it again.  It is bound here
     ;; because transient dispatches keys through its own map while the
     ;; menu is up, and hidden because the row above already says so.
     ;; A group's `hide' keeps its keys working, and transient reads it
     ;; on a top-level group only, which is why this is one.
     [:hide (lambda () t)
      ("SPC" "close" transient-quit-one)]))

(defconst canvas-diagram-setting-keys
  '(("s" . canvas-diagram-cycle-spacing)
    ("B" . canvas-diagram-cycle-shape)
    ("P" . canvas-diagram-cycle-palette) ("k" . canvas-diagram-toggle-kinds)
    ("i" . canvas-diagram-toggle-icons))
  "The setting keys of a diagram that canvas-keys does not hold.
The ones that would take a navigation letter, b and p, are capitals.
`w', `F' and `l' for paper, the font family and the legend, `C' for
Customize and `W' for writing the drawing are common canvas keys, which
`canvas-keys-look-map' brings.")

;;;; The mode

(defun canvas-diagram--bind-mouse (map)
  "Bind the mouse in MAP: a press starts a drag or a click, the wheel scrolls.
Emacs reports fast wheel turns as double and triple events."
  (dolist (press '([down-mouse-1] [double-down-mouse-1] [triple-down-mouse-1]))
    (define-key map press #'canvas-diagram-mouse))
  (dolist (release '([mouse-1] [triple-mouse-1]))
    (define-key map release #'ignore))
  (define-key map [double-mouse-1] #'canvas-diagram-double-click)
  (dolist (turn '("" "double-" "triple-"))
    (dolist (dir '(("down" . canvas-diagram-scroll-down) ("up" . canvas-diagram-scroll-up)
                   ("right" . canvas-diagram-scroll-right) ("left" . canvas-diagram-scroll-left)))
      (define-key map (vector (intern (format "%swheel-%s" turn (car dir)))) (cdr dir))))
  (define-key map [S-wheel-down] #'canvas-diagram-scroll-right)
  (define-key map [S-wheel-up] #'canvas-diagram-scroll-left)
  (define-key map [C-wheel-up] #'canvas-diagram-zoom-in)
  (define-key map [C-wheel-down] #'canvas-diagram-zoom-out))

(defun canvas-diagram--bind-keyboard (map)
  "Bind the keyboard in MAP by remapping the commands that move point.
Whatever keys move point in the user's Emacs move the keyboard here:
forward in, back out, down and up in reading order, M-n and M-p along
a depth, the list commands along siblings and up and down, the defun
commands from branch to branch, the buffer ends to the first and last
node, `goto-line' to a node by name, the text-scale keys to zoom,
`recenter' to centre the node, `kill-ring-save' to copy it, or with a
prefix the whole picture."
  (dolist (remap '((forward-char . canvas-diagram-move-in)
                   (right-char . canvas-diagram-move-in)
                   (backward-char . canvas-diagram-move-out)
                   (left-char . canvas-diagram-move-out)
                   (next-line . canvas-diagram-move-next)
                   (previous-line . canvas-diagram-move-previous)
                   (down-list . canvas-diagram-move-in)
                   (backward-up-list . canvas-diagram-move-out)
                   (up-list . canvas-diagram-move-out)
                   (forward-sexp . canvas-diagram-move-next-sibling)
                   (forward-list . canvas-diagram-move-next-sibling)
                   (backward-sexp . canvas-diagram-move-previous-sibling)
                   (backward-list . canvas-diagram-move-previous-sibling)
                   (beginning-of-defun . canvas-diagram-move-branch)
                   (end-of-defun . canvas-diagram-move-next-branch)
                   (beginning-of-buffer . canvas-diagram-move-first)
                   (end-of-buffer . canvas-diagram-move-last)
                   (scroll-up-command . canvas-diagram-page-down)
                   (scroll-down-command . canvas-diagram-page-up)
                   ;; `pixel-scroll-precision-mode' binds the page keys to
                   ;; these, which scroll the window over its one line.
                   (pixel-scroll-interpolate-down . canvas-diagram-page-down)
                   (pixel-scroll-interpolate-up . canvas-diagram-page-up)
                   (goto-line . canvas-diagram-jump)
                   (consult-goto-line . canvas-diagram-jump)
                   (text-scale-increase . canvas-diagram-zoom-in)
                   (text-scale-decrease . canvas-diagram-zoom-out)
                   (text-scale-adjust . canvas-diagram-zoom-adjust)
                   (recenter-top-bottom . canvas-diagram-recenter)
                   (recenter . canvas-diagram-recenter)
                   ;; The common copy: the node, or with a prefix the
                   ;; whole picture, as in every canvas buffer.
                   (kill-ring-save . canvas-keys-copy-picture)))
    (define-key map (vector 'remap (car remap)) (cdr remap)))
  ;; +, =, - and 0 are common canvas keys, which call
  ;; `canvas-keys-zoom-function', and a diagram sets that to
  ;; `canvas-diagram--zoom-by-key'.
  (define-key map (kbd "z") #'canvas-diagram-zoom-fit)
  ;; The plain letters too, as in other read-only buffers.
  (define-key map (kbd "n") #'canvas-diagram-move-next)
  (define-key map (kbd "p") #'canvas-diagram-move-previous)
  (define-key map (kbd "f") #'canvas-diagram-move-in)
  (define-key map (kbd "b") #'canvas-diagram-move-out)
  (define-key map (kbd "^") #'canvas-diagram-move-out)
  (define-key map (kbd "M-n") #'canvas-diagram-move-next-at-depth)
  (define-key map (kbd "M-p") #'canvas-diagram-move-previous-at-depth)
  (define-key map [home] #'canvas-diagram-home)
  (define-key map (kbd "RET") #'canvas-diagram-toggle-card)
  (define-key map (kbd "C-<return>") #'canvas-diagram-visit-source)
  ;; A user's M-w may run a command of their own, which no remap sees.
  (define-key map (kbd "M-w") #'canvas-keys-copy-picture)
  (define-key map [escape] #'canvas-diagram-close-popup)
  ;; SPC and g are common canvas keys: SPC opens the menu through
  ;; canvas-keys, and g reverts, which `revert-buffer-function' sends to
  ;; `canvas-diagram-refresh'.  m is common as well now, and shows and
  ;; hides the map of canvas-minimap.
  (define-key map (kbd "C-SPC") #'canvas-diagram-toggle-mark)
  (define-key map [remap set-mark-command] #'canvas-diagram-toggle-mark)
  (define-key map (kbd "M") #'canvas-diagram-mark-all)
  (define-key map (kbd "U") #'canvas-diagram-unmark-all)
  (define-key map [remap keyboard-quit] #'canvas-diagram-quit)
  (pcase-dolist (`(,key . ,command) canvas-diagram-setting-keys)
    (define-key map (kbd key) command)))

(defun canvas-diagram-fill-mode-map (map)
  "Put the keys of a diagram into MAP, which loses the keys it held; MAP.
A mouse event over a box arrives prefixed by the hot spot's id, so the
prefix leads to a keymap that falls back on this one and swallows the
rest, rather than to an undefined-key complaint."
  (let ((node (make-sparse-keymap)))
    (setcdr map nil)
    ;; Two parents: the common canvas keys with the looks, and the keys of
    ;; `special-mode', which `define-derived-mode' would give this map if
    ;; it had none.  The line above drops the parent with the bindings.
    (set-keymap-parent map (make-composed-keymap canvas-keys-look-map special-mode-map))
    (canvas-diagram--bind-mouse map)
    (canvas-diagram--bind-keyboard map)
    (canvas-diagram--bind-folds map)
    (define-key map [remap write-file] #'canvas-diagram-write)
    (set-keymap-parent node map)
    (define-key node [t] #'ignore)
    (define-key map [canvas-diagram-node] node)
    map))

(defun canvas-diagram-make-mode-map ()
  "A fresh keymap of the keys every diagram buffer starts from."
  (canvas-diagram-fill-mode-map (make-sparse-keymap)))

(defvar canvas-diagram-mode-map (canvas-diagram-make-mode-map)
  "Keys every diagram buffer has; a package's mode map inherits them.")

;; Loading this file again fills the map that the open buffers already
;; use, so that they get the keys of the code just loaded.
(canvas-diagram-fill-mode-map canvas-diagram-mode-map)

(defun canvas-diagram--header ()
  "The header line: what the package says of the keyboard's node, else its label.
Nothing when the buffer holds no diagram, as after a `:build' that
signalled.  Redisplay evaluates this, so an error here would come back
with every redraw."
  (if (and canvas-diagram--diagram canvas-diagram--selected)
      (or (canvas-diagram--call canvas-diagram--diagram :header canvas-diagram--diagram
                                canvas-diagram--selected)
          (canvas-diagram-node-label canvas-diagram--selected))
    ""))

(define-derived-mode canvas-diagram-mode special-mode "Diagram"
  "Major mode a buffer showing a diagram on a canvas derives from.

The keyboard is on one node, ringed.  The keys that move point move
it; \\[canvas-diagram-jump] jumps to a node by name.
\\[canvas-diagram-toggle-card] opens the node's card,
\\[canvas-diagram-visit-source] goes to its line in the source,
\\[canvas-diagram-copy-node] copies it, and with a prefix argument its
text in the source.
\\[canvas-diagram-menu] opens the menu of looks, whose keys work here
directly as well.  The wheel and the page commands move the view, a
drag pans it.

\\{canvas-diagram-mode-map}"
  (setq cursor-type nil
        truncate-lines t)
  (setq-local revert-buffer-function #'canvas-diagram-refresh)
  (setq canvas-keys-menu-command #'canvas-diagram-menu
        canvas-keys-write-command #'canvas-diagram-write
        ;; M-w copies the node the keyboard is on; with a prefix, the
        ;; whole picture.
        canvas-keys-copy-function #'canvas-diagram-copy-node
        canvas-keys-group 'canvas-diagram
        canvas-keys-zoom-function #'canvas-diagram--zoom-by-key
        ;; The setting commands of canvas-diagram lay the diagram out
        ;; again themselves, so a look key has nothing left to draw.
        canvas-keys-redraw-function #'ignore)
  (setq header-line-format '(:eval (canvas-diagram--header)))
  (add-hook 'kill-buffer-hook #'canvas-diagram--release nil t)
  (add-hook 'window-size-change-functions #'canvas-diagram--window-resized nil t))

;;;###autoload
(defun canvas-diagram-show (name mode diagram spec &optional source)
  "Show DIAGRAM, built from SPEC, in the buffer NAME under MODE, a mode
derived from `canvas-diagram-mode'.  With SOURCE, a buffer, follow it:
reread it once typing there pauses.  The buffer takes the directory it
is shown from, so that what acts on the diagram acts in that project.
Return the buffer."
  (let ((buffer (get-buffer-create name))
        (directory default-directory))
    (with-current-buffer buffer
      (canvas-diagram--release)
      (funcall mode)
      (setq default-directory directory)
      (canvas-diagram-adopt diagram spec)
      (when source
        (canvas-diagram--follow source)))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (canvas-diagram--fit-window (get-buffer-window buffer))
      (canvas-diagram-redraw)
      (canvas-diagram--sync-hot-spots buffer))
    buffer))

(provide 'canvas-diagram)
;;; canvas-diagram.el ends here
