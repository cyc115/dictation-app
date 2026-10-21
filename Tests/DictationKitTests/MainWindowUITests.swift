import AppKit
import SwiftUI
import XCTest
@testable import DictationKit

/// The sidebar picks tabs by each row's `.tag`. A modifier after the tag (the Corrections badge)
/// hid it from the List: no row was ever highlighted and clicking the sidebar did nothing.
/// (Synthetic clicks don't reach List rows here, so this checks the highlight the tags drive.)
final class SidebarTests: XCTestCase {
    func testTheCurrentTabsRowIsSelected() {
        for tab in MainTab.allCases {
            let selection = TabSelection()
            selection.tab = tab
            let history = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
            let hosted = HostedView(MainView(selection: selection, services: makeServices(self, history: history)), size: NSSize(width: 860, height: 620))
            let sidebar = hosted.elements { $0.object is NSTableView }.first?.object as? NSTableView
            XCTAssertEqual(sidebar?.numberOfRows, MainTab.allCases.count)
            XCTAssertEqual(sidebar?.selectedRow, MainTab.allCases.firstIndex(of: tab), "\(tab.title) row highlighted")
        }
    }
}

/// Each page is built on its first visit and kept, hidden, behind the selected one (MainView):
/// rebuilding Settings took ~100 ms of every tab switch.
final class KeptPagesTests: XCTestCase {
    private func host(_ tab: MainTab, settings: AppSettings? = nil) -> (HostedView<MainView>, TabSelection) {
        let selection = TabSelection()
        selection.tab = tab
        let history = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        let hosted = HostedView(MainView(selection: selection, services: makeServices(self, settings: settings, history: history)),
                                size: NSSize(width: 860, height: 620))
        addTeardownBlock { hosted.close() }
        return (hosted, selection)
    }

    private func switches(in view: NSView) -> Set<ObjectIdentifier> {
        view.subviews.reduce(into: Set(view is NSSwitch ? [ObjectIdentifier(view)] : [])) { $0.formUnion(switches(in: $1)) }
    }

    func testSettingsIsKeptAcrossTabSwitches() {
        let (hosted, selection) = host(.settings)
        let controls = switches(in: hosted.hostingView)
        XCTAssertFalse(controls.isEmpty)
        XCTAssertNotNil(hosted.element(id: "setting.Hotkey"))

        selection.tab = .history
        hosted.settle()
        XCTAssertNil(hosted.element(id: "setting.Hotkey"), "a hidden page is out of the accessibility tree")
        XCTAssertNotNil(hosted.element(id: "history.empty") ?? hosted.elements { $0.label == "History" }.first)

        selection.tab = .settings
        hosted.settle()
        XCTAssertNotNil(hosted.element(id: "setting.Hotkey"))
        XCTAssertEqual(switches(in: hosted.hostingView), controls, "the same switches, not rebuilt")
    }

    /// History and Corrections each searched from the toolbar; kept alive together they put two
    /// search fields there, and AppKit threw (crashed) inserting the second. Needs the app's real
    /// window: HostedView's has no toolbar.
    func testOneToolbarSearchFieldAcrossKeptPages() {
        let selection = TabSelection()
        selection.tab = .history
        let history = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        let window = MainWindowController.makeWindow(rootView: MainView(selection: selection, services: makeServices(self, history: history)))
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        addTeardownBlock { window.close() }
        func searchFields() -> [NSSearchField] {
            spinRunLoop(0.2)
            return (window.toolbar?.items ?? []).compactMap { $0.view as? NSSearchField }
                + (window.toolbar?.items ?? []).compactMap { ($0 as? NSSearchToolbarItem)?.searchField }
        }
        for (tab, prompt) in [(MainTab.history, "Search history"), (.corrections, "Search corrections"),
                              (.history, "Search history"), (.settings, nil), (.commands, "Search commands"),
                              (.corrections, "Search corrections")] {
            selection.tab = tab
            let fields = searchFields()
            XCTAssertEqual(fields.count, prompt == nil ? 0 : 1, "\(tab.title)")
            if let prompt { XCTAssertEqual(fields.first?.placeholderString, prompt) }
        }
    }

    /// The query typed in MainView's toolbar field filters the page in front.
    func testSearchFiltersHistoryAndCorrections() {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "Book the flight.", duration: 1)
        store.add(text: "Call the dentist.", duration: 1)
        store.entries.forEach { store.setCorrection($0.text + "!", for: $0.id) }
        let history = HostedView(HistoryView(store: store, search: "dentist"), size: NSSize(width: 760, height: 400))
        addTeardownBlock { history.close() }
        XCTAssertEqual(history.elements(id: "history.row").count, 1)
        let corrections = HostedView(CorrectionsView(store: store, search: "flight"), size: NSSize(width: 760, height: 480))
        addTeardownBlock { corrections.close() }
        XCTAssertEqual(corrections.elements(id: "corrections.card").count, 1)
    }

    func testSettingsRereadsCustomSetupsEachTimeItIsShown() throws {
        let file = makeTempURL(self, "setups.json")
        let settings = AppSettings(defaults: makeDefaults(self), secrets: InMemorySecretStore(), customSetupsFile: file,
                                   learned: noLearnedPrompts(self))
        let (hosted, selection) = host(.settings, settings: settings)
        selection.tab = .history
        hosted.settle()
        try #"{"setups": [{"id": "try", "title": "Try", "speech": "apple", "polish": "apple", "prompt": "v1"}]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(settings.setups.contains { $0.id == "try" })

        selection.tab = .settings
        hosted.settle()
        XCTAssertTrue(settings.setups.contains { $0.id == "try" }, "edits show up when Settings opens again")
    }
}

/// Puts a page in a kept tab whose shown state the test flips, as MainView does.
private final class KeptTab: ObservableObject {
    let page = KeptPage()
    @Published var editing: UUID?
}

private struct KeptCorrections: View {
    @ObservedObject var tab: KeptTab
    let store: HistoryStore

    var body: some View {
        CorrectionsView(store: store, editing: tab.editing).environment(\.keptPage, tab.page)
    }
}

final class KeptCorrectionsTests: XCTestCase {
    /// History's pencil opens Corrections on the new correction even when Corrections is already
    /// built (kept hidden), and a hidden Corrections lets go of the keyboard.
    func testOpeningAKeptCorrectionsFocusesTheEditedOne() throws {
        let store = HistoryStore(fileURL: makeTempURL(self), defaults: makeDefaults(self))
        store.add(text: "First.", duration: 1)
        store.add(text: "Second.", duration: 1)
        store.setCorrection("First!", for: store.entries[1].id)
        let tab = KeptTab()
        tab.page.shown = true
        let hosted = HostedView(KeptCorrections(tab: tab, store: store), size: NSSize(width: 760, height: 480))
        addTeardownBlock { hosted.close() }

        tab.page.shown = false
        hosted.settle()
        let id = store.entries[0].id
        store.setCorrection("Second!", for: id)
        tab.editing = id
        tab.page.shown = true
        hosted.settle()
        let field = try XCTUnwrap(hosted.window.firstResponder as? NSTextView, "the new correction has the cursor")
        XCTAssertEqual(field.string, "Second!")

        tab.page.shown = false
        hosted.settle()
        XCTAssertFalse(hosted.window.firstResponder === field, "hidden, it doesn't keep the keyboard")
    }
}

final class MainWindowTests: XCTestCase {
    func testTitleBarIsTransparentAndUntitledSoNoBandShowsOverTheContent() {
        let window = MainWindowController.makeWindow(rootView: Text("content"))
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.title, "DictationApp", "still named for the Window menu and Mission Control")
    }
}
