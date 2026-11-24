#ifndef X11THREADINIT_H
#define X11THREADINIT_H

// Deliberately Qt-free: X11/Xlib.h's macros (Bool, True, False, Status,
// ...) collide with Qt's own headers (confirmed live: including
// Xlib.h directly in main.cpp broke QJSPrimitiveValue/QMetaTypeId
// overload resolution) - isolated here so nothing Qt-related ever
// sees Xlib.h.
void gcsInitXThreads();

#endif // X11THREADINIT_H
