/* GPU Cine Studio - "gcclut3d": GPU 3D LUT (.cube) colour grading filter.
 *
 * A GstGLFilter subclass. Parses an Adobe/Resolve .cube 3D LUT into a
 * GL_TEXTURE_3D and samples it per pixel with hardware trilinear
 * interpolation, blended against the original colour by "intensity".
 */

#include "gstgllut3d.h"

#include <gst/gl/gstglfuncs.h>
#include <gst/gl/gstglshaderstrings.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

GST_DEBUG_CATEGORY_STATIC (gst_gl_lut3d_debug);
#define GST_CAT_DEFAULT gst_gl_lut3d_debug

enum
{
  PROP_0,
  PROP_LUT_FILE,
  PROP_INTENSITY,
};

struct _GstGLLut3D
{
  GstGLFilter parent;

  /* properties */
  gchar *lut_file;
  gdouble intensity;

  /* parsed LUT, owned, guarded by lut_lock (set from app thread,
   * consumed on the GL thread) */
  GMutex lut_lock;
  gfloat *lut_data;             /* size^3 * 3 floats, R fastest */
  gint lut_size;
  gfloat domain_min[3];
  gfloat domain_max[3];
  gboolean lut_dirty;           /* needs (re)upload on the GL thread */

  /* GL-thread-only state */
  GstGLShader *shader;
  guint lut_tex;                /* GL_TEXTURE_3D name, 0 = none */
  gint uploaded_size;
};

G_DEFINE_TYPE (GstGLLut3D, gst_gl_lut3d, GST_TYPE_GL_FILTER)

/* ------------------------------------------------------------------ */
/* .cube parsing                                                       */
/* ------------------------------------------------------------------ */

/* Adobe Cube LUT Specification 1.0:
 *   - ASCII, one directive/triple per line
 *   - '#' starts a comment; blank lines ignored
 *   - TITLE "..."                   (ignored here)
 *   - LUT_3D_SIZE N                 (2..256; we accept 2..256)
 *   - LUT_1D_SIZE N                 (1D LUTs: rejected, not our job)
 *   - DOMAIN_MIN r g b              (default 0 0 0)
 *   - DOMAIN_MAX r g b              (default 1 1 1)
 *   - then exactly N*N*N lines of "r g b" floats, with RED varying
 *     fastest and BLUE slowest -- which is exactly GL_TEXTURE_3D's
 *     own memory order for width=R, height=G, depth=B, so the parsed
 *     array uploads with no reshuffling.
 * Values may exceed [0,1] (HDR/log LUTs); we do not clamp on parse.
 */
