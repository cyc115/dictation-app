import AVFoundation
import XCTest
@testable import DictationKit

/// `./build.sh --keep-running` swapped the installed app under a running copy; macOS then gave that
/// copy only zeros from the mic ("Client is not granted access to the input device"), so every
/// dictation came back empty or as text a model made up from silence, until it was relaunched.
final class MicSilenceTests: XCTestCase {
    /// Starts `mic` on a fake wired mic; returns what feeds it audio.
    private func start(_ mic: MicCapture, onBuffer: @escaping (AVAudioPCMBuffer) -> Void = { _ in }) throws
        -> (AVAudioPCMBuffer) -> Void {
        let mics = FakeMics(mic)
        try mic.start(inputUID: "", onBuffer: onBuffer, onError: { XCTFail($0) })
        return try XCTUnwrap(mics.feeds[FakeMics.wired.id])
    }

    private func feed(_ deliver: (AVAudioPCMBuffer) -> Void, amplitude: Float, count: Int) {
        for _ in 0..<count { deliver(AudioLevelTests.buffer(amplitude: amplitude)) }
    }

    func testAllZeroAudioIsFlaggedAfterHalfASecond() throws {
        let mic = MicCapture()
        XCTAssertFalse(mic.heardOnlySilence, "nothing recorded yet")
        let deliver = try start(mic)
        feed(deliver, amplitude: 0, count: MicCapture.silenceBuffers - 1)
        XCTAssertFalse(mic.heardOnlySilence, "a quick press can start with a few zero buffers")
        feed(deliver, amplitude: 0, count: 1)
        XCTAssertTrue(mic.heardOnlySilence)
        mic.stop()
        XCTAssertTrue(mic.heardOnlySilence, "still known after stop, when the engine checks")
    }

    func testAnyNoiseCountsAsSignal() throws {
        let mic = MicCapture()
        let deliver = try start(mic)
        feed(deliver, amplitude: 0, count: 30)
        feed(deliver, amplitude: 0.0001, count: 1)  // a quiet room is never exactly zero
        feed(deliver, amplitude: 0, count: 30)
        XCTAssertFalse(mic.heardOnlySilence)
    }

    func testEachDictationStartsOver() throws {
        let mic = MicCapture()
        feed(try start(mic), amplitude: 0, count: 30)
        _ = try start(mic)
        XCTAssertFalse(mic.heardOnlySilence)
        mic.stop()
    }

    func testBuffersStillReachTheEngine() throws {
        let mic = MicCapture()
        var got = 0
        let deliver = try start(mic, onBuffer: { _ in got += 1 })
        deliver(AudioLevelTests.buffer(amplitude: 0))
        XCTAssertEqual(got, 1)
    }

