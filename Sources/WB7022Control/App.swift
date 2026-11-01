import AVFoundation
import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--probe"), i + 1 < args.count {
            Probe.main(outDir: args[i + 1], steps: Array(args[(i + 2)...]))
        } else if let i = args.firstIndex(of: "--suggest"), i + 2 < args.count {
            SuggestionCheck.main(id: args[i + 1], to: URL(fileURLWithPath: args[i + 2]))
        } else if let i = args.firstIndex(of: "--login-item"), i + 2 < args.count {
            // --login-item <on|off|status> <file>: change or report launch at login.
            let action = args[i + 1]
            var log = ""
            do {
                if action != "status" { try LoginItem.set(action == "on") }
            } catch { log += "error: \(error.localizedDescription)\n" }
            log += "status: \(LoginItem.status.rawValue) (0 not registered, 1 enabled, 2 requires approval, 3 not found)\n"
            try? log.write(to: URL(fileURLWithPath: args[i + 2]), atomically: true, encoding: .utf8)
        } else if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            RenderControls.main(to: URL(fileURLWithPath: args[i + 1]), bar: args.contains("--bar"))
        } else {
            WB7022ControlApp.main()
        }
    }
}

struct WB7022ControlApp: App {
    // CLT-only toolchains lack the SwiftUI macro plugin, so no @State here.
    private let model = CameraModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("WB7022 Control", id: "main") {
            ContentView().environment(model)
        }
        .defaultSize(width: 1200, height: 760)

        MenuBarExtra("WB7022", systemImage: "web.camera") {
            MenuBarContent().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The system marks a login-item launch on the open event. `--hidden`
        // does the same by hand, for testing.
        let event = NSAppleEventManager.shared().currentAppleEvent
        LoginItem.launchedAtLogin = CommandLine.arguments.contains("--hidden")
            || (event?.eventID == kAEOpenApplication
                && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard LoginItem.launchedAtLogin else { return }
        // Start in the menu bar only. Hidden rather than closed, so reopening
        // the app (Dock, Finder, Spotlight) can bring the same window back.
        DispatchQueue.main.async {
            Self.mainWindows.forEach { $0.orderOut(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let window = Self.mainWindows.first else { return true }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return false
    }

    /// The app's own window. A hidden window reports it can't become main, so
    /// it's matched by its title bar; the menu bar extra's windows have none.
    private static var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.styleMask.contains(.titled) && !($0 is NSPanel) }
    }
}

/// `--suggest <id> <file>`: applies a suggestion through the app model, records
/// its check result, then puts every setting back.
enum SuggestionCheck {
    static func main(id: String, to url: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let model = CameraModel.shared
            guard let suggestion = Suggestion.all.first(where: { $0.id == id }) else { exit(1) }
            try? await Task.sleep(for: .seconds(5))
            let saved = model.snapshot()
            model.applySuggestion(suggestion)
            try? await Task.sleep(for: .seconds(7))
            let result = model.suggestionStatus ?? "no status"
            model.restore(saved)
            try? await Task.sleep(for: .seconds(2))
            try? (result + "\n").write(to: url, atomically: true, encoding: .utf8)
            exit(0)
        }
        app.run()
    }
}

/// `--render <png>`: draws the controls pane as it looks at launch, offscreen,
/// for checking layout without a screenshot.
enum RenderControls {
    static func main(to url: URL, bar: Bool, args: [String] = CommandLine.arguments) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            // With --bar: the preview's bottom bar at a wide and a narrow width.
            let content: AnyView = bar
                ? AnyView(VStack(alignment: .leading, spacing: 30) {
                    FPSChart().padding(10).frame(width: 1000, alignment: .leading).border(.gray)
                    PreviewBar().padding(10).frame(width: 1000, alignment: .leading).border(.gray)
                    PreviewBar().padding(10).frame(width: 560, alignment: .leading).border(.gray)
                }.padding(20).frame(width: 1100, height: 3400, alignment: .top).background(Color(nsColor: .windowBackgroundColor)))
                : AnyView(ControlsPane().frame(width: 440, height: 3400))
            let host = NSHostingView(rootView: content.environment(CameraModel.shared))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: bar ? 1100 : 440, height: 3400), styleMask: args.contains("--focused") ? [.titled] : [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            // A focused window, so controls draw as they do in normal use
            // (macOS greys switches in windows that aren't key).
            if args.contains("--focused") {
                app.setActivationPolicy(.regular)
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
            }
            // With --bar, let the frame-rate chart collect some history and a change.
            let originalRate = CameraModel.shared.frameRate
            if bar {
                var trace = ""
                for second in 1...8 {
                    try? await Task.sleep(for: .seconds(1))
                    let m = CameraModel.shared
                    trace += "\(second)s: stats.fps=\(String(format: "%.1f", m.stats.fps)) size=\(m.stats.width)x\(m.stats.height) history=\(m.fpsHistory.count)\n"
                }
                try? trace.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                CameraModel.shared.frameRate = CameraModel.shared.frameRate == "30" ? "60" : "30"
                try? await Task.sleep(for: .seconds(8))
            } else {
                try? await Task.sleep(for: .seconds(2))
            }
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            if CameraModel.shared.frameRate != originalRate { CameraModel.shared.frameRate = originalRate }
            exit(0)
        }
        app.run()
    }
}

