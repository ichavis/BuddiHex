import Darwin
import Foundation
import Security

struct StationSettings: Codable, Equatable {
    var host = "192.168.0.36"
    var savedControllerIPs: [String]? = nil
    var controllerIPs: [String] { savedControllerIPs ?? [host] }

    mutating func setControllerIPs(_ input: String) throws {
        var addresses: [String] = []
        var seen = Set<String>()
        for line in input.components(separatedBy: .newlines) {
            let ip = line.trimmingCharacters(in: .whitespaces)
            guard !ip.isEmpty else { continue }
            var address = in_addr()
            guard !ip.utf8.contains(0), inet_pton(AF_INET, ip, &address) == 1 else {
                throw AppError.message("Enter a valid IPv4 address for “\(ip)”. Use one address per line.")
            }
            if seen.insert(ip).inserted { addresses.append(ip) }
        }
        guard let first = addresses.first else {
            throw AppError.message("Enter at least one controller IPv4 address.")
        }
        savedControllerIPs = addresses
        if !seen.contains(host) { host = first }
    }

    var bridgeHost: String? = nil
    var bridgePort: Int? = nil
    var usesBridge: Bool { bridgeHost?.isEmpty == false }
    var resolvedBridgePort: Int { bridgePort ?? 4533 }

    var commandPort = 4210
    var replyPort = 4211
    var username = "WA1W"
    var latitude = 41.12345
    var longitude = -73.12345
    // Optional so existing saved settings decode without a migration/reset.
    var gridSquare: String? = nil
    mutating func setGridSquare(_ input: String) {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        gridSquare = normalized.isEmpty ? nil : normalized
        if let point = Geo.stationCoordinates(normalized) {
            latitude = point.0
            longitude = point.1
        }
    }
    mutating func setManualLatitude(_ value: Double) { latitude = value; gridSquare = nil }
    mutating func setManualLongitude(_ value: Double) { longitude = value; gridSquare = nil }
    func validate() throws {
        if let grid = gridSquare, Geo.stationCoordinates(grid) == nil {
            throw AppError.message("Enter a valid 4- or 6-character Maidenhead grid (for example FN31 or FN31PR), or clear the grid and enter latitude/longitude.")
        }
        if let bridgeHost, !bridgeHost.isEmpty {
            guard !bridgeHost.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "/" }),
                  (1...65535).contains(resolvedBridgePort) else {
                throw AppError.message("Enter a Pi hostname or IP address and a valid TCP port.")
            }
        }
        guard commandPort > 0 && commandPort <= 65535 && replyPort > 0 && replyPort <= 65535 else { throw AppError.message("Ports must be between 1 and 65535.") }
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppError.message("Enter the controller’s IPv4 address.") }
        guard latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) else { throw AppError.message("Enter valid station latitude and longitude.") }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

struct RotorReply {
    let bearing: Double?
    let direction: String
    let stuck: Bool
    let error: String?
    static func parse(_ text: String) -> RotorReply? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("GET_BEARING:") {
            let parts = text.components(separatedBy: ":")
            guard parts.count >= 2, let value = Double(parts[1]), value.isFinite, (0...360).contains(value), !parts.contains("Error!") else {
                return RotorReply(bearing: nil, direction: "STOP", stuck: false, error: "Controller reports a compass error: \(text)")
            }
            return RotorReply(bearing: value.truncatingRemainder(dividingBy: 360), direction: parts.contains("CCW") ? "CCW" : parts.contains("CW") ? "CW" : "STOP", stuck: parts.contains(where: { $0.lowercased() == "stuck" }), error: nil)
        }
        if text.hasPrefix("AZ:"), let value = Double(text.dropFirst(3)), value.isFinite, (0...360).contains(value) {
            // PST bearing replies do not report movement direction.
            return RotorReply(bearing: value.truncatingRemainder(dividingBy: 360), direction: "UNKNOWN", stuck: false, error: nil)
        }
        if text.lowercased().contains("error") || text.hasPrefix("ERR:") { return RotorReply(bearing: nil, direction: "STOP", stuck: false, error: text) }
        return nil
    }
}

