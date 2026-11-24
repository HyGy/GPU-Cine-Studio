#include "ProxyAssets.h"

#include <gst/gst.h>
// Qt "signals" keyword collides with GLib's (same fix as TimelineEngine.h)
#ifdef signals
#undef signals
#endif
#include <ges/ges.h>
#define signals Q_SIGNALS
#include <QDebug>

namespace ProxyAssets {

GESAsset *unwrapOriginal(GESAsset *delivered)
{
    if (!delivered) return nullptr;
    GESAsset *target = ges_asset_get_proxy_target(delivered);
    return target ? target : delivered;
}

bool install(GESAsset *original, GESAsset *proxy, const QString &sourcePath, const QString &proxyPath)
{
    if (!original || !proxy) return false;

    if (ges_asset_get_error(original)) {
        qWarning() << "ProxyAssets: refusing to proxy" << sourcePath
                   << "- the original asset itself failed to load";
        return false;
    }

    const bool ok = ges_asset_set_proxy(original, proxy);
    if (!ok) {
        qWarning() << "ProxyAssets: ges_asset_set_proxy() refused for" << sourcePath
                   << "->" << proxyPath;
    } else {
        qDebug() << "ProxyAssets: installed" << proxyPath << "as proxy for" << sourcePath;
    }
    return ok;
}

bool uninstall(GESAsset *original, const QString &sourcePath)
{
    if (!original) return false;

    // NULL proxy = remove ALL proxies from this asset (ges-asset.c), not
    // just the most recently installed one.
    const bool ok = ges_asset_set_proxy(original, nullptr);
    if (ok) {
        qDebug() << "ProxyAssets: removed proxy for" << sourcePath;
    }
    return ok;
}

}
