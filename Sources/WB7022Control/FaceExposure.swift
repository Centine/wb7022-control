import CoreVideo
import Foundation
import Vision

/// The largest face in a frame and how bright its skin is.
struct FaceMeasurement: Equatable {
    /// Normalized to the frame, origin top-left.
    var rect: CGRect
    /// Mean 8-bit video-range luma over the middle of the face.
    var luma: Double
}

enum FaceMeter {
    /// Expects 8-bit video-range luma in plane 0, like `FrameStats.measure`.
    static func measure(_ pb: CVPixelBuffer) -> FaceMeasurement? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform([request])
        guard let face = request.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) }) else { return nil }
        let box = face.boundingBox  // Vision's origin is bottom-left
        let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        // Cheeks, nose and forehead: skip hair, beard edges and background.
        let core = rect.insetBy(dx: rect.width * 0.25, dy: rect.height * 0.2)
        guard let luma = meanLuma(pb, in: core) else { return nil }
        return FaceMeasurement(rect: rect, luma: luma)
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    private static func meanLuma(_ pb: CVPixelBuffer, in rect: CGRect) -> Double? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferIsPlanar(pb), let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pb, 0)
        let height = CVPixelBufferGetHeightOfPlane(pb, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let x0 = max(0, Int(rect.minX * CGFloat(width))), x1 = min(width, Int(rect.maxX * CGFloat(width)))
        let y0 = max(0, Int(rect.minY * CGFloat(height))), y1 = min(height, Int(rect.maxY * CGFloat(height)))
        guard x1 > x0, y1 > y0 else { return nil }
        let step = max(1, (x1 - x0) / 64)
        var sum = 0, n = 0
        for y in stride(from: y0, to: y1, by: step) {
            let row = luma + y * rowBytes
            for x in stride(from: x0, to: x1, by: step) { sum += Int(row[x]); n += 1 }
        }
        return n > 0 ? Double(sum) / Double(n) : nil
    }
}

/// Steers the camera's brightness control so the face sits at a target luma.
/// With auto exposure on, brightness biases the camera's own exposure, so its
/// flicker handling keeps working. Measured on this camera: one brightness
/// step moves frame luma by roughly 0.6, and the camera settles within a second.
struct FaceExposureController {
    var target: Double
    static let range = 24...232

    private var smoothed: Double?
    private var lastAdjust = Date.distantPast

    init(target: Double) { self.target = target }

    /// The brightness to set next, or nil to leave it alone.
    mutating func update(faceLuma: Double, brightness: Int, now: Date = Date()) -> Int? {
        let s = smoothed.map { $0 * 0.6 + faceLuma * 0.4 } ?? faceLuma
        smoothed = s
        // Give the camera time to settle after the previous change.
        guard now.timeIntervalSince(lastAdjust) >= 0.8 else { return nil }
        let error = target - s
        guard abs(error) > 5 else { return nil }
        let step = max(-16, min(16, Int((error * 1.2).rounded())))
        let next = max(Self.range.lowerBound, min(Self.range.upperBound, brightness + step))
        guard next != brightness else { return nil }
        lastAdjust = now
        smoothed = nil  // older readings predate the change
        return next
    }
}
