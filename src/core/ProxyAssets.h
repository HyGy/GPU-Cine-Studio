#ifndef PROXYASSETS_H
#define PROXYASSETS_H

#include <QString>

// Installs/removes a GES-level proxy relationship between a source file's
// GESUriClipAsset and a generated proxy file's own GESUriClipAsset
// (ges_asset_set_proxy() - proxy_build_plan.md Part J.4). Free functions,
// not a QObject - thin, stateless wrappers around the GES calls, used by
// BackendManager wherever a proxy becomes/stops being the effective active
// variant for a source.
//
// Nothing here ever discovers media: the assets are resolved beforehand on the
// AssetLoader thread (a GstDiscoverer run on a sleeping external disk can take
// many seconds and must never run on the GUI thread) and handed in. Main
// thread only (ges_asset_set_proxy() is not thread-safe against the engine).
//
// Ownership: no function here refs or unrefs any GESAsset. GES's asset cache
// is process-global and keeps its own reference for the process's lifetime,
// and the references BackendManager keeps are never released either (see
// TimelineEngine.cpp's addClipToGES(), the "INTENTIONALLY NOT UNREFFED"
// comment) - an attempted "fix" of that here risks the exact same hazard that
// produced two live crashes elsewhere in this codebase from unverified GES
// ref/unref changes. A leak bounded by distinct source-file count is
// recoverable; a use-after-free is not.
struct _GESAsset;
namespace ProxyAssets {

// What AssetLoader delivers for a path is the END of its proxy chain (the
// current proxy if one is installed). ges_asset_set_proxy() needs the true
// original: set_proxy on a proxy would build a proxy-of-a-proxy chain GES
// refuses. Returns the proxy-target of `delivered`, or `delivered` itself.
_GESAsset *unwrapOriginal(_GESAsset *delivered);

// Makes `proxy` the GES-level default proxy of `original`: anything that later
// requests the source's own GESUriClipAsset (the engine's asset loader) gets
// the proxy's asset instead, via GES's own asset-cache chain-follow.
// Returns false (and logs via qWarning) on any failure and never installs a
// partial/broken proxy relationship in that case.
bool install(_GESAsset *original, _GESAsset *proxy, const QString &sourcePath, const QString &proxyPath);

// Removes ALL proxies from `original` (ges_asset_set_proxy() with a NULL proxy
// clears the whole list, not just the most recent one) - used when proxy
// editing is disabled, or when switching the active variant away from whatever
// was last installed (see D16 in proxy_build_plan.md Part J.4.3: install() is
// always paired with an uninstall() of whatever was installed before, since
// set_proxy() ACCUMULATES rather than replaces).
bool uninstall(_GESAsset *original, const QString &sourcePath);

}

#endif // PROXYASSETS_H
