import Foundation

/// Codable model of Resources/envision-pro-layout.json.
struct ControlLayout: Codable {
    struct USB: Codable {
        var vendorId: String
        var productId: String
    }

    struct ImageInfo: Codable {
        var file: String
        var width: Double
        var height: Double
        var aspectRatio: Double { height > 0 ? width / height : 1 }
    }

    struct Images: Codable {
        var front: ImageInfo
        var back: ImageInfo
        var sideLeft: ImageInfo
        var sideRight: ImageInfo

        func info(for side: Side) -> ImageInfo {
            switch side {
            case .front: return front
            case .back: return back
            case .sideLeft: return sideLeft
            case .sideRight: return sideRight
            }
        }
    }

    enum Kind: String, Codable {
        case button, stick, trigger
    }

    enum Side: String, Codable, CaseIterable {
        case front, back, sideLeft, sideRight

        var title: String {
            switch self {
            case .front: return "Front"
            case .back: return "Back"
            case .sideLeft: return "Left side"
            case .sideRight: return "Right side"
            }
        }
    }

    enum LabelAnchor: String, Codable { case center, leading, trailing }

    struct LabelColumns: Codable {
        var left: Double
        var right: Double
    }

    /// Extra space reserved beside a view's image for callout labels, as fractions of the image width.
    struct LabelGutters: Codable {
        var left: Double
        var right: Double
    }

    struct Control: Codable, Identifiable, Hashable {
        var id: String
        var label: String
        var kind: Kind
        var order: Int
        var view: Side
        /// Fractions of the image width / height.
        var x: Double
        var y: Double
        var radius: Double?
        var shape: String?
        /// Callout label position relative to the control, as fractions of the image width / height.
        var labelDx: Double?
        var labelDy: Double?
        /// "left" or "right": put the label in that view's aligned label column instead of at labelDx/labelDy.
        var labelSide: String?
        /// User-positioned label (edit mode): anchor point as fractions of the image (may lie outside 0...1,
        /// i.e. in the gutters) and which edge of the pill the anchor refers to. Overrides labelSide / labelDx.
        var labelX: Double?
        var labelY: Double?
        var labelAnchor: LabelAnchor?
        /// Intermediate corner points of the leader line, control -> corners -> label, as image fractions.
        /// When nil, `leaderPreset` (if any) computes the corners from the label and control positions.
        var leader: [[Double]]?
        /// "oneCorner" or "twoCorners": orthogonal leader shape recomputed as the label moves.
        var leaderPreset: String?
        /// Where the leader leaves the label: "side" (left/right edge), "below", "above", or nil = auto.
        var leaderAttach: String?

        var isPill: Bool { shape == "pill" }
    }

    var device: String
    var usb: USB
    var images: Images
    var defaultHotspotRadius: Double
    /// Per view (by Side raw value): x positions (fractions of width) of the left and right label columns.
    var labelColumns: [String: LabelColumns]?
    var labelGutters: [String: LabelGutters]?
    var labelFont: LabelFont?

    /// Callout text size. Fixed: always `size` points. Scaled: `size` at the image's natural pixel
    /// width, growing and shrinking with the view, locked between `minSize` and `maxSize`.
    struct LabelFont: Codable, Equatable {
        var size: Double = 10
        var scaled: Bool = false
        var minSize: Double = 7
        var maxSize: Double = 16

        static let standard = LabelFont()

        /// Point size for a view drawn `viewScale` times its natural image size.
        func pointSize(viewScale: Double) -> Double {
            guard scaled else { return size }
            return min(max(size * viewScale, minSize), maxSize)
        }
    }

    var font: LabelFont { labelFont ?? .standard }
    var note: String?
    var controls: [Control]

    var controlsByOrder: [Control] { controls.sorted { $0.order < $1.order } }

    func control(id: String) -> Control? { controls.first { $0.id == id } }

    func radius(of control: Control) -> Double { control.radius ?? defaultHotspotRadius }

    func gutters(for side: Side) -> LabelGutters { labelGutters?[side.rawValue] ?? LabelGutters(left: 0, right: 0) }

    /// Width of the view including its label gutters, in image pixels.
    func framedWidth(for side: Side) -> Double {
        let g = gutters(for: side)
        return images.info(for: side).width * (1 + g.left + g.right)
    }

    // MARK: User layout (edit mode)

    static var userLayoutURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GDHub", isDirectory: true)
        return dir.appendingPathComponent("envision-pro-layout.json")
    }

    /// The user's edited layout if one was saved, otherwise the bundled one.
    static func load() -> ControlLayout? {
        if let data = try? Data(contentsOf: userLayoutURL),
           let user = try? JSONDecoder().decode(ControlLayout.self, from: data) {
            return user
        }
        return loadFromBundle()
    }

    func saveAsUserLayout() {
        do {
            let dir = Self.userLayoutURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: Self.userLayoutURL, options: .atomic)
        } catch {
            print("ControlLayout: failed to save user layout: \(error)")
        }
    }

    static func deleteUserLayout() {
        try? FileManager.default.removeItem(at: userLayoutURL)
    }

    /// Loads the bundled layout, or nil (with a console message) if it is missing or malformed.
    static func loadFromBundle() -> ControlLayout? {
        guard let url = Bundle.module.url(forResource: "envision-pro-layout", withExtension: "json") else {
            print("ControlLayout: envision-pro-layout.json not found in bundle")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ControlLayout.self, from: data)
        } catch {
            print("ControlLayout: failed to load layout: \(error)")
            return nil
        }
    }
}
