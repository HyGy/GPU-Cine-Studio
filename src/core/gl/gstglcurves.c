/* GPU Cine Studio - "gcccurves": GPU tonal-curves colour grading filter.
 *
 * A GstGLFilter subclass, sibling to gcclut3d (see gstgllut3d.c - this
 * file deliberately copies its GL/shader-dialect boilerplate verbatim
 * where noted, since that plumbing is already debugged there). Instead
 * of a 3D LUT loaded from a file, this element owns a compact textual
 * curve description (up to 4 channels: a combined "master" RGB curve
 * plus independent R/G/B curves, Photoshop-style), interpolates each
 * with a monotone cubic Hermite spline (Fritsch-Carlson limiter - see
 * pchip_eval() below), bakes the composed result into a 256x1 2D
 * texture (one row, RGB - each channel's own lookup reads a different
 * component), and samples it per pixel. Chosen over gcclut3d's 3D-LUT
 * approach for this effect specifically because a per-channel 1D curve
 * only has 256*3 meaningful values - a 3D cube would need N^3 texels to
 * carry 3*N of them, and large-enough-to-be-smooth N (64+) makes a
 * live-dragged .cube file reparse far too slow for interactive preview.
 * A plain string property + in-memory table avoids file I/O entirely.
 */

#include "gstglcurves.h"

#include <gst/gl/gstglfuncs.h>
#include <gst/gl/gstglshaderstrings.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

GST_DEBUG_CATEGORY_STATIC (gst_gl_curves_debug);
#define GST_CAT_DEFAULT gst_gl_curves_debug

#define CURVE_TABLE_SIZE 256
/* Hard ceiling on control points per channel - generous (the old
 * frei0r-based plan capped at 5; this is just a sanity bound against a
 * malformed/huge property string, not a UX-visible limit). */
#define CURVE_MAX_POINTS 64

enum
{
  PROP_0,
  PROP_CURVE_POINTS,
  PROP_INTENSITY,
};

struct _GstGLCurves
{
  GstGLFilter parent;

  /* properties */
  gchar *curve_points;
  gdouble intensity;

  /* built 256x3 RGB table + dirty flag, guarded by lock (built on the
   * app thread in set_property, consumed/uploaded on the GL thread) */
  GMutex table_lock;
  gfloat table[CURVE_TABLE_SIZE * 3];
  gboolean table_dirty;

  /* GL-thread-only state */
  GstGLShader *shader;
  guint curve_tex;              /* GL_TEXTURE_2D name, 0 = none */
};

G_DEFINE_TYPE (GstGLCurves, gst_gl_curves, GST_TYPE_GL_FILTER)

/* ------------------------------------------------------------------ */
/* monotone cubic Hermite interpolation (Fritsch-Carlson)             */
/* ------------------------------------------------------------------ */

typedef struct
{
  gfloat x[CURVE_MAX_POINTS];
  gfloat y[CURVE_MAX_POINTS];
  gint n;
} Curve1D;

static void
curve1d_identity (Curve1D * c)
{
  c->n = 2;
  c->x[0] = 0.0f; c->y[0] = 0.0f;
  c->x[1] = 1.0f; c->y[1] = 1.0f;
}

/* Evaluates a monotone cubic Hermite spline through (xs,ys) (xs strictly
 * increasing, n>=2) at x, clamping x into [xs[0], xs[n-1]] first (curve
 * points are expected to span the full [0,1] domain via pinned
 * endpoints - see the QML editor - so this clamp is a defensive
 * fallback, not the normal path). Tangents use the Fritsch-Carlson
 * (1980) limiter, which provably never overshoots a monotone data
 * segment - plain Catmull-Rom can, which would locally invert contrast
 * on a tone curve. */