static gboolean
gst_gl_lut3d_parse_cube (const gchar * path, gfloat ** out_data,
    gint * out_size, gfloat out_dmin[3], gfloat out_dmax[3], GError ** error)
{
  FILE *f = fopen (path, "rb");
  gchar line[1024];
  gint size = -1;
  gfloat *data = NULL;
  gint64 n_entries = 0, got = 0;

  out_dmin[0] = out_dmin[1] = out_dmin[2] = 0.0f;
  out_dmax[0] = out_dmax[1] = out_dmax[2] = 1.0f;

  if (!f) {
    g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
        "cannot open LUT file '%s'", path);
    return FALSE;
  }

  while (fgets (line, sizeof (line), f)) {
    gchar *p = line;
    gchar *hash;
    gfloat a, b, c;

    hash = strchr (p, '#');
    if (hash)
      *hash = '\0';
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
      p++;
    if (*p == '\0')
      continue;

    if (g_ascii_strncasecmp (p, "TITLE", 5) == 0)
      continue;
    if (g_ascii_strncasecmp (p, "LUT_1D_SIZE", 11) == 0) {
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
          "'%s' is a 1D LUT; gcclut3d requires a 3D (LUT_3D_SIZE) cube", path);
      goto fail;
    }
    if (g_ascii_strncasecmp (p, "LUT_3D_SIZE", 11) == 0) {
      if (sscanf (p + 11, "%d", &size) != 1 || size < 2 || size > 256) {
        g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
            "invalid LUT_3D_SIZE in '%s'", path);
        goto fail;
      }
      n_entries = (gint64) size * size * size;
      data = g_new (gfloat, n_entries * 3);
      continue;
    }
    if (g_ascii_strncasecmp (p, "DOMAIN_MIN", 10) == 0) {
      if (sscanf (p + 10, "%f %f %f", &a, &b, &c) == 3) {
        out_dmin[0] = a; out_dmin[1] = b; out_dmin[2] = c;
      }
      continue;
    }
    if (g_ascii_strncasecmp (p, "DOMAIN_MAX", 10) == 0) {
      if (sscanf (p + 10, "%f %f %f", &a, &b, &c) == 3) {
        out_dmax[0] = a; out_dmax[1] = b; out_dmax[2] = c;
      }
      continue;
    }

    /* data triple */
    if (sscanf (p, "%f %f %f", &a, &b, &c) == 3) {
      if (!data) {
        g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
            "'%s' has LUT data before any LUT_3D_SIZE header", path);
        goto fail;
      }
      if (got >= n_entries) {
        got++;                  /* count the overflow, reported below */
        continue;
      }
      data[got * 3 + 0] = a;
      data[got * 3 + 1] = b;
      data[got * 3 + 2] = c;
      got++;
      continue;
    }
    /* unknown directive: ignore (forward compatible) */
  }
  fclose (f);
  f = NULL;

  if (size < 0) {
    g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
        "'%s' has no LUT_3D_SIZE header", path);
    goto fail;
  }
  if (got != n_entries) {
    g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
        "'%s' declares LUT_3D_SIZE %d (%" G_GINT64_FORMAT " entries) but has %"
        G_GINT64_FORMAT, path, size, n_entries, got);
    goto fail;
  }
  for (gint i = 0; i < 3; i++) {
    if (!(out_dmax[i] > out_dmin[i])) {
      g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
          "'%s' has a degenerate DOMAIN_MIN/DOMAIN_MAX on channel %d", path, i);
      goto fail;
    }
  }

  *out_data = data;
  *out_size = size;
  return TRUE;

fail:
  if (f)
    fclose (f);
  g_free (data);
  return FALSE;
}

/* ------------------------------------------------------------------ */
/* shader                                                              */
/* ------------------------------------------------------------------ */

/* The LUT lookup itself. Note the half-texel scale: a GL_TEXTURE_3D of
 * N samples has its grid NODES at texel centres (i+0.5)/N, so an input
 * value of 0.0 must map to 0.5/N and 1.0 to (N-0.5)/N -- otherwise the
 * sampled result is biased by half a grid cell and the endpoints get
 * clamped flat (this is the classic "LUT looks slightly washed out /
 * wrong at the extremes" bug). GL_LINEAR on a 3D texture *is* the
 * trilinear interpolation, done in fixed-function sampling hardware.
 *
 * "tex" (the input frame) is bound to texture unit 1 with uniform
 * tex=1 by gst_gl_filter_render_to_target_with_shader() itself - read
 * from gstglfilter.c's _draw_with_shader_cb(), NOT assumed: it is unit
 * 1, not 0. We therefore put the LUT on unit 0 to stay out of its way.
 */
static const gchar *lut3d_frag_body =
    "uniform sampler2D tex;\n"
    "uniform sampler3D lut;\n"
    "uniform float lut_size;\n"
    "uniform float intensity;\n"
    "uniform vec3 domain_min;\n"
    "uniform vec3 domain_max;\n"
    "void main (void)\n"
    "{\n"
    "  vec4 src = TEX2D (tex, v_texcoord);\n"
    "  vec3 n = clamp ((src.rgb - domain_min) / (domain_max - domain_min),\n"
    "                  0.0, 1.0);\n"
    "  vec3 c = (n * (lut_size - 1.0) + 0.5) / lut_size;\n"
    "  vec3 graded = TEX3D (lut, c).rgb;\n"
    "  fragColor = vec4 (mix (src.rgb, graded, intensity), src.a);\n"
    "}\n";

