import Foundation
import ServiceManagement

/// Built-in starting points for common uses. Each sets the camera controls that
/// matter for the use and this app's preview format, then checks that the
/// camera really delivers that format. Other apps pick their own resolution and
/// frame rate, so the check confirms what the camera can do in this setup.
struct Suggestion: Identifiable {
    let id: String
    let name: String
    let summary: String
    let resolution: String
    let frameRate: String
    let values: [String: Int]
    var faceExposure: Bool? = nil

    /// Steady exposure, no moving crop, no HDR banding.
    private static let recording = ["hdr": 0, "aeMode": 8, "aePriority": 0, "autoFraming": 0, "backlight": 0]

    static let all: [Suggestion] = [
        Suggestion(id: "call", name: "Video call",
                   summary: "Auto framing keeps you centred, face exposure keeps you lit, and the camera may slow down in dim light for a brighter picture. Checked at 1080p, 30 fps.",
                   resolution: "1080p", frameRate: "30",
                   values: ["hdr": 0, "aeMode": 8, "aePriority": 1, "autoFraming": 1, "backlight": 0],
                   faceExposure: true),
        Suggestion(id: "rec4k", name: "Recording, 4K",
                   summary: "Sharpest picture: 4K at 30 fps with a steady frame rate, no moving crop and HDR off. Pick 4K in your recording app too.",
                   resolution: "4K", frameRate: "30", values: recording),
        Suggestion(id: "rec60", name: "Recording, 60 fps",
                   summary: "Smoothest motion: 1080p at 60 fps with a steady frame rate, no moving crop and HDR off. Needs reasonable light. Pick 1080p at 60 fps in your recording app too.",
                   resolution: "1080p", frameRate: "60", values: recording),
    ]
}

/// Launch at login through the system's login items.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// Set by the app delegate: true when the system started the app at login.
    nonisolated(unsafe) static var launchedAtLogin = false
}
