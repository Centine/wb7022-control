import AVFoundation
import CoreImage

/// Luma statistics for judging exposure and HDR: how much of the frame is
/// blown out or crushed, and how wide the tonal spread is.
struct FrameStats: Equatable {
    var mean = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var p5 = 0
    var p95 = 0
    var width = 0
    var height = 0
    /// Measured from frame timestamps, not the requested rate.
    var fps = 0.0

    var summary: String {
        String(format: "mean %.0f · p5 %d · p95 %d · highlights %.1f%% · shadows %.1f%%", mean, p5, p95, highlights, shadows)
    }

    /// Expects 8-bit video-range luma in plane 0 (16…235).
    static func measure(_ pb: CVPixelBuffer) -> FrameStats {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferIsPlanar(pb), let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return FrameStats() }
        let width = CVPixelBufferGetWidthOfPlane(pb, 0)
        let height = CVPixelBufferGetHeightOfPlane(pb, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let step = max(1, width / 320)

        var hist = [Int](repeating: 0, count: 256)
        var sum = 0, n = 0
        for y in stride(from: 0, to: height, by: step) {
            let row = luma + y * rowBytes
            for x in stride(from: 0, to: width, by: step) {
                let v = Int(row[x])
                hist[v] += 1; sum += v; n += 1
            }
        }
        guard n > 0 else { return FrameStats() }
        var s = FrameStats()
        s.width = CVPixelBufferGetWidth(pb)
        s.height = CVPixelBufferGetHeight(pb)
        s.mean = Double(sum) / Double(n)
        s.highlights = Double(hist[233...].reduce(0, +)) * 100 / Double(n)
        s.shadows = Double(hist[...18].reduce(0, +)) * 100 / Double(n)
        var acc = 0
        for i in 0..<256 {
            acc += hist[i]
            if s.p5 == 0, acc >= n / 20 { s.p5 = i }
            if acc >= n * 19 / 20 { s.p95 = i; break }
        }
        return s
    }
}

