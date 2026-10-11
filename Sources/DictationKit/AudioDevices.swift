import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio

struct AudioInputDevice: Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// CoreAudio helpers: list microphones, pick the one to record from, read/write output mute and volume.
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// The microphone a dictation records from: the one with `uid` if it's connected, else the
    /// system default input. Nil if there's no input at all.
    static func inputDevice(uid: String) -> AudioDeviceID? {
        if !uid.isEmpty, let device = inputDevices().first(where: { $0.uid == uid }) { return device.id }
        return defaultInputDevice()
    }

    // MARK: Output (for mute-while-dictating)

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func device(withUID uid: String) -> AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func uid(of id: AudioDeviceID) -> String? { stringProperty(id, kAudioDevicePropertyDeviceUID) }

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// Name of the mic a dictation will actually use: the preferred one if it's connected,
    /// otherwise the system default input.
    static func activeInputName(preferredUID: String) -> String? {
        if !preferredUID.isEmpty, let device = inputDevices().first(where: { $0.uid == preferredUID }) {
            return device.name
        }
        return defaultInputDevice().flatMap { stringProperty($0, kAudioObjectPropertyName) }
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool? {
        var address = outputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func setMuted(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = outputAddress(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address),
              AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    static func volume(_ id: AudioDeviceID) -> Float? {
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ id: AudioDeviceID, _ volume: Float) -> Bool {
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address),
              AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = Float32(volume)
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    // MARK: Private

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

    func mute() {
        guard UserDefaults.standard.dictionary(forKey: Self.pendingKey) == nil,
              let device = AudioDevices.defaultOutputDevice(),
              let uid = AudioDevices.uid(of: device) else { return }
        if AudioDevices.isMuted(device) == false, AudioDevices.setMuted(device, true) {
            save(["uid": uid, "kind": "mute"])
        } else if AudioDevices.isMuted(device) == nil,
                  let volume = AudioDevices.volume(device), volume > 0,
                  AudioDevices.setVolume(device, 0) {
            save(["uid": uid, "kind": "volume", "volume": volume])
        }
    }

    /// Restores whatever mute() changed (also used at launch for crash recovery).
    func restore() {
        guard let pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        guard let uid = pending["uid"] as? String, let device = AudioDevices.device(withUID: uid) else { return }
        if pending["kind"] as? String == "mute" {
            _ = AudioDevices.setMuted(device, false)
        } else if let volume = pending["volume"] as? Float {
            _ = AudioDevices.setVolume(device, volume)
        }
    }

    private func save(_ value: [String: Any]) {
        UserDefaults.standard.set(value, forKey: Self.pendingKey)
    }
}

/// Short system sounds for start / stop / cancel.
enum InteractionSound {
    case start, stop, cancel

    func play() {
        let name: String
        switch self {
        case .start: name = "Tink"
        case .stop: name = "Pop"
        case .cancel: name = "Bottle"
        }
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.35
        sound.play()
    }
}