/* We supply BOTH stages ourselves and write the "#version" line into
 * the source text by hand. Both of those are deliberate, and were
 * established by reading gst-plugins-base 1.24's gstglslstage.c /
 * gstglfilter.c (and confirmed by a real compile failure first):
 *
 *  1. GstGLSLStage NEVER emits a "#version" directive derived from the
 *     version/profile arguments you pass it. _maybe_prepend_version()
 *     only ever prepends a hardcoded "#version 100\n", and only when
 *     the profile includes GST_GLSL_PROFILE_ES. The version/profile
 *     args are used purely for the
 *     gst_gl_context_supports_glsl_profile_version() sanity check. A
 *     stage created as (VERSION_150, PROFILE_CORE) is handed to the
 *     driver with no #version line at all, i.e. compiled as GLSL 1.10 -
 *     which is exactly how the first attempt here failed ("global
 *     function texture requires #version 130 or later").
 *  2. gst_glsl_stage_new_default_vertex() asks for
 *     PROFILE_ES|COMPATIBILITY, so on this (OPENGL3 core) context it
 *     DOES get "#version 100" + attribute/varying - a dialect that
 *     cannot be linked against a core-profile fragment stage. So the
 *     vertex stage has to be ours too, in the matching dialect.
 *
 * Attribute names a_position/a_texcoord are mandatory: GstGLFilter's
 * _get_attributes() looks up exactly those two names on whichever
 * shader was last passed to render_to_target_with_shader().
 */
static const gchar *lut3d_vert_modern =
    "in vec4 a_position;\n"
    "in vec2 a_texcoord;\n"
    "out vec2 v_texcoord;\n"
    "void main (void)\n"
    "{\n"
    "  gl_Position = a_position;\n" "  v_texcoord = a_texcoord;\n" "}\n";
static const gchar *lut3d_vert_legacy =
    "attribute vec4 a_position;\n"
    "attribute vec2 a_texcoord;\n"
    "varying vec2 v_texcoord;\n"
    "void main (void)\n"
    "{\n"
    "  gl_Position = a_position;\n" "  v_texcoord = a_texcoord;\n" "}\n";

static const gchar *lut3d_frag_prologue_modern =
    "in vec2 v_texcoord;\n"
    "out vec4 fragColor;\n"
    "#define TEX2D texture\n" "#define TEX3D texture\n";
static const gchar *lut3d_frag_prologue_legacy =
    "varying vec2 v_texcoord;\n"
    "#define fragColor gl_FragColor\n"
    "#define TEX2D texture2D\n" "#define TEX3D texture3D\n";

static GstGLShader *
gst_gl_lut3d_build_shader (GstGLLut3D * self, GstGLContext * context,
    GError ** error)
{
  GstGLSLVersion version;
  GstGLSLProfile profile;
  const gchar *vert_src, *frag_prologue, *version_line;
  gchar *frag, *vert;
  GstGLSLStage *vert_stage, *frag_stage;
  GstGLShader *shader;

  /* supported_gl_api restricts us to desktop GL (glTexImage3D is absent
   * from gst's GLES function table), so only the two desktop dialects
   * need covering here. */
  if (gst_gl_context_supports_glsl_profile_version (context,
          GST_GLSL_VERSION_150, GST_GLSL_PROFILE_CORE)) {
    version = GST_GLSL_VERSION_150;
    profile = GST_GLSL_PROFILE_CORE;
    version_line = "#version 150\n";
    vert_src = lut3d_vert_modern;
    frag_prologue = lut3d_frag_prologue_modern;
  } else {
    version = GST_GLSL_VERSION_120;
    profile = GST_GLSL_PROFILE_COMPATIBILITY;
    version_line = "#version 120\n";
    vert_src = lut3d_vert_legacy;
    frag_prologue = lut3d_frag_prologue_legacy;
  }

  vert = g_strconcat (version_line, vert_src, NULL);
  frag = g_strconcat (version_line, frag_prologue, lut3d_frag_body, NULL);

  vert_stage = gst_glsl_stage_new_with_string (context, GL_VERTEX_SHADER,
      version, profile, vert);
  frag_stage = gst_glsl_stage_new_with_string (context, GL_FRAGMENT_SHADER,
      version, profile, frag);
  g_free (vert);
  g_free (frag);

  /* takes ownership of the (floating) stages on success and on failure */
  shader = gst_gl_shader_new_link_with_stages (context, error,
      vert_stage, frag_stage, NULL);
  return shader;
}

