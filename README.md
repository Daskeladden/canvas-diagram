# canvas-diagram

Diagrams of boxes on an Emacs 32 canvas, and the module that makes
them possible: `canvas-cairo`, cairo and pango drawing straight into a
canvas image's pixel buffer.

Two packages are built on it: canvas-mindmap, an outline as a tree, and
canvas-vhdl-fsm, a VHDL state machine as a graph. Each is only its
model, its layout, its edges and how the keyboard walks it; everything
else is here.

This is a prototype.

## Why

Emacs 32's `canvas` image type is a writable ARGB32 pixel buffer that
keeps its contents between refreshes. It has no drawing primitives and
no text: Emacs exposes no glyph rasterizer to Lisp, so a package
wanting real fonts on a canvas has had to ship pre-rendered glyphs or
typeset through an external process.

`canvas-cairo.so` closes that gap. It lays a cairo image surface over
the canvas's own buffer, reached through the Emacs 32 module function
`canvas_data`, and sets text with pango. Paths, fills, strokes and
labels in any installed font land directly in the pixels Emacs will
show; `canvas-cairo-flush` then asks Emacs to redisplay them. Nothing
is copied and no new image object is made per frame, which is what a
drawing that pans, zooms and drags needs.

`canvas-diagram.el` is what every diagram of boxes then needs and none
should write twice: a canvas the size of its window that scrolls and
zooms over the drawing; boxes with a label, a kind that outlines them,
a note, an icon and a place in a source buffer; hot spots, a card that
opens on a click, a legend; the keyboard on one box, ringed, moved by
the user's own point-movement keys; the mouse; canvas-minimap's
thumbnail and click; following the buffer the drawing came from and
putting point where a box came from; a transient menu of looks; PNG
export in batch.

## Requirements

- Emacs 32.0.50, built from source. Emacs 32 is not released; this
  needs a build from the master branch, with canvas image support and
  with modules (`(image-type-available-p 'canvas)` and
  `module-file-suffix`)
- cairo and pango runtime libraries, which any Emacs built with cairo
  already pulls in
- Their development headers, or `make deps-local` (see Build)
- librsvg's headers for icons; without them `canvas-cairo-svg` and
  `canvas-cairo-svg-picture` signal
