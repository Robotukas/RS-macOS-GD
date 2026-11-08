import Foundation

/// Extension point: every supported peripheral implements this and is routed
/// reports by `AppModel` based on USB vendor/product id.
@MainActor
protocol DeviceModule: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// VID/PID pairs this module wants IOHIDManager to match.
    var matchList: [(vendorId: Int, productId: Int)] { get }
    func matches(vendorId: Int, productId: Int) -> Bool
    /// A HID interface of the device appeared / disappeared.
    func interfaceConnected(usagePage: Int, productId: Int)
    func interfaceDisconnected(usagePage: Int)
    /// `bytes` includes the report ID as byte 0 when the device uses report IDs.
    func handle(reportID: UInt32, bytes: [UInt8], usagePage: Int)
}

extension DeviceModule {
    func matches(vendorId: Int, productId: Int) -> Bool {
        matchList.contains { $0.vendorId == vendorId && $0.productId == productId }
    }
}
