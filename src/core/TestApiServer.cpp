#include "TestApiServer.h"

#include <QQmlApplicationEngine>
#include <QQmlExpression>
#include <QQmlContext>
#include <QQuickWindow>
#include <QLocalServer>
#include <QLocalSocket>
#include <QJsonDocument>
#include <QJsonArray>
#include <QStandardPaths>
#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QTimer>

TestApiServer::TestApiServer(QQmlApplicationEngine *engine, QObject *rootObject,
                              const QString &socketPath, QObject *parent)
    : QObject(parent), m_engine(engine), m_root(rootObject), m_server(nullptr)
{
    m_socketPath = socketPath;
    if (m_socketPath.isEmpty()) {
        QString runtimeDir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
        if (runtimeDir.isEmpty()) runtimeDir = QDir::tempPath();
        m_socketPath = runtimeDir + QString("/gpu-cine-studio-%1.sock").arg(QCoreApplication::applicationPid());
    }
}

TestApiServer::~TestApiServer()
{
    if (m_server) {
        m_server->close();
        QLocalServer::removeServer(m_socketPath);
    }
}

bool TestApiServer::listen()
{
    // Stale socket file from a previous crash (the SIGSEGV handler
    // re-raises the signal - destructors never run) - removeServer()
    // clears it before we try to bind, exactly as QLocalServer's own docs
    // recommend for this situation.
    QLocalServer::removeServer(m_socketPath);

    m_server = new QLocalServer(this);
    // User-only access on the socket FILE is the actual access control
    // here (this is a Unix domain socket, not TCP - nothing to firewall,
    // nothing reachable off this host at all).
    m_server->setSocketOptions(QLocalServer::UserAccessOption);

    if (!m_server->listen(m_socketPath)) {
        qWarning() << "TestApiServer: failed to listen on" << m_socketPath
                   << ":" << m_server->errorString();
        return false;
    }

    connect(m_server, &QLocalServer::newConnection, this, &TestApiServer::onNewConnection);
    qInfo() << "TestApiServer: listening on" << m_socketPath;
    return true;
}

void TestApiServer::onNewConnection()
{
    while (QLocalSocket *sock = m_server->nextPendingConnection()) {
        m_buffers.insert(sock, QByteArray());
        connect(sock, &QLocalSocket::readyRead, this, &TestApiServer::onReadyRead);
        connect(sock, &QLocalSocket::disconnected, this, &TestApiServer::onDisconnected);
    }
}

void TestApiServer::onDisconnected()
{
    QLocalSocket *sock = qobject_cast<QLocalSocket *>(sender());
    if (!sock) return;
    m_buffers.remove(sock);
    sock->deleteLater();
}

void TestApiServer::onReadyRead()
{
    QLocalSocket *sock = qobject_cast<QLocalSocket *>(sender());
    if (!sock) return;

    QByteArray &buf = m_buffers[sock];
    buf.append(sock->readAll());

    // Guard against a runaway/misbehaving client filling memory with a
    // line that never terminates.
    if (buf.size() > 1024 * 1024) {
        qWarning() << "TestApiServer: client line exceeded 1MiB, dropping connection";
        sock->disconnectFromServer();
        return;
    }

    int nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
        QByteArray line = buf.left(nl);
        buf.remove(0, nl + 1);

        if (line.trimmed().isEmpty()) continue;

        QJsonParseError perr;
        QJsonDocument doc = QJsonDocument::fromJson(line, &perr);
        QJsonObject response;
        if (perr.error != QJsonParseError::NoError || !doc.isObject()) {
            response["ok"] = false;
            response["error"] = QString("invalid JSON: %1").arg(perr.errorString());
        } else {
            QJsonObject req = doc.object();
            response = dispatch(req);
            if (req.contains("id")) response["id"] = req.value("id");
        }
        sock->write(QJsonDocument(response).toJson(QJsonDocument::Compact));
        sock->write("\n");
    }
    sock->flush();
}

