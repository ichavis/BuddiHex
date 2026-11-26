import Foundation
import Network

@MainActor final class RotctldServer {
    static let port: NWEndpoint.Port = 4533
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]

    func start(command: @escaping (String) -> String?, status: @escaping (String) -> Void) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        let server = try NWListener(using: parameters)
        listener = server
        server.stateUpdateHandler = { [weak self, weak server] state in
            MainActor.assumeIsolated {
                guard let self, let server, self.listener === server else { return }
                switch state {
                case .ready: status("Listening on 127.0.0.1:4533")
                case .failed(let error):
                    self.stop()
                    status("Hamlib server failed: \(error.localizedDescription)")
                default: break
                }
            }
        }
        server.newConnectionHandler = { [weak self, weak server] connection in
            MainActor.assumeIsolated {
                guard let self, let server, self.listener === server, self.clients.count < 16 else {
                    connection.cancel()
                    return
                }
                let id = UUID()
                self.clients[id] = connection
                connection.start(queue: .main)
                self.receive(id, command: command)
            }
        }
        server.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in clients.values { client.cancel() }
        clients.removeAll()
    }

    private func close(_ id: UUID) {
        clients.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ id: UUID, pending: Data = Data(), command: @escaping (String) -> String?) {
        clients[id]?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, let client = self.clients[id] else { return }
                guard error == nil else { self.close(id); return }
                var buffer = pending
                if let data { buffer.append(data) }
                var output = Data()
                var closing = done
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard line.count <= 256 else { self.close(id); return }
                    guard let reply = command(String(decoding: line, as: UTF8.self)) else {
                        closing = true
                        break
                    }
                    output.append(contentsOf: reply.utf8)
                }
                guard buffer.count <= 256 else { self.close(id); return }
                if output.isEmpty {
                    if closing { self.close(id) }
                    else { self.receive(id, pending: buffer, command: command) }
                    return
                }
                client.send(content: output, completion: .contentProcessed { [weak self] error in
                    MainActor.assumeIsolated {
                        if closing || error != nil { self?.close(id) }
                        else { self?.receive(id, pending: buffer, command: command) }
                    }
                })
            }
        }
    }
}

enum RotctldProtocol {
    static func response(to line: String, position: () -> Double?, move: (Int) -> Bool, stop: () -> Bool) -> String? {
        var request = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return "" }
        var separator: Character?
        if let prefix = request.first, "+;|,".contains(prefix) {
            separator = prefix == "+" ? "\n" : prefix
            request.removeFirst()
        }
        let fields = request.split(whereSeparator: \.isWhitespace)
        let arguments = fields.dropFirst()
        var name = ""
        var values: [String] = []
        var result = 0
        switch fields.first {
        case "q", "Q", "\\quit":
            return nil
        case "p", "\\get_pos":
            name = "get_pos"
            if !arguments.isEmpty { result = -1 }
            else if let azimuth = position(), azimuth.isFinite {
                let value = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), azimuth)
                values = separator == nil ? [value, "0.000000"] : ["Azimuth: \(value)", "Elevation: 0.000000"]
            } else { result = -5 }
        case "P", "\\set_pos":
            name = "set_pos"
            if arguments.count == 2, let azimuth = Double(fields[1]), (0...360).contains(azimuth),
               let elevation = Double(fields[2]), elevation == 0 {
                if !move(Int(azimuth.rounded())) { result = -5 }
            } else { result = -1 }
        case "S", "\\stop":
            name = "stop"
            if !arguments.isEmpty { result = -1 }
            else if !stop() { result = -5 }
        default:
            return "RPRT -11\n"
        }
        let report = "RPRT \(result)"
        if let separator {
            let header = ([name + ":"] + arguments.map(String.init)).joined(separator: " ")
            return ([header] + values + [report]).joined(separator: String(separator)) + "\n"
        }
        return values.isEmpty ? report + "\n" : values.joined(separator: "\n") + "\n"
    }
}
