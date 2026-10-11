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

    func show(_ tab: MainTab) {
        selection.tab = tab
        if window == nil {
            let host = NSHostingController(rootView: MainView(selection: selection))
            let window = NSWindow(contentViewController: host)
            window.title = "DictationApp"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 860, height: 620))
            window.minSize = NSSize(width: 680, height: 480)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DictationAppMainWindow")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class TabSelection: ObservableObject {
    @Published var tab: MainTab = .home
    /// The correction to edit when Corrections opens.
    var editing: UUID?
}

private struct MainView: View {
    @ObservedObject var selection: TabSelection
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, selection: Binding(get: { selection.tab }, set: { if let t = $0 { selection.tab = t } })) { tab in
                Label(tab.title, systemImage: tab.icon).tag(tab)
                    .badge(tab == .corrections ? history.corrections.count : 0)
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
            switch selection.tab {
            case .home: HomeView()
            case .history: HistoryView(store: history, onCorrect: { id in
                selection.editing = id
                selection.tab = .corrections
            })
            case .corrections: CorrectionsView(store: history, editing: selection.editing)
                .onDisappear { selection.editing = nil }
            case .settings: SettingsView(settings: .shared)
            }
        }
    }
}

private struct HomeView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Insights").font(.largeTitle.bold())
                    Text(settings.hint + ".").foregroundStyle(.secondary)
                }
                InsightsView(insights: .shared)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}
