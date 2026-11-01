import Foundation

enum ControlSection: String, CaseIterable, Identifiable {
    case dell = "Dell Features"
    case image = "Image"
    case exposure = "Exposure & Focus"
    case framing = "Zoom & Framing"
    var id: String { rawValue }
}

struct Choice: Hashable {
    let value: Int
    let label: String
}

enum SliderFormat: Hashable {
    case plain, kelvin, arcSecondsAsDegrees, exposure100us, zoomPercent

    func string(_ v: Int) -> String {
        switch self {
        case .plain: return "\(v)"
        case .kelvin: return "\(v) K"
        case .arcSecondsAsDegrees: return String(format: "%.0f°", Double(v) / 3600)
        case .exposure100us:
            let ms = Double(v) / 10
            return ms >= 1 ? String(format: "%.1f ms", ms) : String(format: "%.0f µs", ms * 1000)
        case .zoomPercent: return String(format: "%.2f×", Double(v) / 100)
        }
    }
}

enum ControlKind: Hashable {
    case slider(SliderFormat)
    case toggle(on: Int, off: Int)
    case choice([Choice])
}

/// One user-facing control. Several specs may share a (unit, selector) when the
/// payload packs multiple fields, e.g. pan and tilt.
struct ControlSpec: Identifiable, Hashable {
    let id: String
    let name: String
    let section: ControlSection
    let unit: UInt8
    let selector: UInt8
    /// Total payload size in bytes.
    let size: Int
    var offset = 0
    var fieldSize: Int? = nil
    var signed = false
    let kind: ControlKind
    /// Only adjustable while another control holds this value (e.g. manual exposure).
    var enabledWhen: Requirement? = nil
    var help: String? = nil
    /// Always shown under the control.
    var note: String? = nil
    /// Set for features on Dell's vendor command channel instead of a plain UVC control.
    var dell: DellCommand? = nil
    /// Factory default where the camera can't report one (vendor commands).
    var defaultValue: Int? = nil
    /// The camera only applies this when the video stream starts.
    var restartsVideo = false

    struct Requirement: Hashable {
        let id: String
        let value: Int
        /// Met when the other control is above `value` rather than equal to it.
        var above = false
        /// Shown under the control while the requirement isn't met.
        var hint: String? = nil

        func isMet(by v: Int) -> Bool { above ? v > value : v == value }
    }

    var field: Int { fieldSize ?? size }

    func with(enabledWhen r: Requirement) -> ControlSpec {
        var c = self; c.enabledWhen = r; return c
    }
}

enum Catalog {
    static let cameraTerminal: UInt8 = 1
    static let processingUnit: UInt8 = 3
    static let dellXU: UInt8 = 14

