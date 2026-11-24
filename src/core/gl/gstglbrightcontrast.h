/* GPU Cine Studio - brightness/contrast GL filter element "gccbc" */
#ifndef __GST_GL_BRIGHT_CONTRAST_H__
#define __GST_GL_BRIGHT_CONTRAST_H__

#include <gst/gst.h>
#include <gst/gl/gstglfilter.h>

G_BEGIN_DECLS

#define GST_TYPE_GL_BRIGHT_CONTRAST (gst_gl_bright_contrast_get_type())
G_DECLARE_FINAL_TYPE (GstGLBrightContrast, gst_gl_bright_contrast, GST,
    GL_BRIGHT_CONTRAST, GstGLFilter)

/* Registers the "gccbc" element into the default GStreamer registry.
 * Call once after gst_init(). Returns TRUE on success. */
gboolean gst_gl_bright_contrast_register (void);

G_END_DECLS

#endif
