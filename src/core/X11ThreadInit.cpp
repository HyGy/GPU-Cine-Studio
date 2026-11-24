#include "X11ThreadInit.h"
#include <dlfcn.h>

// libX11 is loaded at runtime instead of linked: the app must start on systems
// without it (pure native-Wayland sessions). If it is absent there is no Xlib
// Display to protect and nothing to do.
void gcsInitXThreads() {
    void *h = dlopen("libX11.so.6", RTLD_LAZY | RTLD_GLOBAL);
    if (!h)
        return;
    using XInitThreadsFn = int (*)();
    if (auto fn = reinterpret_cast<XInitThreadsFn>(dlsym(h, "XInitThreads")))
        fn();
    // Keep the library loaded: Xlib's thread-safety state lives in it.
}