- transient, for the menus
- [canvas-keys](https://github.com/Daskeladden/canvas-keys), the keys that
  every canvas buffer shares

## Build

No archive carries this: it needs Emacs 32.0.50 built from source, and
the drawing goes through a module compiled on your machine.

```sh
git clone https://github.com/Daskeladden/canvas-diagram.git
cd canvas-diagram
make            # builds canvas-cairo.so
make test       # runs the ERT suite
```

Then put the directory on the load path; the packages built on this
each say how they want to be loaded alongside it.

No root for the headers? `make deps-local` downloads `libpango1.0-dev`
with `apt-get download`, unpacks its headers into `./include`, and
drops link stubs in `./lib` (distributions ship `libpango-1.0.so.0`
but the unversioned symlink only comes with the `-dev` package).

Packages built on this expect it beside them, `../canvas-diagram`, and
their `make test` builds the module here.

## Writing a diagram

A package makes a `canvas-diagram` struct with a plist of callbacks
and hands it, with a spec, to `canvas-diagram-show`:

```elisp
(canvas-diagram-show "*my-diagram*" #'my-diagram-mode
                     (canvas-diagram-create :callbacks my-diagram--callbacks)
                     spec (current-buffer))
```

The spec is whatever the package reads its model from, compared with
`equal` to see whether a source buffer changed. The callbacks:

| callback | does |
|---|---|
| `:build (diagram spec)` | the model |
| `:layout (diagram ctx)` | size and place the nodes, return them in reading order |
| `:draw-edges (diagram ctx)` | stroke the edges, in drawing coordinates |
| `:front (diagram)` | optional: the boxes drawn last, over the other boxes |
| `:draw-front (diagram ctx nodes)` | optional: a backdrop for the front boxes, drawn after the other boxes and before the front boxes |
| `:draw-over (diagram ctx)` | optional: drawn after every box, such as lines that must stay in sight where they cross a box |
| `:zoom (diagram zoom)` | optional: the diagram is now drawn at ZOOM, as when a package zooms another diagram along with it through `canvas-diagram-zoom-to` |
| `:draw-trail (diagram ctx node width)` | optional: mark the way to the keyboard's node |
| `:node-rgb (diagram node)` | optional: the box's fill |
| `:node-shape (diagram node)` | optional: `rounded`, `square` or `pill` for that one box, else `canvas-diagram-shape` decides |
| `:node-text (diagram node)` | optional: what the box says, else the label |
| `:badge (diagram node)` | optional: `(TEXT RGB)`, a pill before the label and a row of the legend. If the package's legend has a `badge` row, the badge gets no row. |
| `:header (diagram node)` | optional: the header line for the node |
| `:card (diagram node)` | optional: `(TITLE PATH BODY)` for its card |
| `:content (diagram node)` | optional: `(HEADER BODY)` that copying the node copies, else the label and the note |
| `:source-text (diagram node part buffer)` | optional: the `header`, `body` or `all` of the node's text in the buffer followed |
| `:legend (diagram)` | optional: rows `(LABEL RGB fill|outline|badge)` before the badges and the kinds. A `badge` row leaves out the rows of the badges in use. |
| `:move (diagram node direction)` | where a direction leads, or nil |
| `:node-key`, `:restore` | optional: find the node again after a rebuild. The node found keeps its place on the canvas. |
| `:double-click (diagram node)` | optional |
| `:open (diagram node)` | optional: `RET` and a click on a box give the box to the package in place of its card |
| `:select (diagram node)` | optional: the keyboard is on the node, after a move, a rebuild or a relayout |
| `:go (diagram node)` | optional: a move or a jump by name put the keyboard on the node, never a rebuild or a relayout |
| `:read-source (buffer)` | optional: the spec of a buffer, for following it |
| `:fold-trees (diagram node)` | optional: the trees under the node, as `(KEY . CHILD-TREES)`, hidden boxes too; a nil node gives the top. A diagram with this callback folds. |
| `:fold-start (diagram)` | optional: `(:levels N :open KEYS)`, the folds a new view starts with |
| `:menu` | a transient made with `canvas-diagram-define-menu` |

Nodes are `canvas-diagram-node` structs, or a package's `:include` of
one, with `label kind note icon pos x y w h`. `canvas-diagram-measure`
gives a layout the function that turns a text into its box's size,
`canvas-diagram-size-node` applies it with room for the node's icon,
`canvas-diagram-middle-x` and `-y` help with edges. A layout whose
edges reach beyond the boxes sets the diagram's `slack`, the pixels
they need.

The directions `:move` is asked for are `in`, `out`, `next`,
`previous`, `next-at-depth`, `previous-at-depth`, `next-sibling`,
`previous-sibling`, `branch`, `next-branch`, `first` and `last`; the
mode map sends the remapped point-movement commands to them, so
`forward-char` is `in`, `backward-up-list` is `out`,
`beginning-of-defun` is `branch` and so on, whatever keys the user has
on those. `canvas-diagram-neighbour` steps along a list and holds at
its ends.

`canvas-diagram-define-setting` makes a command that cycles a variable
and lays out again; `canvas-diagram-define-menu` makes a transient with
the package's groups first and the shared zoom, box, colour and icon
groups after, whose keys `canvas-diagram-mode-map` binds in the buffer
too. A package's mode derives from `canvas-diagram-mode` and adds its
own keys. `canvas-diagram-extra-kinds` and
`canvas-diagram-extra-kind-icons` let a package add kinds with a colour
and an icon.

A box may hold rows: a line of text under its label for each port of an
entity, field of a class or field of a register. Put them in the node's
`rows`, and the box takes the width of the widest of them and a line of
height for each, with a rule under the label.
`canvas-diagram-row-anchor` gives the place an arrow joins a row, on the
left or right edge of the box at that row's height, so a line can land
on a port rather than in the middle of a box; a row the node does not
hold is an error. canvas-graph reads `:rows` on a node spec and
`:from-row` and `:to-row` on an edge spec, and draws the arrow between
those places.

`canvas-diagram-export` draws a diagram from a spec into a PNG, an SVG
or a PDF, by the file's name, without a buffer or a frame; in a diagram
buffer `C-x C-w`, or `W`, writes the drawing with the looks in force
the same way, through the package's `:export` callback when it has one.

## Keys every diagram has

The keyboard is on a node, ringed in the cursor's colour, with a halo,
and its box tinted towards that colour; a marked node is ringed and
tinted the same way, more faintly. `canvas-diagram-selection-tint` and
`canvas-diagram-mark-tint` set how far, and 0 leaves the fill alone.
The commands that move point are remapped, so whatever runs
`forward-char` moves in, `backward-char` out, `next-line` and
`previous-line` through the nodes in reading order, `M-n` and `M-p`
along a depth, the list commands along siblings and up and down,
`beginning-of-defun` and `end-of-defun` between branches, the buffer
ends to the first and last node, `goto-line` to a node by name, and
`recenter` centres it. The plain letters `n`, `p`, `f` and `b` do the
same as their control versions, `^` goes out. The view follows the
selection: a node partly in view is nudged inside, one off the canvas
is centred. While smear-cursor is on, its cursor flies from the box the
keyboard left to the box it reached; `canvas-diagram-fly-function`
names another way to show the move, or nil for none. `RET` opens the
node's card and closes it, `ESC` closes it,
`C-RET` visits the node's place in the source, the page commands and
the wheel scroll, `S-` with the wheel sideways, a drag pans, a click on
a box selects it and opens its card, `g` reads the source again, `q`
closes the buffer and `?` lists every key.

`C-SPC` marks the node at the ring and lets it go again, `M` marks
every node and `U` lets them all go; a marked node is ringed and its
box tinted. The copy keys take the marked nodes when there are any.

`M-w`, or any key that runs `kill-ring-save`, copies the node at the
ring: its header, a blank line and its body. With a prefix argument,
it copies the whole diagram as a picture, as `C-u M-w` does in every
canvas buffer. The menu's Copy group has `y y` for the node, `y h` for
its header, `y b` for its body, `y s` for its text in the buffer that the
diagram follows, and `y p` for the picture. If you use embark,
`embark-act` in a diagram offers the node as a target. Its actions are
`w`, `h`, `b` and `s`, and a prefix argument before one copies from the
source.

A package, or you, can add actions for the diagrams where they make
sense. `canvas-diagram-node-actions` is a list of `(CONDITION . KEYMAP)`.
CONDITION is a condition of `buffer-match-p`, as in
`display-buffer-alist`: `(derived-mode . canvas-mindmap-mode)`, a
function of the buffer, or an `and` of both. KEYMAP is a keymap, or a
variable that holds one, and its commands act on the node at the ring.
`embark-act` offers the actions of every entry whose condition holds,
beside the copying keys, which win a key that both bind.
`canvas-diagram-marked-actions` does the same for the marked boxes.
Embark answers the first question that an action asks in the minibuffer
with the node's label, and presses `RET`. If a command of yours asks for
something else, add it to `embark-target-injection-hooks` with
`embark--ignore-target`. For example, to offer a command of your own in
state machine diagrams:

```elisp
(defvar-keymap my-fsm-actions
  "t" #'my-fsm-trace-state)
(add-to-list 'canvas-diagram-node-actions
             '((derived-mode . canvas-vhdl-fsm-mode) . my-fsm-actions))
```

A diagram's buffer takes the directory that it was shown from, so an
action runs in that project.

A diagram that folds has the keys of magit. `TAB` folds the box at the
ring or unfolds it. `C-<tab>` cycles the box: folded, then open with its
children folded, then all open. `<backtab>` cycles the levels of the
whole diagram. A digit from `1` to `4` shows that many levels of the box,
and `M-1` to `M-4` show that many levels of the diagram. `[` and `]` show
one level fewer or more. A command that sets the levels drops the folds
that you set. The keyboard stays on its box while the box shows, or goes
to the nearest shown box above it. In a diagram that does not fold, these
keys keep their usual commands.

A layout asks `canvas-diagram-folded-p` with the key and the depth of a
box whether the box hides its children. The fold of the key wins. Without
a fold, the levels decide. If the levels are a number and the depth is the
levels minus 1 or more, the box is folded. `canvas-diagram-set-fold` sets a fold, and
`canvas-diagram-unfold-to` opens every box above a key. A key that occurs
twice in the fold trees is an error. An export outside a diagram buffer
draws the folds that the diagram starts with.

Zoom steps through fixed factors with the text-scale keys, `+`, `-`
and `0`, or `C-` with the wheel; `z` fits the whole drawing. Text is
set again at each zoom, so it stays crisp.

When the drawing is built again, the node at the ring keeps its place
on the canvas. The other boxes slide from where they were to their new
places in `canvas-diagram-animate` seconds, 0.2 by default. Any key ends
the slide at once, and nil turns the slide off.

`SPC` opens the package's menu, and `SPC` closes it again. `m` shows and
hides the map of canvas-minimap, as it does in every canvas buffer. Its
shared keys, which work in the buffer directly too, are `B` boxes
(rounded, square, pill), `s` spacing (compact, normal, airy), `F` font
(the frame's, or a generic Sans, Serif or Monospace at its size), `P`
palette, `k` kinds, `l` legend, `w` paper (dark ink on white instead
of the theme), `i` icons, and `C` opens Customize to keep a choice.

## Colours, kinds, icons

Font and colours follow the frame's faces; `canvas-diagram-font` and
`canvas-diagram-colors` override them. `canvas-diagram-palettes` hold
named palettes for numbered things, a mind map's branches or a
machine's depths, and `derived` makes hues from the background, pastel
on light and deep on dark. `canvas-diagram-kinds` maps a kind to its
outline colour and ships todo, done, risk, idea, question, next and
the code kinds; `canvas-diagram-kind-icons` gives them icons, named
`COLLECTION:NAME` as svg-lib knows them and taken from
`canvas-diagram-icon-directory` or svg-lib's cache, fetched by svg-lib
when they are nowhere. The module rasterizes an SVG through a mask, so
an icon takes the text colour whatever colour it was drawn in.
`canvas-diagram-icon-data` returns an icon's SVG text by the same name,
for a package that draws icons of its own with `canvas-cairo-svg`.

## Palette

`canvas-palette.el` gives canvas drawings eight series slots. Each slot
has a colour, a marker shape and a dash pattern, so a drawing never
needs colour alone to tell its series apart. The colours are the faces
`canvas-series-1` to `canvas-series-8`, and the faces `canvas-grid`,
`canvas-axis` and `canvas-reference` colour the chrome. The series
defaults pass the colour checks on a black and a white background. On
white, three of them get a contrast relief, a contrast below 3:1. The
marker shapes, the dash patterns and the legend of a chart make up for
the low contrast.

A theme sets the faces with `custom-theme-set-faces`. A user sets them
in the init file. On the frame's background, every way to set a face
counts. On the other background, only face specs that name a background
count. An example from a Modus theme:

```elisp
(defun my-canvas-series-from-modus (&rest _)
  (modus-themes-with-colors
    (custom-set-faces `(canvas-series-1 ((t :foreground ,bg-graph-blue-0))))))
