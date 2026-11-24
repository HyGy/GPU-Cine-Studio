/* GPU Cine Studio - 3D LUT (.cube) GL filter element "gcclut3d" */
#ifndef __GST_GL_LUT3D_H__
#define __GST_GL_LUT3D_H__

#include <gst/gst.h>
#include <gst/gl/gstglfilter.h>

G_BEGIN_DECLS

#define GST_TYPE_GL_LUT3D (gst_gl_lut3d_get_type())
G_DECLARE_FINAL_TYPE (GstGLLut3D, gst_gl_lut3d, GST, GL_LUT3D, GstGLFilter)

/* Registers the "gcclut3d" element into the default GStreamer registry.
 * Call once after gst_init(). Returns TRUE on success. */
gboolean gst_gl_lut3d_register (void);

G_END_DECLS

#endif
