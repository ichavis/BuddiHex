import SwiftUI
import AppKit

let radioGreen = Color(red: 0.49, green: 0.89, blue: 0.63)
let panelColor = Color(red: 0.075, green: 0.10, blue: 0.12)

struct MainView: View {
    @ObservedObject var model: RotatorModel
    @State private var showCalibration = false
    @State private var showLog = false
    private let presets: [(String, Int)] = [("N",0),("NE",45),("E",90),("SE",135),("S",180),("SW",225),("W",270),("NW",315)]
    var body: some View {
        VStack(spacing: 18) {
            header
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 14) {
                    HStack {
                        Text("LIVE AZIMUTH").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Label(model.online ? "CONTROLLER ONLINE" : model.connected ? "WAITING FOR REPLY" : "DISCONNECTED", systemImage: "circle.fill")
                            .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(model.online ? radioGreen : .secondary)
                    }
                    CompassView(bearing: model.bearing ?? 0, target: model.target)
                        .frame(width: 390, height: 390)
                        .accessibilityLabel("Rotor compass, current bearing \(model.heading) degrees")
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(model.heading).font(.system(size: 65, weight: .light, design: .monospaced))
                        Text("°").font(.system(size: 30, weight: .light)).foregroundStyle(radioGreen)
                    }
                    HStack(spacing: 8) {
                        directionPill("CCW")
                        directionPill("STOP")
                        directionPill("CW")
                    }
                    HStack {
                        Text(model.lastSeen.map { "Last reply " + $0.formatted(date: .omitted, time: .standard) } ?? "Waiting for controller")
                        Spacer()
                        if let target = model.target { Text("TARGET \(target)°").foregroundStyle(radioGreen) }
                    }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(20).frame(maxWidth: .infinity).background(panelColor, in: RoundedRectangle(cornerRadius: 18))
                VStack(spacing: 16) {
                    manualCard
                    qrzCard
                    HStack {
                        Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!model.connected)
                        Spacer()
                        Button("Set north…") { showCalibration = true }.disabled(!model.canMove)
                    }.font(.system(size: 12)).padding(.horizontal, 2)
                }.frame(width: 340)
            }
            HStack(spacing: 10) {
                Image(systemName: model.stuck || !model.fault.isEmpty ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(model.stuck || !model.fault.isEmpty ? Color.orange : radioGreen)
                Text(model.status).font(.system(size: 12)).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button { showLog.toggle() } label: { Label("Log", systemImage: "terminal") }
            }.padding(14).background(panelColor, in: RoundedRectangle(cornerRadius: 12))
            if showLog { diagnosticLog.frame(height: 160) }
        }
        .padding(24).padding(.top, 12)
        .background(Color(red: 0.035, green: 0.052, blue: 0.065))
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .alert("Set this physical position as north?", isPresented: $showCalibration) {
            Button("Cancel", role: .cancel) { }
            Button("Set north") { model.calibrateNorth() }
        } message: {
            Text("The antenna must already physically point TRUE NORTH. The app will send STOP, wait for stable stopped feedback, then set the north reference. This does not turn the antenna north.")
        }

    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 29, weight: .light)).foregroundStyle(radioGreen)
            VStack(alignment: .leading, spacing: 3) {
                Text("BUDDIHEX").font(.system(size: 22, weight: .bold, design: .rounded)).tracking(3)
                Text("ANTENNA ROTATOR  /  MAC EDITION").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.7).foregroundStyle(.secondary)
            }
            Spacer()
            if model.settings.usesBridge {
                Text(model.settings.bridgeHost ?? "").font(.callout.monospaced())
            } else {
                Picker("Controller IP", selection: Binding(
                    get: { model.settings.host },
                    set: { model.selectControllerIP($0) }
                )) {
                    ForEach(model.settings.controllerIPs, id: \.self) { ip in
                        Text(ip).tag(ip)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(model.connected)
                .help(model.connected ? "Disconnect to select a different controller." : "Select a saved controller IP.")
            }
            Button(model.connected ? "Disconnect" : "Connect") { model.connected ? model.disconnect() : model.connect() }
                .buttonStyle(.borderedProminent).tint(model.connected ? Color.gray : radioGreen).foregroundStyle(model.connected ? .white : .black)
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.help("Controller, station, QRZ and DXCC settings")
        }
    }
    private func directionPill(_ label: String) -> some View {
        Text(label).font(.system(size: 11, weight: .bold, design: .monospaced))
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(model.online && model.direction == label ? radioGreen.opacity(0.18) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(model.online && model.direction == label ? radioGreen : .secondary)
    }
    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionTitle("01", "MANUAL TARGET")
            HStack {
                TextField("0–360°", text: $model.manualTarget).textFieldStyle(.roundedBorder).font(.system(size: 22, design: .monospaced)).onSubmit { model.goManual() }
                Button("GO") { model.goManual() }.buttonStyle(.borderedProminent).tint(radioGreen).foregroundStyle(.black).disabled(!model.canMove)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                ForEach(presets, id: \.0) { name, value in
                    Button { model.manualTarget = String(value); model.move(to: value) } label: {
                        VStack(spacing: 3) { Text(name).font(.system(size: 12, weight: .semibold)); Text("\(value)°").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 3)
                    }.disabled(!model.canMove)
                }
            }
            Button { model.stop() } label: {
                Label("STOP ROTATOR", systemImage: "stop.fill").font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).tint(Color(red: 0.65, green: 0.19, blue: 0.22)).disabled(!model.connected)
            Text("⌘ . to stop").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }.padding(18).background(panelColor, in: RoundedRectangle(cornerRadius: 16))
    }
    private var qrzCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("02", "CALLSIGN OR PREFIX")
            HStack(spacing: 8) {
                TextField("Callsign or prefix", text: $model.callsign).textFieldStyle(.roundedBorder).font(.system(size: 16, design: .monospaced)).onSubmit { model.lookup() }
                if model.lookingUp { ProgressView().controlSize(.small) }
                Button("Look up") { model.lookup() }.disabled(model.lookingUp)
                Button { model.clearQRZ() } label: { Image(systemName: "xmark") }.help("Clear lookup")
            }
            if !model.qrzError.isEmpty { Text(model.qrzError).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            if let station = model.qrz {
                HStack(alignment: .firstTextBaseline) {
                    Text(station.callsign).font(.system(size: 19, weight: .semibold, design: .monospaced))
                    Text(station.source).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(station.bearing)°").font(.system(size: 26, weight: .light, design: .monospaced)).foregroundStyle(radioGreen)
                }
                if model.detailsExpanded {
                    if !station.name.isEmpty { Text(station.name).font(.system(size: 12)).textSelection(.enabled) }
                    Text([station.grid, station.country, "\(station.distance) km"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Rotate to \(station.bearing)°") { model.move(to: station.bearing, isQRZ: true) }
                        .buttonStyle(.borderedProminent).tint(radioGreen.opacity(0.85)).foregroundStyle(.black).disabled(!model.canMove)
                    Spacer()
                    Button(model.detailsExpanded ? "Less" : "Details") { model.detailsExpanded.toggle() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if !model.lookingUp && model.qrzError.isEmpty {
                Text("Look up a callsign or enter a DXCC prefix such as FG.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(18).background(panelColor, in: RoundedRectangle(cornerRadius: 16))
    }
    private func sectionTitle(_ index: String, _ name: String) -> some View {
        HStack(spacing: 8) { Text(index).foregroundStyle(radioGreen); Text(name).foregroundStyle(.secondary) }
            .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.3)
    }
    private var diagnosticLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("CONTROLLER LOG").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary); Spacer(); Button("Save log…") { model.exportLog() }; Button("Clear") { model.logs = [] } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.logs) { entry in Text(entry.date.formatted(date: .omitted, time: .standard) + "  " + entry.text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }.padding(12).background(panelColor, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsView: View {
    @ObservedObject var model: RotatorModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: StationSettings
    @State private var controllerIPs: String
    @State private var autoConnect: Bool
    @State private var hamlibEnabled: Bool
    @State private var secret: String
    @State private var error = ""
    init(model: RotatorModel) {
        self.model = model
        _settings = State(initialValue: model.settings)
        _controllerIPs = State(initialValue: model.settings.controllerIPs.joined(separator: "\n"))
        _secret = State(initialValue: model.password)
        _autoConnect = State(initialValue: model.autoConnect)
        _hamlibEnabled = State(initialValue: model.hamlibEnabled)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Station settings").font(.title2.bold())
            Form {
                Section("Controller") {
                    TextField("Pi bridge hostname or IP", text: Binding(
                        get: { settings.bridgeHost ?? "" },
                        set: { settings.bridgeHost = $0 }
                    ))
                    TextField("Pi bridge TCP port", value: Binding(
                        get: { settings.resolvedBridgePort },
                        set: { settings.bridgePort = $0 }
                    ), format: .number.grouping(.never))
                    Text("Leave the Pi hostname blank to connect directly to the controller.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !settings.usesBridge {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Controller IPv4 addresses")
                            TextEditor(text: $controllerIPs)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 74)
                                .accessibilityLabel("Controller IPv4 addresses")
                            Text("Enter one IPv4 address per line. All addresses use the ports below.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("Command port", value: $settings.commandPort, format: .number.grouping(.never))
                        TextField("Local reply port", value: $settings.replyPort, format: .number.grouping(.never))
                    }
                    Toggle("Connect automatically when app launches", isOn: $autoConnect)
                }
                Section("SmartSDR for Mac") {
                    Toggle("Enable Hamlib rotctld server", isOn: $hamlibEnabled)
                    if hamlibEnabled {
                        Text("Connect SmartSDR to 127.0.0.1, port 4533. Keep BuddiHex open and connected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.hamlibStatus.isEmpty {
                        Text(model.hamlibStatus).font(.caption)
                    }
                }
                Section("Your antenna location") {
                    TextField("Grid square (4 or 6 characters)", text: Binding(
                        get: { settings.gridSquare ?? "" },
                        set: { settings.setGridSquare($0) }
                    ))
                    TextField("Latitude", value: Binding(
                        get: { settings.latitude },
                        set: { settings.setManualLatitude($0) }
                    ), format: .number.precision(.fractionLength(0...6)))
                    TextField("Longitude", value: Binding(
                        get: { settings.longitude },
                        set: { settings.setManualLongitude($0) }
                    ), format: .number.precision(.fractionLength(0...6)))
                    if let grid = settings.gridSquare, Geo.stationCoordinates(grid) == nil {
                        Text("Use a grid such as FN31 or FN31PR. Clear the grid to use coordinates instead.").font(.caption).foregroundStyle(.orange)
                    }
                    Text("Enter either a grid or coordinates. A valid grid fills its center latitude/longitude automatically. Editing a coordinate clears the grid. West and south are negative.").font(.caption).foregroundStyle(.secondary)
                }
                Section("QRZ XML access") {
                    TextField("Username", text: $settings.username)
                    SecureField("Password", text: $secret)
                    Text("Password is saved in macOS Keychain. QRZ XML location data may require a subscription.").font(.caption).foregroundStyle(.secondary)
                }
                Section("DXCC country list") {
                    HStack {
                        Button("Update DXCC List") { Task { await model.updateDXCC() } }
                            .disabled(model.updatingDXCC)
                        if model.updatingDXCC { ProgressView().controlSize(.small) }
                    }
                    Text("AD1C Country Files · Win-Test mirror").font(.caption).foregroundStyle(.secondary)
                    if !model.dxccUpdateStatus.isEmpty {
                        Text(model.dxccUpdateStatus).font(.caption)
                    }
                }
            }.formStyle(.grouped)
            if !error.isEmpty { Text(error).foregroundStyle(.orange).font(.caption) }
            HStack {
                Text("Stop the Node-RED rotator flow before connecting this app.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        var updated = settings
                        let bridgeHost = updated.bridgeHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        updated.bridgeHost = bridgeHost.isEmpty ? nil : bridgeHost
                        if !updated.usesBridge { try updated.setControllerIPs(controllerIPs) }
                        try model.saveSettings(updated, password: secret, autoConnect: autoConnect)
                        model.setHamlibEnabled(hamlibEnabled)
                        dismiss()
                    }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(radioGreen).foregroundStyle(.black)
            }
        }.padding(24).frame(width: 640, height: 750).preferredColorScheme(.dark)
    }
}

struct CompassView: View {
    var bearing: Double
    var target: Int?
    private let continents: [[CGPoint]] = [
        [(0.13,0.30),(0.18,0.25),(0.24,0.22),(0.30,0.23),(0.33,0.26),(0.30,0.29),(0.27,0.30),(0.25,0.35),(0.21,0.36),(0.19,0.40),(0.15,0.39),(0.12,0.34)].map(CGPoint.init),
        [(0.27,0.39),(0.33,0.40),(0.36,0.46),(0.35,0.52),(0.32,0.58),(0.30,0.66),(0.27,0.73),(0.25,0.66),(0.25,0.60),(0.23,0.54),(0.22,0.47)].map(CGPoint.init),
        [(0.42,0.34),(0.48,0.30),(0.55,0.31),(0.59,0.29),(0.68,0.29),(0.74,0.33),(0.82,0.35),(0.86,0.39),(0.82,0.42),(0.75,0.41),(0.71,0.44),(0.65,0.43),(0.61,0.46),(0.58,0.45),(0.55,0.40),(0.50,0.39),(0.48,0.42),(0.43,0.40)].map(CGPoint.init),
        [(0.45,0.43),(0.51,0.41),(0.56,0.46),(0.57,0.53),(0.54,0.58),(0.52,0.66),(0.48,0.72),(0.44,0.65),(0.41,0.58),(0.40,0.50)].map(CGPoint.init),
        [(0.69,0.58),(0.74,0.55),(0.81,0.57),(0.84,0.62),(0.80,0.67),(0.73,0.68),(0.68,0.63)].map(CGPoint.init)
    ]
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width/2, y: size.height/2)
            let radius = side * 0.43
            let circle = CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2)
            context.fill(Path(ellipseIn: circle), with: .color(Color(red: 0.045, green: 0.08, blue: 0.09)))
            context.stroke(Path(ellipseIn: circle), with: .color(.white.opacity(0.18)), lineWidth: 1)
            let inner = circle.insetBy(dx: 16, dy: 16)
            context.stroke(Path(ellipseIn: inner), with: .color(radioGreen.opacity(0.13)), lineWidth: 1)
            var mapContext = context
            mapContext.clip(to: Path(ellipseIn: inner))
            for points in continents {
                var path = Path()
                for (index, point) in points.enumerated() {
                    let p = CGPoint(x: center.x + (point.x-0.5)*side, y: center.y+(point.y-0.5)*side)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
                mapContext.fill(path, with: .color(radioGreen.opacity(0.13)))
                mapContext.stroke(path, with: .color(radioGreen.opacity(0.25)), lineWidth: 0.7)
            }
            for angle in stride(from: 0, to: 360, by: 10) {
                let major = angle % 30 == 0
                let a = Double(angle) * .pi/180
                var path = Path()
                path.move(to: CGPoint(x: center.x+sin(a)*(radius-3), y: center.y-cos(a)*(radius-3)))
                path.addLine(to: CGPoint(x: center.x+sin(a)*(radius-(major ? 16:9)), y: center.y-cos(a)*(radius-(major ? 16:9))))
                context.stroke(path, with: .color(.white.opacity(major ? 0.65 : 0.23)), lineWidth: major ? 1.5 : 1)
            }
            for (label, angle) in [("N",0.0),("E",90.0),("S",180.0),("W",270.0)] {
                let a = angle * .pi/180
                let p = CGPoint(x: center.x+sin(a)*(radius+17), y: center.y-cos(a)*(radius+17))
                context.draw(Text(label).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(label == "N" ? radioGreen : .white), at: p)
            }
            if let target {
                let a = Double(target) * .pi/180
                var mark = Path()
                for (index, r) in [radius-21, radius-39].enumerated() {
                    let p = CGPoint(x: center.x+sin(a)*r, y: center.y-cos(a)*r)
                    if index == 0 { mark.move(to: p) } else { mark.addLine(to: p) }
                }
                context.stroke(mark, with: .color(.yellow), lineWidth: 4)
            }
            var pointerContext = context
            pointerContext.translateBy(x: center.x, y: center.y)
            pointerContext.rotate(by: .degrees(bearing))
            var arrow = Path()
            arrow.move(to: CGPoint(x: 0, y: -radius+27))
            arrow.addLine(to: CGPoint(x: -9, y: 19))
            arrow.addLine(to: CGPoint(x: 0, y: 9))
            arrow.addLine(to: CGPoint(x: 9, y: 19))
            arrow.closeSubpath()
            pointerContext.fill(arrow, with: .color(radioGreen))
            var tail = Path()
            tail.move(to: CGPoint(x: 0, y: radius-35)); tail.addLine(to: CGPoint(x: -5, y: 0)); tail.addLine(to: CGPoint(x: 5, y: 0)); tail.closeSubpath()
            pointerContext.fill(tail, with: .color(.white.opacity(0.25)))
            context.fill(Path(ellipseIn: CGRect(x: center.x-10, y: center.y-10, width: 20, height: 20)), with: .color(Color(red: 0.12, green: 0.18, blue: 0.18)))
            context.stroke(Path(ellipseIn: CGRect(x: center.x-10, y: center.y-10, width: 20, height: 20)), with: .color(radioGreen), lineWidth: 2)
        }
    }
}
