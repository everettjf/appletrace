//
//  HTTPServer.swift
//  A minimal HTTP server bound to 127.0.0.1 that hands a local trace to
//  ui.perfetto.dev.
//
//  The browser opens http://127.0.0.1:<port>/ (a same-origin page served
//  here). That page fetches /trace.json from the same origin, opens
//  ui.perfetto.dev and passes the bytes with Perfetto's documented postMessage
//  protocol (PING/PONG, then {perfetto: {buffer, title}}). Nothing is uploaded,
//  and no public site has to reach into localhost, which current Chrome gates
//  behind a Local Network Access permission prompt.
//

#if os(macOS)
import Darwin
import Foundation

final class TraceHandoffServer {
    private let socketFD: Int32
    private let traceName: String
    private let body: Data
    let port: UInt16

    init(port: UInt16, traceName: String, body: Data) throws {
        self.port = port
        self.traceName = traceName
        self.body = body
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw CLIError("socket() failed") }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(socketFD)
            throw CLIError("cannot listen on 127.0.0.1:\(port) (is another `appletrace open` running? try --port)")
        }
        guard listen(socketFD, 16) == 0 else {
            close(socketFD)
            throw CLIError("listen() failed")
        }
    }

    deinit {
        close(socketFD)
    }

    var pageURL: String { "http://127.0.0.1:\(port)/" }

    /// Serves until Perfetto confirms the hand-off (the page calls /done), or
    /// `timeout` seconds pass. Returns whether the trace was handed off.
    func serveUntilDelivered(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let delivered = DispatchSemaphore(value: 0)
        let workers = DispatchQueue(label: "appletrace.http", attributes: .concurrent)
        while Date() < deadline {
            var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            if poll(&pollFD, 1, 200) > 0 {
                let client = accept(socketFD, nil, nil)
                if client >= 0 {
                    // Browsers open speculative connections that may never send
                    // a request, so each connection is served independently.
                    workers.async {
                        if self.handle(client) {
                            delivered.signal()
                        }
                    }
                }
            }
            if delivered.wait(timeout: .now()) == .success {
                Thread.sleep(forTimeInterval: 0.3)
                return true
            }
        }
        return false
    }

    /// Returns true when the request reports a completed hand-off.
    private func handle(_ client: Int32) -> Bool {
        defer { close(client) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil, request.count < 65536 {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            request.append(buffer, count: count)
        }
        let requestLine = String(decoding: request.prefix { $0 != UInt8(ascii: "\r") }, as: UTF8.self)
        guard !requestLine.isEmpty else { return false }
        if ProcessInfo.processInfo.environment["APPLETRACE_HTTP_DEBUG"] != nil {
            FileHandle.standardError.write(Data("http: \(requestLine)\n".utf8))
        }
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let target = parts.count > 1 ? String(parts[1]) : ""

        guard method == "GET" else {
            respond(client, status: "405 Method Not Allowed", type: "text/plain", body: Data())
            return false
        }
        switch target {
        case "/", "/index.html":
            respond(client, status: "200 OK", type: "text/html; charset=utf-8", body: Data(page.utf8))
        case "/trace.json":
            respond(client, status: "200 OK", type: "application/json", body: body)
        case "/done":
            respond(client, status: "204 No Content", type: "text/plain", body: Data())
            return true
        default:
            respond(client, status: "404 Not Found", type: "text/plain", body: Data())
        }
        return false
    }

    private func respond(_ client: Int32, status: String, type: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        sendAll(client, Data(header.utf8))
        sendAll(client, body)
    }

    private func sendAll(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(client, base + offset, raw.count - offset, 0)
                if count <= 0 { return }
                offset += count
            }
        }
    }

    private var page: String {
        let title = traceName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let jsTitle = String(decoding: (try? JSONSerialization.data(withJSONObject: [traceName])) ?? Data("[\"trace\"]".utf8), as: UTF8.self)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>AppleTrace → Perfetto</title>
        <style>
          body { font: 15px -apple-system, system-ui, sans-serif; margin: 48px; color: #222; background: #fafafa; }
          button { font: inherit; padding: 8px 16px; border-radius: 6px; border: 1px solid #888; background: #fff; cursor: pointer; }
          #status { margin-top: 16px; color: #555; }
        </style></head>
        <body>
          <h2>AppleTrace</h2>
          <p>Handing <code>\(title)</code> to <a href="https://ui.perfetto.dev">ui.perfetto.dev</a>.
             The trace is passed to the Perfetto tab in your browser; it is not uploaded anywhere.</p>
          <button id="open">Open in Perfetto</button>
          <div id="status">Opening Perfetto…</div>
          <script>
          const ORIGIN = "https://ui.perfetto.dev";
          const TITLE = \(jsTitle)[0];
          const status = (text) => { document.getElementById("status").textContent = text; };
          let started = false;
          async function openInPerfetto() {
            if (started) return;
            const win = window.open(ORIGIN + "/#!/");
            if (!win) { status("Your browser blocked the pop-up. Click “Open in Perfetto”."); return; }
            started = true;
            status("Loading trace…");
            const buffer = await (await fetch("/trace.json")).arrayBuffer();
            status("Waiting for Perfetto to start…");
            const ping = setInterval(() => win.postMessage("PING", ORIGIN), 100);
            window.addEventListener("message", (event) => {
              if (event.source !== win || event.data !== "PONG") return;
              clearInterval(ping);
              win.postMessage({ perfetto: { buffer, title: TITLE, fileName: TITLE } }, ORIGIN);
              status("Trace sent to Perfetto. You can close this tab.");
              fetch("/done").catch(() => {});
            });
          }
          document.getElementById("open").addEventListener("click", () => { started = false; openInPerfetto(); });
          openInPerfetto();
          </script>
        </body></html>
        """
    }
}
#endif
