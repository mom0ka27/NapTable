import Foundation
import Network

/// 极简 HTTP/1.1 服务，只给本机的网页和批量脚本用。模拟器和 Mac 共用网络，
/// 浏览器直接访问 http://localhost:<port>。所有连接都在主队列上处理，渲染也在主线程。
final class GalleryServer {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    struct Response {
        var status = 200
        var contentType = "application/json; charset=utf-8"
        var body = Data()
        var headers: [String: String] = [:]

        static func json(_ value: some Encodable, status: Int = 200) -> Response {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return Response(status: status, body: (try? encoder.encode(value)) ?? Data("{}".utf8))
        }

        static func text(_ value: String, status: Int) -> Response {
            Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(value.utf8))
        }
    }

    private let listener: NWListener
    private let handler: (Request) -> Response

    init(port: UInt16, handler: @escaping (Request) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { state in
            print("[gallery] listener: \(state)")
        }
        listener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.respond(self.handler(request), on: connection)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Cache-Control: no-store\r\n"
        for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// 头部收齐、正文够 Content-Length 才算一个完整请求；不够返回 `nil` 继续收。
    private static func parse(_ data: Data) -> Request? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<marker.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                length = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[marker.upperBound...]
        guard body.count >= length else { return nil }
        let target = String(parts[1])
        let components = URLComponents(string: "http://localhost\(target)")
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: components?.path ?? target, query: query, body: Data(body.prefix(length)))
    }
}
