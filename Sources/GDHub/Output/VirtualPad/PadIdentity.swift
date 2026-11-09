import Foundation

/// Identity catalogue (design §4.2): data only. D3 carries the two primary Xbox identities; the fallbacks arrive in D6.
struct PadIdentity: Equatable {
    let id: String
    let title: String
    let vendorID: UInt32
    let productID: UInt32
    let versionNumber: UInt32
    let transport: String
    let manufacturer: String
    let product: String
    let serialNumber: String
    let locationID: UInt32
    let reportIntervalUs: UInt32
    let descriptor: [UInt8]
    /// reportID → padded send length (only `xbox-pr208`).
    let sendLengths: [UInt8: Int]
    let builder: (PadState) -> [PadReport]

    static func == (l: PadIdentity, r: PadIdentity) -> Bool { l.id == r.id }

    /// The serial every GDHub pad carries; the duplicate check (D4) uses it to recognise its own device.
    static let serial = "GDHub-1"

    private static func xbox(id: String, title: String, productID: UInt32) -> PadIdentity {
        PadIdentity(id: id, title: title, vendorID: 0x045E, productID: productID, versionNumber: 0x0513,
                    transport: "Bluetooth Low Energy", manufacturer: "Microsoft", product: "Xbox Wireless Controller",
                    serialNumber: serial, locationID: 0x4744_4801, reportIntervalUs: 1000,
                    descriptor: PadDescriptors.xboxBT16, sendLengths: [:], builder: PadReportBuilders.xboxBT16)
    }

    static let xboxBT16_02E0 = xbox(id: "xbox-bt16-02e0", title: "Xbox 02E0 (compact 16 B)", productID: 0x02E0)
    static let xboxBT16 = xbox(id: "xbox-bt16", title: "Xbox 0B13 (compact 16 B)", productID: 0x0B13)

    static let all: [PadIdentity] = [xboxBT16_02E0, xboxBT16]
    static let `default` = xboxBT16_02E0

    static func named(_ id: String) -> PadIdentity? { all.first { $0.id == id } }

    /// Reports for one state, in the descriptor's input order.
    func reports(for state: PadState) -> [PadReport] { builder(state) }

    /// Builds the DeviceSpec. `UserDefaults` `vhid.pad.productOverride` replaces the product string (cosmetic test only).
    func spec() throws -> DeviceSpec {
        let inputs = try HIDReportSizer.inputs(descriptor)
        let neutral = Dictionary(uniqueKeysWithValues: reports(for: .neutral).map { ($0.id, $0.bytes) })
        let override = UserDefaults.standard.string(forKey: "vhid.pad.productOverride")
        return DeviceSpec(slot: .pad, vendorID: vendorID, productID: productID, versionNumber: versionNumber,
                          locationID: locationID, reportIntervalUs: reportIntervalUs,
                          transport: transport, manufacturer: manufacturer,
                          product: (override?.isEmpty == false ? override! : product), serialNumber: serialNumber,
                          descriptor: descriptor, sendLengths: sendLengths,
                          neutralReports: inputs.map { neutral[$0.id] ?? [] })
    }
}
