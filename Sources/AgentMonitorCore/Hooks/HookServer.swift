import Foundation
import Network

/// Receives Claude Code's `type: "http"` hooks on the loopback interface.
///
/// HTTP rather than a `command` hook because a command hook forks a shell per event, and
/// `PreToolUse` fires on every tool call — DESIGN.md §6 P1 rules that out. Claude Code
/// POSTs the hook's JSON input and reads the response body as the hook's output, so the
/// reply is always `200` with an **empty body**: no decision, no added context, nothing
/// that could change what the agent does. This channel is read-only by construction.
///
/// Deliberately a few dozen lines of HTTP/1.1 rather than a dependency: one request per
/// connection, bodies with a `Content-Length`, nothing else — which is all Claude Code
/// sends.
public final class HookServer: @unchecked Sendable {

    /// Fixed so the URL written into `settings.json` stays valid across launches.
    public static let defaultPort: UInt16 = 47_291
    /// The path prefix every installed hook URL shares — how the installer recognises its
    /// own entries, and how the server rejects requests that are not hooks.
    public static let pathPrefix = "/agent-monitor/v1/"

    public enum State: Sendable, Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    public let port: UInt16
    private let onEvent: @Sendable (HookEvent) -> Void
    private let queue = DispatchQueue(label: "agent-monitor.hooks", qos: .utility)
    private var listener: NWListener?
    private let lock = NSLock()
    private var _state: State = .stopped
    /// Largest body accepted. `PreToolUse` carries the tool input, which for a `Write`
    /// is the whole file; anything bigger than this is not worth buffering to learn a
    /// tool name.
    private let maxRequestBytes = 8 * 1024 * 1024

    public init(port: UInt16 = HookServer.defaultPort, onEvent: @escaping @Sendable (HookEvent) -> Void) {
        self.port = port
        self.onEvent = onEvent
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    private func setState(_ state: State) {
        lock.lock()
        _state = state
        lock.unlock()
    }

    public func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            // Loopback only. Nothing off this machine can reach it.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                         port: NWEndpoint.Port(rawValue: port)!)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.setState(.listening(port: self?.port ?? 0))
                case .failed(let error): self?.setState(.failed(error.localizedDescription))
                case .cancelled: self?.setState(.stopped)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.respond(on: connection, status: self.accept(request) ? "200 OK" : "404 Not Found")
            case .incomplete where buffer.count < self.maxRequestBytes && !isComplete && error == nil:
                self.receive(on: connection, buffer: buffer)
            case .incomplete, .invalid:
                self.respond(on: connection, status: "400 Bad Request")
            }
        }
    }

    /// Returns whether the request was a hook we understood.
    private func accept(_ request: HTTPRequest) -> Bool {
        guard request.method == "POST", request.path.hasPrefix(Self.pathPrefix) else { return false }
        guard var event = try? JSONDecoder().decode(HookEvent.self, from: request.body) else { return false }
        event.receivedAt = Date()
        onEvent(event)
        return true
    }

    private func respond(on connection: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Just enough of an HTTP/1.1 request parser for one POST with a `Content-Length`.
struct HTTPRequest: Equatable {
    let method: String
    let path: String
    let body: Data

    enum ParseResult: Equatable {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return .invalid }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= contentLength else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + contentLength)]
        return .complete(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), body: Data(body)))
    }
}
