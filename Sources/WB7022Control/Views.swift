import AVFoundation
import Charts
import SwiftUI

struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewHostView { PreviewHostView(session: session) }

    func updateNSView(_ view: PreviewHostView, context: Context) { view.mirrored = mirrored }
}

/// Hosts the preview layer and mirrors it with a layer transform. The capture
/// connection's own mirroring isn't reliably available for external cameras.
final class PreviewHostView: NSView {
    private let preview: AVCaptureVideoPreviewLayer

    var mirrored = false {
        didSet { needsLayout = true }
    }

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Keep the system from mirroring on its own, so the toggle is the only flip.
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        preview.bounds = bounds
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        preview.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }
}

struct ContentView: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        HSplitView {
            PreviewPane()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            ControlsPane()
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 520)
        }
        .frame(minWidth: 900, minHeight: 620)
    }
}

private struct PreviewPane: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.black
                if model.cameraAccess == .authorized && model.connected {
                    if let still = model.stillPreview {
                        Image(nsImage: still).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        PreviewView(session: model.feed.session, mirrored: model.mirrored)
                    }
                    if model.faceExposure, model.stillPreview == nil, let face = model.face, model.stats.width > 0 {
                        FaceBox(face: face, frame: CGSize(width: model.stats.width, height: model.stats.height), mirrored: model.mirrored)
                    }
                    Text(model.stats.summary)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                        .padding(10)
                    if model.state("hdr").available {
                        let on = model.value("hdr") == 1
                        Text(on ? "HDR ON" : "HDR OFF")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(on ? Color.orange : Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                } else {
                    PreviewPlaceholder()
                }
            }
            if model.cameraAccess == .authorized && model.connected {
                FPSChart()
                    .padding(.horizontal, 10).padding(.top, 8)
            }
            PreviewBar()
                .padding(10)
            if let note = model.frameRateNote {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            ForEach([model.linkWarning, model.resolutionWarning].compactMap { $0 }, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
    }
}

private struct PreviewPlaceholder: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: model.connected ? "video.slash" : "web.camera")
                .font(.system(size: 40))
            if !model.connected {
                Text("Dell WB7022 not connected").font(.headline)
                Text("Plug it in. The app picks it up automatically.").foregroundStyle(.secondary)
            } else if model.cameraAccess == .denied || model.cameraAccess == .restricted {
                Text("Camera access is off").font(.headline)
                Text("Controls still work. To see the preview, allow WB7022 Control in System Settings › Privacy & Security › Camera.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            } else {
                ProgressView()
            }
        }
        .foregroundStyle(.white)
        .padding(40)
    }
}

private struct ClipMeter: View {
    let value: Double
    var body: some View {
        Gauge(value: min(value, 20), in: 0...20) { EmptyView() } currentValueLabel: {
            Text(String(format: "%.1f%%", value)).monospacedDigit()
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(value > 5 ? .orange : .green)
        .frame(width: 110)
    }
}

struct ControlsPane: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack {
                    Label(model.connected ? "Connected" : "Not connected",
                          systemImage: model.connected ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.connected ? .green : .secondary)
                    Spacer()
                    Button("Re-read") { model.refreshAll() }.disabled(!model.connected)
                    Button("Defaults") { model.resetToDefaults() }.disabled(!model.connected)
                }
                if model.connected, let link = model.link {
                    ConnectionInfo(link: link, stats: model.stats)
                }
                Toggle("Restore my settings when the camera reconnects", isOn: $model.restoreOnConnect)
                Toggle(isOn: $model.launchAtLogin) {
                    Text("Launch at login")
                    Text(model.launchAtLoginNote ?? "Starts in the menu bar with the window hidden, so your settings and face exposure apply without opening it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }

            Section("Presets") {
                if model.presetNames.isEmpty {
                    Text("No presets yet").foregroundStyle(.secondary)
                }
                ForEach(model.presetNames, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("Load") { model.loadPreset(named: name) }
                        Button(role: .destructive) { model.deletePreset(named: name) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                LabeledContent {
                    HStack {
                        ForEach(Suggestion.all) { suggestion in
                            Button(suggestion.name) { model.applySuggestion(suggestion) }
                                .help(suggestion.summary)
                                .disabled(!model.connected)
                        }
                    }
                } label: {
                    Text("Suggestions")
                    Text(model.suggestionStatus ?? "Starting points for calls and recordings. Hover for details.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("New preset name", text: $model.newPresetName)
                    Button("Save") { model.savePreset(named: model.newPresetName); model.newPresetName = "" }
                        .disabled(model.newPresetName.trimmingCharacters(in: .whitespaces).isEmpty || !model.connected)
                }
            }

            FaceExposureSection()

            ForEach(ControlSection.allCases) { section in
                let specs = Catalog.all.filter { $0.section == section }
                if !specs.isEmpty {
                    Section(section.rawValue) {
                        ForEach(specs) { ControlRow(spec: $0) }
                    }
                }
            }

            Section {
                DisclosureGroup("Vendor controls (XU 14)") { VendorExplorer() }
            } footer: {
                Text("Raw access to Dell's extension unit, for diagnostics only. Values written here aren't saved or restored.")
            }
        }
        .formStyle(.grouped)
    }
}

struct ControlRow: View {
    @Environment(CameraModel.self) private var model
    let spec: ControlSpec

    var body: some View {
        let st = model.state(spec.id)
        Group {
            switch spec.kind {
            case let .toggle(on, off):
                Toggle(isOn: Binding(get: { st.cur == on }, set: { model.set(spec.id, $0 ? on : off) })) {
                    Text(spec.name)
                    caption
                }
            case let .choice(choices):
                Picker(selection: Binding(get: { st.cur }, set: { model.set(spec.id, $0) })) {
                    ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                } label: {
                    Text(spec.name)
                    caption
                }
            case let .slider(format):
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(spec.name)
                        Spacer()
                        Text(format.string(st.cur)).monospacedDigit().foregroundStyle(.secondary)
                        Button { model.set(spec.id, st.def) } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.borderless)
                            .help("Reset to \(format.string(st.def))")
                    }
                    if st.max > st.min {
                        Slider(
                            value: Binding(
                                get: { Double(st.cur) },
                                set: { v in
                                    let snapped = st.min + Int(((v - Double(st.min)) / Double(st.step)).rounded()) * st.step
                                    if snapped != st.cur { model.set(spec.id, snapped) }
                                }),
                            in: Double(st.min)...Double(st.max))
                    }
                    caption
                }
            }
        }
        .disabled(!model.isEnabled(spec))
        .help(spec.help ?? "")
        .opacity(st.available || !model.connected ? 1 : 0.4)
    }

