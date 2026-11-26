import Foundation
import Darwin

final class UDPTransport {
    private var descriptor: Int32 = -1
    private var connectionID: UUID?
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.buddihex.udp")
    private var peer = sockaddr_in()
    var received: ((String) -> Void)?
    var failed: ((String) -> Void)?
    var isOpen: Bool { descriptor >= 0 }

    func start(host: String, commandPort: Int, replyPort: Int) throws {
        guard descriptor < 0 else { return }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(commandPort).bigEndian
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else { throw AppError.message("Use the controller’s numeric IPv4 address, such as 192.168.0.36.") }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw AppError.message("Could not create a UDP socket.") }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = UInt16(replyPort).bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw AppError.message("Cannot listen on UDP port \(replyPort). Stop the Node-RED rotator flow or another app using that port.")
        }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); throw AppError.message("Could not configure UDP reception.") }
        descriptor = fd; peer = target
        let expectedIP = target.sin_addr.s_addr
        let expectedPort = target.sin_port
        let id = UUID()
        connectionID = id
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                var sender = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                    }
                }
                if count < 0 {
                    if errno != EAGAIN && errno != EWOULDBLOCK {
                        DispatchQueue.main.async {
                            guard let self, self.connectionID == id else { return }
                            self.failed?("UDP receive failed.")
                        }
                    }
                    break
                }
                guard sender.sin_addr.s_addr == expectedIP, sender.sin_port == expectedPort else { continue }
                let text = String(decoding: buffer.prefix(count), as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self, self.connectionID == id else { return }
                    self.received?(text)
                }
            }
        }
        readSource.setCancelHandler { Darwin.close(fd) }
        source = readSource
        readSource.resume()
    }
    func send(_ text: String) throws {
        guard descriptor >= 0 else { throw AppError.message("Connect to the controller first.") }
        let data = Array(text.utf8)
        var destination = peer
        let count = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(descriptor, data, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard count == data.count else { throw AppError.message("The UDP command could not be sent.") }
    }
    func close() {
        connectionID = nil
        source?.cancel(); source = nil; descriptor = -1
    }
    deinit { close() }
}
