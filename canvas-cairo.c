/* canvas-cairo.c -- cairo and pango drawing into an Emacs 32 canvas.

   Copyright (C) 2026 Ronny Randen

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   A canvas image is a bare ARGB32 pixel buffer: Emacs exposes it to
   modules through env->canvas_data but draws nothing into it itself.
   This module lays a cairo image surface over that buffer, so paths,
   fills, strokes and pango-set text land straight in the pixels Emacs
   will show.  canvas-cairo-flush then asks Emacs to redisplay them.

   A context is a user-ptr wrapping the surface.  Every operation first
   re-reads the canvas's buffer pointer and size: the buffer moves when
   the spec's :data-width or :data-height change, and a stale surface
   would write past the old one.  A resize resets the drawing state.

   cairo's ARGB32 is premultiplied, native-endian -- the same layout
   Emacs uses for the canvas, since it hands the buffer to cairo too.  */

#include <emacs-module.h>
#include <cairo.h>
#include <cairo-pdf.h>
#include <cairo-svg.h>
#include <pango/pangocairo.h>
#ifdef HAVE_RSVG
#include <librsvg/rsvg.h>
#endif
#ifdef HAVE_PIXBUF
#include <gdk-pixbuf/gdk-pixbuf.h>
#endif
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

int plugin_is_GPL_compatible;

struct ctx
{
  emacs_value canvas;        /* Global ref to the image spec.  */
  uint32_t *data;            /* Pixel buffer the surface sits on.  */
  int width, height;
  cairo_surface_t *surface;
  cairo_t *cr;
  PangoLayout *layout;
  PangoAttrList *plain_attrs; /* What plain text is set with: no hyphens.  */
  char *font;                /* Description the layout currently uses.  */
  bool dead;                 /* Destroyed: refuse every operation.  */
  bool file;                 /* Draws into an SVG or PDF file, not a canvas.  */
};

typedef emacs_value (*efun) (emacs_env *, ptrdiff_t, emacs_value *, void *);

/* --- Lisp plumbing --- */

static emacs_value
intern (emacs_env *env, const char *name)
{
  return env->intern (env, name);
}

static emacs_value
nil (emacs_env *env)
{
  return intern (env, "nil");
}

static bool
ok (emacs_env *env)
{
  return env->non_local_exit_check (env) == emacs_funcall_exit_return;
}

static emacs_value
call (emacs_env *env, const char *fn, ptrdiff_t n, emacs_value *args)
{
  return env->funcall (env, intern (env, fn), n, args);
}

static void
signal_error (emacs_env *env, const char *fmt, ...)
{
  char msg[512];
  va_list ap;
  va_start (ap, fmt);
  vsnprintf (msg, sizeof msg, fmt, ap);
  va_end (ap);
  emacs_value s = env->make_string (env, msg, (ptrdiff_t) strlen (msg));
  emacs_value data = call (env, "list", 1, &s);
  env->non_local_exit_signal (env, intern (env, "error"), data);
}

static void
signal_wrong_type (emacs_env *env, const char *predicate, emacs_value v)
{
  emacs_value args[] = { intern (env, predicate), v };
  emacs_value data = call (env, "list", 2, args);
  env->non_local_exit_signal (env, intern (env, "wrong-type-argument"), data);
}

static bool
is_type (emacs_env *env, emacs_value v, const char *type)
{
  return env->eq (env, env->type_of (env, v), intern (env, type));
}

/* V as a double; integers and floats both count.  */
static double
num (emacs_env *env, emacs_value v)
{
  if (is_type (env, v, "integer"))
    return (double) env->extract_integer (env, v);
  if (is_type (env, v, "float"))
    return env->extract_float (env, v);
  signal_wrong_type (env, "numberp", v);
  return 0;
}

/* The N numbers at ARGS into OUT.  False after signalling.  */
static bool
nums (emacs_env *env, emacs_value *args, int n, double *out)
{
  for (int i = 0; i < n; i++)
    {
      out[i] = num (env, args[i]);
      if (!ok (env))
        return false;
    }
  return true;
}

/* malloc'ed copy of string V; NULL after signalling.  */
static char *
string (emacs_env *env, emacs_value v)
{
  if (!is_type (env, v, "string"))
    {
      signal_wrong_type (env, "stringp", v);
      return NULL;
    }
  ptrdiff_t n = 0;
  env->copy_string_contents (env, v, NULL, &n);
  char *s = malloc ((size_t) n);
  if (!s)
    {
      signal_error (env, "canvas-cairo: out of memory");
      return NULL;
    }
  env->copy_string_contents (env, v, s, &n);
  return s;
}

static emacs_value
size_pair (emacs_env *env, int w, int h)
{
  emacs_value args[] = { env->make_integer (env, w), env->make_integer (env, h) };
  return call (env, "cons", 2, args);
}

/* CANVAS's KEY property, which must be an integer.  */
static int
spec_dim (emacs_env *env, emacs_value canvas, const char *key)
{
  emacs_value plist = call (env, "cdr", 1, &canvas);
  emacs_value args[] = { plist, intern (env, key) };
  emacs_value v = call (env, "plist-get", 2, args);
  if (!ok (env))
    return 0;
  if (!is_type (env, v, "integer"))
    {
      signal_error (env, "canvas-cairo: %s of the canvas is not an integer", key);
      return 0;
    }
  return (int) env->extract_integer (env, v);
}

