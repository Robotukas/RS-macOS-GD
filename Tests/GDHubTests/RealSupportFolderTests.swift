import XCTest
@testable import GDHub

/// The unit tests must never read or write the owner's real ~/Library/Application Support/GDHub: on 2026-11-10 a test
/// that began a layout edit left a pre-edit snapshot there and the next app start replaced the owner's layout with it.
final class RealSupportFolderTests: XCTestCase {
    func testEveryUserFileResolvesOutsideTheRealFolderUnderTests() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GDHub", isDirectory: true).standardizedFileURL.path
        let urls = [ControlLayout.userLayoutURL, ControlLayout.preEditSnapshotURL, ControlLayout.backupsDirectory,
                    MappingStore.envisionPro.url, MappingStore.defaultURL(fileName: "dev-runs"), DevTemplates.folderURL]
        for u in urls {
            XCTAssertFalse(u.standardizedFileURL.path.hasPrefix(real), "\(u.path) is in the owner's real folder")
        }
    }
}
