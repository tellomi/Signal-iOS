//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Network

/// 本进程里的 HTTP 测试服务（只监听 127.0.0.1）：抓取器的安全用例用它看**线上真实的**请求头、重定向、Set-Cookie、
/// 压缩与超时——这些都发生在 CFNetwork 里，`URLProtocol` 桩看不到（例如 CFNetwork 自己补的 `Accept-Language`）。
///
/// 每个连接只答一个请求，答完就关（`Connection: close`）。
final class TellomiLocalHTTPTestServer: @unchecked Sendable {

    struct Request {
        let method: String
        let path: String
        /// 原样（名字保留大小写、顺序不变）
        let headers: [(name: String, value: String)]

        func header(_ name: String) -> String? {
            return headers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
        }

        func hasHeader(_ name: String) -> Bool {
            return header(name) != nil
        }
    }

    indirect enum Reply {
        case response(status: Int, headers: [(String, String)], body: Data)
        /// 不带 `Content-Length`，正文到连接关闭为止（边读边计的上限用例）
        case closeDelimited(status: Int, headers: [(String, String)], body: Data)
        /// 收下请求以后什么都不回，连接一直挂着（超时用例）
        case stall
        /// 收下请求以后直接断开（RST，网络层失败用例）
        case drop
        case delayed(TimeInterval, Reply)

        static func html(_ html: String, status: Int = 200, extraHeaders: [(String, String)] = []) -> Reply {
            return .response(
                status: status,
                headers: [("Content-Type", "text/html; charset=utf-8")] + extraHeaders,
                body: Data(html.utf8),
            )
        }

        static func redirect(to location: String, status: Int = 302, extraHeaders: [(String, String)] = []) -> Reply {
            return .response(
                status: status,
                headers: [("Location", location), ("Content-Type", "text/html")] + extraHeaders,
                body: Data("<html>moved</html>".utf8),
            )
        }
    }

    typealias Handler = @Sendable (Request) -> Reply

    private let listener: NWListener
    private let queue = DispatchQueue(label: "TellomiLocalHTTPTestServer")
    private let handler: Handler
    private let lock = NSLock()
    private var _requests = [Request]()
    private var _connectionCount = 0
    private var liveConnections = [NWConnection]()
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = AtomicFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    if resumed.set() { continuation.resume() }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let connections = liveConnections
        liveConnections.removeAll()
        lock.unlock()
        connections.forEach { $0.cancel() }
    }

    var origin: String { "http://127.0.0.1:\(port)" }

    func url(_ path: String) -> URL {
        return URL(string: origin + path)!
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _connectionCount
    }

    // MARK: -

    private func accept(_ connection: NWConnection) {
        lock.lock()
        _connectionCount += 1
        liveConnections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receiveHead(on: connection, buffer: Data())
    }

    private func receiveHead(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
                guard let request = Self.parse(head: head) else {
                    connection.cancel()
                    return
                }
                self.lock.lock()
                self._requests.append(request)
                self.lock.unlock()
                self.send(self.handler(request), on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveHead(on: connection, buffer: buffer)
        }
    }

    private func send(_ reply: Reply, on connection: NWConnection) {
        switch reply {
        case .stall:
            return
        case .drop:
            connection.forceCancel()
        case .delayed(let delay, let inner):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.send(inner, on: connection)
            }
        case .response(let status, let headers, let body), .closeDelimited(let status, let headers, let body):
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            for (name, value) in headers {
                head += "\(name): \(value)\r\n"
            }
            if case .response = reply {
                head += "Content-Length: \(body.count)\r\n"
            }
            head += "Connection: close\r\n\r\n"
            var payload = Data(head.utf8)
            payload.append(body)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            })
        }
    }

    private static func parse(head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        let headers: [(name: String, value: String)] = lines.dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (name, value)
        }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// 第一次调用返回 true
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

/// 测试用的 gzip（RFC 1952）：原始 DEFLATE 用 `NSData.compressed(using: .zlib)`（Apple 的 `.zlib` 产出的就是不带头的 RFC 1951），
/// 外面包 gzip 头尾（CRC32 + 原长）。
enum TellomiTestGzip {
    static func gzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var result = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        result.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        return result
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