struct Geo {
    static func stationCoordinates(_ input: String) -> (Double, Double)? {
        let grid = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard grid.count == 4 || grid.count == 6 else { return nil }
        return maidenhead(grid)
    }
    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
    static func bearingAndDistance(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> (Int, Int) {
        let rad = Double.pi / 180
        let a = fromLat * rad, b = toLat * rad, d = (toLon - fromLon) * rad
        let y = sin(d) * cos(b)
        let x = cos(a) * sin(b) - sin(a) * cos(b) * cos(d)
        let bearing = Int(((atan2(y, x) / rad + 360).truncatingRemainder(dividingBy: 360)).rounded()) % 360
        let h = min(1, max(0, pow(sin((b - a) / 2), 2) + cos(a) * cos(b) * pow(sin(d / 2), 2)))
        return (bearing, Int((6371 * 2 * atan2(sqrt(h), sqrt(1 - h))).rounded()))
    }
    static func maidenhead(_ locator: String) -> (Double, Double)? {
        let g = Array(locator.uppercased().utf8)
        guard g.count == 4 || g.count == 6 || g.count == 8,
              (65...82).contains(g[0]), (65...82).contains(g[1]),
              (48...57).contains(g[2]), (48...57).contains(g[3]) else { return nil }
        var lon = Double(g[0] - 65) * 20 - 180 + Double(g[2] - 48) * 2
        var lat = Double(g[1] - 65) * 10 - 90 + Double(g[3] - 48)
        var w = 2.0, h = 1.0
        if g.count >= 6 {
            guard (65...88).contains(g[4]), (65...88).contains(g[5]) else { return nil }
            w /= 24; h /= 24
            lon += Double(g[4] - 65) * w; lat += Double(g[5] - 65) * h
        }
        if g.count == 8 {
            guard (48...57).contains(g[6]), (48...57).contains(g[7]) else { return nil }
            w /= 10; h /= 10
            lon += Double(g[6] - 48) * w; lat += Double(g[7] - 48) * h
        }
        return (lat + h / 2, lon + w / 2)
    }
}

struct QRZStation: Equatable {
    var callsign: String
    var name: String
    var grid: String
    var country: String
    var latitude: Double
    var longitude: Double
    var bearing: Int
    var distance: Int
    var source = "QRZ"
}

final class QRZDocument: NSObject, XMLParserDelegate {
    var session: [String: String] = [:]
    var station: [String: String] = [:]
    private var stack: [String] = []
    private var text = ""
    static func parse(_ data: Data) throws -> QRZDocument {
        let document = QRZDocument()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = document
        guard parser.parse() else { throw AppError.message("QRZ returned an invalid XML response.") }
        return document
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String]) {
        stack.append(elementName); text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count >= 2 {
            let parent = stack[stack.count - 2]
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if parent == "Session" { session[elementName] = value }
            if parent == "Callsign" { station[elementName] = value }
        }
        _ = stack.popLast(); text = ""
    }
    func resolvedStation(settings: StationSettings) throws -> QRZStation {
        if let error = session["Error"], !error.isEmpty { throw AppError.message(error) }
        guard let call = station["call"], !call.isEmpty else { throw AppError.message("Callsign not found in QRZ.") }
        let grid = station["grid", default: ""].uppercased()
        var lat: Double?, lon: Double?
        if let rawLat = station["lat"], let rawLon = station["lon"],
           let la = Double(rawLat), let lo = Double(rawLon), la.isFinite, lo.isFinite,
           (-90...90).contains(la), (-180...180).contains(lo) { lat = la; lon = lo }
        else if let point = Geo.maidenhead(grid) { lat = point.0; lon = point.1 }
        guard let lat, let lon else {
            throw AppError.message(session["Message"] ?? "QRZ returned no location. Check your QRZ XML subscription.")
        }
        let route = Geo.bearingAndDistance(fromLat: settings.latitude, fromLon: settings.longitude, toLat: lat, toLon: lon)
        let name = station["name_fmt"] ?? [station["fname"], station["name"]].compactMap { $0 }.joined(separator: " ")
        return QRZStation(callsign: call, name: name, grid: grid, country: station["country"] ?? station["land"] ?? "", latitude: lat, longitude: lon, bearing: route.0, distance: route.1)
    }
}

struct QRZService {
    static func fetch(_ items: [URLQueryItem]) async throws -> QRZDocument {
        var components = URLComponents(string: "https://xmldata.qrz.com/xml/current/")!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AppError.message("Cannot reach QRZ. Check your Internet connection and try again.") }
        guard let http = result.1 as? HTTPURLResponse, http.statusCode == 200 else { throw AppError.message("QRZ returned an HTTP error. Try again later.") }
        return try QRZDocument.parse(result.0)
    }
    static func lookup(call: String, settings: StationSettings, password: String) async throws -> QRZStation {
        try settings.validate()
        let call = call.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard call.range(of: "^[A-Z0-9/]{1,15}$", options: .regularExpression) != nil else { throw AppError.message("Enter a valid callsign.") }
        guard !settings.username.isEmpty, !password.isEmpty else { throw AppError.message("Enter your QRZ username and password in Settings.") }
        let login = try await fetch([URLQueryItem(name: "username", value: settings.username), URLQueryItem(name: "password", value: password), URLQueryItem(name: "agent", value: "BuddiHexMac-1.0")])
        if let error = login.session["Error"], !error.isEmpty { throw AppError.message(error) }
        guard let key = login.session["Key"], !key.isEmpty else { throw AppError.message("QRZ login failed. Check your credentials and XML access.") }
        try Task.checkCancellation()
        let record = try await fetch([URLQueryItem(name: "s", value: key), URLQueryItem(name: "callsign", value: call)])
        try Task.checkCancellation()
        return try record.resolvedStation(settings: settings)
    }
}

struct PasswordStore {
    static let service = "com.buddihex.mac.qrz"
    static func load() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "qrz", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ password: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "qrz"]
        if password.isEmpty { SecItemDelete(query as CFDictionary); return }
        let value = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = Data(password.utf8)
            attributes[kSecAttrLabel as String] = "BuddiHex QRZ password"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError.message("Could not save the QRZ password to Keychain (\(status)).") }
    }
}
