import AudioToolbox
import CoreAudio
import Foundation

/// The default output device's main volume, read and written through CoreAudio.
///
/// Every call can fail — an aggregate or USB device may have no settable main volume, and
/// a device can vanish between two calls — so each one answers nil or false rather than
/// throwing. Ducking is a nicety; a device that won't cooperate just doesn't get ducked.
enum SystemVolume {
    static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// 0…1, or nil when the device has no main volume to read.
    static func level(of device: AudioDeviceID) -> Float? {
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr
        else { return nil }
        return level
    }

    /// False, not nil, when the device can't say: an unmuted guess only means we duck a
    /// device that was silent anyway.
    static func isMuted(_ device: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
        else { return false }
        return muted != 0
    }

    @discardableResult
    static func setLevel(_ level: Float, on device: AudioDeviceID) -> Bool {
        var address = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return false }
        var value = Float32(max(0, min(1, level)))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    /// The slider in Control Centre — one value for the whole device, however many
    /// channels it has.
    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
