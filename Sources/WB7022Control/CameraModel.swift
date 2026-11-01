import AVFoundation
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CameraModel {
    static let shared = CameraModel()

    struct ControlState {
        var info: UVCDevice.Info = []
        var min = 0, max = 1, step = 1, def = 0, cur = 0
        var available = false
        var readable: Bool { info.contains(.get) }
        var settable: Bool { info.contains(.set) }
    }

    struct VendorSelector: Identifiable {
        let selector: UInt8
        let info: UVCDevice.Info
        let length: Int
        var current: [UInt8]?
        var id: UInt8 { selector }
    }

    private(set) var connected = false
    private(set) var states: [String: ControlState] = [:]
    private(set) var stats = FrameStats()
    private(set) var link: USBLink?
    /// Resolutions the camera offers on its current connection.
    private(set) var offeredResolutions: [String] = []
    private(set) var cameraAccess: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var presetNames: [String] = []
    private(set) var vendorSelectors: [VendorSelector] = []
    var lastError: String?
    // View-local UI state lives here because @State is unavailable without Xcode.
    var newPresetName = ""
    var vendorDrafts: [UInt8: String] = [:]
    /// Shown instead of the live preview, for `--render --window` screenshots.
    @ObservationIgnored var stillPreview: NSImage?

    var mirrored: Bool { didSet { defaults.set(mirrored, forKey: Keys.mirrored) } }
    var restoreOnConnect: Bool { didSet { defaults.set(restoreOnConnect, forKey: Keys.restore) } }
    var resolution: String {
        didSet {
            defaults.set(resolution, forKey: Keys.resolution)
            feed.setPreset(preset(for: resolution))
            markChange(resolution)
        }
    }
    static let frameRateChoices = ["Highest", "60", "30"]
    var frameRate: String {
        didSet {
            defaults.set(frameRate, forKey: Keys.frameRate)
            feed.setFrameRate(Double(frameRate))
            markChange(frameRate == "Highest" ? "Highest fps" : "\(frameRate) fps")
        }
    }
    /// Frame rates the camera offers per resolution on its current connection.
    private(set) var offeredFrameRates: [String: [Int]] = [:]

    /// Keeps the face at a target brightness by steering the brightness control.
    var faceExposure: Bool {
        didSet {
            defaults.set(faceExposure, forKey: Keys.faceExposure)
            faceExposureChanged()
            markChange("Face exposure \(faceExposure ? "on" : "off")")
        }
    }
    var faceTarget: Double {
        didSet {
            defaults.set(faceTarget, forKey: Keys.faceTarget)
            faceController.target = faceTarget
        }
    }
    private(set) var face: FaceMeasurement?
    private var faceController: FaceExposureController
    /// The user's own brightness, put back when face exposure turns off.
    private var userBrightness: Int?

    let feed = CameraFeed()
    private var device: UVCDevice?
    private let specs = Catalog.all
    private let defaults = UserDefaults.standard
    private var lastValues: [String: Int]
    private var observers: [NSObjectProtocol] = []
    /// Dell features re-queried once after an unfinished reply.
    private var retriedQueries: Set<String> = []

    private enum Keys {
        static let last = "lastValues", presets = "presets", restore = "restoreOnConnect"
        static let mirrored = "mirrored", resolution = "resolution", frameRate = "frameRate"
        static let faceExposure = "faceExposure", faceTarget = "faceTarget"
    }

    init() {
        lastValues = defaults.dictionary(forKey: Keys.last) as? [String: Int] ?? [:]
        restoreOnConnect = defaults.object(forKey: Keys.restore) as? Bool ?? true
        mirrored = defaults.object(forKey: Keys.mirrored) as? Bool ?? true
        resolution = defaults.string(forKey: Keys.resolution) ?? "1080p"
        frameRate = defaults.string(forKey: Keys.frameRate) ?? "30"
        let target = defaults.object(forKey: Keys.faceTarget) as? Double ?? 110
        faceExposure = defaults.bool(forKey: Keys.faceExposure)
        faceTarget = target
        faceController = FaceExposureController(target: target)
        presetNames = presets.keys.sorted()
        feed.onStats = { [weak self] s in self?.recordStats(s) }
        feed.onFace = { [weak self] f in self?.handleFace(f) }
        feed.onFormatApplied = { [weak self] in self?.reassertFramePriority() }
        feed.setFrameRate(Double(frameRate))
        feed.setFaceMetering(faceExposure)
        if faceExposure { userBrightness = lastValues["brightness"] }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            // Give the device a moment to finish enumerating before talking to it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self?.connect(reapply: true) } }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, CameraFeed.findDevice() == nil else { return }
                self.device = nil
                self.connected = false
                self.link = nil
                self.offeredResolutions = []
                self.feed.stop()
            }
        })
        connect(reapply: restoreOnConnect)
        requestCameraAccess()
    }

    // MARK: Connection

    func connect(reapply: Bool) {
        device = UVCDevice()
        connected = device != nil
        guard connected else { return }
        link = USBLink.current()
        offeredResolutions = CameraFeed.offeredResolutions()
        offeredFrameRates = Dictionary(uniqueKeysWithValues: offeredResolutions.map { ($0, CameraFeed.frameRates(for: $0)) })
        refreshAll()
        if reapply, restoreOnConnect, !lastValues.isEmpty { apply(lastValues, label: "Settings restored") }
        if cameraAccess == .authorized { feed.start(preset: preset(for: resolution)) }
    }

    func requestCameraAccess() {
        // connect() already started the feed if access was granted earlier;
        // starting it again makes the camera switch modes twice at launch.
        let alreadyAuthorized = cameraAccess == .authorized
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
                    if granted, !alreadyAuthorized, self.connected { self.feed.start(preset: self.preset(for: self.resolution)) }
                }
            }
        }
    }

    private func preset(for name: String) -> AVCaptureSession.Preset {
        // Fall back to the best resolution the connection offers, not the session's generic default.
        let name = offeredResolutions.isEmpty || offeredResolutions.contains(name) ? name : offeredResolutions[0]
        return CameraFeed.presets.first { $0.1 == name }?.0 ?? .hd1920x1080
    }

    /// Why the preview isn't at the chosen resolution, if it isn't.
    var resolutionWarning: String? {
        guard connected else { return nil }
        if !offeredResolutions.isEmpty, !offeredResolutions.contains(resolution) {
            let why = link.map { $0.isUSB3 ? "" : " at \($0.label)" } ?? ""
            return "The camera doesn't offer \(resolution)\(why), so the preview uses \(offeredResolutions[0])."
        }
        if let want = CameraFeed.dimensions[resolution], stats.width > 0, (stats.width, stats.height) != want {
            return "Asked for \(resolution), but the camera is sending \(stats.width)×\(stats.height)."
        }
        return nil
    }

    /// Whether the camera offers this frame-rate choice at the current resolution.
    func isFrameRateOffered(_ choice: String) -> Bool {
        guard let fps = Int(choice), let offered = offeredFrameRates[resolution], !offered.isEmpty else { return true }
        return offered.contains(fps)
    }

    /// The frame rate in effect, and anything that limits it.
    var frameRateNote: String? {
        guard connected else { return nil }
        let offered = offeredFrameRates[resolution] ?? []
        var lines: [String] = []
        var effective = Int(frameRate) ?? offered.first
        if let want = Int(frameRate), let best = offered.first, !offered.contains(want) {
            lines.append("\(resolution) goes up to \(best) fps, so it runs at \(best).")
            effective = best
        }
        if let effective, effective > 30, value("autoFraming") == 1 {
            lines.append("Dell's auto framing doesn't work above 30 fps.")
        }
        if let effective, stats.fps > 0, stats.fps < Double(effective) * 0.85 {
            if value("aeMode") == 1 {
                lines.append(String(format: "Running at %.0f fps: with auto exposure off, this camera stays around 30 fps.", stats.fps))
            } else if value("aePriority") == 1 {
                lines.append(String(format: "Running at %.0f fps: in low light the camera slows down because \u{201C}Allow lower frame rate in low light\u{201D} is on.", stats.fps))
            } else {
                lines.append(String(format: "Running at %.0f fps.", stats.fps))
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// Connection speed advice when the link can't carry full resolution.
    var linkWarning: String? {
        guard connected, let link, !link.isUSB3 else { return nil }
        return "Connected at \(link.label). 4K and HDR need USB 3: try another port, cable or dock."
    }

    // MARK: Reading

    func refreshAll() {
        for spec in specs { refresh(spec) }
        refreshVendorSelectors()
    }

    private func refresh(_ spec: ControlSpec) {
        guard let device else { return }
        var st = states[spec.id] ?? ControlState()
        if let command = spec.dell {
            let value = device.query(command)
            // A value outside the choices is a reply the camera hadn't finished
            // (seen right after AI framing turns on): keep the last known value
            // and ask once more shortly.
            if case let .choice(choices) = spec.kind, let v = value, !choices.contains(where: { $0.value == v }) {
                st.cur = lastValues[spec.id] ?? spec.defaultValue ?? st.cur
                states[spec.id] = st
                if retriedQueries.insert(spec.id).inserted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(spec) }
                }
                return
            }
            retriedQueries.remove(spec.id)
            st.available = value != nil
            st.info = value != nil ? [.get, .set] : []
            st.def = spec.defaultValue ?? 0
            st.cur = value ?? lastValues[spec.id] ?? st.def
            states[spec.id] = st
            return
        }
        guard let info = device.info(unit: spec.unit, selector: spec.selector) else {
            st.available = false
            states[spec.id] = st
            return
        }
        st.info = info
        st.available = true
        func read(_ r: UVCDevice.Request) -> Int? {
            device.get(r, unit: spec.unit, selector: spec.selector, length: spec.size)
                .flatMap { Payload.decode($0, offset: spec.offset, size: spec.field, signed: spec.signed) }
        }
        if case .slider = spec.kind {
            st.min = read(.min) ?? st.min
            st.max = read(.max) ?? st.max
            st.step = Swift.max(1, read(.res) ?? 1)
        }
        if let d = read(.def) { st.def = d }
        if info.contains(.get), let c = read(.cur) {
            st.cur = c
        } else if let remembered = lastValues[spec.id] {
            st.cur = remembered  // set-only control: show what we last wrote
        }
        states[spec.id] = st
    }

    /// Re-reads controls whose availability depends on an auto mode.
    private func refreshDependents(of id: String) {
        for spec in specs where spec.enabledWhen?.id == id { refresh(spec) }
    }

    func state(_ id: String) -> ControlState { states[id] ?? ControlState() }

    func value(_ id: String) -> Int { state(id).cur }

    func isEnabled(_ spec: ControlSpec) -> Bool {
        let st = state(spec.id)
        guard connected, st.available, st.settable else { return false }
        if spec.id == Self.steeredControl, faceExposure { return false }
        if let req = spec.enabledWhen { return req.isMet(by: value(req.id)) }
        return true
    }

    /// Why a control is greyed out, when another control is holding it back.
    func unmetHint(_ spec: ControlSpec) -> String? {
        if connected, spec.id == Self.steeredControl, faceExposure {
            return "Face exposure is adjusting this. Your own setting comes back when you turn it off."
        }
        guard connected, let req = spec.enabledWhen, !req.isMet(by: value(req.id)) else { return nil }
        return req.hint
    }

    // MARK: Writing

    func set(_ id: String, _ newValue: Int) {
        guard let spec = specs.first(where: { $0.id == id }) else { return }
        if write(spec, newValue) {
            markChange(describe(spec, newValue), key: spec.id)
            if spec.restartsVideo { feed.restart() }
        }
        refresh(spec)
        refreshDependents(of: id)
        // Other views of the same control (pan/tilt, zoom/field of view).
        if spec.dell == nil {
            specs.filter { $0.dell == nil && $0.unit == spec.unit && $0.selector == spec.selector && $0.id != spec.id }.forEach(refresh)
        }
        rememberCurrent()
    }

    @discardableResult
    private func write(_ spec: ControlSpec, _ value: Int) -> Bool {
        guard let device else { return false }
        if let command = spec.dell {
            let ok = device.send(command, value: value)
            if ok { lastValues[spec.id] = value; lastError = nil } else { lastError = "Camera rejected \(spec.name)" }
            return ok
        }
        var payload: [UInt8]
        if spec.field < spec.size {
            // Packed payload: read the whole thing, patch our field.
            guard let cur = device.get(.cur, unit: spec.unit, selector: spec.selector, length: spec.size), cur.count == spec.size else { return false }
            payload = cur
        } else {
            payload = [UInt8](repeating: 0, count: spec.size)
        }
        Payload.encode(value, into: &payload, offset: spec.offset, size: spec.field)
        let ok = device.set(unit: spec.unit, selector: spec.selector, bytes: payload)
        if ok {
            lastValues[spec.id] = value
            lastError = nil
        } else {
            lastError = "Camera rejected \(spec.name) = \(value)"
        }
        return ok
    }

    /// Applies a stored set of values in catalog order, so auto modes land
    /// before the manual values they gate.
    func apply(_ values: [String: Int], label: String? = nil) {
        if let label { markChange(label) }
        var needsRestart = false
        if faceExposure, let b = values[Self.steeredControl] { userBrightness = b }
        for spec in specs {
            guard let v = values[spec.id], state(spec.id).settable else { continue }
            if let req = spec.enabledWhen, let gate = values[req.id], !req.isMet(by: gate) { continue }
            let changed = v != state(spec.id).cur
            if write(spec, v), changed, spec.restartsVideo { needsRestart = true }
        }
        if needsRestart { feed.restart() }
        refreshAll()
        rememberCurrent()
    }

    func resetToDefaults() {
        var values: [String: Int] = [:]
        for spec in specs where state(spec.id).available { values[spec.id] = state(spec.id).def }
        apply(values, label: "Defaults")
    }

    private func currentValues() -> [String: Int] {
        var out: [String: Int] = [:]
        for spec in specs {
            let st = state(spec.id)
            // While face exposure steers brightness, keep the user's own value.
            if spec.id == Self.steeredControl, faceExposure {
                if let own = userBrightness { out[spec.id] = own }
                continue
            }
            if st.available, st.settable, st.readable || lastValues[spec.id] != nil { out[spec.id] = st.cur }
        }
        return out
    }

    private func rememberCurrent() {
        lastValues.merge(currentValues()) { _, new in new }
        defaults.set(lastValues, forKey: Keys.last)
    }

    /// After a format or frame-rate change the camera quietly goes back to
    /// lowering its frame rate in low light, while still reporting the setting
    /// as off: 1080p at 60 fps then runs at 30. Writing the setting again
    /// restores it immediately (measured on the camera).
    private func reassertFramePriority() {
        guard let spec = specs.first(where: { $0.id == "aePriority" }), state(spec.id).settable else { return }
        write(spec, value(spec.id))
    }

    // MARK: Frame-rate history

    struct FPSSample { let time: Date; let fps: Double }
    struct ChangeMarker: Identifiable {
        let id = UUID()
        let time: Date
        let label: String
        let key: String
    }
    static let historyWindow: TimeInterval = 90
    /// Published once a second, so the chart redraws at that rate rather than
    /// with every stats update.
    private(set) var fpsHistory: [FPSSample] = []
    /// Changes the camera accepted, for marking on the frame-rate chart.
    private(set) var changeMarkers: [ChangeMarker] = []
    /// The chart marker under the pointer (view state; @State needs Xcode's macros).
    var hoveredMarker: ChangeMarker.ID?
    @ObservationIgnored private var fpsBuffer: [FPSSample] = []
    @ObservationIgnored private var lastChartUpdate = Date.distantPast

    private func recordStats(_ s: FrameStats) {
        stats = s
        let now = Date()
        // Two samples a second is plenty for a 90-second chart.
        if s.fps > 0, now.timeIntervalSince(fpsBuffer.last?.time ?? .distantPast) >= 0.5 {
            fpsBuffer.append(FPSSample(time: now, fps: s.fps))
        }
        guard now.timeIntervalSince(lastChartUpdate) >= 1 else { return }
        lastChartUpdate = now
        let cutoff = now.addingTimeInterval(-Self.historyWindow)
        fpsBuffer.removeAll { $0.time < cutoff }
        fpsHistory = fpsBuffer
        if changeMarkers.contains(where: { $0.time < cutoff }) { changeMarkers.removeAll { $0.time < cutoff } }
    }

    /// `key` groups changes to the same control: a slider drag becomes one marker.
    private func markChange(_ label: String, key: String? = nil) {
        guard connected else { return }
        let now = Date(), key = key ?? label
        if let last = changeMarkers.last, last.key == key, now.timeIntervalSince(last.time) < 1.5 {
            changeMarkers.removeLast()
        }
        changeMarkers.append(ChangeMarker(time: now, label: label, key: key))
    }

    private func describe(_ spec: ControlSpec, _ value: Int) -> String {
        switch spec.kind {
        case let .toggle(on, _): return "\(spec.name) \(value == on ? "on" : "off")"
        case let .choice(choices): return "\(spec.name) \(choices.first { $0.value == value }?.label ?? "\(value)")"
        case let .slider(format): return "\(spec.name) \(format.string(value))"
        }
    }

    /// The frame rate the camera should be delivering, given the choice and resolution.
    var expectedFrameRate: Int? {
        let offered = offeredFrameRates[resolution] ?? []
        if let want = Int(frameRate), offered.isEmpty || offered.contains(want) { return want }
        return offered.first
    }

    // MARK: Face exposure

    /// The control face exposure steers.
    static let steeredControl = "brightness"

    private func faceExposureChanged() {
        feed.setFaceMetering(faceExposure)
        if faceExposure {
            userBrightness = lastValues[Self.steeredControl] ?? value(Self.steeredControl)
            faceController = FaceExposureController(target: faceTarget)
        } else {
            face = nil
            if let own = userBrightness { set(Self.steeredControl, own) }
            userBrightness = nil
        }
    }

    private func handleFace(_ measurement: FaceMeasurement?) {
        face = measurement
        guard faceExposure, let measurement, let device,
              let spec = specs.first(where: { $0.id == Self.steeredControl }), state(spec.id).settable,
              let next = faceController.update(faceLuma: measurement.luma, brightness: value(spec.id)) else { return }
        // Written directly, so the user's own brightness stays the remembered one.
        var payload = [UInt8](repeating: 0, count: spec.size)
        Payload.encode(next, into: &payload, size: spec.size)
        if device.set(unit: spec.unit, selector: spec.selector, bytes: payload) { states[spec.id]?.cur = next }
    }

    // MARK: Suggestions

    /// Result of the last suggestion's format check.
    private(set) var suggestionStatus: String?
    @ObservationIgnored private var suggestionCheck: UUID?

    func applySuggestion(_ suggestion: Suggestion) {
        if resolution != suggestion.resolution { resolution = suggestion.resolution }
        if frameRate != suggestion.frameRate { frameRate = suggestion.frameRate }
        apply(suggestion.values, label: "Suggestion: \(suggestion.name)")
        if let face = suggestion.faceExposure, faceExposure != face { faceExposure = face }
        suggestionStatus = "\(suggestion.name): checking what the camera delivers…"
        let check = UUID()
        suggestionCheck = check
        // Format changes take a couple of seconds to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.suggestionCheck == check else { return }
            self.suggestionStatus = self.verify(suggestion)
        }
    }

    /// Diagnostics: everything a suggestion can change, to put back afterwards.
    struct Snapshot { let values: [String: Int]; let resolution: String; let frameRate: String; let faceExposure: Bool }

    func snapshot() -> Snapshot {
        Snapshot(values: currentValues(), resolution: resolution, frameRate: frameRate, faceExposure: faceExposure)
    }

    func restore(_ snapshot: Snapshot) {
        if faceExposure != snapshot.faceExposure { faceExposure = snapshot.faceExposure }
        if resolution != snapshot.resolution { resolution = snapshot.resolution }
        if frameRate != snapshot.frameRate { frameRate = snapshot.frameRate }
        apply(snapshot.values)
    }

    private func verify(_ suggestion: Suggestion) -> String {
        guard stats.width > 0, stats.fps > 0 else {
            return "\(suggestion.name): couldn't check, the preview isn't running."
        }
        let delivered = String(format: "%d×%d at %.0f fps", stats.width, stats.height, stats.fps)
        let sizeOK = CameraFeed.dimensions[suggestion.resolution].map { $0 == (stats.width, stats.height) } ?? true
        let rateOK = Double(suggestion.frameRate).map { stats.fps >= $0 * 0.9 } ?? true
        if sizeOK && rateOK { return "\(suggestion.name): applied, and the camera delivers \(delivered)." }
        let reason = [resolutionWarning, frameRateNote].compactMap { $0 }.joined(separator: " ")
        return "\(suggestion.name): applied, but the camera delivers \(delivered). \(reason)"
    }

    // MARK: Launch at login

    var launchAtLogin: Bool = LoginItem.status == .enabled {
        didSet {
            guard launchAtLogin != (LoginItem.status == .enabled) else { return }
            do { try LoginItem.set(launchAtLogin) } catch { lastError = "Couldn't change launch at login: \(error.localizedDescription)" }
            launchAtLogin = LoginItem.status == .enabled
        }
    }

    /// Shown when macOS wants the user to approve the login item.
    var launchAtLoginNote: String? {
        LoginItem.status == .requiresApproval
            ? "Approve WB7022 Control in System Settings › General › Login Items to finish." : nil
    }

    // MARK: Presets

    private var presets: [String: [String: Int]] {
        get { defaults.dictionary(forKey: Keys.presets) as? [String: [String: Int]] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.presets); presetNames = newValue.keys.sorted() }
    }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        presets[trimmed] = currentValues()
    }

    func loadPreset(named name: String) {
        if let values = presets[name] { apply(values, label: "Preset \u{201C}\(name)\u{201D}") }
    }

    func deletePreset(named name: String) {
        presets[name] = nil
    }

    // MARK: Vendor explorer (XU 14)

    func refreshVendorSelectors() {
        guard let device else { vendorSelectors = []; return }
        vendorSelectors = (1...31).compactMap { sel in
            let s = UInt8(sel)
            guard let info = device.info(unit: Catalog.dellXU, selector: s),
                  let len = device.length(unit: Catalog.dellXU, selector: s), len > 0, len <= 64 else { return nil }
            let cur = info.contains(.get) ? device.get(.cur, unit: Catalog.dellXU, selector: s, length: len) : nil
            return VendorSelector(selector: s, info: info, length: len, current: cur)
        }
    }

    func writeVendor(selector: UInt8, hex: String) {
        guard let device, let sel = vendorSelectors.first(where: { $0.selector == selector }) else { return }
        guard let bytes = Payload.parseHex(hex), bytes.count == sel.length else {
            lastError = "Selector \(selector) needs exactly \(sel.length) byte(s) of hex"
            return
        }
        let ok = device.set(unit: Catalog.dellXU, selector: selector, bytes: bytes)
        lastError = ok ? nil : "Camera rejected XU14 selector \(selector)"
        if ok { markChange("XU14 selector \(selector)") }
        refreshVendorSelectors()
    }
}