static gfloat
pchip_eval (const gfloat * xs, const gfloat * ys, gint n, gfloat x)
{
  gfloat h[CURVE_MAX_POINTS - 1], d[CURVE_MAX_POINTS - 1];
  gfloat m[CURVE_MAX_POINTS];
  gint k, seg;

  if (n < 2)
    return CLAMP (x, 0.0f, 1.0f);
  if (n > CURVE_MAX_POINTS)
    n = CURVE_MAX_POINTS;

  x = CLAMP (x, xs[0], xs[n - 1]);

  if (n == 2)
    return ys[0] + (ys[1] - ys[0]) * ((x - xs[0]) / (xs[1] - xs[0]));

  for (k = 0; k < n - 1; k++) {
    h[k] = xs[k + 1] - xs[k];
    d[k] = (h[k] > 1e-6f) ? (ys[k + 1] - ys[k]) / h[k] : 0.0f;
  }

  /* Endpoint tangents: one-sided 3-point estimate, monotonicity-limited
   * to never exceed (or reverse the sign of) the adjacent secant. */
  m[0] = d[0];
  m[n - 1] = d[n - 2];
  if (n > 2) {
    gfloat m0 = ((2.0f * h[0] + h[1]) * d[0] - h[0] * d[1]) / (h[0] + h[1]);
    if ((m0 > 0) != (d[0] > 0))
      m0 = 0.0f;
    else if ((d[0] > 0) != (d[1] > 0) && fabsf (m0) > 3.0f * fabsf (d[0]))
      m0 = 3.0f * d[0];
    m[0] = m0;

    gfloat mn = ((2.0f * h[n - 2] + h[n - 3]) * d[n - 2]
        - h[n - 2] * d[n - 3]) / (h[n - 2] + h[n - 3]);
    if ((mn > 0) != (d[n - 2] > 0))
      mn = 0.0f;
    else if ((d[n - 2] > 0) != (d[n - 3] > 0) &&
        fabsf (mn) > 3.0f * fabsf (d[n - 2]))
      mn = 3.0f * d[n - 2];
    m[n - 1] = mn;
  }

  /* Interior tangents: zero at a local extremum (sign change in the
   * secants), else a weighted harmonic mean of the two adjacent
   * secants, limited so the Hermite segment on neither side overshoots. */
  for (k = 1; k < n - 1; k++) {
    if (d[k - 1] == 0.0f || d[k] == 0.0f || (d[k - 1] > 0) != (d[k] > 0)) {
      m[k] = 0.0f;
      continue;
    }
    gfloat w1 = 2.0f * h[k] + h[k - 1];
    gfloat w2 = h[k] + 2.0f * h[k - 1];
    m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k]);
  }
  for (k = 0; k < n - 1; k++) {
    if (d[k] == 0.0f) {
      m[k] = 0.0f;
      m[k + 1] = 0.0f;
      continue;
    }
    gfloat alpha = m[k] / d[k];
    gfloat beta = m[k + 1] / d[k];
    gfloat sq = alpha * alpha + beta * beta;
    if (sq > 9.0f) {
      gfloat tau = 3.0f / sqrtf (sq);
      m[k] = tau * alpha * d[k];
      m[k + 1] = tau * beta * d[k];
    }
  }

  seg = n - 2;
  for (k = 0; k < n - 1; k++) {
    if (x <= xs[k + 1]) {
      seg = k;
      break;
    }
  }
  {
    gfloat t = (x - xs[seg]) / h[seg];
    gfloat t2 = t * t, t3 = t2 * t;
    gfloat h00 = 2 * t3 - 3 * t2 + 1;
    gfloat h10 = t3 - 2 * t2 + t;
    gfloat h01 = -2 * t3 + 3 * t2;
    gfloat h11 = t3 - t2;
    return h00 * ys[seg] + h10 * h[seg] * m[seg]
        + h01 * ys[seg + 1] + h11 * h[seg] * m[seg + 1];
  }
}

/* ------------------------------------------------------------------ */
/* "curve-points" string parsing                                      */
/* ------------------------------------------------------------------ */

/* Format: up to 4 channel specs separated by '|', each
 * "<letter>:<in>,<out>;<in>,<out>;...". Letter is one of m/r/g/b
 * (master/red/green/blue); an omitted channel stays identity. Example:
 * "m:0,0;1,1|r:0,0;0.25,0.18;1,1|g:0,0;1,1|b:0,0;1,1"
 * Points need not arrive pre-sorted; this parser sorts by input value
 * and drops a point whose input duplicates the previous one (ties would
 * make the spline's secant slope undefined). A channel that parses to
 * fewer than 2 usable points, or is absent, falls back to identity -
 * never a black/garbage curve from a malformed string. */