/* A wrapped identifier, pattern_2d_go say, is not a word to hyphenate.  */
static void
no_hyphens (PangoAttrList *attrs)
{
#if PANGO_VERSION_CHECK (1, 44, 0)
  pango_attr_list_insert (attrs, pango_attr_insert_hyphens_new (FALSE));
#else
  (void) attrs;
#endif
}

/* --- The surface over the canvas --- */

static void
drop_surface (struct ctx *c)
{
  if (c->layout)
    g_object_unref (c->layout);
  if (c->plain_attrs)
    pango_attr_list_unref (c->plain_attrs);
  if (c->cr)
    cairo_destroy (c->cr);
  if (c->surface && c->file)
    cairo_surface_finish (c->surface);
  if (c->surface)
    cairo_surface_destroy (c->surface);
  c->layout = NULL;
  c->plain_attrs = NULL;
  c->cr = NULL;
  c->surface = NULL;
  free (c->font);
  c->font = NULL;
}

static bool
cairo_ok (emacs_env *env, struct ctx *c)
{
  cairo_status_t status = cairo_status (c->cr);
  if (status == CAIRO_STATUS_SUCCESS)
    return true;
  signal_error (env, "canvas-cairo: %s", cairo_status_to_string (status));
  return false;
}

/* Finish making C over the SURFACE it was just given, W by H.  */
static bool
take_surface (emacs_env *env, struct ctx *c, cairo_surface_t *surface, int w, int h)
{
  c->width = w;
  c->height = h;
  c->surface = surface;
  c->cr = cairo_create (c->surface);
  c->layout = pango_cairo_create_layout (c->cr);
  c->plain_attrs = pango_attr_list_new ();
  no_hyphens (c->plain_attrs);
  pango_layout_set_attributes (c->layout, c->plain_attrs);
  return cairo_ok (env, c);
}

static bool
make_surface (emacs_env *env, struct ctx *c, uint32_t *data, int w, int h)
{
  drop_surface (c);
  c->data = data;
  return take_surface (env, c,
                       cairo_image_surface_create_for_data ((unsigned char *) data,
                                                            CAIRO_FORMAT_ARGB32,
                                                            w, h, w * 4),
                       w, h);
}

/* Whether FILE ends in EXT, whatever the case.  */
static bool
has_ext (const char *file, const char *ext)
{
  size_t n = strlen (file), m = strlen (ext);
  return n >= m && strcasecmp (file + n - m, ext) == 0;
}

/* A surface writing FILE, an SVG or a PDF by its name, W by H points;
   NULL after signalling for another name.  */
static cairo_surface_t *
file_surface (emacs_env *env, const char *file, double w, double h)
{
  if (has_ext (file, ".svg"))
    {
      /* SVG 1.1 is what every viewer reads.  */
      cairo_surface_t *s = cairo_svg_surface_create (file, w, h);
      cairo_svg_surface_restrict_to_version (s, CAIRO_SVG_VERSION_1_1);
      return s;
    }
  if (has_ext (file, ".pdf"))
    return cairo_pdf_surface_create (file, w, h);
  signal_error (env, "canvas-cairo: %s is neither .svg nor .pdf", file);
  return NULL;
}

/* Point the surface at the canvas's current buffer.  (Not `sync':
   unistd.h, which gio drags in, has that name.)  */
static bool
sync_surface (emacs_env *env, struct ctx *c)
{
  if (c->file)
    return true;
  uint32_t *data = env->canvas_data (env, c->canvas);
  if (!ok (env))
    return false;
  int w = spec_dim (env, c->canvas, ":data-width");
  int h = spec_dim (env, c->canvas, ":data-height");
  if (!ok (env))
    return false;
  if (data == c->data && w == c->width && h == c->height)
    return true;
  return make_surface (env, c, data, w, h);
}

static void finalize (void *p);

static struct ctx *
raw_ctx (emacs_env *env, emacs_value v)
{
  if (!is_type (env, v, "user-ptr")
      || env->get_user_finalizer (env, v) != finalize)
    {
      signal_wrong_type (env, "canvas-cairo-context-p", v);
      return NULL;
    }
  return env->get_user_ptr (env, v);
}

/* The live, synced context V holds; NULL after signalling.  */
static struct ctx *
ctx_of (emacs_env *env, emacs_value v)
{
  struct ctx *c = raw_ctx (env, v);
  if (!c)
    return NULL;
  if (c->dead)
    {
      signal_error (env, "canvas-cairo: context has been destroyed");
      return NULL;
    }
  return sync_surface (env, c) ? c : NULL;
}

static emacs_value
done (emacs_env *env, struct ctx *c)
{
  cairo_ok (env, c);
  return nil (env);
}

static void
finalize (void *p)
{
  struct ctx *c = p;
  drop_surface (c);
  /* A context never destroyed keeps its global ref to the canvas: a
     finalizer has no environment to release it with.  */
  free (c);
}

/* --- Contexts --- */

