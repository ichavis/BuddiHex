import Foundation
import SwiftUI
import AppKit

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor final class RotatorModel: ObservableObject {
    static let shared = RotatorModel()
    @Published var settings: StationSettings
    @Published var password = ""
    @Published var showSettings = false
    @Published private(set) var autoConnect = false
    @Published var connected = false
    @Published var online = false
    @Published var bearing: Double?
    @Published var direction = "STOP"
    @Published var target: Int?
    @Published var stuck = false
    @Published var fault = ""
    @Published var status = "Open Settings to check your controller and station location."
    @Published var manualTarget = ""
    @Published var callsign = ""
    @Published var qrz: QRZStation?
    @Published var qrzError = ""
    @Published private(set) var updatingDXCC = false
    @Published private(set) var dxccUpdateStatus = ""
    @Published private(set) var hamlibEnabled = false
    @Published private(set) var hamlibStatus = ""
    private let hamlib = RotctldServer()
    private var bearingReceivedAt = Date.distantPast
    private let dxccStore = DXCCStore()
    @Published var lookingUp = false
    @Published var detailsExpanded = true
    @Published var logs: [LogEntry] = []
    @Published var lastSeen: Date?
    @Published var calibrating = false
    private let defaults: UserDefaults
    private var handledLaunchConnection = false
    private let transport = UDPTransport()
    private let bridge = BridgeTransport()
    private var timer: Timer?
    private var lookupTask: Task<Void, Never>?
    private var lookupID = UUID()
    private var qrzArrivalCount = 0
    private var trackQRZArrival = false
    private var calibrationStage = 0
    private var calibrationDeadline = Date.distantPast
    private var calibrationSamples = 0
    private var previousCalibrationBearing: Double?
    private var lastPoll = Date.distantPast
    private var trackingMotion = false
    private var stopRequested = false
    var canMove: Bool { connected && online && !stuck && fault.isEmpty && !calibrating }
    var heading: String { bearing.map { String(format: "%03.0f", $0) } ?? "—" }

    init(defaults: UserDefaults = .standard, loadPassword: Bool = true) {
        self.defaults = defaults
        hamlibEnabled = defaults.bool(forKey: "hamlibEnabled")
        autoConnect = defaults.bool(forKey: "autoConnectOnLaunch")
        if let data = defaults.data(forKey: "stationSettings"), let loaded = try? JSONDecoder().decode(StationSettings.self, from: data) {
            settings = loaded
            if loadPassword { password = PasswordStore.load() }
        } else { settings = StationSettings() }
        transport.received = { [weak self] text in self?.receive(text) }
        bridge.received = { [weak self] text in self?.receive(text) }
        bridge.failed = { [weak self] message in
            guard let self else { return }
            self.endConnection()
            self.clearControllerFeedback()
            self.status = message
            self.addLog(message)
        }
        transport.failed = { [weak self] error in self?.status = error; self?.addLog(error) }
    }
    func setAutoConnect(_ enabled: Bool) {
        autoConnect = enabled
        defaults.set(enabled, forKey: "autoConnectOnLaunch")
    }
    func connectOnLaunchIfEnabled() {
        guard !handledLaunchConnection else { return }
        handledLaunchConnection = true
        if autoConnect { connect() }
        if hamlibEnabled { startHamlib() }
    }
    func setHamlibEnabled(_ enabled: Bool) {
        let changed = hamlibEnabled != enabled
        hamlibEnabled = enabled
        defaults.set(enabled, forKey: "hamlibEnabled")
        if enabled {
            if changed || !hamlibStatus.hasPrefix("Listening") { startHamlib() }
        } else {
            hamlib.stop()
            hamlibStatus = ""
        }
    }

    private var hamlibBearing: Double? {
        guard connected, online, fault.isEmpty, !stuck,
              Date().timeIntervalSince(bearingReceivedAt) <= 6.5,
              let bearing, bearing.isFinite, (0..<360).contains(bearing) else { return nil }
        return bearing
    }

    private func startHamlib() {
        do {
            try hamlib.start(command: { [weak self] line in
                guard let self else { return nil }
                return RotctldProtocol.response(to: line, position: { self.hamlibBearing }, move: { value in
                    guard self.hamlibBearing != nil else { return false }
                    return self.move(to: value)
                }, stop: { self.stop() })
            }, status: { [weak self] message in self?.hamlibStatus = message })
        } catch {
            hamlibStatus = error.localizedDescription
        }
    }

    func addLog(_ text: String) {
        logs.append(LogEntry(text: text))
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }
    func saveSettings(_ proposed: StationSettings, password updatedPassword: String, autoConnect updatedAutoConnect: Bool? = nil) throws {
        var updated = proposed
        if let grid = updated.gridSquare { updated.setGridSquare(grid) }
        try updated.validate()
        // Verify the address before saving, using the same numeric-IPv4 contract as UDP.
        var address = in_addr()
        guard inet_pton(AF_INET, updated.host, &address) == 1 else { throw AppError.message("Enter a numeric IPv4 address for the controller.") }
        let encoded = try JSONEncoder().encode(updated)
        try PasswordStore.save(updatedPassword)
        let changedConnection = settings.bridgeHost != updated.bridgeHost || settings.resolvedBridgePort != updated.resolvedBridgePort || settings.host != updated.host || settings.commandPort != updated.commandPort || settings.replyPort != updated.replyPort
        if changedConnection {
            disconnect()
            clearControllerFeedback()
        }
        cancelLookup()
        settings = updated; password = updatedPassword
        defaults.set(encoded, forKey: "stationSettings")
        if let enabled = updatedAutoConnect { setAutoConnect(enabled) }
        qrz = nil; qrzError = ""; trackQRZArrival = false
        status = "Settings saved. \(connected ? "Controller connection retained." : "Choose Connect when ready.")"
    }
    func selectControllerIP(_ ip: String) {
        guard !connected, ip != settings.host, settings.controllerIPs.contains(ip) else { return }
        var updated = settings
        updated.host = ip
        do {
            let encoded = try JSONEncoder().encode(updated)
            defaults.set(encoded, forKey: "stationSettings")
            settings = updated
            clearControllerFeedback()
            status = "Selected \(ip). Choose Connect when ready."
        } catch {
            status = error.localizedDescription
        }
    }
    private func clearControllerFeedback() {
        bearing = nil
        target = nil
        lastSeen = nil
        fault = ""
        stuck = false
    }
    func connect() {
        guard !connected else { return }
        do {
            try settings.validate()
            if let host = settings.bridgeHost, settings.usesBridge {
                bridge.start(host: host, port: settings.resolvedBridgePort)
                addLog("Connecting to Pi bridge at \(host):\(settings.resolvedBridgePort)")
            } else {
                try transport.start(host: settings.host, commandPort: settings.commandPort, replyPort: settings.replyPort)
                addLog("Connected UDP \(settings.host):\(settings.commandPort), listening on :\(settings.replyPort)")
            }
            connected = true; online = false; lastSeen = nil; fault = ""; stuck = false; bearing = nil; direction = "STOP"
            status = "Waiting for controller replies…"
            try send("GET_BEARING")
            lastPoll = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            endConnection()
            status = error.localizedDescription; addLog(status)
        }
    }
    func disconnect() {
        guard connected else { return }
        // A user-initiated disconnect/quit also requests STOP, never a new target.
        let requestedStop = (try? send("<PST><STOP>")) != nil
        endConnection(flushBridge: requestedStop)
        status = requestedStop ? "Disconnected after requesting STOP." : "Disconnected."
        addLog(status)
    }
    private func endConnection(flushBridge: Bool = false) {
        bridge.close(flush: flushBridge)
        timer?.invalidate(); timer = nil
        transport.close(); connected = false; online = false; direction = "STOP"
        calibrating = false; calibrationStage = 0; trackQRZArrival = false
        trackingMotion = false; stopRequested = false
    }
    func tick(now: Date = Date()) {
        guard connected else { return }
        if let seen = lastSeen, now.timeIntervalSince(seen) > 6.5 {
            online = false
            direction = "UNKNOWN"
            status = "Rotator offline — no recent feedback. Position and movement are unknown."
        }
        if calibrating && now > calibrationDeadline {
            calibrating = false; calibrationStage = 0
            try? send("<PST><STOP>")
            status = "Calibration was not confirmed; STOP sent."
            addLog(status)
        }
        let interval = direction == "CW" || direction == "CCW" || calibrating ? 0.5 : 2.0
        if now.timeIntervalSince(lastPoll) >= interval {
            do { try send("GET_BEARING") } catch { status = error.localizedDescription }
            lastPoll = now
        }
    }
    func refresh() {
        do { try send("GET_BEARING"); status = "Bearing refresh requested." }
        catch { status = error.localizedDescription }
    }
    private func send(_ command: String) throws {
        if settings.usesBridge { try bridge.send(command) }
        else { try transport.send(command) }
        addLog("TX  \(command)")
    }
    @discardableResult
    func move(to value: Int, isQRZ: Bool = false) -> Bool {
        guard canMove else { status = "Movement requires recent, fault-free controller feedback. Connect or refresh first."; return false }
        guard (0...360).contains(value) else { status = "Enter a bearing between 0 and 360°."; return false }
        let resolved = value % 360
        do {
            // Exact R4 command format. The ESP8266 firmware selects motor direction.
            try send("<AZIMUTH>\(resolved)")
            target = resolved
            trackingMotion = true; stopRequested = false
            qrzArrivalCount = 0
            trackQRZArrival = isQRZ
            if isQRZ { detailsExpanded = true }
            status = "Target \(resolved)° sent. Waiting for movement feedback."
            return true
        } catch { status = error.localizedDescription; return false }
    }
    func goManual() {
        guard let value = Int(manualTarget.trimmingCharacters(in: .whitespaces)), (0...360).contains(value) else { status = "Enter a whole-number bearing from 0 to 360°."; return }
        move(to: value)
    }
    @discardableResult
    func stop() -> Bool {
        calibrating = false; calibrationStage = 0; trackQRZArrival = false
        do {
            try send("<PST><STOP>")
            trackingMotion = true; stopRequested = true
            status = "STOP sent. Waiting for stopped feedback."
            return true
        } catch { status = error.localizedDescription; return false }
    }
    func calibrateNorth() {
        guard canMove else { status = "Connect and wait for valid controller feedback before calibration."; return }
        // The confirmation explains that the antenna must already physically point north.
        do {
            try send("<PST><STOP>")
            calibrating = true; calibrationStage = 1; calibrationSamples = 0
            previousCalibrationBearing = nil; calibrationDeadline = Date().addingTimeInterval(15)
            trackQRZArrival = false; target = nil
            trackingMotion = false; stopRequested = false
            status = "Stopping before setting the current position as north…"
        } catch { status = error.localizedDescription }
    }
    func receive(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        addLog("RX  \(text)")
        guard let reply = RotorReply.parse(text) else { return }
        lastSeen = Date(); online = true
        stuck = reply.stuck; fault = reply.error ?? ""
        if let b = reply.bearing {
            bearing = b
            bearingReceivedAt = Date()
        }
        if reply.direction != "UNKNOWN" { direction = reply.direction }
        if !fault.isEmpty || stuck {
            if calibrating { calibrating = false; calibrationStage = 0; try? send("<PST><STOP>") }
            status = stuck ? "Controller reports ROTATOR STUCK. Press STOP and inspect the rotor." : fault
            return
        }
        let wasCalibrating = calibrating
        if calibrating, text.hasPrefix("GET_BEARING:"), let b = reply.bearing {
            if direction != "STOP" { calibrationSamples = 0; previousCalibrationBearing = nil }
            else if calibrationStage == 1 {
                if let previous = previousCalibrationBearing, Geo.angularDistance(previous, b) <= 3 { calibrationSamples += 1 }
                else { calibrationSamples = 1 }
                previousCalibrationBearing = b
                if calibrationSamples >= 2 {
                    do {
                        try send("CAL_DECL"); calibrationStage = 2; calibrationDeadline = Date().addingTimeInterval(10)
                        status = "North reference sent. Checking controller feedback…"
                    } catch { calibrating = false; status = error.localizedDescription }
                }
            } else if calibrationStage == 2, Geo.angularDistance(b, 0) <= 5 {
                calibrating = false; calibrationStage = 0
                status = "North reference confirmed. No movement command was sent by calibration."
            }
        }
        // Only a fresh bearing plus explicit motor state can confirm movement or arrival.
        if trackingMotion && !wasCalibrating, let b = reply.bearing {
            if reply.direction == "CW" || reply.direction == "CCW" {
                let destination = stopRequested ? "; waiting for STOP confirmation." : target.map { "; target \($0)°." } ?? "."
                status = "Moving \(reply.direction) — current \(heading)°" + destination
            } else if reply.direction == "STOP" {
                if stopRequested {
                    status = "Stopped at \(heading)°."
                } else if let target {
                    if Geo.angularDistance(b, Double(target)) <= 5 {
                        status = "Target reached — stopped at \(heading)° (target \(target)°; within 5°)."
                    } else {
                        status = "Stopped at \(heading)°; target \(target)° has not been reached."
                    }
                }
            } else {
                status = "Current bearing \(heading)°; movement state is unknown."
            }
        }
        if trackQRZArrival, let qrz, let b = reply.bearing, text.hasPrefix("GET_BEARING:") {
            if reply.direction == "STOP", Geo.angularDistance(b, Double(qrz.bearing)) <= 5 { qrzArrivalCount += 1 }
            else { qrzArrivalCount = 0 }
            if qrzArrivalCount >= 2 {
                detailsExpanded = false; trackQRZArrival = false
                status = "Arrived at \(qrz.callsign), \(qrz.bearing)°."
            }
        }
    }
    func lookup() {
        cancelLookup()
        callsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        qrz = nil; qrzError = ""; detailsExpanded = true; trackQRZArrival = false
        guard callsign.range(of: "^[A-Z0-9]+(?:/[A-Z0-9]+)*$", options: .regularExpression) != nil,
              callsign.count <= 15 else {
            qrzError = "Enter a valid callsign or prefix."
            return
        }
        let id = UUID(); lookupID = id
        let call = callsign, config = settings, secret = password
        lookingUp = true
        lookupTask = Task {
            defer {
                if lookupID == id { lookingUp = false }
            }
            do {
                try config.validate()
                let result: QRZStation
                do {
                    result = try await QRZService.lookup(call: call, settings: config, password: secret)
                } catch {
                    try Task.checkCancellation()
                    let qrzFailure = error.localizedDescription
                    let list: DXCCList
                    do {
                        list = try await dxccStore.list()
                    } catch {
                        throw AppError.message("\(qrzFailure) DXCC list unavailable. Open Settings to retry the download.")
                    }
                    guard let match = list.lookup(call, settings: config) else {
                        throw AppError.message("\(qrzFailure) No DXCC match for \(call).")
                    }
                    result = match
                }
                guard !Task.isCancelled, lookupID == id else { return }
                qrz = result
                status = "\(result.source) target ready. Choose Rotate to move the antenna."
                addLog("\(result.source) \(result.callsign) → \(result.bearing)°, \(result.distance) km")
            } catch {
                guard !Task.isCancelled, lookupID == id else { return }
                qrzError = error.localizedDescription
                addLog("Lookup failed: \(qrzError)")
            }
        }
    }
    func updateDXCC() async {
        guard !updatingDXCC else { return }
        updatingDXCC = true
        dxccUpdateStatus = ""
        defer { updatingDXCC = false }
        do {
            let list = try await dxccStore.refresh()
            dxccUpdateStatus = "Saved \(list.entityCount) DXCC entities. Updated \(Date().formatted(date: .abbreviated, time: .shortened))."
        } catch {
            dxccUpdateStatus = "Update failed. \(error.localizedDescription)"
        }
    }
    private func cancelLookup() {
        lookupID = UUID(); lookupTask?.cancel(); lookupTask = nil; lookingUp = false
    }
    func clearQRZ() {
        cancelLookup(); callsign = ""; qrz = nil; qrzError = ""; qrzArrivalCount = 0; trackQRZArrival = false
    }
    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "BuddiHex-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = ISO8601DateFormatter()
        let output = logs.map { "\(format.string(from: $0.date))  \($0.text)" }.joined(separator: "\n")
        do { try output.write(to: url, atomically: true, encoding: .utf8) }
        catch { status = "Could not save the diagnostic log." }
    }
}