static void
parse_channel_points (const gchar * spec, Curve1D * out)
{
  gfloat xs[CURVE_MAX_POINTS], ys[CURVE_MAX_POINTS];
  gint n = 0;
  gchar **points = g_strsplit (spec, ";", -1);

  for (gint i = 0; points[i] != NULL && n < CURVE_MAX_POINTS; i++) {
    gfloat in, outv;
    if (sscanf (points[i], "%f,%f", &in, &outv) == 2) {
      xs[n] = CLAMP (in, 0.0f, 1.0f);
      ys[n] = CLAMP (outv, 0.0f, 1.0f);
      n++;
    }
  }
  g_strfreev (points);

  /* insertion sort by x (n is tiny) */
  for (gint i = 1; i < n; i++) {
    gfloat kx = xs[i], ky = ys[i];
    gint j = i - 1;
    while (j >= 0 && xs[j] > kx) {
      xs[j + 1] = xs[j]; ys[j + 1] = ys[j];
      j--;
    }
    xs[j + 1] = kx; ys[j + 1] = ky;
  }
  /* drop duplicate-x points (keep the first) */
  gint w = 0;
  for (gint i = 0; i < n; i++) {
    if (w > 0 && xs[i] - xs[w - 1] < 1e-6f)
      continue;
    xs[w] = xs[i]; ys[w] = ys[i];
    w++;
  }
  n = w;

  if (n < 2) {
    curve1d_identity (out);
    return;
  }
  out->n = n;
  memcpy (out->x, xs, n * sizeof (gfloat));
  memcpy (out->y, ys, n * sizeof (gfloat));
}

static void
parse_curve_points (const gchar * spec, Curve1D * m, Curve1D * r,
    Curve1D * g, Curve1D * b)
{
  curve1d_identity (m);
  curve1d_identity (r);
  curve1d_identity (g);
  curve1d_identity (b);
  if (!spec || !*spec)
    return;

  gchar **channels = g_strsplit (spec, "|", -1);
  for (gint i = 0; channels[i] != NULL; i++) {
    gchar *ch = channels[i];
    if (strlen (ch) < 2 || ch[1] != ':')
      continue;
    switch (ch[0]) {
      case 'm': parse_channel_points (ch + 2, m); break;
      case 'r': parse_channel_points (ch + 2, r); break;
      case 'g': parse_channel_points (ch + 2, g); break;
      case 'b': parse_channel_points (ch + 2, b); break;
      default: break;
    }
  }
  g_strfreev (channels);
}

/* Builds the composed 256x3 table: per Photoshop's own semantics, the
 * master (RGB-combined) curve is applied ON TOP OF each already
 * per-channel-curved value, not independently of it. */
static void
build_table (const gchar * spec, gfloat * table_out)
{
  Curve1D m, r, g, b;
  parse_curve_points (spec, &m, &r, &g, &b);

  for (gint i = 0; i < CURVE_TABLE_SIZE; i++) {
    gfloat x = (gfloat) i / (gfloat) (CURVE_TABLE_SIZE - 1);
    gfloat rv = pchip_eval (r.x, r.y, r.n, x);
    gfloat gv = pchip_eval (g.x, g.y, g.n, x);
    gfloat bv = pchip_eval (b.x, b.y, b.n, x);
    table_out[i * 3 + 0] = CLAMP (pchip_eval (m.x, m.y, m.n, rv), 0.0f, 1.0f);
    table_out[i * 3 + 1] = CLAMP (pchip_eval (m.x, m.y, m.n, gv), 0.0f, 1.0f);
    table_out[i * 3 + 2] = CLAMP (pchip_eval (m.x, m.y, m.n, bv), 0.0f, 1.0f);
  }
}

/* ------------------------------------------------------------------ */
/* shader - dialect-selection/vertex-stage boilerplate copied from     */
/* gstgllut3d.c's gst_gl_lut3d_build_shader(), see its comment for the */
/* "#version"/attribute-naming rationale; not re-derived here.        */
/* ------------------------------------------------------------------ */

/* "curves" (unit 0) is a single 256x1 row; each output channel samples
 * a DIFFERENT component of the SAME texel column (u.r/u.g/u.b each
 * select their own row position), so one small texture carries all
 * three per-channel curves (with the master curve already folded into
 * the table by build_table() - no separate master lookup needed here).
 * Half-texel correction is the 1D analogue of gcclut3d's: a 256-sample
 * row has its nodes at (i+0.5)/256, so input 0.0 must map to 0.5/256
 * and 1.0 to 255.5/256.
 */