static emacs_value
Fcontext (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  emacs_value canvas = args[0];
  uint32_t *data = env->canvas_data (env, canvas);
  if (!ok (env))
    return nil (env);
  int w = spec_dim (env, canvas, ":data-width");
  int h = spec_dim (env, canvas, ":data-height");
  if (!ok (env))
    return nil (env);
  struct ctx *c = calloc (1, sizeof *c);
  if (!c)
    {
      signal_error (env, "canvas-cairo: out of memory");
      return nil (env);
    }
  c->canvas = env->make_global_ref (env, canvas);
  if (!make_surface (env, c, data, w, h))
    {
      env->free_global_ref (env, c->canvas);
      finalize (c);
      return nil (env);
    }
  return env->make_user_ptr (env, finalize, c);
}

static emacs_value
Ffile_context (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  char *file = string (env, args[0]);
  if (!file)
    return nil (env);
  double size[2];
  if (!nums (env, args + 1, 2, size) || size[0] <= 0 || size[1] <= 0)
    {
      if (ok (env))
        signal_error (env, "canvas-cairo: a file context needs a width and a height above 0");
      free (file);
      return nil (env);
    }
  cairo_surface_t *surface = file_surface (env, file, size[0], size[1]);
  free (file);
  if (!surface)
    return nil (env);
  struct ctx *c = calloc (1, sizeof *c);
  if (!c)
    {
      cairo_surface_destroy (surface);
      signal_error (env, "canvas-cairo: out of memory");
      return nil (env);
    }
  c->file = true;
  if (!take_surface (env, c, surface, (int) ceil (size[0]), (int) ceil (size[1])))
    {
      finalize (c);
      return nil (env);
    }
  return env->make_user_ptr (env, finalize, c);
}

static emacs_value
Fdestroy (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  struct ctx *c = raw_ctx (env, args[0]);
  if (!c || c->dead)
    return nil (env);
  drop_surface (c);
  if (!c->file)
    env->free_global_ref (env, c->canvas);
  c->dead = true;
  return nil (env);
}

/* C when it has pixels to read; NULL after signalling for a file context.  */
static struct ctx *
pixel_ctx (emacs_env *env, emacs_value v)
{
  struct ctx *c = ctx_of (env, v);
  if (c && c->file)
    {
      signal_error (env, "canvas-cairo: a file context has no pixels to read");
      return NULL;
    }
  return c;
}

/* --- Drawing --- */

/* An operation taking a context and N numbers.  */
#define OP(NAME, N, BODY)                                               \
  static emacs_value                                                    \
  NAME (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)    \
  {                                                                     \
    (void) nargs; (void) d;                                             \
    struct ctx *c = ctx_of (env, args[0]);                              \
    if (!c)                                                             \
      return nil (env);                                                 \
    double a[N > 0 ? N : 1];                                            \
    (void) a;                                                           \
    if (!nums (env, args + 1, N, a))                                    \
      return nil (env);                                                 \
    BODY;                                                               \
    return done (env, c);                                               \
  }

OP (Fset_color, 4, cairo_set_source_rgba (c->cr, a[0], a[1], a[2], a[3]))
OP (Fset_line_width, 1, cairo_set_line_width (c->cr, a[0]))

/* Whether the dash VALUE, named WHAT in the error, is finite.  False
   after signalling.  */
static bool
dash_number_finite (emacs_env *env, const char *what, double value)
{
  if (isfinite (value))
    return true;
  signal_error (env, "canvas-cairo: dash %s %g is not finite", what, value);
  return false;
}

/* The lengths in the vector V as a malloc'ed array, their count in *N.
   NULL after signalling.  */
static double *
dash_lengths (emacs_env *env, emacs_value v, int *n)
{
  if (!is_type (env, v, "vector"))
    {
      signal_wrong_type (env, "vectorp", v);
      return NULL;
    }
  ptrdiff_t size = env->vec_size (env, v);
  double *lengths = malloc (sizeof (double) * (size_t) (size > 0 ? size : 1));
  if (!lengths)
    {
      signal_error (env, "canvas-cairo: out of memory");
      return NULL;
    }
  double total = 0;
  for (ptrdiff_t i = 0; i < size; i++)
    {
      lengths[i] = num (env, env->vec_get (env, v, i));
      if (!ok (env) || !dash_number_finite (env, "length", lengths[i]))
        {
          free (lengths);
          return NULL;
        }
      if (lengths[i] < 0)
        {
          signal_error (env, "canvas-cairo: dash length %g is negative", lengths[i]);
          free (lengths);
          return NULL;
        }
      total += lengths[i];
    }
  if (size > 0 && total == 0)
    {
      signal_error (env, "canvas-cairo: dash lengths are all 0");
      free (lengths);
      return NULL;
    }
  *n = (int) size;
  return lengths;
}

static emacs_value
Fset_dash (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) d;
  struct ctx *c = ctx_of (env, args[0]);
  if (!c)
    return nil (env);
  double offset = 0;
  if (nargs > 2 && env->is_not_nil (env, args[2]))
    {
      offset = num (env, args[2]);
      if (!ok (env) || !dash_number_finite (env, "offset", offset))
        return nil (env);
    }
  int n = 0;
  double *lengths = dash_lengths (env, args[1], &n);
  if (!lengths)
    return nil (env);
  cairo_set_dash (c->cr, lengths, n, offset);
  free (lengths);
  return done (env, c);
}

/* A canvas is cleared by replacing its pixels; a file, fresh and
   written once, is painted over instead, since the SVG backend can
   only spell the SOURCE operator as compositing filters, which
   librsvg and browsers render badly or not at all.  */
