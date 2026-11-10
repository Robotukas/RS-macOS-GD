import XCTest
@testable import GDHub

final class ViewTabTests: XCTestCase {
    private typealias Side = ControlLayout.Side
    private let all: [[Side]] = ControlLayout.defaultViewColumns

    private func columns(_ tab: ViewTab, editing: Bool = false, devRunning: Bool = false, devFocus: [Side] = [],
                         guided: Bool = false, allColumns: [[Side]]? = nil) -> [[Side]] {
        ViewTab.visibleColumns(tab: tab, editing: editing, devRunning: devRunning, devFocus: devFocus, guidedLearn: guided,
                               allColumns: allColumns ?? all)
    }

    func testRawValuesAndTitles() {
        XCTAssertEqual(ViewTab.allCases.map(\.rawValue), ["all", "front", "back", "sides"])
        XCTAssertEqual(ViewTab.allCases.map(\.title), ["All", "Front", "Back", "Sides"])
        XCTAssertEqual(ViewTab(rawValue: "sides"), .sides)
        XCTAssertNil(ViewTab(rawValue: "left"))
    }

    func testTheTabDecidesWhenNothingOverridesIt() {
        XCTAssertEqual(columns(.all), all)
        XCTAssertEqual(columns(.front), [[.front]])
        XCTAssertEqual(columns(.back), [[.back]])
        XCTAssertEqual(columns(.sides), [[.sideLeft], [.sideRight]])
    }

    func testAllUsesTheUsersArrangement() {
        let arranged: [[Side]] = [[.front, .back], [.sideLeft, .sideRight]]
        XCTAssertEqual(columns(.all, allColumns: arranged), arranged)
        XCTAssertEqual(columns(.front, allColumns: arranged), [[.front]])
    }

    func testEditLayoutAlwaysShowsAll() {
        for tab in ViewTab.allCases {
            XCTAssertEqual(columns(tab, editing: true), all, "\(tab)")
        }
    }

    func testGuidedLearnAllShowsAll() {
        for tab in ViewTab.allCases {
            XCTAssertEqual(columns(tab, guided: true), all, "\(tab)")
        }
    }

    func testADeveloperRunShowsItsFocusedViewsNeverTheTab() {
        for tab in ViewTab.allCases {
            XCTAssertEqual(columns(tab, devRunning: true, devFocus: [.back]), [[.back]], "\(tab)")
            XCTAssertEqual(columns(tab, devRunning: true, devFocus: [.sideLeft, .front]), [[.sideLeft], [.front]], "\(tab)")
        }
    }

    func testADeveloperRunWithNoFocusShowsAllNeverTheTab() {
        for tab in ViewTab.allCases {
            XCTAssertEqual(columns(tab, devRunning: true, devFocus: []), all, "\(tab)")
        }
    }

    func testDeveloperModeWithoutARunKeepsTheTab() {
        XCTAssertEqual(columns(.sides, devRunning: false, devFocus: []), [[.sideLeft], [.sideRight]])
    }

    func testEditingWinsOverARun() {
        XCTAssertEqual(columns(.front, editing: true, devRunning: true, devFocus: [.back]), all)
    }

    func testPickerIsDisabledWhileSomethingOverridesTheTab() {
        XCTAssertTrue(ViewTab.tabPickerEnabled(editing: false, devRunning: false, guidedLearn: false))
        XCTAssertFalse(ViewTab.tabPickerEnabled(editing: true, devRunning: false, guidedLearn: false))
        XCTAssertFalse(ViewTab.tabPickerEnabled(editing: false, devRunning: true, guidedLearn: false))
        XCTAssertFalse(ViewTab.tabPickerEnabled(editing: false, devRunning: false, guidedLearn: true))
    }

    func testEveryTabShowsOnlyViewsOfTheLayout() throws {
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        for tab in ViewTab.allCases {
            let shown = Set(columns(tab, allColumns: layout.columns).flatMap { $0 })
            XCTAssertFalse(shown.isEmpty)
            XCTAssertTrue(shown.isSubset(of: Set(Side.allCases)))
        }
        XCTAssertEqual(Set(columns(.all, allColumns: layout.columns).flatMap { $0 }), Set(Side.allCases))
    }
}
