import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import IOKit
import os

struct AudioInputDevice: Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// Bluetooth mics take about a second to send real audio: the headset first switches into its
    /// call mode. The pill shows that wait (`OverlayWindow.showListening(warmingUp:)`).
    var isBluetooth = false
}

/// The mics a dictation records from: the one `chosen` (the preferred mic if it's connected, else the
/// system default input) and, with Intelligent mic selection, the `backups` opened alongside it.
struct MicPick: Equatable {
    let chosen: AudioInputDevice
    var backups: [AudioInputDevice] = []
}

/// CoreAudio helpers: list microphones, pick the one to record from, read/write output mute and volume.
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        allDevices().compactMap(input)
    }

    /// The microphone `id`, if it is one.
    static func input(_ id: AudioDeviceID) -> AudioInputDevice? { input(id, transport: transportType(id)) }

    private static func input(_ id: AudioDeviceID, transport: UInt32) -> AudioInputDevice? {
        guard inputChannelCount(id) > 0,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name,
                                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                                    || transport == kAudioDeviceTransportTypeBluetoothLE)
    }

    static func defaultInputDevice() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    /// The mics a dictation records from, in one pass over the devices (each question CoreAudio is
    /// asked is a round trip to coreaudiod, and it's asked several per device): `chosen` is the
    /// preferred mic if it's connected, else the system default input; nil when none is connected.
    /// With `backups`, Intelligent mic selection's backups too: every other connected mic that's real
    /// wired or built-in hardware. Not Bluetooth (opening a headset's mic drops its audio to call
    /// quality), virtual devices (Steam, Jump Desktop), an iPhone's Continuity mic, or the Mac's own
    /// mic while the lid is closed (it then records pure silence).
    static func pick(preferredUID: String, backups: Bool) -> MicPick? {
        let lidClosed = backups && isLidClosed()
        var inputs: [(device: AudioInputDevice, backup: Bool)] = []
        for id in allDevices() {
            let transport = transportType(id)
            guard let device = input(id, transport: transport) else { continue }
            inputs.append((device, wiredTransports.contains(transport) && !(lidClosed && transport == kAudioDeviceTransportTypeBuiltIn)))
        }
        let preferred = preferredUID.isEmpty ? nil : inputs.first { $0.device.uid == preferredUID }?.device
        guard let chosen = preferred ?? defaultInputDevice().flatMap({ id in inputs.first { $0.device.id == id }?.device }) else {
            return nil
        }
        if preferred == nil, !preferredUID.isEmpty {
            log.error("input \(preferredUID, privacy: .public) isn't connected; using the default")
        }
        return MicPick(chosen: chosen, backups: backups ? inputs.filter { $0.backup && $0.device.id != chosen.id }.map(\.device) : [])
    }

    /// The mic a dictation will actually use (`pick` without the backups).
    static func activeInput(preferredUID: String) -> AudioInputDevice? {
        pick(preferredUID: preferredUID, backups: false)?.chosen
    }

    /// Intelligent mic selection's backups besides `chosen` (see `pick`).
    static func backupInputs(excluding chosen: AudioInputDevice) -> [AudioInputDevice] {
        pick(preferredUID: chosen.uid, backups: true)?.backups ?? []
    }

    private static let log = Logger(subsystem: "com.mikechen.DictationApp", category: "mic")

    private static let wiredTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
        kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeHDMI,
        kAudioDeviceTransportTypeDisplayPort,
    ]

    /// A MacBook with its lid closed (an external display in use), whose own mic is then silent.
    static func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }

    // MARK: Output (for mute-while-dictating)

    static func defaultOutputDevice() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    static func device(withUID uid: String) -> AudioDeviceID? {
        allDevices().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func uid(of id: AudioDeviceID) -> String? { stringProperty(id, kAudioDevicePropertyDeviceUID) }

    /// nil when the device has no mute switch (then `volume` is the way to silence it).
    static func isMuted(_ id: AudioDeviceID) -> Bool? {
        outputProperty(id, kAudioDevicePropertyMute, UInt32.self).map { $0 != 0 }
    }

    static func setMuted(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        setOutputProperty(id, kAudioDevicePropertyMute, UInt32(muted ? 1 : 0))
    }

    static func volume(_ id: AudioDeviceID) -> Float? {
        outputProperty(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32.self)
    }

    static func setVolume(_ id: AudioDeviceID, _ volume: Float) -> Bool {
        setOutputProperty(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(volume))
    }

    // MARK: Private

    /// An output-scope property's value, or nil if the device doesn't have the property.
    private static func outputProperty<T: AdditiveArithmetic>(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _: T.Type) -> T? {
        var address = outputAddress(selector)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value = T.zero
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// False if the device doesn't have the property, won't let it be set, or refused the value.
    private static func setOutputProperty<T>(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: T) -> Bool {
        var address = outputAddress(selector)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address),
              AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    /// Every audio device, input or output.
    private static func allDevices() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = globalAddress(selector)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = globalAddress(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Silences the default output while dictating and puts it back afterwards.
/// Uses mute when the device supports it, otherwise volume 0. What to restore is also
/// saved to UserDefaults, so a crash mid-dictation is undone on the next launch.
final class OutputMuter {
    private static let pendingKey = "pendingAudioRestore"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func mute() {
        guard defaults.dictionary(forKey: Self.pendingKey) == nil,
              let device = AudioDevices.defaultOutputDevice(),
              let uid = AudioDevices.uid(of: device) else { return }
        let muted = AudioDevices.isMuted(device)
        if muted == false, AudioDevices.setMuted(device, true) {
            save(["uid": uid, "kind": "mute"])
        } else if muted == nil,
                  let volume = AudioDevices.volume(device), volume > 0,
                  AudioDevices.setVolume(device, 0) {
            save(["uid": uid, "kind": "volume", "volume": volume])
        }
    }

    /// Restores whatever mute() changed (also used at launch for crash recovery).
    func restore() {
        guard let pending = defaults.dictionary(forKey: Self.pendingKey) else { return }
        defaults.removeObject(forKey: Self.pendingKey)
        guard let uid = pending["uid"] as? String, let device = AudioDevices.device(withUID: uid) else { return }
        if pending["kind"] as? String == "mute" {
            _ = AudioDevices.setMuted(device, false)
        } else if let volume = pending["volume"] as? Float {
            _ = AudioDevices.setVolume(device, volume)
        }
    }

    private func save(_ value: [String: Any]) {
        defaults.set(value, forKey: Self.pendingKey)
    }
}

/// Short system sounds for start / stop / cancel.
enum InteractionSound: String {
    case start = "Tink", stop = "Pop", cancel = "Bottle"

    func play() {
        guard let sound = NSSound(named: NSSound.Name(rawValue))?.copy() as? NSSound else { return }
        sound.volume = 0.35
        sound.play()
    }
}
