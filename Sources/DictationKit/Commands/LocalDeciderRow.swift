import AppKit
import SwiftUI

/// Settings › Experimental, under "Decide commands on this Mac": whether Decider is ready, and the one
/// step to get it there: download it (in the browser: Perplexity's site doesn't serve the app to
/// anything else) or open it. Checked every 2 s until it's ready, so it turns ready on its own.
struct LocalDeciderRow: View {
    var check: () async -> LocalDecider.Status = { await LocalDecider.status() }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var launch: () -> Void = {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LocalDecider.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
    @State private var status: LocalDecider.Status?

    var body: some View {
        SettingRow("Decider", detail) {
            switch status {
            case .notInstalled:
                HStack {
                    Button("About") { openURL(LocalDecider.about) }
                    Button("Get Decider…") { openURL(LocalDecider.download) }.keyboardShortcut(.defaultAction)
                }
            case .notRunning:
                Button("Open Decider") { launch() }
            case .starting:
                ProgressView().controlSize(.small)
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Ready")
            case nil:
                EmptyView()
            }
        }
        .task {
            while !Task.isCancelled {
                status = await check()
                try? await Task.sleep(for: .seconds(status == .ready ? 30 : 2))
            }
        }
    }

    private var detail: String {
        switch status {
        case .ready: "Ready: commands are decided on this Mac."
        case .starting(let what): "Starting (\(what)). The first time, it downloads its 5.8 GB model."
        case .notRunning: "Installed but not running. Until it is, commands say “Decider isn't running”."
        case .notInstalled: "Not installed: a free app from Perplexity. Get it, open the download, drag Decider to Applications and open it; it downloads its 5.8 GB model once. Needs 16 GB of memory."
        case nil: "Checking…"
        }
    }
}
