import Foundation
import Network
import os

/// Private, loopback-only delivery. URLs contain an opaque session identifier,
/// never the provider URL. Requests can only read indexed media, not disk paths.
final nonisolated class TimeshiftServer: @unchecked Sendable {
    private let cache: TimeshiftCache
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "lume.timeshift.http")
    private let listener: NWListener

    init(cache: TimeshiftCache) throws {
        self.cache = cache
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let resolved = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let boundPort = listener.port
                let sessionToken = token
                resolved.withLock { completed in
                    guard !completed else { return }
                    switch state {
                    case .ready:
                        guard let port = boundPort,
                              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(sessionToken)/") else { return }
                        completed = true
                        continuation.resume(returning: url)
                    case let .failed(error):
                        completed = true
                        continuation.resume(throwing: error)
                    case .cancelled:
                        completed = true
                        continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
                receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = data
            request.append(chunk ?? Data())
            guard request.count <= 8192 else { connection.cancel(); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                Task { await self.respond(connection, request: request) }
            } else if complete {
                connection.cancel()
            } else {
                receive(connection, data: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) async {
        guard let text = String(data: request, encoding: .utf8) else { connection.cancel(); return }
        let firstLine = text.components(separatedBy: "\r\n")[0]
        let fields = firstLine.split(separator: " ")
        guard fields.count == 3, fields[0] == "GET" else {
            send(connection, status: "405 Method Not Allowed", data: Data(), type: "text/plain")
            return
        }
        let parts = fields[1].split(separator: "/")
        guard parts.count >= 2, parts[0] == Substring(token) else {
            send(connection, status: "404 Not Found", data: Data(), type: "text/plain")
            return
        }
        do {
            if parts.count == 3, parts[2] == "index.m3u8", let sequence = Int64(parts[1]) {
                let snapshot = await cache.snapshot(from: sequence)
                send(connection, status: "200 OK", data: Data(snapshot.playlist.utf8), type: "application/vnd.apple.mpegurl")
            } else if parts.count == 3, parts[2].hasPrefix("segment-"), parts[2].hasSuffix(".ts"),
                      let id = Int64(parts[2].dropFirst(8).dropLast(3)), let bytes = try await cache.segment(id: id)
            {
                send(connection, status: "200 OK", data: bytes, type: "video/mp2t")
            } else {
                send(connection, status: "404 Not Found", data: Data(), type: "text/plain")
            }
        } catch {
            send(connection, status: "503 Service Unavailable", data: Data(), type: "text/plain")
        }
    }

    private func send(_ connection: NWConnection, status: String, data: Data, type: String) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
