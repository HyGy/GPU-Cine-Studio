/* GPU Cine Studio - "gccbc": GPU port of frei0r's brightness + contrast0r.
 *
 * Both frei0r filters are a fixed per-channel 8-bit lookup (measured by
 * running the real plugins over a 0..255 grey ramp), so a closed-form
 * fragment shader reproduces them without a CPU round trip:
 *
 *   brightness b (0..1, neutral 0.5):
 *     b <  0.5:  out = in * 2b
 *     b >= 0.5:  out = in + (1 - in) * 2(b - 0.5)
 *   contrast c (0..1, neutral 0.5):
 *     out = 0.5 + (in - 0.5) * 2c, clamped to [0,1]
 *
 * Verified against the plugins' ramps for b/c in {0 .. 1}: max error is
 * 1 of 256 levels (the plugins truncate in 8-bit integer arithmetic, we
 * compute in float). Brightness is applied before contrast, the order
 * Kdenlive/MLT stacks them in; a clip with only one of the two effects
 * just leaves the other at its neutral 0.5. Same GL/shader-dialect
 * boilerplate as gstglcurves.c.
 */

#include "gstglbrightcontrast.h"

#include <gst/gl/gstglfuncs.h>
#include <gst/gl/gstglshaderstrings.h>

GST_DEBUG_CATEGORY_STATIC (gst_gl_bright_contrast_debug);
#define GST_CAT_DEFAULT gst_gl_bright_contrast_debug

enum
{
  PROP_0,
  PROP_BRIGHTNESS,
  PROP_CONTRAST,
};

struct _GstGLBrightContrast
{
  GstGLFilter parent;

  /* properties: written on the app/streaming thread, read on the GL thread */
  GMutex lock;
  gdouble brightness;
  gdouble contrast;

  /* GL-thread-only */
  GstGLShader *shader;
};

G_DEFINE_TYPE (GstGLBrightContrast, gst_gl_bright_contrast, GST_TYPE_GL_FILTER)

static const gchar *bc_frag_body =
    "uniform sampler2D tex;\n"
    "uniform float brightness;\n"
    "uniform float contrast;\n"
    "void main (void)\n"
    "{\n"
    "  vec4 src = TEX2D (tex, v_texcoord);\n"
    "  vec3 c = clamp (src.rgb, 0.0, 1.0);\n"
    "  if (brightness < 0.5)\n"
    "    c = c * (2.0 * brightness);\n"
    "  else\n"
    "    c = c + (1.0 - c) * (2.0 * (brightness - 0.5));\n"
    "  c = clamp (vec3 (128.0 / 255.0) + (c - vec3 (128.0 / 255.0)) *\n"
    "      (2.0 * contrast), 0.0, 1.0);\n"
    "  fragColor = vec4 (c, src.a);\n"
    "}\n";

static const gchar *bc_vert_modern =
    "in vec4 a_position;\n"
    "in vec2 a_texcoord;\n"
    "out vec2 v_texcoord;\n"
    "void main (void)\n"
    "{\n"
    "  gl_Position = a_position;\n" "  v_texcoord = a_texcoord;\n" "}\n";
static const gchar *bc_vert_legacy =
    "attribute vec4 a_position;\n"
    "attribute vec2 a_texcoord;\n"
    "varying vec2 v_texcoord;\n"
    "void main (void)\n"
    "{\n"
    "  gl_Position = a_position;\n" "  v_texcoord = a_texcoord;\n" "}\n";

static const gchar *bc_frag_prologue_modern =
    "in vec2 v_texcoord;\n"
    "out vec4 fragColor;\n"
    "#define TEX2D texture\n";
static const gchar *bc_frag_prologue_legacy =
    "varying vec2 v_texcoord;\n"
    "#define fragColor gl_FragColor\n"
    "#define TEX2D texture2D\n";

static GstGLShader *
gst_gl_bright_contrast_build_shader (GstGLContext * context, GError ** error)
{
  GstGLSLVersion version;
  GstGLSLProfile profile;
  const gchar *vert_src, *frag_prologue, *version_line;
  gchar *frag, *vert;
  GstGLSLStage *vert_stage, *frag_stage;

  if (gst_gl_context_supports_glsl_profile_version (context,
          GST_GLSL_VERSION_150, GST_GLSL_PROFILE_CORE)) {
    version = GST_GLSL_VERSION_150;
    profile = GST_GLSL_PROFILE_CORE;
    version_line = "#version 150\n";
    vert_src = bc_vert_modern;
    frag_prologue = bc_frag_prologue_modern;
  } else {
    version = GST_GLSL_VERSION_120;
    profile = GST_GLSL_PROFILE_COMPATIBILITY;
    version_line = "#version 120\n";
    vert_src = bc_vert_legacy;
    frag_prologue = bc_frag_prologue_legacy;
  }

  vert = g_strconcat (version_line, vert_src, NULL);
  frag = g_strconcat (version_line, frag_prologue, bc_frag_body, NULL);

  vert_stage = gst_glsl_stage_new_with_string (context, GL_VERTEX_SHADER,
      version, profile, vert);
  frag_stage = gst_glsl_stage_new_with_string (context, GL_FRAGMENT_SHADER,
      version, profile, frag);
  g_free (vert);
  g_free (frag);

  return gst_gl_shader_new_link_with_stages (context, error,
      vert_stage, frag_stage, NULL);
}