static const gchar *curves_frag_body =
    "uniform sampler2D tex;\n"
    "uniform sampler2D curves;\n"
    "uniform float intensity;\n"
    "void main (void)\n"
    "{\n"
    "  vec4 src = TEX2D (tex, v_texcoord);\n"
    "  vec3 n = clamp (src.rgb, 0.0, 1.0);\n"
    "  vec3 u = (n * 255.0 + 0.5) / 256.0;\n"
    "  vec3 graded = vec3 (TEX2D (curves, vec2 (u.r, 0.5)).r,\n"
    "                      TEX2D (curves, vec2 (u.g, 0.5)).g,\n"
    "                      TEX2D (curves, vec2 (u.b, 0.5)).b);\n"
    "  fragColor = vec4 (mix (src.rgb, graded, intensity), src.a);\n"
    "}\n";

static const gchar *curves_vert_modern =
    "in vec4 a_position;\n"
    "in vec2 a_texcoord;\n"
    "out vec2 v_texcoord;\n"
    "void main (void)\n"
    "{\n"
    "  gl_Position = a_position;\n" "  v_texcoord = a_texcoord;\n" "}\n";
static const gchar *curves_vert_legacy =
    "attribute vec4 a_position;\n"
    "attribute vec2 a_texcoord;\n"
    "varying vec2 v_texcoord;\n"
    "void main (void)\n"
    "{\n"
    "  gl_Position = a_position;\n" "  v_texcoord = a_texcoord;\n" "}\n";

static const gchar *curves_frag_prologue_modern =
    "in vec2 v_texcoord;\n"
    "out vec4 fragColor;\n"
    "#define TEX2D texture\n";
static const gchar *curves_frag_prologue_legacy =
    "varying vec2 v_texcoord;\n"
    "#define fragColor gl_FragColor\n"
    "#define TEX2D texture2D\n";

static GstGLShader *
gst_gl_curves_build_shader (GstGLCurves * self, GstGLContext * context,
    GError ** error)
{
  GstGLSLVersion version;
  GstGLSLProfile profile;
  const gchar *vert_src, *frag_prologue, *version_line;
  gchar *frag, *vert;
  GstGLSLStage *vert_stage, *frag_stage;
  GstGLShader *shader;

  if (gst_gl_context_supports_glsl_profile_version (context,
          GST_GLSL_VERSION_150, GST_GLSL_PROFILE_CORE)) {
    version = GST_GLSL_VERSION_150;
    profile = GST_GLSL_PROFILE_CORE;
    version_line = "#version 150\n";
    vert_src = curves_vert_modern;
    frag_prologue = curves_frag_prologue_modern;
  } else {
    version = GST_GLSL_VERSION_120;
    profile = GST_GLSL_PROFILE_COMPATIBILITY;
    version_line = "#version 120\n";
    vert_src = curves_vert_legacy;
    frag_prologue = curves_frag_prologue_legacy;
  }

  vert = g_strconcat (version_line, vert_src, NULL);
  frag = g_strconcat (version_line, frag_prologue, curves_frag_body, NULL);

  vert_stage = gst_glsl_stage_new_with_string (context, GL_VERTEX_SHADER,
      version, profile, vert);
  frag_stage = gst_glsl_stage_new_with_string (context, GL_FRAGMENT_SHADER,
      version, profile, frag);
  g_free (vert);
  g_free (frag);

  shader = gst_gl_shader_new_link_with_stages (context, error,
      vert_stage, frag_stage, NULL);
  return shader;
}

/* ------------------------------------------------------------------ */
/* GL upload / render                                                  */
/* ------------------------------------------------------------------ */

static void
gst_gl_curves_upload_table (GstGLCurves * self, GstGLContext * context)
{
  const GstGLFuncs *gl = context->gl_vtable;
  gfloat data[CURVE_TABLE_SIZE * 3];

  g_mutex_lock (&self->table_lock);
  if (!self->table_dirty) {
    g_mutex_unlock (&self->table_lock);
    return;
  }
  self->table_dirty = FALSE;
  memcpy (data, self->table, sizeof (data));
  g_mutex_unlock (&self->table_lock);

  if (!self->curve_tex)
    gl->GenTextures (1, &self->curve_tex);
  gl->ActiveTexture (GL_TEXTURE1);
  gl->BindTexture (GL_TEXTURE_2D, self->curve_tex);
  gl->TexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  gl->TexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  gl->TexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  gl->TexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  gl->TexImage2D (GL_TEXTURE_2D, 0, GL_RGB16F, CURVE_TABLE_SIZE, 1, 0,
      GL_RGB, GL_FLOAT, data);

  GST_INFO_OBJECT (self, "uploaded %dx1 curve table as texture %u",
      CURVE_TABLE_SIZE, self->curve_tex);
}

