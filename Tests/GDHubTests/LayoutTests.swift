import XCTest
@testable import GDHub

final class LayoutTests: XCTestCase {
    func testBundledLayoutLoadsAndIsComplete() throws {
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        XCTAssertEqual(layout.controls.count, 31)
        XCTAssertEqual(Set(layout.controls.map(\.id)).count, 31, "control ids are unique")
        XCTAssertEqual(Set(layout.controls.map(\.order)).count, 31, "learn order has no duplicates")
        XCTAssertEqual(layout.columns.flatMap { $0 }.count, ControlLayout.Side.allCases.count)
    }

    func testMoveViewBetweenAndWithinColumns() throws {
        var layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        XCTAssertEqual(layout.columns, [[.sideLeft], [.front], [.back], [.sideRight]])
        layout.moveView(.back, dx: -1, dy: 0)
        XCTAssertEqual(layout.columns, [[.sideLeft], [.back, .front], [.sideRight]], "back joins the front column at its row")
        layout.moveView(.back, dx: 0, dy: 1)
        XCTAssertEqual(layout.columns, [[.sideLeft], [.front, .back], [.sideRight]])
        layout.moveView(.sideLeft, dx: -1, dy: 0)
        XCTAssertEqual(layout.columns.first, [.sideLeft], "moving the first column left keeps it first")
        layout.moveView(.sideRight, dx: 1, dy: 0)
        XCTAssertEqual(layout.columns.last, [.sideRight])
    }

    func testInvalidColumnsFallBackToDefault() throws {
        var layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        layout.viewColumns = [["front"], ["back"]]          // missing the side views
        XCTAssertEqual(layout.columns, ControlLayout.defaultViewColumns)
    }

    func testLabelFontFixedAndScaledWithLock() {
        var f = ControlLayout.LabelFont(size: 10, scaled: false, minSize: 7, maxSize: 16)
        XCTAssertEqual(f.pointSize(viewScale: 0.3), 10)
        XCTAssertEqual(f.pointSize(viewScale: 3), 10)
        f.scaled = true
        XCTAssertEqual(f.pointSize(viewScale: 1.2), 12)
        XCTAssertEqual(f.pointSize(viewScale: 0.3), 7, "locked at the minimum")
        XCTAssertEqual(f.pointSize(viewScale: 3), 16, "locked at the maximum")
    }

    func testUserLayoutRoundTripsThroughJSON() throws {
        var layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        layout.controls[0].labelX = -0.2
        layout.controls[0].labelY = 0.4
        layout.controls[0].labelAnchor = .trailing
        layout.controls[0].leader = [[0.1, 0.2]]
        layout.controls[0].leaderPreset = "twoCorners"
        layout.controls[0].leaderAttach = "below"
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(ControlLayout.self, from: data)
        XCTAssertEqual(back.controls[0].labelX, -0.2)
        XCTAssertEqual(back.controls[0].labelAnchor, .trailing)
        XCTAssertEqual(back.controls[0].leader, [[0.1, 0.2]])
        XCTAssertEqual(back.controls[0].leaderPreset, "twoCorners")
        XCTAssertEqual(back.controls[0].leaderAttach, "below")
    }
}
