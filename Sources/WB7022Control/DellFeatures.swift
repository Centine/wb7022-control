import Foundation

/// Dell's vendor command channel, as used by Dell Display and Peripheral Manager:
/// 8-byte packets written to extension unit 6 selector 1, replies read from
/// selector 2. Packets are `FF cmd [sub] value…` to set and `FE cmd [sub]` to
/// query, zero-padded. (DDPM stores them as hex longs, e.g. HDR on = 0x0111FF,
/// and sends them little-endian.)
struct DellCommand: Hashable {
    static let unit: UInt8 = 6
    static let commandSelector: UInt8 = 1
    static let replySelector: UInt8 = 2
    static let packetSize = 8

    let command: UInt8
    var sub: UInt8? = nil
    var querySub: UInt8? = nil
    var valueSize = 1
    /// Where the current value sits in a query reply.
    let replyOffset: Int

    func setPacket(_ value: Int) -> [UInt8] {
        var p: [UInt8] = [0xFF, command]
        if let sub { p.append(sub) }
        var v = [UInt8](repeating: 0, count: valueSize)
        Payload.encode(value, into: &v, size: valueSize)
        return Self.pad(p + v)
    }

    var queryPacket: [UInt8] {
        var p: [UInt8] = [0xFE, command]
        if let querySub { p.append(querySub) }
        return Self.pad(p)
    }

    func decodeReply(_ reply: [UInt8]) -> Int? {
        guard reply.count == Self.packetSize, reply[0] == 0xFE, reply[1] == command else { return nil }
        // Several features share a command byte; make sure this reply is ours.
        if let querySub, reply[2] != querySub { return nil }
        return Payload.decode(reply, offset: replyOffset, size: valueSize, signed: false)
    }

    private static func pad(_ p: [UInt8]) -> [UInt8] { p + [UInt8](repeating: 0, count: packetSize - p.count) }
}

enum DellFeatures {
    private static func spec(_ id: String, _ name: String, _ cmd: DellCommand, _ kind: ControlKind, default def: Int,
                             enabledWhen: ControlSpec.Requirement? = nil, help: String? = nil) -> ControlSpec {
        ControlSpec(id: id, name: name, section: .dell, unit: DellCommand.unit, selector: DellCommand.commandSelector,
                    size: DellCommand.packetSize, kind: kind, enabledWhen: enabledWhen, help: help, dell: cmd, defaultValue: def)
    }

    private static let framing = ControlSpec.Requirement(id: "autoFraming", value: 1)

    /// The camera reads the HDR setting only when streaming starts, so the
    /// preview is restarted after a change. Other apps see it on their next start.
    private static var hdr: ControlSpec {
        var s = spec("hdr", "HDR", DellCommand(command: 0x11, replyOffset: 2), .toggle(on: 1, off: 0), default: 0,
                     help: "Lifts shadows and holds back highlights, but can add visible banding to smooth gradients such as walls or the glow around a window. The preview restarts briefly to apply it; other apps using the camera pick it up the next time they start video.")
        s.restartsVideo = true
        return s
    }

    /// Order matters: Auto Framing is applied before the settings it gates.
    static let specs: [ControlSpec] = [
        hdr,
        spec("fov", "Field of view", DellCommand(command: 0x10, sub: 0x01, valueSize: 2, replyOffset: 4),
             .choice([Choice(value: 65, label: "65°"), Choice(value: 78, label: "78°"), Choice(value: 90, label: "90°")]), default: 90),
        spec("autoFraming", "AI Auto Framing", DellCommand(command: 0x14, sub: 0x01, querySub: 0x01, replyOffset: 3),
             .toggle(on: 1, off: 0), default: 0,
             help: "Keeps you centred by cropping and following. Dell notes it doesn't work at 60 fps."),
        spec("frameSize", "Framing", DellCommand(command: 0x14, sub: 0x12, querySub: 0x12, replyOffset: 3),
             .choice([Choice(value: 1, label: "Standard"), Choice(value: 2, label: "Narrow")]), default: 1, enabledWhen: framing),
        spec("trackingSensitivity", "Tracking speed", DellCommand(command: 0x14, sub: 0x11, querySub: 0x11, replyOffset: 3),
             .choice([Choice(value: 1, label: "Normal"), Choice(value: 2, label: "Fast")]), default: 1, enabledWhen: framing),
        spec("cameraTransition", "Smooth transitions", DellCommand(command: 0x14, sub: 0x10, querySub: 0x10, replyOffset: 3),
             .toggle(on: 1, off: 0), default: 1, enabledWhen: framing),
    ]
}
