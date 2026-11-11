import Foundation

/// What a `record` step (and a template with `recordReceiver`) needs besides the runner's own rules: the fixed table
/// that says which extra bit of report 0x06 each paddle and SAX key sets, and the limits of the recording. Pure.
enum DevRecorder {
    /// Changed receiver reports kept per step; later ones are counted in `DevAttempt.receiverDropped`.
    static let maxFramesPerStep = 4000

    /// The extra bit each paddle and SAX key sets in report 0x06 (hardware positions, measured; the receiver notes
    /// `docs/protocol/envision-pro-receiver.md`). A record step opens its window by this table and not by what the
    /// mapping has stored, so the survey that checks the table can still start when a stored bit is wrong.
    static let keyBits: [String: UInt16] = [
        "paddle_outer_right": 1, "paddle_inner_right": 2, "paddle_inner_left": 4,
        "paddle_outer_left": 8, "sax_left": 16, "sax_right": 32,
    ]

    /// Whether `control` counts as pressed on `frame` for a record step: a paddle or SAX key by its table bit, any
    /// other control the way the mapping reads it.
    static func isActive(_ control: String, _ frame: GamepadFrame, mapping: ControlMapping) -> Bool {
        if let bit = keyBits[control] { return frame.extra & bit != 0 }
        return mapping.isActive(control, frame)
    }

    /// What the table's Seen column says of a record step: "receiver frames kept: 212".
    static func kept(frames: Int, dropped: Int) -> String {
        "receiver frames kept: \(frames)" + (dropped > 0 ? " (\(dropped) more did not fit and were left out)" : "")
    }

    /// "Recorded 212 receiver reports in 8.4 s; nothing was judged." (the tooltip of the word "recorded")
    static func summary(frames: Int, dropped: Int, seconds: Double) -> String {
        var s = "Recorded \(frames) receiver report\(frames == 1 ? "" : "s") that changed, over \(String(format: "%.1f", seconds)) s; nothing was judged."
        if dropped > 0 { s += " \(dropped) more did not fit and were left out." }
        return s
    }
}