    /// The real stop path: a silent recording is never uploaded.
    func testCloudEngineReportsSilenceInsteadOfUploading() {
        let engine = CloudEngine()
        let client = FakeTranscriptionClient()
        engine.client = client
        engine.modelID = CloudBackupTests.main
        let mics = FakeMics(engine.mic)
        engine.start(inputUID: "", backups: false, onLevel: { _ in }, onMic: { _ in }, onError: { XCTFail($0) })
        for _ in 0..<47 { mics.feeds[FakeMics.wired.id]?(AudioLevelTests.buffer(amplitude: 0)) }  // 1 s of zeros through the tap path
        let done = expectation(description: "stopped")
        var error: String?
        engine.stop(completion: { XCTFail("got text: \($0)"); done.fulfill() }, failure: { error = $0; done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(error, MicCapture.silenceMessage)
        XCTAssertTrue(client.asked.isEmpty, "silence isn't sent to the cloud model")
    }

    func testOnDeviceEngineReportsSilence() throws {
        let engine = SpeechEngine()
        feed(try start(engine.mic), amplitude: 0, count: 30)
        var error: String?
        (engine as DictationEngine).stop(completion: { XCTFail("got text: \($0)") }, failure: { error = $0 })
        XCTAssertEqual(error, MicCapture.silenceMessage)
    }
}

final class BundleWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func install(_ name: String, contents: String) throws -> URL {
        let bundle = dir.appendingPathComponent(name).appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let exe = bundle.appendingPathComponent("DictationApp")
        try contents.write(to: exe, atomically: false, encoding: .utf8)
        return exe
    }

    private func waitForReplaced(_ watcher: BundleWatcher, _ replaced: XCTestExpectation, after change: () throws -> Void) rethrows {
        watcher.start()
        try change()
        wait(for: [replaced], timeout: 3)
    }

    /// What build.sh --keep-running does: move the old bundle aside, move the new one in, delete the old.
    func testNoticesTheBundleSwap() throws {
        let exe = try install("DictationApp.app", contents: "old")
        _ = try install(".DictationApp-new.app", contents: "new")
        let replaced = expectation(description: "replaced")
        let watcher = BundleWatcher(executable: exe) { replaced.fulfill() }
        try waitForReplaced(watcher, replaced) {
            let fm = FileManager.default
            let installed = dir.appendingPathComponent("DictationApp.app"), old = dir.appendingPathComponent(".old.app")
            try fm.moveItem(at: installed, to: old)
            try fm.moveItem(at: dir.appendingPathComponent(".DictationApp-new.app"), to: installed)
            try fm.removeItem(at: old)
        }
    }

    func testNoticesAnInPlaceCopy() throws {
        let exe = try install("DictationApp.app", contents: "old")
        let replaced = expectation(description: "replaced")
        let watcher = BundleWatcher(executable: exe) { replaced.fulfill() }
        try waitForReplaced(watcher, replaced) {
            Thread.sleep(forTimeInterval: 0.01)  // a different mtime
            try "new build".write(to: exe, atomically: false, encoding: .utf8)
        }
    }

    func testQuietWhenNothingChanges() throws {
        let exe = try install("DictationApp.app", contents: "old")
        let watcher = BundleWatcher(executable: exe) { XCTFail("not replaced") }
        watcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
}

final class AppRelaunchTests: XCTestCase {
    private var busy = false
    private var relaunches = 0

    private func makeRelaunch() -> AppRelaunch {
        let relaunch = AppRelaunch()
        relaunch.delay = 0.01
        relaunch.isBusy = { [unowned self] in busy }
        relaunch.relaunch = { [unowned self] in relaunches += 1 }
        return relaunch
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    func testRelaunchesRightAwayWhenIdle() {
        let relaunch = makeRelaunch()
        relaunch.updateInstalled()
        settle()
        XCTAssertEqual(relaunches, 1)
        relaunch.relaunchIfIdle()
        settle()
        XCTAssertEqual(relaunches, 1, "only once per new build")
    }

    func testWaitsForTheDictationInProgress() {
        let relaunch = makeRelaunch()
        busy = true
        relaunch.updateInstalled()
        settle()
        XCTAssertEqual(relaunches, 0, "never cuts off a dictation")
        busy = false
        relaunch.relaunchIfIdle()
        settle()
        XCTAssertEqual(relaunches, 1)
    }

    func testADictationStartedDuringTheGraceWaitsToo() {
        let relaunch = makeRelaunch()
        relaunch.delay = 0.05
        relaunch.updateInstalled()
        busy = true  // pressed the hotkey right after the last one finished
        settle()
        XCTAssertEqual(relaunches, 0)
        XCTAssertTrue(relaunch.pending)
        busy = false
        relaunch.relaunchIfIdle()
        settle()
        XCTAssertEqual(relaunches, 1)
    }

    func testNothingInstalledNothingHappens() {
        let relaunch = makeRelaunch()
        relaunch.relaunchIfIdle()
        settle()
        XCTAssertEqual(relaunches, 0)
    }

    /// The real helper script, with a stand-in for `open`: it waits for the app to exit, then opens
    /// a new copy (-n). Without -n, an `open` a millisecond after the exit found LaunchServices still
    /// listing the dead app and launched nothing (Oct 25, 03:07: the app stayed closed).
    func testTheHelperOpensANewCopyOnceTheAppHasExited() throws {
        let folder = makeTempURL(self, "relaunch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let opened = folder.appendingPathComponent("opened.txt")
        let fakeOpen = folder.appendingPathComponent("open")
        try "#!/bin/sh\necho \"$@\" > \"\(opened.path)\"\n".write(to: fakeOpen, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
        let app = Process()  // stands in for the app that's quitting
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["0.4"]
        try app.run()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = AppRelaunch.reopenScript(after: app.processIdentifier,
                                                    bundle: URL(fileURLWithPath: "/Applications/Some App.app"), open: fakeOpen.path)
        try helper.run()
        spinRunLoop(0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path), "not while the app is still running")
        app.waitUntilExit()
        helper.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: opened, encoding: .utf8), "-n /Applications/Some App.app\n")
    }
}