static gboolean
gst_gl_curves_filter_texture (GstGLFilter * filter, GstGLMemory * in,
    GstGLMemory * out)
{
  GstGLCurves *self = GST_GL_CURVES (filter);
  GstGLContext *context = GST_GL_BASE_FILTER (filter)->context;
  const GstGLFuncs *gl = context->gl_vtable;
  gdouble intensity;

  /* GstBaseTransform's own automatic gst_object_sync_values() runs on the
   * STREAMING thread, synced to that thread's notion of "now" - but this
   * callback runs on the separate GL thread (GstGLBaseFilter dispatches
   * actual rendering there), which can lag behind or race ahead of the
   * streaming thread's syncs. Verified live: without this explicit
   * re-sync, a keyframed "intensity" control source was observed stuck at
   * its LAST value for every single rendered frame (including frame 0),
   * because the streaming thread had already raced through every sync
   * point before the GL thread got around to rendering anything - the
   * property only ever reflected whichever value the streaming thread
   * synced to most recently, never the value correct for THIS frame.
   * GstGLFilter's instance struct publicly exposes `inbuf` (the real
   * GstBuffer, with its own PTS) specifically for cases like this -
   * re-syncing here, on the GL thread, against the actual buffer being
   * rendered, eliminates the race regardless of what the streaming
   * thread's own sync timing happened to be.
   */
  gst_object_sync_values (GST_OBJECT (self), GST_BUFFER_PTS (filter->inbuf));

  if (!self->shader) {
    GError *err = NULL;
    self->shader = gst_gl_curves_build_shader (self, context, &err);
    if (!self->shader) {
      GST_ELEMENT_ERROR (self, RESOURCE, NOT_FOUND, (NULL),
          ("failed to compile curves shader: %s",
              err ? err->message : "unknown"));
      g_clear_error (&err);
      return FALSE;
    }
  }

  gst_gl_curves_upload_table (self, context);

  g_mutex_lock (&self->table_lock);
  intensity = self->intensity;
  g_mutex_unlock (&self->table_lock);

  if (!self->curve_tex)
    intensity = 0.0;

  gst_gl_shader_use (self->shader);

  gl->ActiveTexture (GL_TEXTURE0);
  gl->BindTexture (GL_TEXTURE_2D, self->curve_tex);
  gst_gl_shader_set_uniform_1i (self->shader, "curves", 0);
  gst_gl_shader_set_uniform_1f (self->shader, "intensity", (gfloat) intensity);

  gst_gl_filter_render_to_target_with_shader (filter, in, out, self->shader);
  return TRUE;
}

static void
gst_gl_curves_gl_stop (GstGLBaseFilter * base)
{
  GstGLCurves *self = GST_GL_CURVES (base);
  const GstGLFuncs *gl = base->context ? base->context->gl_vtable : NULL;

  if (self->curve_tex && gl) {
    gl->DeleteTextures (1, &self->curve_tex);
    self->curve_tex = 0;
  }
  if (self->shader) {
    gst_object_unref (self->shader);
    self->shader = NULL;
  }
  g_mutex_lock (&self->table_lock);
  self->table_dirty = TRUE;
  g_mutex_unlock (&self->table_lock);

  GST_GL_BASE_FILTER_CLASS (gst_gl_curves_parent_class)->gl_stop (base);
}

/* ------------------------------------------------------------------ */
/* GObject                                                             */
/* ------------------------------------------------------------------ */

static void
gst_gl_curves_set_curve_points (GstGLCurves * self, const gchar * spec)
{
  gfloat table[CURVE_TABLE_SIZE * 3];
  build_table (spec, table);

  g_mutex_lock (&self->table_lock);
  g_free (self->curve_points);
  self->curve_points = g_strdup (spec);
  memcpy (self->table, table, sizeof (table));
  self->table_dirty = TRUE;
  g_mutex_unlock (&self->table_lock);
}

