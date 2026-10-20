import AppKit
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case home, history, corrections, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .corrections: return "Corrections"
        case .settings: return "Settings"
        }
    }

    /// The toolbar search field's prompt, on the pages that search.
    var searchPrompt: String? {
        switch self {
        case .history: return "Search history"
        case .corrections: return "Search corrections"
        case .home, .settings: return nil
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .corrections: return "pencil.line"
        case .settings: return "gearshape"
        }
    }
}

/// The app window: sidebar with Home (insights), History, Corrections and Settings.
final class MainWindowController {
    private var window: NSWindow?
    private let selection = TabSelection()
    private let services: AppServices

    init(services: AppServices) { self.services = services }

    func show(_ tab: MainTab) {
        selection.tab = tab
        if window == nil {
            window = Self.makeWindow(rootView: MainView(selection: selection, services: services))
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The configured but not yet shown window, so tests can check its setup.
    static func makeWindow<Root: View>(rootView: Root) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = "DictationApp"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Content runs under the title bar; without these the system draws it as a lighter
        // band with the title over the detail column.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 860, height: 620))
        window.minSize = NSSize(width: 680, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DictationAppMainWindow")
        window.center()
        return window
    }
}

final class TabSelection: ObservableObject {
    @Published var tab: MainTab = .home
    /// The correction to edit when Corrections opens.
    var editing: UUID?
}

struct MainView: View {
    @ObservedObject var selection: TabSelection
    let services: AppServices
    @ObservedObject private var history: HistoryStore
    @State private var visited: Set<MainTab> = []
    @State private var searches: [MainTab: String] = [:]
    @State private var pages = Dictionary(uniqueKeysWithValues: MainTab.allCases.map { ($0, KeptPage()) })

    init(selection: TabSelection, services: AppServices) {
        self.selection = selection
        self.services = services
        history = services.history
    }

    private var settings: AppSettings { services.settings }

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, selection: Binding(get: { selection.tab }, set: { if let t = $0 { selection.tab = t } })) { tab in
                // .tag last: List matches rows to the selection by the outermost view's tag.
                Label(tab.title, systemImage: tab.icon)
                    .badge(tab == .corrections ? history.corrections.count : 0)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(AppVersion.current.version)").font(.caption.weight(.medium))
                    Text(AppVersion.current.commit + (AppVersion.current.built.map {
                        " · " + $0.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                    } ?? ""))
                    .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .textSelection(.enabled)
                .accessibilityIdentifier("sidebar.version")
            }
        } detail: {
            // Each page is built once, on its first visit, and kept: rebuilding one (Settings has
            // ~20 native switches and pop-ups) took ~100 ms of every tab switch.
            ZStack {
                ForEach(MainTab.allCases.filter { visited.contains($0) || $0 == selection.tab }) { tab in
                    let shown = tab == selection.tab
                    page(tab)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                        .environment(\.keptPage, pages[tab])
                }
                // One search field, for the page in front: with each kept page adding its own, the
                // toolbar got two and AppKit threw. Only this empty view comes and goes, not a page.
                if let prompt = selection.tab.searchPrompt {
                    Color.clear.frame(width: 0, height: 0)
                        .searchable(text: Binding(get: { searches[selection.tab, default: ""] },
                                                  set: { searches[selection.tab] = $0 }),
                                    placement: .toolbar, prompt: prompt)
                }
            }
            .onChange(of: selection.tab, initial: true) {
                visited.insert(selection.tab)
                for (tab, page) in pages where page.shown != (tab == selection.tab) { page.shown = tab == selection.tab }
            }
        }
    }

    @ViewBuilder private func page(_ tab: MainTab) -> some View {
        switch tab {
        case .home: HomeView(settings: settings, history: history, insights: services.insights)
        case .history: HistoryView(store: history, onCorrect: { id in
            selection.editing = id
            selection.tab = .corrections
        }, suggester: services.suggester, search: searches[.history, default: ""], commandMode: services.commands)
        case .corrections: CorrectionsView(store: history, suggester: services.suggester, learn: services.learn,
                                           editing: selection.editing, search: searches[.corrections, default: ""])
            .onTabHidden { selection.editing = nil }
        case .settings: SettingsView(services: services)
        }
    }
}

/// Whether a kept page is the selected tab's (MainView). An object, not a Bool in the environment:
/// changing an environment value re-checks every view on the page (~20 ms for Settings).
final class KeptPage: ObservableObject {
    @Published var shown = false
}

extension EnvironmentValues {
    /// The page this view is on, when it's one of MainView's kept tabs.
    @Entry var keptPage: KeptPage?
}

extension View {
    /// Runs `action` each time this page comes on screen: when it appears, and when its kept tab
    /// is selected again. Use it in a tab's page instead of onAppear, which runs only once there.
    func onTabShown(perform action: @escaping () -> Void) -> some View {
        modifier(OnTabShown(shown: true, action: action))
    }

    /// Runs `action` each time this page's tab is left (the page stays, hidden).
    func onTabHidden(perform action: @escaping () -> Void) -> some View {
        modifier(OnTabShown(shown: false, action: action))
    }
}

private struct OnTabShown: ViewModifier {
    @Environment(\.keptPage) private var page
    /// `page.shown`, mirrored so the action runs in a view update, with the page's current values.
    @State private var visible: Bool?
    let shown: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if let page {
            content
                .onReceive(page.$shown) { visible = $0 }
                .onChange(of: visible) { old, new in
                    if shown ? new == true : (old == true && new == false) { action() }
                }
        } else {
            content.onAppear { if shown { action() } }
        }
    }
}

private struct HomeView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    let insights: Insights

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Insights").font(.largeTitle.bold())
                    Text(settings.hint + ".").foregroundStyle(.secondary)
                }
                let breakdown = TimeBreakdown(history.entries)
                InsightsView(insights: insights, breakdown: breakdown)
                if settings.showDetailedAnalytics {
                    RecentLatencyView(entries: history.entries, usual: breakdown,
                                      backupWait: settings.effectiveBackup ? settings.setup.backupWait : nil)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}