OP (Fclear, 4,
    {
      cairo_save (c->cr);
      if (!c->file)
        cairo_set_operator (c->cr, CAIRO_OPERATOR_SOURCE);
      cairo_set_source_rgba (c->cr, a[0], a[1], a[2], a[3]);
      cairo_paint (c->cr);
      cairo_restore (c->cr);
    })
OP (Fnew_path, 0, cairo_new_path (c->cr))
OP (Fmove_to, 2, cairo_move_to (c->cr, a[0], a[1]))
OP (Fline_to, 2, cairo_line_to (c->cr, a[0], a[1]))
OP (Fcurve_to, 6, cairo_curve_to (c->cr, a[0], a[1], a[2], a[3], a[4], a[5]))
OP (Farc, 5, cairo_arc (c->cr, a[0], a[1], a[2], a[3], a[4]))
OP (Frectangle, 4, cairo_rectangle (c->cr, a[0], a[1], a[2], a[3]))
OP (Fclose_path, 0, cairo_close_path (c->cr))
OP (Fclip, 0, cairo_clip (c->cr))
OP (Freset_clip, 0, cairo_reset_clip (c->cr))
OP (Fsave, 0, cairo_save (c->cr))
OP (Frestore, 0, cairo_restore (c->cr))
OP (Ftranslate, 2, cairo_translate (c->cr, a[0], a[1]))
OP (Fscale, 2, cairo_scale (c->cr, a[0], a[1]))

static emacs_value
paint_path (emacs_env *env, ptrdiff_t nargs, emacs_value *args, bool fill)
{
  struct ctx *c = ctx_of (env, args[0]);
  if (!c)
    return nil (env);
  bool preserve = nargs > 1 && env->is_not_nil (env, args[1]);
  if (fill && preserve)
    cairo_fill_preserve (c->cr);
  else if (fill)
    cairo_fill (c->cr);
  else if (preserve)
    cairo_stroke_preserve (c->cr);
  else
    cairo_stroke (c->cr);
  return done (env, c);
}

static emacs_value
Ffill (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) d;
  return paint_path (env, nargs, args, true);
}

static emacs_value
Fstroke (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) d;
  return paint_path (env, nargs, args, false);
}

/* --- Text --- */

static bool
set_font (emacs_env *env, struct ctx *c, emacs_value font)
{
  char *f = string (env, font);
  if (!f)
    return false;
  if (c->font && strcmp (c->font, f) == 0)
    {
      free (f);
      return true;
    }
  PangoFontDescription *desc = pango_font_description_from_string (f);
  pango_layout_set_font_description (c->layout, desc);
  pango_font_description_free (desc);
  free (c->font);
  c->font = f;
  return true;
}

/* Wrap the layout at WIDTH pixels when WIDTH is a number rather than
   NULL or nil, and bring it up to date with the surface.  */
static bool
set_width (emacs_env *env, struct ctx *c, emacs_value width)
{
  int w = -1;
  if (width && env->is_not_nil (env, width))
    {
      w = (int) (num (env, width) * PANGO_SCALE);
      if (!ok (env))
        return false;
    }
  pango_layout_set_width (c->layout, w);
  pango_layout_set_wrap (c->layout, PANGO_WRAP_WORD);
  pango_cairo_update_layout (c->cr, c->layout);
  return true;
}

/* Put TEXT in FONT on the layout, plainly: whatever markup coloured
   before is let go.  */
static bool
set_layout (emacs_env *env, struct ctx *c, emacs_value text,
            emacs_value font, emacs_value width)
{
  if (!set_font (env, c, font))
    return false;
  char *t = string (env, text);
  if (!t)
    return false;
  pango_layout_set_text (c->layout, t, -1);
  pango_layout_set_attributes (c->layout, c->plain_attrs);
  free (t);
  return set_width (env, c, width);
}

/* Put MARKUP, pango markup, in FONT on the layout: its spans colour
   and style the text.  Bad markup is an error.  */
static bool
set_markup_layout (emacs_env *env, struct ctx *c, emacs_value markup,
                   emacs_value font, emacs_value width)
{
  if (!set_font (env, c, font))
    return false;
  char *m = string (env, markup);
  if (!m)
    return false;
  PangoAttrList *attrs = NULL;
  char *text = NULL;
  GError *err = NULL;
  if (!pango_parse_markup (m, -1, 0, &attrs, &text, NULL, &err))
    {
      signal_error (env, "canvas-cairo: bad markup: %s",
                    err ? err->message : "unknown");
      if (err)
        g_error_free (err);
      free (m);
      return false;
    }
  free (m);
  pango_layout_set_text (c->layout, text, -1);
  g_free (text);
  no_hyphens (attrs);
  pango_layout_set_attributes (c->layout, attrs);
  pango_attr_list_unref (attrs);
  return set_width (env, c, width);
}

static emacs_value
layout_size (emacs_env *env, struct ctx *c)
{
  int w, h;
  pango_layout_get_pixel_size (c->layout, &w, &h);
  return size_pair (env, w, h);
}

static emacs_value
Ftext_size (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) d;
  struct ctx *c = ctx_of (env, args[0]);
  if (!c)
    return nil (env);
  if (!set_layout (env, c, args[1], args[2], nargs > 3 ? args[3] : NULL))
    return nil (env);
  return layout_size (env, c);
}