    /// Why the control is greyed out, plus any standing advice. Forms show a
    /// label's second Text as a subtitle, so this stays in the control's row.
    @ViewBuilder private var caption: some View {
        let lines = [model.unmetHint(spec), spec.note].compactMap { $0 }
        if !lines.isEmpty {
            Text(lines.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VendorExplorer: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        if model.vendorSelectors.isEmpty {
            Text("Nothing to show").foregroundStyle(.secondary)
        }
        ForEach(model.vendorSelectors) { sel in
            HStack {
                Text("sel \(sel.selector)").monospacedDigit().frame(width: 52, alignment: .leading)
                Text(access(sel.info)).font(.caption).foregroundStyle(.secondary).frame(width: 30)
                Text(sel.current.map(Payload.hex) ?? "—").font(.body.monospaced()).frame(minWidth: 60, alignment: .leading)
                Spacer()
                if sel.info.contains(.set) {
                    TextField("hex", text: Binding(get: { model.vendorDrafts[sel.selector] ?? "" }, set: { model.vendorDrafts[sel.selector] = $0 }))
                        .font(.body.monospaced())
                        .frame(width: 80)
                    Button("Set") { model.writeVendor(selector: sel.selector, hex: model.vendorDrafts[sel.selector] ?? "") }
                }
            }
        }
        Button("Re-read vendor controls") { model.refreshVendorSelectors() }
    }

    private func access(_ i: UVCDevice.Info) -> String {
        (i.contains(.get) ? "R" : "") + (i.contains(.set) ? "W" : "")
    }
}

struct MenuBarContent: View {
    @Environment(CameraModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !model.connected {
            Text("WB7022 not connected")
        }
        ForEach(Catalog.all.filter { spec in
            if case .toggle = spec.kind { return spec.section == .dell || spec.id == "aeMode" || spec.id == "focusAuto" || spec.id == "wbAuto" }
            return spec.section == .dell
        }) { spec in
            MenuItem(spec: spec)
        }
        Divider()
        Toggle("Face exposure", isOn: Binding(get: { model.faceExposure }, set: { model.faceExposure = $0 }))
            .disabled(!model.connected || model.cameraAccess != .authorized)
        Menu("Suggestions") {
            ForEach(Suggestion.all) { suggestion in
                Button(suggestion.name) { model.applySuggestion(suggestion) }
            }
        }
        .disabled(!model.connected)
        if !model.presetNames.isEmpty {
            Menu("Presets") {
                ForEach(model.presetNames, id: \.self) { name in
                    Button(name) { model.loadPreset(named: name) }
                }
            }
        }
        Divider()
        Button("Open WB7022 Control…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private struct MenuItem: View {
        @Environment(CameraModel.self) private var model
        let spec: ControlSpec
        var body: some View {
            switch spec.kind {
            case let .toggle(on, off):
                Toggle(spec.name, isOn: Binding(get: { model.value(spec.id) == on }, set: { model.set(spec.id, $0 ? on : off) }))
                    .disabled(!model.isEnabled(spec))
            case let .choice(choices):
                Picker(spec.name, selection: Binding(get: { model.value(spec.id) }, set: { model.set(spec.id, $0) })) {
                    ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                }
                .disabled(!model.isEnabled(spec))
            case .slider:
                EmptyView()
            }
        }
    }
}

/// Link speed, how the camera is attached, and what it's actually streaming.
private struct ConnectionInfo: View {
    let link: USBLink
    let stats: FrameStats

    var body: some View {
        LabeledContent("Connection") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(link.label + (link.throughDock ? ", through a Thunderbolt dock" : ", on a Mac port"))
                    .foregroundStyle(link.isUSB3 ? Color.secondary : Color.orange)
                if stats.width > 0 {
                    Text(String(format: "Streaming %d×%d at %.0f fps", stats.width, stats.height, stats.fps))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help("4K needs a USB 3 link: the camera sends uncompressed video. Over USB 2 it only offers smaller sizes.")
    }
}

private struct FaceExposureSection: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Face exposure") {
            Toggle(isOn: $model.faceExposure) {
                Text("Keep my face well exposed")
                Text(model.cameraAccess == .authorized
                     ? "Finds your face and steers the camera's brightness to keep it at the target, whatever is behind you. Works while this app is open; other apps get the adjusted picture too."
                     : "Needs camera access, to see your face.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.connected || model.cameraAccess != .authorized)
            if model.faceExposure {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Target face brightness")
                        Spacer()
                        Text("\(Int(model.faceTarget))").monospacedDigit().foregroundStyle(.secondary)
                        Button("Use current") { model.faceTarget = (model.face?.luma ?? model.faceTarget).rounded() }
                            .disabled(model.face == nil)
                            .help("Keep your face as bright as it is right now.")
                    }
                    Slider(value: $model.faceTarget, in: 60...200)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var status: String {
        guard let face = model.face else { return "No face in view, so the current setting is held." }
        return "Face brightness \(Int(face.luma)), camera brightness \(model.value(CameraModel.steeredControl))."
    }
}

/// Outlines the face being metered, over the aspect-fitted preview.
private struct FaceBox: View {
    let face: FaceMeasurement
    let frame: CGSize
    let mirrored: Bool

    var body: some View {
        GeometryReader { geo in
            let fitted = AVMakeRect(aspectRatio: frame, insideRect: CGRect(origin: .zero, size: geo.size))
            let x = mirrored ? 1 - face.rect.maxX : face.rect.minX
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: face.rect.width * fitted.width, height: face.rect.height * fitted.height)
                .position(x: fitted.minX + (x + face.rect.width / 2) * fitted.width,
                          y: fitted.minY + face.rect.midY * fitted.height)
        }
        .allowsHitTesting(false)
    }
}

/// Resolution, frame rate, mirroring and the clip meter: one row when the
/// preview is wide enough, two otherwise.
struct PreviewBar: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { pickers; mirror; Spacer(); meter }
            VStack(alignment: .leading, spacing: 8) {
                HStack { pickers; Spacer() }
                HStack { mirror; Spacer(); meter }
            }
        }
    }

    @ViewBuilder private var pickers: some View {
        @Bindable var model = model
        Picker("Resolution", selection: $model.resolution) {
            ForEach(CameraFeed.presets, id: \.1) { Text($0.1).tag($0.1) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("The app selects the camera's own 4K mode directly. Apps that ask macOS for its standard \u{201C}4K\u{201D} setting can end up with this camera in its 1080p mode: in testing, macOS chose 1080p both through a Thunderbolt dock and on the Mac's own port, while selecting 4K directly works on both. Apple doesn't document why.")
        HStack(spacing: 6) {
            Text("FPS")
            // A SwiftUI segmented picker can't disable single segments, so this uses
            // the AppKit control to grey out rates the resolution doesn't offer.
            SegmentedChoice(options: CameraModel.frameRateChoices, selection: $model.frameRate,
                            isEnabled: model.isFrameRateOffered)
                .fixedSize()
        }
        .help("60 fps is available at 1080p and 720p. It also needs auto exposure on (manual exposure runs at about 30 fps) and AI Auto Framing off. In low light the camera may still slow down if \u{201C}Allow lower frame rate in low light\u{201D} is on.")
    }

    private var mirror: some View {
        @Bindable var model = model
        return Toggle("Mirror preview", isOn: $model.mirrored)
            .fixedSize()
            .help("Flips only this preview, like a mirror. Video calls and other apps aren't affected.")
    }

    private var meter: some View {
        HStack {
            Text("Highlights clipped").foregroundStyle(.secondary).fixedSize()
            ClipMeter(value: model.stats.highlights)
        }
    }
}

/// An AppKit segmented control, for when individual segments must be disabled.
struct SegmentedChoice: NSViewRepresentable {
    let options: [String]
    @Binding var selection: String
    var isEnabled: (String) -> Bool = { _ in true }

    func makeNSView(context: Context) -> NSSegmentedControl {
        NSSegmentedControl(labels: options, trackingMode: .selectOne,
                           target: context.coordinator, action: #selector(Coordinator.changed(_:)))
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (i, option) in options.enumerated() { control.setEnabled(isEnabled(option), forSegment: i) }
        control.selectedSegment = options.firstIndex(of: selection) ?? -1
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SegmentedChoice
        init(_ parent: SegmentedChoice) { self.parent = parent }

        @objc func changed(_ control: NSSegmentedControl) {
            guard parent.options.indices.contains(control.selectedSegment) else { return }
            parent.selection = parent.options[control.selectedSegment]
        }
    }
}

/// Measured frame rate over the last 90 seconds, with the rate the camera
/// should be delivering and a marker for each change it accepted. Markers are
/// plain lines; hovering one shows what changed.
struct FPSChart: View {
    @Environment(CameraModel.self) private var model

    var body: some View {
        let now = model.fpsHistory.last?.time ?? Date()
        let start = now.addingTimeInterval(-CameraModel.historyWindow)
        let peak = model.fpsHistory.map(\.fps).max() ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Frame rate, last 90 seconds").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let current = model.fpsHistory.last?.fps {
                    Text(String(format: "%.0f fps", current)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Chart {
                if let target = model.expectedFrameRate {
                    RuleMark(y: .value("Expected", target))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                ForEach(model.changeMarkers) { marker in
                    if marker.id == model.hoveredMarker {
                        RuleMark(x: .value("Time", marker.time))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .annotation(position: .top, alignment: .leading, spacing: 2) {
                                Text(marker.label).font(.caption2).foregroundStyle(.orange).fixedSize()
                            }
                    } else {
                        RuleMark(x: .value("Time", marker.time))
                            .foregroundStyle(.orange.opacity(0.7))
                    }
                }
                ForEach(segmented, id: \.index) { point in
                    LineMark(x: .value("Time", point.sample.time), y: .value("FPS", point.sample.fps),
                             series: .value("Run", point.run))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .chartXScale(domain: start...now)
            .chartYScale(domain: 0...max(65, peak + 5))
            .chartYAxis { AxisMarks(position: .leading, values: [0, 30, 60]) }
            .chartXAxis {
                AxisMarks(values: (0...6).map { start.addingTimeInterval(Double($0) * 15) }) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let ago = Int((now.timeIntervalSince(date)).rounded())
                            Text(ago == 0 ? "now" : "\(ago)s ago")
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in model.hoveredMarker = marker(at: phase, proxy: proxy, geo: geo) }
                }
            }
            .frame(height: 110)
            Text(lastChange(now: now)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The marker within a couple of seconds of the pointer, if any.
    private func marker(at phase: HoverPhase, proxy: ChartProxy, geo: GeometryProxy) -> CameraModel.ChangeMarker.ID? {
        guard case let .active(point) = phase, let plot = proxy.plotFrame,
              let date: Date = proxy.value(atX: point.x - geo[plot].origin.x) else { return nil }
        return model.changeMarkers
            .filter { abs($0.time.timeIntervalSince(date)) < 2 }
            .min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }?.id
    }

    private func lastChange(now: Date) -> String {
        guard let last = model.changeMarkers.last else { return "No changes in the last 90 seconds." }
        let ago = max(0, Int(now.timeIntervalSince(last.time).rounded()))
        return "Last change: \(last.label), \(ago == 0 ? "just now" : "\(ago)s ago"). Hover a marker to see what changed."
    }

    /// Samples split into runs wherever frames stopped arriving (the camera
    /// pauses while it switches modes), so the line breaks instead of
    /// bridging the gap.
    private var segmented: [(index: Int, run: Int, sample: CameraModel.FPSSample)] {
        var run = 0
        var previous: Date?
        return model.fpsHistory.enumerated().map { i, sample in
            if let previous, sample.time.timeIntervalSince(previous) > 1.2 { run += 1 }
            previous = sample.time
            return (i, run, sample)
        }
    }
}
