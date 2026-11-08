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

        var isPill: Bool { shape == "pill" }
    }

    var device: String
    var usb: USB
    var images: Images
    var defaultHotspotRadius: Double
    var note: String?
    var controls: [Control]

    var controlsByOrder: [Control] { controls.sorted { $0.order < $1.order } }

    func control(id: String) -> Control? { controls.first { $0.id == id } }

    func radius(of control: Control) -> Double { control.radius ?? defaultHotspotRadius }

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
