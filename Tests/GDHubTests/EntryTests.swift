import XCTest
@testable import GDHub

final class EntryTests: XCTestCase {
    func testEngineOptionsParseTheDevAids() {
        let o = EngineOptions(arguments: ["GDHub", "--engine", "--engine-foreground", "--latency-log", "--test-pattern",
                                          "--publish-pad", "xbox-bt16-02e0", "--unpublish-after", "12.5",
                                          "--switch-pad-after", "3", "xbox-bt16"])
        XCTAssertTrue(o.foreground); XCTAssertTrue(o.latencyLog); XCTAssertTrue(o.testPattern)
        XCTAssertEqual(o.publishPad, "xbox-bt16-02e0")
        XCTAssertEqual(o.unpublishAfter, 12.5)
        XCTAssertEqual(o.switchPadAfter?.seconds, 3)
        XCTAssertEqual(o.switchPadAfter?.identity, "xbox-bt16")
    }

    func testEngineOptionsDefaultsAndMalformedValues() {
        XCTAssertEqual(EngineOptions(arguments: ["GDHub", "--engine"]), EngineOptions())
        let o = EngineOptions(arguments: ["--publish-pad", "--unpublish-after", "soon", "--switch-pad-after", "1"])
        XCTAssertEqual(o.publishPad, "--unpublish-after", "the next token is taken as the value, like the old GUI parser")
        XCTAssertNil(o.unpublishAfter)
        XCTAssertNil(o.switchPadAfter)
    }

    func testEngineRunsOnlyWhenLaunchdSetItsLabel() {
        XCTAssertTrue(EngineMain.startedByLaunchd(environment: ["XPC_SERVICE_NAME": "com.interlinked.gdhub.engine"]))
        XCTAssertFalse(EngineMain.startedByLaunchd(environment: ["XPC_SERVICE_NAME": "application.com.interlinked.gdhub.176886480.176886485"]))
        XCTAssertFalse(EngineMain.startedByLaunchd(environment: [:]))
    }
}