static emacs_value
Ftext (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) d;
  struct ctx *c = ctx_of (env, args[0]);
  if (!c)
    return nil (env);
  double xy[2];
  if (!nums (env, args + 1, 2, xy))
    return nil (env);
  if (!set_layout (env, c, args[3], args[4], nargs > 5 ? args[5] : NULL))
    return nil (env);
  cairo_move_to (c->cr, xy[0], xy[1]);
  pango_cairo_show_layout (c->cr, c->layout);
  cairo_new_path (c->cr);
  if (!cairo_ok (env, c))
    return nil (env);
  return layout_size (env, c);
}

static emacs_value
Fmarkup_size (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) d;
  struct ctx *c = ctx_of (env, args[0]);
  if (!c)
    return nil (env);
  if (!set_markup_layout (env, c, args[1], args[2], nargs > 3 ? args[3] : NULL))
    return nil (env);
  return layout_size (env, c);
}

static emacs_value
Fmarkup (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) d;
  struct ctx *c = ctx_of (env, args[0]);
  if (!c)
    return nil (env);
  double xy[2];
  if (!nums (env, args + 1, 2, xy))
    return nil (env);
  if (!set_markup_layout (env, c, args[3], args[4], nargs > 5 ? args[5] : NULL))
    return nil (env);
  cairo_move_to (c->cr, xy[0], xy[1]);
  pango_cairo_show_layout (c->cr, c->layout);
  cairo_new_path (c->cr);
  if (!cairo_ok (env, c))
    return nil (env);
  return layout_size (env, c);
}

/* --- SVG --- */

#ifdef HAVE_RSVG
/* The SVG rendered into a fresh surface of the box's size, or NULL
   after signalling.  */
static cairo_surface_t *
svg_surface (emacs_env *env, const char *svg, double w, double h)
{
  GError *err = NULL;
  RsvgHandle *handle = rsvg_handle_new_from_data ((const guint8 *) svg, strlen (svg), &err);
  if (!handle)
    {
      signal_error (env, "canvas-cairo: svg: %s", err ? err->message : "unreadable");
      g_clear_error (&err);
      return NULL;
    }
  cairo_surface_t *surface
    = cairo_image_surface_create (CAIRO_FORMAT_ARGB32, (int) ceil (w), (int) ceil (h));
  cairo_t *cr = cairo_create (surface);
  RsvgRectangle viewport = { 0, 0, w, h };
  gboolean ok = rsvg_handle_render_document (handle, cr, &viewport, &err);
  cairo_destroy (cr);
  g_object_unref (handle);
  if (!ok)
    {
      signal_error (env, "canvas-cairo: svg: %s", err ? err->message : "not rendered");
      g_clear_error (&err);
      cairo_surface_destroy (surface);
      return NULL;
    }
  return surface;
}
#endif

/* How a rendered drawing is put onto CR with its top-left corner at X Y.  */
typedef void (*svg_painter) (cairo_t *cr, cairo_surface_t *drawing, double x, double y);

/* The current colour, painted through the drawing's alpha: the icon
   takes whatever colour the text has, whatever colour it was drawn in.  */
static void
paint_through_mask (cairo_t *cr, cairo_surface_t *drawing, double x, double y)
{
  cairo_mask_surface (cr, drawing, x, y);
}

static void
paint_own_colours (cairo_t *cr, cairo_surface_t *drawing, double x, double y)
{
  cairo_save (cr);
  cairo_set_source_surface (cr, drawing, x, y);
  cairo_paint (cr);
  cairo_restore (cr);
}

/* Paint the SVG data of ARGS, CTX SVG X Y W H, into its box with PAINT.  */
static emacs_value
paint_svg (emacs_env *env, emacs_value *args, svg_painter paint)
{
  struct ctx *c = ctx_of (env, args[0]);
  if (!c)
    return nil (env);
#ifndef HAVE_RSVG
  (void) paint;
  signal_error (env, "canvas-cairo: built without librsvg, so no SVG");
  return nil (env);
#else
  char *svg = string (env, args[1]);
  if (!svg)
    return nil (env);
  double a[4];
  if (!nums (env, args + 2, 4, a))
    {
      free (svg);
      return nil (env);
    }
  if (a[2] <= 0 || a[3] <= 0)
    {
      free (svg);
      signal_error (env, "canvas-cairo: svg box %gx%g is empty", a[2], a[3]);
      return nil (env);
    }
  cairo_surface_t *drawing = svg_surface (env, svg, a[2], a[3]);
  free (svg);
  if (!drawing)
    return nil (env);
  paint (c->cr, drawing, a[0], a[1]);
  cairo_surface_destroy (drawing);
  return done (env, c);
#endif
}

static emacs_value
Fsvg (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  return paint_svg (env, args, paint_through_mask);
}

static emacs_value
Fsvg_picture (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  return paint_svg (env, args, paint_own_colours);
}

/* --- Images --- */

/* The PNG in FILE as a surface, or NULL after signalling.  */
static cairo_surface_t *
png_surface (emacs_env *env, const char *file)
{
  cairo_surface_t *s = cairo_image_surface_create_from_png (file);
  cairo_status_t status = cairo_surface_status (s);
  if (status != CAIRO_STATUS_SUCCESS)
    {
      signal_error (env, "canvas-cairo: image: %s: %s", file,
                    cairo_status_to_string (status));
      cairo_surface_destroy (s);
      return NULL;
    }
  return s;
}

