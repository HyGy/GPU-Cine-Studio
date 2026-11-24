#pragma once

// Which codec-dependent features work with the GStreamer plugins that are
// actually registered, and what the user has to install when they don't.
//
// Patent-encumbered software codecs (H.264/H.265/AAC: gst-libav, x264, x265,
// OpenH264, fdk-aac, faad) are never bundled in the AppImage - they come from
// the host distribution's own GStreamer packages (the AppImage's AppRun
// exposes a whitelist of those plugin files, see build_appimage.sh). This
// class queries the registry BY CAPS (not by element names) so it reports
// the truth for any build: the AppImage, the dev build against
// gstreamer/install, or a distro build against the system GStreamer.
//
// Exposed to QML as the "Codecs" singleton (main.cpp).

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>

class CodecCheck : public QObject
{
    Q_OBJECT
    // [{id, title, status: "ok"|"missing"|"hardware-only"|"incompatible",
    //   detail, essential: bool}]
    Q_PROPERTY(QVariantList features READ features NOTIFY changed)
    // True when an essential feature (H.264/H.265 playback, AAC playback,
    // MP4 render) is missing or incompatible - drives the startup dialog.
    Q_PROPERTY(bool essentialMissing READ essentialMissing NOTIFY changed)
    // Stable signature of what is missing ("aac,mp4"), so a "Don't show
    // again" only silences the dialog for this exact situation.
    Q_PROPERTY(QString missingSignature READ missingSignature NOTIFY changed)
    Q_PROPERTY(QString distroName READ distroName CONSTANT)
    // Copyable shell command for this distro ("" when unknown).
    Q_PROPERTY(QString installCommand READ installCommand CONSTANT)
    // Human-readable notes to go with the command (distro caveats).
    Q_PROPERTY(QString installNote READ installNote CONSTANT)
    // Host plugin files that exist but GStreamer refused to load
    // ("libgstlibav.so (host GStreamer 1.30)"), AppImage only.
    Q_PROPERTY(QStringList incompatiblePlugins READ incompatiblePlugins NOTIFY changed)
    // "appimage" (host whitelist active), "appimage-nohost"
    // (GCS_NO_HOST_CODECS=1) or "native" (dev / distro build).
    Q_PROPERTY(QString pluginMode READ pluginMode CONSTANT)
    // Software video decoder factory names (avdec_h264, openh264dec, ...).
    Q_PROPERTY(QStringList softwareVideoDecoders READ softwareVideoDecoders NOTIFY changed)
    Q_PROPERTY(QString gstreamerVersion READ gstreamerVersion CONSTANT)

public:
    explicit CodecCheck(QObject *parent = nullptr);

    QVariantList features() const { return m_features; }
    bool essentialMissing() const { return m_essentialMissing; }
    QString missingSignature() const { return m_missingSignature; }
    QString distroName() const { return m_distroName; }
    QString installCommand() const { return m_installCommand; }
    QString installNote() const { return m_installNote; }
    QStringList incompatiblePlugins() const { return m_incompatiblePlugins; }
    QString pluginMode() const { return m_pluginMode; }
    QStringList softwareVideoDecoders() const { return m_softwareVideoDecoders; }
    QString gstreamerVersion() const;

    // Re-links the AppImage's host plugin whitelist (packages may have been
    // installed since startup), rescans the registry and re-evaluates.
    Q_INVOKABLE void recheck();
    Q_INVOKABLE void copyToClipboard(const QString &text) const;

    // First AAC encoder factory (any rank), avenc_aac preferred;
    // "" when none is registered. Used by ProxyGenerator.
    static QString preferredAacEncoder();

signals:
    void changed();

private:
    void evaluate();
    static void ensureAacEncoderRank();
    void detectDistro();
    void refreshHostPluginLinks();

    QVariantList m_features;
    bool m_essentialMissing = false;
    QString m_missingSignature;
    QString m_distroName;
    QString m_installCommand;
    QString m_installNote;
    QStringList m_incompatiblePlugins;
    QString m_pluginMode;
    QStringList m_softwareVideoDecoders;
};
