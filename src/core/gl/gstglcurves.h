/* GPU Cine Studio - tonal curves GL filter element "gcccurves" */
#ifndef __GST_GL_CURVES_H__
#define __GST_GL_CURVES_H__

#include <gst/gst.h>
#include <gst/gl/gstglfilter.h>

G_BEGIN_DECLS

#define GST_TYPE_GL_CURVES (gst_gl_curves_get_type())
G_DECLARE_FINAL_TYPE (GstGLCurves, gst_gl_curves, GST, GL_CURVES, GstGLFilter)

/* Registers the "gcccurves" element into the default GStreamer registry.
 * Call once after gst_init(). Returns TRUE on success. */
gboolean gst_gl_curves_register (void);

G_END_DECLS

#endif