/* True when FILE starts with the PNG signature.  */
static bool
png_file_p (const char *file)
{
  static const unsigned char sig[8]
    = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
  unsigned char head[8];
  FILE *f = fopen (file, "rb");
  if (!f)
    return false;
  size_t n = fread (head, 1, sizeof head, f);
  fclose (f);
  return n == sizeof head && memcmp (head, sig, sizeof head) == 0;
}

#ifdef HAVE_PIXBUF
/* PIXBUF's pixels as a premultiplied ARGB32 surface, or NULL after
   signalling.  gdk_cairo_set_source_pixbuf lives in gdk, which this
   module does not link, so the conversion is done here.  */
static cairo_surface_t *
pixbuf_surface (emacs_env *env, GdkPixbuf *pixbuf)
{
  int w = gdk_pixbuf_get_width (pixbuf);
  int h = gdk_pixbuf_get_height (pixbuf);
  int channels = gdk_pixbuf_get_n_channels (pixbuf);
  int in_stride = gdk_pixbuf_get_rowstride (pixbuf);
  const unsigned char *pixels = gdk_pixbuf_get_pixels (pixbuf);
  cairo_surface_t *surface
    = cairo_image_surface_create (CAIRO_FORMAT_ARGB32, w, h);
  if (cairo_surface_status (surface) != CAIRO_STATUS_SUCCESS)
    {
      signal_error (env, "canvas-cairo: image: no surface for %dx%d", w, h);
      cairo_surface_destroy (surface);
      return NULL;
    }
  uint32_t *out = (uint32_t *) cairo_image_surface_get_data (surface);
  int out_stride = cairo_image_surface_get_stride (surface) / 4;
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++)
      {
        const unsigned char *p = pixels + y * in_stride + x * channels;
        uint32_t a = channels == 4 ? p[3] : 255;
        uint32_t r = (uint32_t) p[0] * a / 255;
        uint32_t g = (uint32_t) p[1] * a / 255;
        uint32_t b = (uint32_t) p[2] * a / 255;
        out[y * out_stride + x] = (a << 24) | (r << 16) | (g << 8) | b;
      }
  cairo_surface_mark_dirty (surface);
  return surface;
}
#endif

/* The image in FILE as a surface, or NULL after signalling.  */
static cairo_surface_t *
image_surface (emacs_env *env, const char *file)
{
  if (png_file_p (file))
    return png_surface (env, file);
#ifdef HAVE_PIXBUF
  GError *err = NULL;
  GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file (file, &err);
  if (!pixbuf)
    {
      signal_error (env, "canvas-cairo: image: %s: %s", file,
                    err ? err->message : "unreadable");
      g_clear_error (&err);
      return NULL;
    }
  cairo_surface_t *surface = pixbuf_surface (env, pixbuf);
  g_object_unref (pixbuf);
  return surface;
#else
  signal_error (env, "canvas-cairo: image: %s is not a PNG, and the module "
                "was built without gdk-pixbuf", file);
  return NULL;
#endif
}

static emacs_value
Fimage (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  struct ctx *c = ctx_of (env, args[0]);
  if (!c)
    return nil (env);
  char *file = string (env, args[1]);
  if (!file)
    return nil (env);
  double a[4];
  if (!nums (env, args + 2, 4, a))
    {
      free (file);
      return nil (env);
    }
  if (a[2] <= 0 || a[3] <= 0)
    {
      free (file);
      signal_error (env, "canvas-cairo: image box %gx%g is empty", a[2], a[3]);
      return nil (env);
    }
  cairo_surface_t *image = image_surface (env, file);
  free (file);
  if (!image)
    return nil (env);
  int iw = cairo_image_surface_get_width (image);
  int ih = cairo_image_surface_get_height (image);
  if (iw <= 0 || ih <= 0)
    {
      cairo_surface_destroy (image);
      signal_error (env, "canvas-cairo: image: no pixels");
      return nil (env);
    }
  cairo_save (c->cr);
  cairo_translate (c->cr, a[0], a[1]);
  cairo_scale (c->cr, a[2] / iw, a[3] / ih);
  cairo_set_source_surface (c->cr, image, 0, 0);
  cairo_pattern_set_filter (cairo_get_source (c->cr), CAIRO_FILTER_GOOD);
  cairo_rectangle (c->cr, 0, 0, iw, ih);
  cairo_fill (c->cr);
  cairo_restore (c->cr);
  cairo_surface_destroy (image);
  return done (env, c);
}

/* --- Pixels --- */

static emacs_value
Fpixel (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  struct ctx *c = pixel_ctx (env, args[0]);
  if (!c)
    return nil (env);
  double a[2];
  if (!nums (env, args + 1, 2, a))
    return nil (env);
  int x = (int) a[0], y = (int) a[1];
  if (a[0] < 0 || a[1] < 0 || x >= c->width || y >= c->height)
    {
      signal_error (env, "canvas-cairo: pixel (%d, %d) is outside the %dx%d canvas",
                    x, y, c->width, c->height);
      return nil (env);
    }
  cairo_surface_flush (c->surface);
  return env->make_integer (env, (intmax_t) c->data[(size_t) y * c->width + x]);
}

