import AppKit

/// Small floating window showing the live transcript while dictating.
class OverlayWindow {
    private var panel: NSPanel?
    private var textView: NSTextView?

    func show(message: String) {
        if panel == nil { build() }
        textView?.string = message
        panel?.orderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 132),
            styleMask: [.nonactivatingPanel, .titled],
            backing: .buffered, defer: false
        )
        panel.title = "Dictating — release Fn to paste"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let tv = NSTextView(frame: NSRect(x: 14, y: 14, width: 532, height: 84))
        tv.isEditable = false
        tv.font = NSFont.systemFont(ofSize: 15)
        tv.backgroundColor = .clear
        panel.contentView?.addSubview(tv)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: (screen.frame.width - 560) / 2, y: 160))
        }
        self.panel = panel
        self.textView = tv
    }
}
