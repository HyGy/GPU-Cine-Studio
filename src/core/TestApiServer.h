#ifndef TESTAPISERVER_H
#define TESTAPISERVER_H

#include <QObject>
#include <QString>
#include <QHash>
#include <QByteArray>
#include <QJsonObject>
#include <QJsonValue>

class QQmlApplicationEngine;
class QLocalServer;
class QLocalSocket;

// Opt-in local automation API, used ONLY to drive the app from an external
// test script instead of simulated mouse/keyboard input (xdotool proved
// unreliable for this app's QML surfaces during development). NEVER
// started unless explicitly requested (see main.cpp) - a creative app
// must not open any listener by default. Unix domain socket only, never
// TCP: unreachable from the network stack, access-controlled by
// filesystem permissions on the socket file itself.
//
// Protocol: newline-delimited JSON, one request per line, one response
// per line, in order, per connection. See cpp for the command list.
class TestApiServer : public QObject {
    Q_OBJECT
public:
    // rootObject: the QML root (ApplicationWindow) - eval/exec run with
    // this as both context object and scope, so every `id` declared in
    // main.qml and every QML singleton resolves naturally.
    // socketPath: empty => default under $XDG_RUNTIME_DIR (or TMPDIR),
    // pid-suffixed so two running instances never collide.
    explicit TestApiServer(QQmlApplicationEngine *engine, QObject *rootObject,
                            const QString &socketPath, QObject *parent = nullptr);
    ~TestApiServer() override;

    // false + qWarning on failure (e.g. stale socket, permission issue) -
    // never fatal, the app continues normally either way.
    bool listen();
    QString socketPath() const { return m_socketPath; }

private slots:
    void onNewConnection();
    void onReadyRead();
    void onDisconnected();

private:
    QJsonObject dispatch(const QJsonObject &req);
    QJsonValue evaluate(const QString &expr, QString *errorOut);
    QJsonObject cmdState();
    QJsonObject cmdScreenshot(const QString &path, QString *errorOut);

    QQmlApplicationEngine *m_engine;
    QObject *m_root;
    QLocalServer *m_server;
    QString m_socketPath;
    QHash<QLocalSocket *, QByteArray> m_buffers;
};

#endif // TESTAPISERVER_H