static emacs_value
Fpixels (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  struct ctx *c = pixel_ctx (env, args[0]);
  if (!c)
    return nil (env);
  double a[4];
  if (!nums (env, args + 1, 4, a))
    return nil (env);
  int x = (int) a[0], y = (int) a[1], w = (int) a[2], h = (int) a[3];
  if (a[0] < 0 || a[1] < 0 || w < 0 || h < 0
      || x + w > c->width || y + h > c->height)
    {
      signal_error (env, "canvas-cairo: %dx%d at (%d, %d) is outside the %dx%d canvas",
                    w, h, x, y, c->width, c->height);
      return nil (env);
    }
  cairo_surface_flush (c->surface);
  emacs_value mv[] = { env->make_integer (env, (intmax_t) w * h),
                       env->make_integer (env, 0) };
  emacs_value vec = call (env, "make-vector", 2, mv);
  if (!ok (env))
    return nil (env);
  for (int j = 0; j < h; j++)
    for (int i = 0; i < w; i++)
      {
        uint32_t px = c->data[(size_t) (y + j) * c->width + x + i];
        env->vec_set (env, vec, (ptrdiff_t) j * w + i,
                      env->make_integer (env, (intmax_t) px));
      }
  return vec;
}

static emacs_value
Fflush (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  struct ctx *c = ctx_of (env, args[0]);
  if (!c)
    return nil (env);
  cairo_surface_flush (c->surface);
  if (!cairo_ok (env, c))
    return nil (env);
  if (!c->file)
    call (env, "canvas-refresh", 1, &c->canvas);
  return nil (env);
}

static emacs_value
Fwrite_png (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) d;
  struct ctx *c = pixel_ctx (env, args[0]);
  if (!c)
    return nil (env);
  char *file = string (env, args[1]);
  if (!file)
    return nil (env);
  cairo_surface_flush (c->surface);
  cairo_status_t status = cairo_surface_write_to_png (c->surface, file);
  if (status != CAIRO_STATUS_SUCCESS)
    signal_error (env, "canvas-cairo: writing %s: %s", file,
                  cairo_status_to_string (status));
  free (file);
  return nil (env);
}

static emacs_value
Fversion (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *d)
{
  (void) nargs; (void) args; (void) d;
  char buf[128];
  snprintf (buf, sizeof buf, "cairo %s, pango %s",
            cairo_version_string (), pango_version_string ());
  return env->make_string (env, buf, (ptrdiff_t) strlen (buf));
}

/* --- Registration --- */

static void
defun (emacs_env *env, const char *name, ptrdiff_t min, ptrdiff_t max,
       efun fn, const char *doc)
{
  emacs_value args[] = { intern (env, name),
                         env->make_function (env, min, max, fn, doc, NULL) };
  call (env, "defalias", 2, args);
}

