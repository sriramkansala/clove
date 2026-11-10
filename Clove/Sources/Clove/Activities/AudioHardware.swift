import AudioToolbox
import CoreAudio
import Foundation

/// Thin wrappers over the Core Audio property API for the default output device.
enum AudioHardware {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static let defaultOutputAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
    static let volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                       scope: kAudioDevicePropertyScopeOutput)
    static let muteAddress = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = defaultOutputAddress
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func transportType(of device: AudioDeviceID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : 0
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let transport = transportType(of: device)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func name(of device: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// Output volume 0...1, or nil if the device has no software volume (e.g. some HDMI outputs).
    static func volume(of device: AudioDeviceID) -> Float32? {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    /// Whether the device's volume can be changed in software (false for e.g. some HDMI outputs).
    static func canSetVolume(of device: AudioDeviceID) -> Bool {
        var address = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr
        else { return false }
        return settable.boolValue
    }

    static func setVolume(_ volume: Float32, of device: AudioDeviceID) {
        var address = volumeAddress
        var value = min(max(volume, 0), 1)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func setMuted(_ muted: Bool, of device: AudioDeviceID) {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }
}