    /// Order matters: auto modes are applied before the manual values they gate.
    static let standard: [ControlSpec] = [
        // Image
        ControlSpec(id: "brightness", name: "Brightness", section: .image, unit: processingUnit, selector: 2, size: 2, signed: true, kind: .slider(.plain)),
        ControlSpec(id: "contrast", name: "Contrast", section: .image, unit: processingUnit, selector: 3, size: 2, kind: .slider(.plain)),
        ControlSpec(id: "saturation", name: "Saturation", section: .image, unit: processingUnit, selector: 7, size: 2, kind: .slider(.plain)),
        ControlSpec(id: "sharpness", name: "Sharpness", section: .image, unit: processingUnit, selector: 8, size: 2, kind: .slider(.plain)),
        ControlSpec(id: "wbAuto", name: "Auto white balance", section: .image, unit: processingUnit, selector: 11, size: 1, kind: .toggle(on: 1, off: 0)),
        ControlSpec(id: "wbTemp", name: "White balance", section: .image, unit: processingUnit, selector: 10, size: 2, kind: .slider(.kelvin),
                    enabledWhen: manualWhiteBalance),
        ControlSpec(id: "powerLine", name: "Anti-flicker", section: .image, unit: processingUnit, selector: 5, size: 1,
                    kind: .choice([Choice(value: 1, label: "50 Hz"), Choice(value: 2, label: "60 Hz")]),
                    help: "Match your mains frequency to stop banding under artificial light.",
                    note: PowerLine.advice()),

        // Exposure & focus
        ControlSpec(id: "aeMode", name: "Auto exposure", section: .exposure, unit: cameraTerminal, selector: 2, size: 1, kind: .toggle(on: 8, off: 1),
                    help: "With auto exposure off, this camera runs at about 30 fps even when 60 is selected (measured)."),
        ControlSpec(id: "aePriority", name: "Allow lower frame rate in low light", section: .exposure, unit: cameraTerminal, selector: 3, size: 1, kind: .toggle(on: 1, off: 0),
                    help: "When on, the camera may drop below 60 fps in dim light to get a brighter picture. Turn it off to hold 60 fps."),
        ControlSpec(id: "exposure", name: "Exposure time", section: .exposure, unit: cameraTerminal, selector: 4, size: 4, kind: .slider(.exposure100us),
                    enabledWhen: manualExposure, help: "Manual exposure keeps this camera at about 30 fps, even with 60 selected."),
        ControlSpec(id: "gain", name: "Gain", section: .exposure, unit: processingUnit, selector: 4, size: 2, kind: .slider(.plain),
                    enabledWhen: manualExposure),
        ControlSpec(id: "backlight", name: "Backlight compensation", section: .exposure, unit: processingUnit, selector: 1, size: 2, kind: .toggle(on: 1, off: 0),
                    help: "Brightens the whole image for subjects in front of a light. This is not Dell's HDR."),
        ControlSpec(id: "focusAuto", name: "Autofocus", section: .exposure, unit: cameraTerminal, selector: 8, size: 1, kind: .toggle(on: 1, off: 0)),
        ControlSpec(id: "focus", name: "Focus", section: .exposure, unit: cameraTerminal, selector: 6, size: 2, kind: .slider(.plain),
                    enabledWhen: manualFocus),

        // Zoom & framing
        ControlSpec(id: "zoom", name: "Zoom", section: .framing, unit: cameraTerminal, selector: 11, size: 2, kind: .slider(.zoomPercent)),
        ControlSpec(id: "pan", name: "Pan", section: .framing, unit: cameraTerminal, selector: 13, size: 8, offset: 0, fieldSize: 4, signed: true,
                    kind: .slider(.arcSecondsAsDegrees), enabledWhen: zoomedIn, help: "Moves the zoomed-in crop window left and right."),
        ControlSpec(id: "tilt", name: "Tilt", section: .framing, unit: cameraTerminal, selector: 13, size: 8, offset: 4, fieldSize: 4, signed: true,
                    kind: .slider(.arcSecondsAsDegrees), enabledWhen: zoomedIn, help: "Moves the zoomed-in crop window up and down."),
    ]

    // The camera ignores these while its auto mode is on, and doesn't report
    // the values the auto mode picks, so the slider keeps your own setting.
    private static let manualWhiteBalance = ControlSpec.Requirement(id: "wbAuto", value: 0,
                                                                    hint: "Turn off auto white balance to set this.")
    private static let manualExposure = ControlSpec.Requirement(id: "aeMode", value: 1,
                                                                hint: "Turn off auto exposure to set this.")
    private static let manualFocus = ControlSpec.Requirement(id: "focusAuto", value: 0,
                                                             hint: "Turn off autofocus to set this.")

    /// Pan and tilt are digital: they only move the crop, so there's nothing to move at 1×.
    private static let zoomedIn = ControlSpec.Requirement(id: "zoom", value: 100, above: true,
                                                          hint: "Zoom in above 1× to pan and tilt.")

    static var all: [ControlSpec] { DellFeatures.specs + standard }
}

/// Mains frequency by region, for the anti-flicker advice.
enum PowerLine {
    /// Regions on 60 Hz mains. Everywhere else listed by ISO code is 50 Hz, except Japan, which is split.
    private static let sixtyHz: Set<String> = [
        "US", "CA", "MX", "BR", "CO", "VE", "EC", "PE", "SV", "GT", "HN", "NI", "CR", "PA", "CU", "DO", "HT", "PR",
        "BS", "BZ", "TT", "SR", "KR", "TW", "PH", "SA", "LR", "GU", "VI", "BM", "KY", "AW", "AG", "KN", "LC", "VC",
        "MS", "AI", "VG", "AS", "MP", "FM", "MH", "PW",
    ]

    static func advice(region: String? = Locale.current.region?.identifier) -> String {
        let fallback = "If you see rolling bands under indoor lights, switch to the other setting."
        guard let region else { return "Use 50 Hz in Europe, Africa, most of Asia and Australia; 60 Hz in the Americas. " + fallback }
        let name = Locale.current.localizedString(forRegionCode: region) ?? region
        if region == "JP" { return "Japan is split: 50 Hz in the east (Tokyo), 60 Hz in the west (Osaka). " + fallback }
        return "Use \(sixtyHz.contains(region) ? 60 : 50) Hz in \(name). " + fallback
    }
}