/* ------------------------------------------------------------------ */
/* GL upload / render                                                  */
/* ------------------------------------------------------------------ */

static void
gst_gl_lut3d_upload_lut (GstGLLut3D * self, GstGLContext * context)
{
  const GstGLFuncs *gl = context->gl_vtable;
  gfloat *data;
  gint size;

  g_mutex_lock (&self->lut_lock);
  if (!self->lut_dirty) {
    g_mutex_unlock (&self->lut_lock);
    return;
  }
  self->lut_dirty = FALSE;
  size = self->lut_size;
  data = self->lut_data ? g_memdup2 (self->lut_data,
      (gsize) size * size * size * 3 * sizeof (gfloat)) : NULL;
  g_mutex_unlock (&self->lut_lock);

  if (!data) {
    if (self->lut_tex) {
      gl->DeleteTextures (1, &self->lut_tex);
      self->lut_tex = 0;
    }
    return;
  }

  /* TexImage3D is only present in gst's GL function table for desktop
   * GL (base.h marks the texture_3d ext group "not in either GLES"), so
   * this is checked rather than assumed. supported_gl_api already
   * restricts us to desktop GL; this is belt-and-braces. */
  if (!gl->TexImage3D) {
    GST_ELEMENT_ERROR (self, RESOURCE, NOT_FOUND, (NULL),
        ("no glTexImage3D in this GL context; gcclut3d needs desktop OpenGL"));
    g_free (data);
    return;
  }

  if (!self->lut_tex)
    gl->GenTextures (1, &self->lut_tex);
  gl->ActiveTexture (GL_TEXTURE1);
  gl->BindTexture (GL_TEXTURE_3D, self->lut_tex);
  gl->TexParameteri (GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  gl->TexParameteri (GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  gl->TexParameteri (GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  gl->TexParameteri (GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  gl->TexParameteri (GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
  gl->TexImage3D (GL_TEXTURE_3D, 0, GL_RGB16F, size, size, size, 0,
      GL_RGB, GL_FLOAT, data);
  self->uploaded_size = size;
  g_free (data);

  GST_INFO_OBJECT (self, "uploaded %dx%dx%d 3D LUT as texture %u",
      size, size, size, self->lut_tex);
}

static gboolean
gst_gl_lut3d_filter_texture (GstGLFilter * filter, GstGLMemory * in,
    GstGLMemory * out)
{
  GstGLLut3D *self = GST_GL_LUT3D (filter);
  GstGLContext *context = GST_GL_BASE_FILTER (filter)->context;
  const GstGLFuncs *gl = context->gl_vtable;
  gfloat dmin[3], dmax[3];
  gdouble intensity;

  if (!self->shader) {
    GError *err = NULL;
    self->shader = gst_gl_lut3d_build_shader (self, context, &err);
    if (!self->shader) {
      GST_ELEMENT_ERROR (self, RESOURCE, NOT_FOUND, (NULL),
          ("failed to compile 3D LUT shader: %s",
              err ? err->message : "unknown"));
      g_clear_error (&err);
      return FALSE;
    }
  }

  gst_gl_lut3d_upload_lut (self, context);

  g_mutex_lock (&self->lut_lock);
  memcpy (dmin, self->domain_min, sizeof (dmin));
  memcpy (dmax, self->domain_max, sizeof (dmax));
  intensity = self->intensity;
  g_mutex_unlock (&self->lut_lock);

  /* No usable LUT (none set yet, or it failed to parse): render with
   * intensity forced to 0, i.e. an exact passthrough, rather than
   * erroring the pipeline out - same "a bad param never kills playback"
   * behaviour every other ClipEffects entry has. */
  if (!self->lut_tex || self->uploaded_size < 2)
    intensity = 0.0;

  /* Uniforms are plain glUniform*() calls (read from gstglshader.c -
   * set_uniform_pre_check() does NOT call glUseProgram), so the program
   * must be current while we set them. Uniform values and sampler unit
   * bindings then persist in the program object, which is why it is safe
   * to set them here and let render_to_target_with_shader() do the FBO
   * bind + quad draw afterwards (it calls gst_gl_shader_use() again,
   * which is idempotent). */
  gst_gl_shader_use (self->shader);

  gl->ActiveTexture (GL_TEXTURE0);
  gl->BindTexture (GL_TEXTURE_3D, self->lut_tex);
  gst_gl_shader_set_uniform_1i (self->shader, "lut", 0);

  gst_gl_shader_set_uniform_1f (self->shader, "lut_size",
      (gfloat) MAX (self->uploaded_size, 2));
  gst_gl_shader_set_uniform_1f (self->shader, "intensity", (gfloat) intensity);
  gst_gl_shader_set_uniform_3f (self->shader, "domain_min",
      dmin[0], dmin[1], dmin[2]);
  gst_gl_shader_set_uniform_3f (self->shader, "domain_max",
      dmax[0], dmax[1], dmax[2]);

  /* This is the ONLY sanctioned way to draw with a custom shader from a
   * GstGLFilter subclass: filter->default_shader (which
   * _get_attributes() resolves a_position/a_texcoord from) is assigned
   * *by this very function* and is NULL otherwise - so a hand-rolled
   * render_to_target() + draw_fullscreen_quad() would call
   * glVertexAttribPointer(-1, ...) and silently draw nothing. */
  gst_gl_filter_render_to_target_with_shader (filter, in, out, self->shader);
  return TRUE;
}

static void
gst_gl_lut3d_gl_stop (GstGLBaseFilter * base)
{
  GstGLLut3D *self = GST_GL_LUT3D (base);
  const GstGLFuncs *gl = base->context ? base->context->gl_vtable : NULL;

  if (self->lut_tex && gl) {
    gl->DeleteTextures (1, &self->lut_tex);
    self->lut_tex = 0;
  }
  if (self->shader) {
    gst_object_unref (self->shader);
    self->shader = NULL;
  }
  /* force re-upload if we get a new context later */
  g_mutex_lock (&self->lut_lock);
  if (self->lut_data)
    self->lut_dirty = TRUE;
  g_mutex_unlock (&self->lut_lock);

  GST_GL_BASE_FILTER_CLASS (gst_gl_lut3d_parent_class)->gl_stop (base);
}

/* ------------------------------------------------------------------ */
/* GObject                                                             */
/* ------------------------------------------------------------------ */

static void
gst_gl_lut3d_set_lut_file (GstGLLut3D * self, const gchar * path)
{
  gfloat *data = NULL;
  gint size = 0;
  gfloat dmin[3], dmax[3];
  GError *err = NULL;

  if (path && *path) {
    if (!gst_gl_lut3d_parse_cube (path, &data, &size, dmin, dmax, &err)) {
      GST_WARNING_OBJECT (self, "lut-file: %s", err->message);
      g_clear_error (&err);
      /* keep showing the previous LUT rather than flickering to neutral */
      return;
    }
  }

  g_mutex_lock (&self->lut_lock);
  g_free (self->lut_file);
  self->lut_file = g_strdup (path);
  g_free (self->lut_data);
  self->lut_data = data;
  self->lut_size = size;
  if (data) {
    memcpy (self->domain_min, dmin, sizeof (dmin));
    memcpy (self->domain_max, dmax, sizeof (dmax));
  }
  self->lut_dirty = TRUE;
  g_mutex_unlock (&self->lut_lock);
}

static void
gst_gl_lut3d_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstGLLut3D *self = GST_GL_LUT3D (object);

  switch (prop_id) {
    case PROP_LUT_FILE:
      gst_gl_lut3d_set_lut_file (self, g_value_get_string (value));
      break;
    case PROP_INTENSITY:
      g_mutex_lock (&self->lut_lock);
      self->intensity = g_value_get_double (value);
      g_mutex_unlock (&self->lut_lock);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
}

static void
gst_gl_lut3d_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstGLLut3D *self = GST_GL_LUT3D (object);

  switch (prop_id) {
    case PROP_LUT_FILE:
      g_mutex_lock (&self->lut_lock);
      g_value_set_string (value, self->lut_file);
      g_mutex_unlock (&self->lut_lock);
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
gst_gl_lut3d_finalize (GObject * object)
{
  GstGLLut3D *self = GST_GL_LUT3D (object);

  g_free (self->lut_file);
  g_free (self->lut_data);
  g_mutex_clear (&self->lut_lock);
  G_OBJECT_CLASS (gst_gl_lut3d_parent_class)->finalize (object);
}

static void
gst_gl_lut3d_class_init (GstGLLut3DClass * klass)
{
  GObjectClass *gobject_class = G_OBJECT_CLASS (klass);
  GstElementClass *element_class = GST_ELEMENT_CLASS (klass);

  gobject_class->set_property = gst_gl_lut3d_set_property;
  gobject_class->get_property = gst_gl_lut3d_get_property;
  gobject_class->finalize = gst_gl_lut3d_finalize;

  g_object_class_install_property (gobject_class, PROP_LUT_FILE,
      g_param_spec_string ("lut-file", "LUT file",
          "Path to an Adobe/Resolve .cube 3D LUT file", NULL,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_INTENSITY,
      g_param_spec_double ("intensity", "Intensity",
          "Blend between the original (0.0) and fully graded (1.0) colour",
          0.0, 1.0, 1.0,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  gst_element_class_set_static_metadata (element_class,
      "3D LUT (GPU)", "Filter/Effect/Video",
      "Applies an Adobe .cube 3D colour lookup table on the GPU",
      "GPU Cine Studio");

  GST_GL_BASE_FILTER_CLASS (klass)->gl_stop = gst_gl_lut3d_gl_stop;
  GST_GL_FILTER_CLASS (klass)->filter_texture = gst_gl_lut3d_filter_texture;

  gst_gl_filter_add_rgba_pad_templates (GST_GL_FILTER_CLASS (klass));

  /* glTexImage3D is not in gst's GLES function table, so advertise
   * desktop GL only - glupload/glcolorconvert then negotiate a desktop
   * context or the element simply fails to link, instead of silently
   * passing frames through ungraded. */
  GST_GL_BASE_FILTER_CLASS (klass)->supported_gl_api =
      GST_GL_API_OPENGL | GST_GL_API_OPENGL3;
}

static void
gst_gl_lut3d_init (GstGLLut3D * self)
{
  g_mutex_init (&self->lut_lock);
  self->intensity = 1.0;
  self->lut_size = 0;
  self->domain_min[0] = self->domain_min[1] = self->domain_min[2] = 0.0f;
  self->domain_max[0] = self->domain_max[1] = self->domain_max[2] = 1.0f;
}

gboolean
gst_gl_lut3d_register (void)
{
  GST_DEBUG_CATEGORY_INIT (gst_gl_lut3d_debug, "gcclut3d", 0, "GPU 3D LUT");
  return gst_element_register (NULL, "gcclut3d", GST_RANK_NONE,
      GST_TYPE_GL_LUT3D);
}

#ifdef GCCLUT3D_BUILD_STANDALONE_PLUGIN
static gboolean
plugin_init (GstPlugin * plugin)
{
  GST_DEBUG_CATEGORY_INIT (gst_gl_lut3d_debug, "gcclut3d", 0, "GPU 3D LUT");
  return gst_element_register (plugin, "gcclut3d", GST_RANK_NONE,
      GST_TYPE_GL_LUT3D);
}

GST_PLUGIN_DEFINE (GST_VERSION_MAJOR, GST_VERSION_MINOR, gcclut3d,
    "GPU Cine Studio 3D LUT", plugin_init, "1.0", "LGPL", "gpu-cine-studio",
    "https://example.invalid")
#endif
