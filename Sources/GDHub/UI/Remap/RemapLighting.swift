import Foundation

/// Which drawings light up this frame (remap plan, decision B).
///
/// - **pressed**: `mapping.isActive` for every control in the layout, exactly as before remaps (a control mapped to
///   Nothing lights too).
/// - **linked**: the drawing of a pad item the pad is actually sending, when nothing else makes it light. Pressing G1
///   (set to Y) lights G1 (pressed) and Y (linked); pressing Y lights only Y. The linked drawing is the item's home
///   control, which must still send its own item (a control mapped away from an item is not linked to it) and must not be
///   pressed. "Actually sending" is judged from the mapper's own output (`PassthroughPadMapper.padState`), so opposite
///   D-pad directions that cancel light nothing, and Start lights for G5 → Guide only while Start still sends Guide.
///   Controls mapped to Nothing or to the built-in function feed no item and are never linked.
enum RemapLighting {
    enum Level: Equatable { case pressed, linked }

    /// `ControlMapping.isActive` calls a trigger pressed above 100 of 1023 raw; the pad's trigger is raw / 1023.
    static let triggerThreshold = 100.0 / 1023.0

    /// - Parameter sources: `mapping.sourcesByOutput()` if the caller already has it (it changes only with
    ///   `mapping.outputs`); computed when nil. Controls that do not light are absent from the result.
    static func levels(frame: GamepadFrame, mapping: ControlMapping, controls: [ControlLayout.Control],
                       sources: [PadOutput: [String]]? = nil) -> [String: Level] {
        var out: [String: Level] = [:]
        for c in controls where mapping.isActive(c.id, frame) { out[c.id] = .pressed }
        // Without remaps every item has exactly its home control as source, so nothing can be linked.
        if mapping.outputs.isEmpty { return out }

        let table = sources ?? mapping.sourcesByOutput()
        let pad = PassthroughPadMapper.padState(frame, mapping, sources: table)
        for c in controls where out[c.id] == nil && !mapping.isRemapped(c.id) {
            guard case .pad(let item) = mapping.defaultOutput(c.id), isSent(item, pad) else { continue }
            out[c.id] = .linked
        }
        return out
    }

    /// Whether the pad sends `item` this frame. Opposite D-pad directions cancel, as the report builders do.
    static func isSent(_ item: PadOutput, _ pad: PadState) -> Bool {
        switch item {
        case .lt: return pad.lt > triggerThreshold
        case .rt: return pad.rt > triggerThreshold
        case .dpad_up, .dpad_down:
            return pad.buttons.contains(.dpadUp) != pad.buttons.contains(.dpadDown)
                && pad.buttons.contains(item == .dpad_up ? .dpadUp : .dpadDown)
        case .dpad_left, .dpad_right:
            return pad.buttons.contains(.dpadLeft) != pad.buttons.contains(.dpadRight)
                && pad.buttons.contains(item == .dpad_left ? .dpadLeft : .dpadRight)
        default:
            guard let bit = PassthroughPadMapper.buttons(of: item) else { return false }
            return pad.buttons.contains(bit)
        }
    }
}