QJsonValue TestApiServer::evaluate(const QString &expr, QString *errorOut)
{
    // QQmlExpression::evaluate()'s QVariant result only round-trips
    // plain scalar types through QJsonValue::fromVariant() - a JS object
    // or array literal comes back as an opaque QVariant that
    // fromVariant() silently turns into null, indistinguishable from a
    // real null/undefined result. Routing the result through the QML
    // engine's own JSON.stringify() sidesteps that entirely: whatever
    // comes back is always a plain QString of JSON text. Wrapped in a
    // single-element array so a top-level scalar (e.g. "eval: 1+1") is
    // still valid JSON on its own (a bare top-level scalar is only valid
    // per newer JSON specs, not guaranteed across Qt JSON parser
    // versions). __v is assigned exactly once, so this is still exactly
    // one evaluation of `expr` - no double side effects for exec().
    QString wrapped = QStringLiteral(
        "(function(){ var __v = (%1); return JSON.stringify([__v === undefined ? null : __v]); })()"
    ).arg(expr);

    QQmlExpression qexpr(qmlContext(m_root), m_root, wrapped);
    QVariant result = qexpr.evaluate();
    if (qexpr.hasError()) {
        if (errorOut) *errorOut = qexpr.error().toString();
        return QJsonValue();
    }

    if (!result.canConvert<QString>()) {
        if (errorOut) *errorOut = "internal error: JSON.stringify did not return a string";
        return QJsonValue();
    }

    QJsonParseError perr;
    QJsonDocument doc = QJsonDocument::fromJson(result.toString().toUtf8(), &perr);
    if (perr.error != QJsonParseError::NoError || !doc.isArray() || doc.array().size() != 1) {
        if (errorOut) *errorOut = QString("internal error: could not parse stringified result: %1").arg(perr.errorString());
        return QJsonValue();
    }
    return doc.array().at(0);
}

QJsonObject TestApiServer::cmdState()
{
    QString err;
    QJsonValue v = evaluate(QStringLiteral(
        "({"
        "currentWorkspace: root.currentWorkspace,"
        "isProjectOpen: root.isProjectOpen,"
        "projectName: Backend.getSetting('project/name',''),"
        "projectLocation: Backend.getSetting('project/location',''),"
        "editingLoaded: !!(editingWorkspaceLoader && editingWorkspaceLoader.item),"
        "clipCount: (root.timelinePanelRef ? root.timelinePanelRef.clipsModel.count : -1),"
        "playing: (editingWorkspaceLoader && editingWorkspaceLoader.item && editingWorkspaceLoader.item.timelineEngine) ? editingWorkspaceLoader.item.timelineEngine.playing : false,"
        "position: (editingWorkspaceLoader && editingWorkspaceLoader.item && editingWorkspaceLoader.item.timelineEngine) ? editingWorkspaceLoader.item.timelineEngine.position : 0,"
        "totalDuration: (editingWorkspaceLoader && editingWorkspaceLoader.item && editingWorkspaceLoader.item.timelineEngine) ? editingWorkspaceLoader.item.timelineEngine.totalDuration : 0"
        "})"), &err);

    QJsonObject out;
    if (!err.isEmpty()) {
        out["__error__"] = err;
        return out;
    }
    return v.toObject();
}

QJsonObject TestApiServer::cmdScreenshot(const QString &path, QString *errorOut)
{
    QQuickWindow *win = qobject_cast<QQuickWindow *>(m_root);
    QJsonObject out;
    if (!win) {
        if (errorOut) *errorOut = "root object is not a QQuickWindow";
        return out;
    }
    QImage img = win->grabWindow();
    if (img.isNull()) {
        if (errorOut) *errorOut = "grabWindow() returned a null image";
        return out;
    }
    if (!img.save(path)) {
        if (errorOut) *errorOut = QString("failed to save image to %1").arg(path);
        return out;
    }
    out["path"] = path;
    out["w"] = img.width();
    out["h"] = img.height();
    return out;
}

QJsonObject TestApiServer::dispatch(const QJsonObject &req)
{
    QJsonObject res;
    const QString cmd = req.value("cmd").toString();

    if (cmd == "ping") {
        QJsonObject result;
        result["app"] = "gpu-cine-studio";
        result["api"] = 1;
        result["pid"] = QCoreApplication::applicationPid();
        res["ok"] = true;
        res["result"] = result;
        return res;
    }

    if (cmd == "eval" || cmd == "exec") {
        QString src = req.value(cmd == "eval" ? "expr" : "src").toString();
        if (cmd == "exec") src = "(function(){\n" + src + "\n})()";
        QString err;
        QJsonValue v = evaluate(src, &err);
        if (!err.isEmpty()) {
            res["ok"] = false;
            res["error"] = err;
        } else {
            res["ok"] = true;
            res["result"] = v;
        }
        return res;
    }

    if (cmd == "state") {
        QJsonObject s = cmdState();
        if (s.contains("__error__")) {
            res["ok"] = false;
            res["error"] = s.value("__error__");
        } else {
            res["ok"] = true;
            res["result"] = s;
        }
        return res;
    }

    if (cmd == "screenshot") {
        QString err;
        QJsonObject r = cmdScreenshot(req.value("path").toString(), &err);
        if (!err.isEmpty()) {
            res["ok"] = false;
            res["error"] = err;
        } else {
            res["ok"] = true;
            res["result"] = r;
        }
        return res;
    }

    if (cmd == "quit") {
        res["ok"] = true;
        res["result"] = QJsonObject{{"quitting", true}};
        QTimer::singleShot(0, qApp, &QCoreApplication::quit);
        return res;
    }

    res["ok"] = false;
    res["error"] = QString("unknown command: %1").arg(cmd);
    return res;
}