(add-hook 'enable-theme-functions #'my-canvas-series-from-modus)
```

| function | does |
|---|---|
| `canvas-palette-series N &optional BACKGROUND` | slot N, 0 to 7, as `(:rgb RGB :shape SHAPE :dash DASHES)` |
| `canvas-palette-slot-count` | the number of series slots, 8 |
| `canvas-palette-chrome KEY &optional BACKGROUND` | the colour of `grid`, `axis` or `reference` |
| `canvas-palette-background` | `light` on paper, else the frame's background mode |
| `canvas-palette-surface BACKGROUND` | the surface colour a drawing on BACKGROUND uses |
| `canvas-palette-draw-marker CTX SHAPE X Y SIZE` | draw a slot's shape in the current colour |
| `canvas-palette-subscribe FUNCTION` | start the calls of FUNCTION with the theme after each theme change |
| `canvas-palette-unsubscribe FUNCTION` | stop the calls of FUNCTION |
| `canvas-palette-validate RGBS SURFACE BACKGROUND &optional PAIRS` | the dataviz checks of a list of colours |
| `M-x canvas-palette-check` | a report on the current series faces |

While a package is subscribed, canvas-palette checks the series faces
after a theme is enabled, once for each theme in a session. If a check
fails, one warning names the theme and the checks.

## The minimap

canvas-minimap asks `canvas-minimap-thumbnail-functions` for a picture
of any image before reading its file. canvas-diagram answers for its
own canvases with the whole drawing scaled to the minimap's size, the
view tinted and outlined and the selection ringed, and tells the
minimap through `canvas-minimap-picture-changed` whenever the view
moves. A click or drag on that picture comes back through
`canvas-minimap-picture-click-functions` and the view centres there;
when the whole drawing fits already, the click zooms to natural size
around the point instead.

## The source

A diagram shown with a source buffer follows it: after a change there
and a pause, the spec is read again through `:read-source` and the
model rebuilt when it differs, the keyboard staying on its node by
`:node-key`. Going to a node puts point where its `pos` says, in the
source's window if it has one, and pulses the line with the pulse you
have on, smear-cursor's or pulsar's; `canvas-diagram-pulse-function`
names another, or nil for none.

A diagram can also live inside a buffer rather than be all of it.
`canvas-diagram-code-blocks` finds the markdown fences and org source
blocks of a language. `canvas-diagram-region-at` picks the one that
point is in, and `canvas-diagram-region-reader` makes the function
that reads it again as it is edited. That function keeps the last good
drawing while the text is incomplete, and says what is wrong.
`canvas-diagram-text-lines` gives a reader the region's lines with
their buffer positions.

## Readers of diagram languages

A reader turns the text of a diagram language into the spec of a
layout. canvas-mermaid and canvas-plantuml are readers, and
canvas-graph, canvas-mindmap and canvas-sequence are layouts. Each
layout defines itself with `canvas-diagram-define-layout`, by the kind
of spec that it draws: `graph`, `mindmap` or `sequence`.

A new language needs only its reader. `canvas-diagram-reader-create`
makes one from four parts:

- `:package`, the package. It begins the reader's messages and names
  the buffer of the drawing.
- `:language`, the name of the language in messages.
- `:regions`, a function that returns the diagrams of the current
  buffer as `((START . END)...)`.
- `:read`, a function of the text of one diagram and the position
  where it begins. It returns `(KIND . SPEC)`.

The functions of `canvas-diagram-reader.el` do the rest for every
language:

- `canvas-diagram-reader-show` draws the diagram at point with the
  layout of its kind, and follows it while you edit it.
- `canvas-diagram-reader-show-file` does the same for the first
  diagram of a file.
- `canvas-diagram-reader-export` writes a PNG, an SVG or a PDF, also
  in batch.
- `canvas-diagram-reader-demo` opens an example in a buffer to edit.

```elisp
(require 'canvas-diagram-reader)
(require 'canvas-graph)

(defconst my-dot-reader
  (canvas-diagram-reader-create
   :package "my-dot" :language "dot"
   :regions (lambda () (canvas-diagram-code-blocks '("dot")))
   :read #'my-dot-read))           ; returns (graph . SPEC)

(defun my-dot-show ()
  "Draw the dot graph that point is in."
  (interactive)
  (canvas-diagram-reader-show my-dot-reader))
```

The drawing goes to a buffer named after the package, here
`*my-dot*`. A diagram of a kind that no loaded layout draws is an
error that names the kind.

## The module

Every function takes a context made by `canvas-cairo-context` from a
canvas image spec. Numbers may be integers or floats; colours are
R G B A in 0 to 1.

| function | does |
|---|---|
| `canvas-cairo-context CANVAS` | a context over CANVAS's pixels |
| `canvas-cairo-file-context FILE W H` | a context drawing into FILE, an SVG or a PDF by its name, complete when destroyed; its pixels cannot be read |
| `canvas-cairo-destroy CTX` | release it; drawing afterwards is an error |
| `canvas-cairo-clear CTX R G B A` | paint everything within the clip |
| `canvas-cairo-set-color`, `-set-line-width` | state for later fills, strokes, text |
| `canvas-cairo-set-dash CTX DASHES &optional OFFSET` | dash later strokes: DASHES is a vector of on and off lengths in pixels, `[]` for solid |
| `-new-path`, `-move-to`, `-line-to`, `-curve-to`, `-arc`, `-rectangle`, `-close-path` | build a path |
| `canvas-cairo-fill CTX &optional PRESERVE`, `-stroke` | paint it |
| `-clip`, `-reset-clip`, `-save`, `-restore`, `-translate`, `-scale` | clip and transform |
| `canvas-cairo-text CTX X Y TEXT FONT &optional WIDTH` | draw TEXT, top-left at X Y, wrapped at WIDTH; returns `(W . H)` |
| `canvas-cairo-text-size CTX TEXT FONT &optional WIDTH` | measure without drawing |
| `canvas-cairo-markup CTX X Y MARKUP FONT &optional WIDTH` | draw pango markup, `<span foreground="#ff0000">red</span>`, wrapped at WIDTH; `&`, `<` and `>` escaped in the text |
| `canvas-cairo-markup-size CTX MARKUP FONT &optional WIDTH` | measure markup without drawing |
| `canvas-cairo-pixel CTX X Y` | the ARGB32 value there |
| `canvas-cairo-pixels CTX X Y W H` | a region's ARGB32 values as a vector, row by row |
| `canvas-cairo-svg CTX SVG X Y W H` | paint SVG data into a box in the current colour |
| `canvas-cairo-svg-picture CTX SVG X Y W H` | paint SVG data into a box in its own colours |
| `canvas-cairo-flush CTX` | finish and have Emacs redisplay the canvas |
| `canvas-cairo-write-png CTX FILE` | save the pixels as a PNG |
| `canvas-cairo-version` | the cairo and pango in use |

FONT is a pango description. Use an absolute size, `"Noto Sans 14px"`,
to match the frame's text whatever DPI pango assumes;
`canvas-diagram-font` derives one from the default face. Text wraps at
words only, so an identifier is never broken or hyphenated.
`canvas-diagram-face-hex` gives a face's foreground as the `#rrggbb`
markup wants and `canvas-diagram-markup-escape` escapes text for it.

Every call re-reads the canvas's buffer pointer and size, so a spec
whose `:data-width` or `:data-height` changed is followed rather than
written past. A resize resets the drawing state. The cost is about a
microsecond per call.

A context holds a reference that keeps its canvas alive until
`canvas-cairo-destroy`: a module finalizer has no environment to
release it with, so a context that is only dropped leaks that
reference.

Two things about canvases the code leans on: a canvas drawn to is
painted into the frame's back buffer, and the buffer is flipped onto
the screen only when redisplay updates the frame, so every redraw
calls `force-window-update`; and a spec's `:map` or size is part of
its image-cache key, so `image-flush` goes before any `plist-put` on
it.

## What it does not do

A canvas replaces the glyph it is displayed on; it cannot composite
over buffer text. A diagram lives in its own buffer.

## Licence

GPL-3.0-or-later; see [LICENSE](LICENSE).
