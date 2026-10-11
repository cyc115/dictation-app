import AppKit
import os

/// Notices when the installed app is replaced under the running copy (`./build.sh --keep-running`).
///
/// macOS revokes the old process's microphone access once its files are swapped out: it keeps
/// running, but every later dictation records pure zeros ("Client is not granted access to the
/// input device"). So the app relaunches itself into the new build as soon as it's idle.
final class BundleWatcher {
    private let executable: URL
    private let onReplaced: () -> Void
    private var original: Identity?
    private var source: DispatchSourceFileSystemObject?

    /// What changes when the file at a path is replaced: a swap brings a new inode, an in-place copy a new mtime.
    struct Identity: Equatable {
        let device: dev_t, inode: ino_t, modified: timespec

        static func == (a: Identity, b: Identity) -> Bool {
            a.device == b.device && a.inode == b.inode
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    static func identity(of url: URL) -> Identity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino, modified: info.st_mtimespec)
    }

    /// `onReplaced` runs once, on the main queue.
    init(executable: URL, onReplaced: @escaping () -> Void) {
        self.executable = executable
        self.onReplaced = onReplaced
    }

    deinit { source?.cancel() }

    func start() {
        original = Self.identity(of: executable)
        let fd = open(executable.path, O_EVTONLY)
        guard fd >= 0, original != nil else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.delete, .rename, .write, .attrib], queue: .main)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// The watched file went away or changed; the new one may still be landing, so check until it has.
    private func changed(attempt: Int = 0) {
        guard source != nil else { return }
        if let now = Self.identity(of: executable), now != original {
            source?.cancel()
            source = nil
            AppRelaunch.log.info("installed build replaced; relaunching when idle")
            return onReplaced()
        }
        guard attempt < 20 else { return }  // moved away for good (uninstalled): nothing to relaunch into
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.changed(attempt: attempt + 1) }
    }
}

/// Relaunches into a newly installed build, but never in the middle of a dictation.
final class AppRelaunch {
    static let log = Logger(subsystem: "com.mikechen.DictationApp", category: "relaunch")

    /// True while a dictation is recording or its text is still on the way.
    var isBusy: () -> Bool = { false }
    var relaunch: () -> Void = { AppRelaunch.relaunchApp() }
    /// Grace after a dictation, so its paste and clipboard restore (TextInjector.restoreDelay) finish.
    var delay: TimeInterval = 1.5
    private(set) var pending = false
    private var scheduled = false

    /// A new build was installed: relaunch now, or once the dictation in progress is done.
    func updateInstalled() {
        pending = true
        relaunchIfIdle()
    }

    /// Call whenever a dictation finishes (text delivered, failed or cancelled). Main queue.
    func relaunchIfIdle() {
        guard pending, !scheduled, !isBusy() else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.pending, !self.isBusy() else { return }  // a dictation started meanwhile: wait for it
            self.pending = false
            self.relaunch()
        }
    }

    /// Opens the app at its installed path once this process has exited, then quits.
    static func relaunchApp(bundle: URL = Bundle.main.bundleURL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", bundle.path]
        do {
            try task.run()
        } catch {
            return log.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.terminate(nil)
    }
}
