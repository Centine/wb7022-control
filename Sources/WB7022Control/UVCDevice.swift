import CUVC
import Foundation

/// Thin wrapper over the C control-transfer layer. All calls are serialized.
final class UVCDevice {
    static let vendorID: UInt16 = 0x413C
    static let productID: UInt16 = 0xC015
    static let videoControlInterface: UInt8 = 0

    enum Request: UInt8 {
        case cur = 0x81, min = 0x82, max = 0x83, res = 0x84, len = 0x85, info = 0x86, def = 0x87
    }

    /// GET_INFO capability bits (UVC 1.1, 4.1.2).
    struct Info: OptionSet {
        let rawValue: UInt8
        static let get = Info(rawValue: 1 << 0)
        static let set = Info(rawValue: 1 << 1)
        static let disabledByAuto = Info(rawValue: 1 << 2)
        static let autoUpdate = Info(rawValue: 1 << 3)
    }

    private let handle: OpaquePointer
    private let lock = NSLock()

    init?() {
        guard let h = uvc_open(Self.vendorID, Self.productID, Self.videoControlInterface) else { return nil }
        handle = h
    }

    deinit { uvc_close(handle) }

    func get(_ request: Request, unit: UInt8, selector: UInt8, length: Int) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        var buf = [UInt8](repeating: 0, count: length)
        let n = uvc_get(handle, request.rawValue, unit, selector, &buf, UInt16(length))
        guard n > 0 else { return nil }
        return Array(buf.prefix(Int(n)))
    }

    @discardableResult
    func set(unit: UInt8, selector: UInt8, bytes: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return uvc_set(handle, unit, selector, bytes, UInt16(bytes.count)) == bytes.count
    }

    @discardableResult
    func send(_ command: DellCommand, value: Int) -> Bool {
        set(unit: DellCommand.unit, selector: DellCommand.commandSelector, bytes: command.setPacket(value))
    }

    func query(_ command: DellCommand) -> Int? {
        guard set(unit: DellCommand.unit, selector: DellCommand.commandSelector, bytes: command.queryPacket) else { return nil }
        // The firmware answers within a few milliseconds; poll briefly for the reply.
        // Until it does, the reply selector echoes the query itself, which decodes
        // as 0. A real 0 looks identical, so an echo is only accepted at the end.
        var echoed: Int?
        for _ in 0..<10 {
            if let reply = get(.cur, unit: DellCommand.unit, selector: DellCommand.replySelector, length: DellCommand.packetSize),
               let value = command.decodeReply(reply) {
                if reply != command.queryPacket { return value }
                echoed = value
            }
            usleep(10_000)
        }
        return echoed
    }

    func info(unit: UInt8, selector: UInt8) -> Info? {
        get(.info, unit: unit, selector: selector, length: 1).map { Info(rawValue: $0[0]) }
    }

    /// GET_LEN is only defined for extension units.
    func length(unit: UInt8, selector: UInt8) -> Int? {
        guard let b = get(.len, unit: unit, selector: selector, length: 2), b.count == 2 else { return nil }
        return Int(b[0]) | Int(b[1]) << 8
    }
}

/// Little-endian integer packing for control payloads.
enum Payload {
    static func decode(_ bytes: [UInt8], offset: Int = 0, size: Int, signed: Bool) -> Int? {
        guard size > 0, bytes.count >= offset + size else { return nil }
        var v: UInt64 = 0
        for i in 0..<size { v |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        if signed, size < 8, v & (1 << (UInt64(size) * 8 - 1)) != 0 {
            v |= ~((1 << (UInt64(size) * 8)) - 1)
        }
        return Int(Int64(bitPattern: v))
    }

    static func encode(_ value: Int, into bytes: inout [UInt8], offset: Int = 0, size: Int) {
        let v = UInt64(bitPattern: Int64(value))
        for i in 0..<size { bytes[offset + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func parseHex(_ s: String) -> [UInt8]? {
        let clean = s.filter { !$0.isWhitespace }
        guard !clean.isEmpty, clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}
