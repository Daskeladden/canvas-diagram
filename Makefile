# canvas-diagram -- diagrams on an Emacs 32 canvas: the cairo and pango
# module, and the Lisp that a mind map, a state machine or any other
# diagram of boxes is built on.

EMACS  ?= emacs
KEYS   ?= ../canvas-keys
CC         ?= gcc
MODULE      = canvas-cairo.so
SRC         = canvas-cairo.c

CFLAGS     ?= -O2 -Wall -Wextra -std=gnu11 -fPIC

# With the pango -dev package installed pkg-config knows everything.
# Without it, "make deps-local" unpacks the headers into ./include and
# drops link stubs in ./lib (distributions ship libpango-1.0.so.0 but
# the unversioned symlink only comes with the -dev package).
HAVE_PANGO := $(shell pkg-config --exists pangocairo && echo yes)
ifeq ($(HAVE_PANGO),yes)
PKG_CFLAGS := $(shell pkg-config --cflags pangocairo)
PKG_LIBS   := $(shell pkg-config --libs pangocairo)
else
PKG_CFLAGS := -Iinclude/pango-1.0 \
              $(shell pkg-config --cflags cairo glib-2.0 gobject-2.0 harfbuzz)
PKG_LIBS   := $(if $(wildcard lib/libpango-1.0.so),-Llib,) \
              -lpangocairo-1.0 -lpango-1.0 \
              $(shell pkg-config --libs cairo glib-2.0 gobject-2.0)
endif

# Icons are rasterized with librsvg when its headers are around;
# without them canvas-cairo-svg and canvas-cairo-svg-picture signal
# that the module was built without.
HAVE_RSVG := $(shell pkg-config --exists librsvg-2.0 && echo yes)
ifeq ($(HAVE_RSVG),yes)
PKG_CFLAGS += -DHAVE_RSVG $(shell pkg-config --cflags librsvg-2.0)
PKG_LIBS   += $(shell pkg-config --libs librsvg-2.0)
endif

# JPEG, GIF and the other formats gdk-pixbuf knows are decoded with it
# when its headers are around; without them canvas-cairo-image reads
# PNG only and says so.
HAVE_PIXBUF := $(shell pkg-config --exists gdk-pixbuf-2.0 && echo yes)
ifeq ($(HAVE_PIXBUF),yes)
PKG_CFLAGS += -DHAVE_PIXBUF $(shell pkg-config --cflags gdk-pixbuf-2.0)
PKG_LIBS   += $(shell pkg-config --libs gdk-pixbuf-2.0)
endif

INCLUDES    = -I/usr/local/include $(PKG_CFLAGS)
LIBS        = $(PKG_LIBS)

.PHONY: all clean test deps-local

all: $(MODULE)

$(MODULE): $(SRC)
	$(CC) $(CFLAGS) $(INCLUDES) -shared -o $@ $< $(LIBS)

test: $(MODULE)
	$(EMACS) -Q --batch -L . -L $(KEYS) -L tests \
	  -l tests/canvas-diagram-tests.el \
	  -l tests/canvas-palette-tests.el \
	  -l tests/canvas-diagram-reader-tests.el \
	  --eval '(ert-run-tests-batch-and-exit)'

# Headers without root: fetch the -dev package and unpack it here.
deps-local:
	mkdir -p .debs include lib
	cd .debs && apt-get download libpango1.0-dev
	for d in .debs/*.deb; do dpkg-deb -x $$d .debs/root; done
	cp -r .debs/root/usr/include/pango-1.0 include/
	ln -sf /lib/$$(uname -m)-linux-gnu/libpango-1.0.so.0 lib/libpango-1.0.so
	ln -sf /lib/$$(uname -m)-linux-gnu/libpangocairo-1.0.so.0 lib/libpangocairo-1.0.so
	@echo "headers in ./include, link stubs in ./lib -- now run: make"

clean:
	rm -f $(MODULE) *.elc tests/*.elc
