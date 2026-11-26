import Foundation
import Network

@MainActor final class BridgeTransport {
    private var connection: NWConnection?
    var received: ((String) -> Void)?
    var failed: ((String) -> Void)?

    func start(host: String, port: Int) {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let client = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        connection = client
        client.stateUpdateHandler = { [weak self, weak client] state in
            MainActor.assumeIsolated {
                guard let self, let client, self.connection === client else { return }
                switch state {
                case .failed(let error): self.fail(client, error.localizedDescription)
                case .waiting(let error): self.fail(client, error.localizedDescription)
                default: break
                }
            }
        }
        client.start(queue: .main)
        sendLine("BUDDIHEX", to: client)
        receive(client, authenticated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak client] in
            guard let self, let client, self.connection === client, client.state != .ready else { return }
            self.fail(client, "Connection timed out.")
        }
    }

    func send(_ line: String) throws {
        guard let connection else { throw AppError.message("Connect to the Pi bridge first.") }
        sendLine(line, to: connection)
    }

    private func sendLine(_ line: String, to client: NWConnection) {
        client.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [weak self, weak client] error in
            MainActor.assumeIsolated {
                if let client, let error { self?.fail(client, error.localizedDescription) }
            }
        })
    }

    private func receive(_ client: NWConnection, pending: Data = Data(), authenticated: Bool) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak client] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, let client, self.connection === client else { return }
                var buffer = pending
                var identified = authenticated
                if let data { buffer.append(data) }
                while let newline = buffer.firstIndex(of: 10) {
                    let bytes = buffer[..<newline]
                    guard bytes.count <= 4096 else { self.fail(client, "Invalid response length."); return }
                    let line = String(decoding: bytes, as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    if identified {
                        self.received?(line)
                    } else {
                        guard line == "BUDDIHEX 1" else {
                            self.fail(client, "This address is not running the BuddiHex Pi bridge.")
                            return
                        }
                        identified = true
                    }
                }
                if let error { self.fail(client, error.localizedDescription) }
                else if done { self.fail(client, "The server closed the connection.") }
                else if buffer.count > 4096 { self.fail(client, "Invalid response length.") }
                else { self.receive(client, pending: buffer, authenticated: identified) }
            }
        }
    }

    private func fail(_ client: NWConnection, _ message: String) {
        guard connection === client else { return }
        close()
        failed?("Pi bridge: " + message)
    }

    func close(flush: Bool = false) {
        guard let client = connection else { return }
        connection = nil
        if flush {
            client.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in client.cancel() })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { client.cancel() }
        } else {
            client.cancel()
        }
    }
}