/// Headless diagnostics: `--probe <dir> [unit:sel:hex | wait:ms | snap:name]…`
/// Each write is followed by a settle delay, a frame grab, and a readback, all
/// logged to <dir>/probe.log. Used to identify what vendor selectors do.
enum Probe {
    static func main(outDir: String, steps: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run(outDir: URL(fileURLWithPath: outDir), steps: steps)
            exit(0)
        }
        app.run()
    }

    @MainActor
    private static func run(outDir: URL, steps: [String]) async {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var log = ""
        func note(_ s: String) {
            log += s + "\n"
            try? log.write(to: outDir.appendingPathComponent("probe.log"), atomically: true, encoding: .utf8)
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else { return note("no camera access") }
        guard let device = UVCDevice() else { return note("camera not found") }
        let feed = CameraFeed()
        // Same as the app: re-send the low-light frame-rate setting after format changes.
        let framePriority = device.get(.cur, unit: 1, selector: 3, length: 1)
        feed.onFormatApplied = { if let framePriority { device.set(unit: 1, selector: 3, bytes: framePriority) } }
        var steps = steps
        var preset = AVCaptureSession.Preset.hd1920x1080
        if let first = steps.first, first.hasPrefix("res:") {
            preset = CameraFeed.presets.first { "res:" + $0.1 == first }?.0 ?? preset
            steps.removeFirst()
        }
        guard feed.start(preset: preset) else { return note("could not start capture") }
        try? await Task.sleep(for: .seconds(4))

        func snap(_ name: String) async {
            let stats: FrameStats = await withCheckedContinuation { cont in
                feed.snapshot { pb, stats in
                    try? pb.jpegData(quality: 0.5)?.write(to: outDir.appendingPathComponent("\(name).jpg"))
                    cont.resume(returning: stats)
                }
            }
            note(String(format: "%@: %dx%d %.1f fps · %@", name, stats.width, stats.height, stats.fps, stats.summary))
        }

        await snap("00-baseline")
        note("baseline xu14=[\(vendorDump(device))]")
        for (n, step) in steps.enumerated() {
            let parts = step.split(separator: ":").map(String.init)
            switch parts.first {
            case "face":
                // face:<seconds>[:<target>] — measure the face every 250 ms; with a
                // target, steer brightness toward it. Brightness is restored after.
                let seconds = parts.count > 1 ? Double(parts[1]) ?? 10 : 10
                let target = parts.count > 2 ? Double(parts[2]) : nil
                let original = device.get(.cur, unit: 3, selector: 2, length: 2).flatMap { Payload.decode($0, size: 2, signed: true) } ?? 128
                var brightness = original
                var controller = target.map { FaceExposureController(target: $0) }
                let start = Date()
                var lastLog = -1
                while Date().timeIntervalSince(start) < seconds {
                    let face: FaceMeasurement? = await withCheckedContinuation { cont in
                        feed.snapshot { pb, _ in cont.resume(returning: FaceMeter.measure(pb)) }
                    }
                    let t = Date().timeIntervalSince(start)
                    if let face, let next = controller?.update(faceLuma: face.luma, brightness: brightness) {
                        var bytes = [UInt8](repeating: 0, count: 2)
                        Payload.encode(next, into: &bytes, size: 2)
                        device.set(unit: 3, selector: 2, bytes: bytes)
                        note(String(format: "%5.1fs face %.0f -> brightness %d", t, face.luma, next))
                        brightness = next
                    } else if Int(t) != lastLog {
                        lastLog = Int(t)
                        note(String(format: "%5.1fs face %@ brightness %d", t, face.map { String(format: "%.0f at %.2f,%.2f %.2fx%.2f", $0.luma, $0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height) } ?? "none", brightness))
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                await snap(String(format: "%02d-face", n + 1))
                if target != nil {
                    var bytes = [UInt8](repeating: 0, count: 2)
                    Payload.encode(original, into: &bytes, size: 2)
                    device.set(unit: 3, selector: 2, bytes: bytes)
                }
            case "format":
                // format:<w>x<h> — pick the device format directly.
                let dims = parts.count > 1 ? parts[1].split(separator: "x").compactMap { Int($0) } : []
                guard dims.count == 2 else { note("bad step \(step)"); continue }
                feed.selectFormat(width: dims[0], height: dims[1])
                try? await Task.sleep(for: .seconds(3))
            case "fps":
                // fps:<n> or fps:highest
                feed.setFrameRate(parts.count > 1 ? Double(parts[1]) : nil)
                try? await Task.sleep(for: .seconds(3))
            case "active":
                note("active: " + feed.describeActive())
            case "preset":
                // preset:<4K|1080p|720p> — session preset only, as other apps do it.
                guard let p = CameraFeed.presets.first(where: { parts.count > 1 && $0.1 == parts[1] })?.0 else { note("bad step \(step)"); continue }
                feed.setSessionPresetOnly(p)
                try? await Task.sleep(for: .seconds(3))
            case "restart":
                feed.restart()
                try? await Task.sleep(for: .seconds(4))
            case "wait":
                try? await Task.sleep(for: .milliseconds(Int(parts[1]) ?? 1000))
            case "trace":
                // trace:<hex> — write a Dell packet, then log every distinct reply for 300 ms.
                guard parts.count == 2, let bytes = Payload.parseHex(parts[1]) else { note("bad step \(step)"); continue }
                let start = Date()
                device.set(unit: DellCommand.unit, selector: DellCommand.commandSelector, bytes: bytes)
                var last = "", seen: [String] = []
                while Date().timeIntervalSince(start) < 0.3 {
                    let r = device.get(.cur, unit: DellCommand.unit, selector: DellCommand.replySelector, length: 8).map(Payload.hex) ?? "-"
                    if r != last { seen.append(String(format: "%3.0fms %@", Date().timeIntervalSince(start) * 1000, r)); last = r }
                    usleep(2_000)
                }
                note("trace \(parts[1]): " + seen.joined(separator: " | "))
            case "selftest":
                // Set each Dell feature to every value, read it back, restore.
                for spec in DellFeatures.specs {
                    guard let command = spec.dell else { continue }
                    let original = device.query(command)
                    let values: [Int]
                    switch spec.kind {
                    case let .toggle(on, off): values = [on, off]
                    case let .choice(cs): values = cs.map(\.value)
                    case .slider: values = []
                    }
                    var results: [String] = []
                    for v in values {
                        device.send(command, value: v)
                        let back = device.query(command)
                        results.append("\(v)->\(back.map(String.init) ?? "nil")\(back == v ? "" : " MISMATCH")")
                    }
                    if let original { device.send(command, value: original) }
                    note("selftest \(spec.id): original=\(original.map(String.init) ?? "nil") \(results.joined(separator: ", ")) restored=\(device.query(command).map(String.init) ?? "nil")")
                }
            case "snap":
                await snap(String(format: "%02d-", n + 1) + (parts.count > 1 ? parts[1] : "snap"))
            default:
                guard parts.count == 3, let unit = UInt8(parts[0]), let sel = UInt8(parts[1]),
                      let bytes = Payload.parseHex(parts[2]) else { note("bad step \(step)"); continue }
                let ok = device.set(unit: unit, selector: sel, bytes: bytes)
                try? await Task.sleep(for: .milliseconds(2500))
                // XU 6 commands answer on selector 2.
                let readSel: UInt8 = unit == 6 ? 2 : sel
                let back = device.get(.cur, unit: unit, selector: readSel, length: bytes.count).map(Payload.hex) ?? "-"
                note("set \(step) ok=\(ok) readback=\(back) xu14=[\(vendorDump(device))]")
                await snap(String(format: "%02d-u%d-s%d-%@", n + 1, unit, sel, parts[2]))
            }
        }
        feed.stop()
        note("done")
    }

    /// Current value of every readable, small XU 14 selector.
    private static func vendorDump(_ device: UVCDevice) -> String {
        (1...31).compactMap { sel -> String? in
            let s = UInt8(sel)
            guard let info = device.info(unit: Catalog.dellXU, selector: s), info.contains(.get),
                  let len = device.length(unit: Catalog.dellXU, selector: s), len <= 4,
                  let cur = device.get(.cur, unit: Catalog.dellXU, selector: s, length: len) else { return nil }
            return "\(sel)=\(Payload.hex(cur))"
        }.joined(separator: " ")
    }
}