static gboolean
gst_gl_bright_contrast_filter_texture (GstGLFilter * filter, GstGLMemory * in,
    GstGLMemory * out)
{
  GstGLBrightContrast *self = GST_GL_BRIGHT_CONTRAST (filter);
  GstGLContext *context = GST_GL_BASE_FILTER (filter)->context;
  gdouble brightness, contrast;

  /* Keyframed properties must be synced against the buffer actually being
   * rendered, on the GL thread - see the long note in gstglcurves.c. */
  gst_object_sync_values (GST_OBJECT (self), GST_BUFFER_PTS (filter->inbuf));

  if (!self->shader) {
    GError *err = NULL;
    self->shader = gst_gl_bright_contrast_build_shader (context, &err);
    if (!self->shader) {
      GST_ELEMENT_ERROR (self, RESOURCE, NOT_FOUND, (NULL),
          ("failed to compile brightness/contrast shader: %s",
              err ? err->message : "unknown"));
      g_clear_error (&err);
      return FALSE;
    }
  }

  g_mutex_lock (&self->lock);
  brightness = self->brightness;
  contrast = self->contrast;
  g_mutex_unlock (&self->lock);

  gst_gl_shader_use (self->shader);
  gst_gl_shader_set_uniform_1f (self->shader, "brightness",
      (gfloat) brightness);
  gst_gl_shader_set_uniform_1f (self->shader, "contrast", (gfloat) contrast);

  gst_gl_filter_render_to_target_with_shader (filter, in, out, self->shader);
  return TRUE;
}

static void
gst_gl_bright_contrast_gl_stop (GstGLBaseFilter * base)
{
  GstGLBrightContrast *self = GST_GL_BRIGHT_CONTRAST (base);

  if (self->shader) {
    gst_object_unref (self->shader);
    self->shader = NULL;
  }

  GST_GL_BASE_FILTER_CLASS (gst_gl_bright_contrast_parent_class)->gl_stop
      (base);
}

static void
gst_gl_bright_contrast_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstGLBrightContrast *self = GST_GL_BRIGHT_CONTRAST (object);

  g_mutex_lock (&self->lock);
  switch (prop_id) {
    case PROP_BRIGHTNESS:
      self->brightness = g_value_get_double (value);
      break;
    case PROP_CONTRAST:
      self->contrast = g_value_get_double (value);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
  g_mutex_unlock (&self->lock);
}

static void
gst_gl_bright_contrast_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec)
{
  GstGLBrightContrast *self = GST_GL_BRIGHT_CONTRAST (object);

  g_mutex_lock (&self->lock);
  switch (prop_id) {
    case PROP_BRIGHTNESS:
      g_value_set_double (value, self->brightness);
      break;
    case PROP_CONTRAST:
      g_value_set_double (value, self->contrast);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
  }
  g_mutex_unlock (&self->lock);
}

static void
gst_gl_bright_contrast_finalize (GObject * object)
{
  GstGLBrightContrast *self = GST_GL_BRIGHT_CONTRAST (object);

  g_mutex_clear (&self->lock);
  G_OBJECT_CLASS (gst_gl_bright_contrast_parent_class)->finalize (object);
}

static void
gst_gl_bright_contrast_class_init (GstGLBrightContrastClass * klass)
{
  GObjectClass *gobject_class = G_OBJECT_CLASS (klass);
  GstElementClass *element_class = GST_ELEMENT_CLASS (klass);

  gobject_class->set_property = gst_gl_bright_contrast_set_property;
  gobject_class->get_property = gst_gl_bright_contrast_get_property;
  gobject_class->finalize = gst_gl_bright_contrast_finalize;

  g_object_class_install_property (gobject_class, PROP_BRIGHTNESS,
      g_param_spec_double ("brightness", "Brightness",
          "frei0r brightness scale: 0.5 is neutral", 0.0, 1.0, 0.5,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));
  g_object_class_install_property (gobject_class, PROP_CONTRAST,
      g_param_spec_double ("contrast", "Contrast",
          "frei0r contrast0r scale: 0.5 is neutral", 0.0, 1.0, 0.5,
          G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
          GST_PARAM_CONTROLLABLE));

  gst_element_class_set_static_metadata (element_class,
      "Brightness/Contrast (GPU)", "Filter/Effect/Video",
      "frei0r-compatible brightness and contrast on the GPU",
      "GPU Cine Studio");

  GST_GL_BASE_FILTER_CLASS (klass)->gl_stop = gst_gl_bright_contrast_gl_stop;
  GST_GL_FILTER_CLASS (klass)->filter_texture =
      gst_gl_bright_contrast_filter_texture;

  gst_gl_filter_add_rgba_pad_templates (GST_GL_FILTER_CLASS (klass));
}

static void
gst_gl_bright_contrast_init (GstGLBrightContrast * self)
{
  g_mutex_init (&self->lock);
  self->brightness = 0.5;
  self->contrast = 0.5;
}

gboolean
gst_gl_bright_contrast_register (void)
{
  GST_DEBUG_CATEGORY_INIT (gst_gl_bright_contrast_debug, "gccbc", 0,
      "GPU brightness/contrast");
  return gst_element_register (NULL, "gccbc", GST_RANK_NONE,
      GST_TYPE_GL_BRIGHT_CONTRAST);
}