int
emacs_module_init (struct emacs_runtime *rt)
{
  if ((size_t) rt->size < sizeof (*rt))
    return 1;
  emacs_env *env = rt->get_environment (rt);
  if ((size_t) env->size < sizeof (struct emacs_env_32))
    return 2;

  defun (env, "canvas-cairo-context", 1, 1, Fcontext,
         "Return a drawing context on CANVAS, a canvas image spec.\n"
         "The context keeps CANVAS alive until `canvas-cairo-destroy'.\n\n(fn CANVAS)");
  defun (env, "canvas-cairo-file-context", 3, 3, Ffile_context,
         "Return a drawing context writing FILE, an SVG or a PDF by its name, W by H.\n"
         "The file is complete once the context is destroyed; its pixels cannot be read.\n\n"
         "(fn FILE W H)");
  defun (env, "canvas-cairo-destroy", 1, 1, Fdestroy,
         "Release CTX; drawing on it afterwards is an error.\n\n(fn CTX)");
  defun (env, "canvas-cairo-clear", 5, 5, Fclear,
         "Paint the whole canvas, within the clip, with R G B A.\n\n(fn CTX R G B A)");
  defun (env, "canvas-cairo-set-color", 5, 5, Fset_color,
         "Use R G B A, each 0 to 1, for later fills, strokes and text.\n\n(fn CTX R G B A)");
  defun (env, "canvas-cairo-set-line-width", 2, 2, Fset_line_width,
         "Stroke later paths WIDTH pixels wide.\n\n(fn CTX WIDTH)");
  defun (env, "canvas-cairo-set-dash", 2, 3, Fset_dash,
         "Stroke later paths dashed: DASHES is a vector of on and off lengths\n"
         "in pixels, [] for solid lines.  OFFSET, 0 by default, is where in\n"
         "the pattern a stroke starts.\n\n(fn CTX DASHES &optional OFFSET)");
  defun (env, "canvas-cairo-new-path", 1, 1, Fnew_path,
         "Forget the current path.\n\n(fn CTX)");
  defun (env, "canvas-cairo-move-to", 3, 3, Fmove_to,
         "Start a sub-path at X Y.\n\n(fn CTX X Y)");
  defun (env, "canvas-cairo-line-to", 3, 3, Fline_to,
         "Add a line to X Y.\n\n(fn CTX X Y)");
  defun (env, "canvas-cairo-curve-to", 7, 7, Fcurve_to,
         "Add a cubic Bezier through control points X1 Y1, X2 Y2 to X3 Y3.\n\n"
         "(fn CTX X1 Y1 X2 Y2 X3 Y3)");
  defun (env, "canvas-cairo-arc", 6, 6, Farc,
         "Add an arc of RADIUS around XC YC from ANGLE1 to ANGLE2, in radians.\n\n"
         "(fn CTX XC YC RADIUS ANGLE1 ANGLE2)");
  defun (env, "canvas-cairo-rectangle", 5, 5, Frectangle,
         "Add a closed rectangle at X Y of size W H.\n\n(fn CTX X Y W H)");
  defun (env, "canvas-cairo-close-path", 1, 1, Fclose_path,
         "Close the current sub-path.\n\n(fn CTX)");
  defun (env, "canvas-cairo-fill", 1, 2, Ffill,
         "Fill the current path; keep it if PRESERVE is non-nil.\n\n(fn CTX &optional PRESERVE)");
  defun (env, "canvas-cairo-stroke", 1, 2, Fstroke,
         "Stroke the current path; keep it if PRESERVE is non-nil.\n\n(fn CTX &optional PRESERVE)");
  defun (env, "canvas-cairo-clip", 1, 1, Fclip,
         "Restrict later drawing to the current path.\n\n(fn CTX)");
  defun (env, "canvas-cairo-reset-clip", 1, 1, Freset_clip,
         "Lift the clip.\n\n(fn CTX)");
  defun (env, "canvas-cairo-save", 1, 1, Fsave,
         "Push the drawing state: colour, line width, clip, transform.\n\n(fn CTX)");
  defun (env, "canvas-cairo-restore", 1, 1, Frestore,
         "Pop the drawing state pushed by `canvas-cairo-save'.\n\n(fn CTX)");
  defun (env, "canvas-cairo-translate", 3, 3, Ftranslate,
         "Move the origin by X Y.\n\n(fn CTX X Y)");
  defun (env, "canvas-cairo-scale", 3, 3, Fscale,
         "Scale later coordinates by SX SY.\n\n(fn CTX SX SY)");
  defun (env, "canvas-cairo-text", 5, 6, Ftext,
         "Draw TEXT with its top-left corner at X Y in FONT, a pango\n"
         "description such as \"Noto Sans 14px\".  Wrap at WIDTH pixels when\n"
         "given.  Return the text's (WIDTH . HEIGHT).\n\n"
         "(fn CTX X Y TEXT FONT &optional WIDTH)");
  defun (env, "canvas-cairo-text-size", 3, 4, Ftext_size,
         "Return the (WIDTH . HEIGHT) TEXT takes in FONT, wrapped at WIDTH.\n\n"
         "(fn CTX TEXT FONT &optional WIDTH)");
  defun (env, "canvas-cairo-markup", 5, 6, Fmarkup,
         "Draw MARKUP, pango markup such as <span foreground=\"#ff0000\">red</span>,\n"
         "with its top-left corner at X Y in FONT, wrapped at WIDTH pixels when\n"
         "given; the current colour serves where the markup sets none.  Escape\n"
         "&, < and > in the text.  Return the text's (WIDTH . HEIGHT).\n\n"
         "(fn CTX X Y MARKUP FONT &optional WIDTH)");
  defun (env, "canvas-cairo-markup-size", 3, 4, Fmarkup_size,
         "Return the (WIDTH . HEIGHT) MARKUP takes in FONT, wrapped at WIDTH.\n\n"
         "(fn CTX MARKUP FONT &optional WIDTH)");
  defun (env, "canvas-cairo-svg", 6, 6, Fsvg,
         "Paint SVG, a string of SVG data, into the W by H box at X Y in the\n"
         "current colour: the drawing serves as a mask, its own colours are\n"
         "not used.\n\n(fn CTX SVG X Y W H)");
  defun (env, "canvas-cairo-svg-picture", 6, 6, Fsvg_picture,
         "Paint SVG, a string of SVG data, into the W by H box at X Y in its\n"
         "own colours: the drawing as it was drawn, the current colour not\n"
         "used.\n\n(fn CTX SVG X Y W H)");
  defun (env, "canvas-cairo-image", 6, 6, Fimage,
         "Paint the image in FILE into the W by H box at X Y, scaled to fill it.\n\n"
         "(fn CTX FILE X Y W H)");
  defun (env, "canvas-cairo-pixel", 3, 3, Fpixel,
         "Return the ARGB32 value of the pixel at X Y.\n\n(fn CTX X Y)");
  defun (env, "canvas-cairo-pixels", 5, 5, Fpixels,
         "Return the ARGB32 values of the W by H region at X Y as a vector, row by row.\n\n"
         "(fn CTX X Y W H)");
  defun (env, "canvas-cairo-flush", 1, 1, Fflush,
         "Finish drawing and have Emacs redisplay the canvas.\n\n(fn CTX)");
  defun (env, "canvas-cairo-write-png", 2, 2, Fwrite_png,
         "Write the canvas's pixels to FILE as a PNG.\n\n(fn CTX FILE)");
  defun (env, "canvas-cairo-version", 0, 0, Fversion,
         "Return the cairo and pango versions in use.");

  emacs_value feature = intern (env, "canvas-cairo");
  call (env, "provide", 1, &feature);
  return 0;
}