final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "wb7022.session")
    private let frameQueue = DispatchQueue(label: "wb7022.frames")
    private var input: AVCaptureDeviceInput?
    // sessionQueue only.
    private var size: (Int, Int)?
    private var wantedFrameRate: Double? = 30
    private var frameCount = 0
    /// Recent frame timestamps, for a steady frame-rate reading.
    private var frameTimes: [Double] = []
    private var fps = 0.0
    private let faceQueue = DispatchQueue(label: "wb7022.faces")
    // Touched only on frameQueue.
    private var faceMetering = false
    private var measuringFace = false
    private var lastFaceTime = CMTime.zero
    private var pendingSnapshots: [(CVPixelBuffer, FrameStats) -> Void] = []

    /// Called on the main queue a few times per second.
    var onStats: ((FrameStats) -> Void)?
    /// Called on the main queue after the format or frame rate changes.
    var onFormatApplied: (() -> Void)?
    /// Called on the main queue about four times a second while face metering
    /// is on; nil when no face is in view.
    var onFace: ((FaceMeasurement?) -> Void)?

    func setFaceMetering(_ on: Bool) {
        frameQueue.async { self.faceMetering = on }
    }

    static func findDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.first { $0.modelID.contains("VendorID_16700") && $0.modelID.contains("ProductID_49173") }
    }

    /// Largest first.
    static let presets: [(AVCaptureSession.Preset, String)] = [
        (.hd4K3840x2160, "4K"), (.hd1920x1080, "1080p"), (.hd1280x720, "720p"),
    ]
    static let dimensions: [String: (Int, Int)] = ["4K": (3840, 2160), "1080p": (1920, 1080), "720p": (1280, 720)]

    /// Preset names the camera supports right now, largest first. Over a slow
    /// link the camera stops offering the larger ones.
    static func offeredResolutions() -> [String] {
        guard let device = findDevice() else { return [] }
        return presets.filter { device.supportsSessionPreset($0.0) }.map(\.1)
    }

    @discardableResult
    func start(preset: AVCaptureSession.Preset) -> Bool {
        guard let device = Self.findDevice(), let newInput = try? AVCaptureDeviceInput(device: device) else { return false }
        sessionQueue.async { [self] in
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            if session.canAddInput(newInput) { session.addInput(newInput); input = newInput }
            if session.outputs.isEmpty {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: frameQueue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            selectFormat(for: preset)
        }
        return true
    }

    func setPreset(_ preset: AVCaptureSession.Preset) {
        sessionQueue.async { [self] in
            guard session.canSetSessionPreset(preset) else { return }
            session.beginConfiguration()
            session.sessionPreset = preset
            session.commitConfiguration()
            selectFormat(for: preset)
        }
    }

    /// Stops and restarts streaming, so settings the camera only reads at
    /// stream start (HDR) take effect. Has no effect on the camera while
    /// another app keeps it streaming.
    func restart() {
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
            session.startRunning()
            // Starting again can bring back the preset's own format.
            if let (w, h) = size { applyFormat(width: w, height: h) }
        }
    }

    /// Selects the device's own format of this size directly. Session presets
    /// alone leave this camera at 1080p even when asked for 4K.
    func selectFormat(width: Int, height: Int) {
        sessionQueue.async { [self] in applyFormat(width: width, height: height) }
    }

    /// Frames per second to ask for; nil means the highest the size allows.
    func setFrameRate(_ fps: Double?) {
        sessionQueue.async { [self] in
            wantedFrameRate = fps
            if let (w, h) = size { applyFormat(width: w, height: h) }
        }
    }

    /// On sessionQueue.
    private func selectFormat(for preset: AVCaptureSession.Preset) {
        guard let name = Self.presets.first(where: { $0.0 == preset })?.1, let (w, h) = Self.dimensions[name] else { return }
        applyFormat(width: w, height: h)
    }

    /// The camera's 420v formats of a size, each with its frame-rate ranges.
    private static func ranges(_ device: AVCaptureDevice, width: Int, height: Int) -> [(AVCaptureDevice.Format, AVFrameRateRange)] {
        device.formats.flatMap { f -> [(AVCaptureDevice.Format, AVFrameRateRange)] in
            let d = f.formatDescription.dimensions
            guard Int(d.width) == width, Int(d.height) == height,
                  CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return [] }
            return f.videoSupportedFrameRateRanges.map { (f, $0) }
        }
    }

    /// Whole frame rates the camera offers at a preset size, highest first.
    static func frameRates(for name: String) -> [Int] {
        guard let device = findDevice(), let (w, h) = dimensions[name] else { return [] }
        return Set(ranges(device, width: w, height: h).map { Int($0.1.maxFrameRate.rounded()) }).sorted(by: >)
    }

    /// On sessionQueue. Picks the 420v format of that size at the wanted rate,
    /// or the highest it has. The camera advertises rates like 30.00003 fps,
    /// so they're matched loosely and set from its own ranges.
    private func applyFormat(width: Int, height: Int) {
        size = (width, height)
        guard let device = input?.device else { return }
        // Most capable format first: switching between this camera's separate
        // 30 fps and 60 fps 1080p formats left it stuck at 30.
        let options = Self.ranges(device, width: width, height: height).sorted {
            ($0.0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) > ($1.0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        let match = wantedFrameRate.flatMap { want in options.first { abs($0.1.maxFrameRate - want) < 0.5 } }
            ?? options.max { $0.1.maxFrameRate < $1.1.maxFrameRate }
        guard let (format, range) = match, (try? device.lockForConfiguration()) != nil else { return }
        // One configuration change: set separately, the camera sometimes kept
        // streaming at the format's default 30 fps while reporting 60.
        session.beginConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = range.minFrameDuration
        // An explicit rate is pinned; "Highest" lets the camera slow down if it must.
        if wantedFrameRate != nil { device.activeVideoMaxFrameDuration = range.minFrameDuration }
        session.commitConfiguration()
        device.unlockForConfiguration()
        // The camera finishes switching modes a moment later; tell listeners twice.
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.onFormatApplied?() }
        }
    }

    /// Diagnostics: the camera's active format and the session preset.
    func describeActive() -> String {
        sessionQueue.sync {
            guard let device = input?.device else { return "no input" }
            let d = device.activeFormat.formatDescription.dimensions
            return "device \(d.width)x\(d.height) @ \(String(format: "%.1f", 1 / device.activeVideoMinFrameDuration.seconds)) fps, preset \(session.sessionPreset.rawValue)"
        }
    }

    /// Diagnostics: sets only the session preset, the way most apps choose a
    /// resolution, without selecting the device format.
    func setSessionPresetOnly(_ preset: AVCaptureSession.Preset) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = preset
            session.commitConfiguration()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            session.stopRunning()
            if let input { session.removeInput(input); self.input = nil }
        }
    }

    /// Delivers the next frame (on a background queue).
    func snapshot(_ handler: @escaping (CVPixelBuffer, FrameStats) -> Void) {
        frameQueue.async { self.pendingSnapshots.append(handler) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCount += 1
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Frames counted over the last second, starting afresh after a pause
        // (a mode switch) so the reading doesn't mix in the old rate.
        if let last = frameTimes.last, time.seconds - last > 0.5 { frameTimes.removeAll() }
        frameTimes.append(time.seconds)
        frameTimes.removeAll { time.seconds - $0 > 1 }
        // No reading until there's half a second of frames to count.
        if let first = frameTimes.first, time.seconds - first >= 0.5 {
            fps = Double(frameTimes.count - 1) / (time.seconds - first)
        } else {
            fps = 0
        }
        if faceMetering, !measuringFace, (time - lastFaceTime).seconds >= 0.25 {
            measuringFace = true
            lastFaceTime = time
            faceQueue.async { [self] in
                let face = FaceMeter.measure(pb)
                DispatchQueue.main.async { self.onFace?(face) }
                frameQueue.async { self.measuringFace = false }
            }
        }
        if !pendingSnapshots.isEmpty {
            var stats = FrameStats.measure(pb)
            stats.fps = fps
            let handlers = pendingSnapshots
            pendingSnapshots.removeAll()
            handlers.forEach { $0(pb, stats) }
        }
        if frameCount % 8 == 0, let onStats {
            var stats = FrameStats.measure(pb)
            stats.fps = fps
            DispatchQueue.main.async { onStats(stats) }
        }
    }
}

extension CVPixelBuffer {
    func jpegData(quality: Double = 0.7) -> Data? {
        let image = CIImage(cvPixelBuffer: self)
        return CIContext().jpegRepresentation(
            of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }
}
