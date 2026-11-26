import Foundation

struct DXCCList {
    private struct Location {
        let country: String
        let latitude: Double
        let longitude: Double

        init?(_ country: String, latitude: Double, westLongitude: Double) {
            guard (-90...90).contains(latitude), (-180...180).contains(westLongitude) else { return nil }
            self.country = country
            self.latitude = latitude
            longitude = -westLongitude
        }
    }

    private var exact: [String: Location] = [:]
    private var prefixes: [String: Location] = [:]
    private(set) var entityCount = 0

    init(text: String) throws {
        let whitespace = CharacterSet.whitespacesAndNewlines
        let invalid = AppError.message("The download is not a complete CTY.DAT list.")
        let records = text.components(separatedBy: ";")
        guard records.last?.trimmingCharacters(in: whitespace).isEmpty == true else { throw invalid }
        for record in records.dropLast() {
            let fields = record.components(separatedBy: ":").map { $0.trimmingCharacters(in: whitespace) }
            guard fields.count == 9, !fields[0].isEmpty, !fields[7].isEmpty,
                  let lat = Double(fields[4]), let westLon = Double(fields[5]),
                  let entity = Location(fields[0], latitude: lat, westLongitude: westLon)
            else { throw invalid }
            // CTY.DAT also carries starred contest entities outside the DXCC list.
            guard !fields[7].hasPrefix("*") else { continue }
            entityCount += 1
            prefixes[fields[7].uppercased()] = entity
            for entry in fields[8].split(separator: ",") {
                let token = entry.trimmingCharacters(in: whitespace).uppercased()
                let call = String(token.prefix { "=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/".contains($0) })
                guard !call.isEmpty else { throw invalid }
                var location = entity
                if let start = token.firstIndex(of: "<"), let end = token[start...].firstIndex(of: ">") {
                    let coordinates = token[token.index(after: start)..<end].split(separator: "/")
                    if coordinates.count == 2, let lat = Double(coordinates[0]), let lon = Double(coordinates[1]),
                       let override = Location(entity.country, latitude: lat, westLongitude: lon) {
                        location = override
                    }
                }
                if call.hasPrefix("=") {
                    exact[String(call.dropFirst())] = location
                } else {
                    prefixes[call] = location
                }
            }
        }
        guard entityCount > 0 else { throw invalid }
    }

    func lookup(_ call: String, settings: StationSettings) -> QRZStation? {
        let location = exact[call] ?? call.indices.reversed().lazy.compactMap {
            prefixes[String(call[...$0])]
        }.first
        guard let location else { return nil }
        let route = Geo.bearingAndDistance(
            fromLat: settings.latitude, fromLon: settings.longitude,
            toLat: location.latitude, toLon: location.longitude
        )
        return QRZStation(callsign: call, name: "", grid: "", country: location.country,
                          latitude: location.latitude, longitude: location.longitude,
                          bearing: route.0, distance: route.1, source: "DXCC estimate")
    }
}

actor DXCCStore {
    private static let source = URL(string: "https://download.win-test.com/files/country/CTY.DAT")!
    private let file = URL.applicationSupportDirectory
        .appendingPathComponent("BuddiHex Rotator/cty.dat")
    private var cached: DXCCList?
    private var download: Task<DXCCList, Error>?

    private static func parse(_ data: Data) throws -> DXCCList {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw AppError.message("Could not read CTY.DAT.") }
        let list = try DXCCList(text: text)
        guard list.entityCount >= 300 else {
            throw AppError.message("The download is not a complete CTY.DAT list.")
        }
        return list
    }

    func list() async throws -> DXCCList {
        if let cached { return cached }
        if let data = try? Data(contentsOf: file), let list = try? Self.parse(data) {
            cached = list
            return list
        }
        return try await refresh()
    }

    func refresh() async throws -> DXCCList {
        if let download { return try await download.value }
        let task = Task {
            let request = URLRequest(url: Self.source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw AppError.message("Country Files returned an HTTP error.")
            }
            let list = try Self.parse(data)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            cached = list
            return list
        }
        download = task
        defer { download = nil }
        return try await task.value
    }
}