static void
gst_gl_curves_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstGLCurves *self = GST_GL_CURVES (object);

  switch (prop_id) {
    case PROP_CURVE_POINTS:
      gst_gl_curves_set_curve_points (self, g_value_get_string (value));
      break;
    case PROP_INTENSITY:
      g_mutex_lock (&self->table_lock);
      self->intensity = g_value_get_double (value);
      g_mutex_unlock (&self->table_lock);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
gst_gl_curves_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstGLCurves *self = GST_GL_CURVES (object);

  switch (prop_id) {
    case PROP_CURVE_POINTS:
      g_mutex_lock (&self->table_lock);
      g_value_set_string (value, self->curve_points);
      g_mutex_unlock (&self->table_lock);
      break;
    case PROP_INTENSITY:
      g_value_set_double (value, self->intensity);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
gst_gl_curves_finalize (GObject * object)
{
  GstGLCurves *self = GST_GL_CURVES (object);

  g_free (self->curve_points);
  g_mutex_clear (&self->table_lock);
  G_OBJECT_CLASS (gst_gl_curves_parent_class)->finalize (object);
}

static void
gst_gl_curves_class_init (GstGLCurvesClass * klass)
{
  GObjectClass *gobject_class = G_OBJECT_CLASS (klass);
  GstElementClass *element_class = GST_ELEMENT_CLASS (klass);

  gobject_class->set_property = gst_gl_curves_set_property;
  gobject_class->get_property = gst_gl_curves_get_property;
  gobject_class->finalize = gst_gl_curves_finalize;

  g_object_class_install_property (gobject_class, PROP_CURVE_POINTS,
      g_param_spec_string ("curve-points", "Curve points",
          "Per-channel tonal curve control points: "
          "\"m:in,out;...|r:...|g:...|b:...\" (m=master RGB, "
          "in/out in [0,1]); an omitted channel is identity",
          "m:0,0;1,1",
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_INTENSITY,
      g_param_spec_double ("intensity", "Intensity",
          "Blend between the original (0.0) and fully graded (1.0) colour",
          0.0, 1.0, 1.0,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  gst_element_class_set_static_metadata (element_class,
      "Curves (GPU)", "Filter/Effect/Video",
      "Applies a per-channel tonal curve (monotone cubic Hermite) on the GPU",
      "GPU Cine Studio");

  GST_GL_BASE_FILTER_CLASS (klass)->gl_stop = gst_gl_curves_gl_stop;
  GST_GL_FILTER_CLASS (klass)->filter_texture = gst_gl_curves_filter_texture;

  gst_gl_filter_add_rgba_pad_templates (GST_GL_FILTER_CLASS (klass));

  /* A 2D texture has no desktop-only dependency the way gcclut3d's 3D
   * one does (glTexImage3D is absent from gst's GLES table;
   * glTexImage2D is not), so this element is not restricted to desktop
   * GL - left at the GstGLFilter default (GL|GL3|GLES2|GLES3). */
}

static void
gst_gl_curves_init (GstGLCurves * self)
{
  g_mutex_init (&self->table_lock);
  self->intensity = 1.0;
  self->curve_points = g_strdup ("m:0,0;1,1");
  build_table (self->curve_points, self->table);
  self->table_dirty = TRUE;
}

gboolean
gst_gl_curves_register (void)
{
  GST_DEBUG_CATEGORY_INIT (gst_gl_curves_debug, "gcccurves", 0,
      "GPU tonal curves");
  return gst_element_register (NULL, "gcccurves", GST_RANK_NONE,
      GST_TYPE_GL_CURVES);
}

#ifdef GCCCURVES_BUILD_STANDALONE_PLUGIN
static gboolean
plugin_init (GstPlugin * plugin)
{
  GST_DEBUG_CATEGORY_INIT (gst_gl_curves_debug, "gcccurves", 0,
      "GPU tonal curves");
  return gst_element_register (plugin, "gcccurves", GST_RANK_NONE,
      GST_TYPE_GL_CURVES);
}

GST_PLUGIN_DEFINE (GST_VERSION_MAJOR, GST_VERSION_MINOR, gcccurves,
    "GPU Cine Studio Curves", plugin_init, "1.0", "LGPL", "gpu-cine-studio",
    "https://example.invalid")
#endif
