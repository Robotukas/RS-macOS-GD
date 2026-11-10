import Foundation

/// Which drawings light up this frame (remap plan, decision B).
///
/// - **pressed**: `mapping.isActive` for every control in the layout, exactly as before remaps (a control mapped to
///   Nothing lights too).
/// - **linked**: every other control that sends a pad item the pad is actually sending this frame. The relation shows in
///   both directions: with G1 set to Y, pressing G1 lights G1 (pressed) and Y (linked), and pressing Y lights Y (pressed)
///   and G1 (linked). A control mapped away from an item is not linked to it. "Actually sending" is judged from the
///   mapper's own output (`PassthroughPadMapper.padState`), so opposite D-pad directions that cancel light nothing.
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
        // Every control that sends an item the pad is sending right now is part of the relation, in both directions:
        // with G1 → Y, pressing G1 links Y and pressing Y links G1.
        let drawn = Set(controls.map(\.id))
        for (item, ids) in table where isSent(item, pad) {
            for id in ids where out[id] == nil && drawn.contains(id) { out[id] = .linked }
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
