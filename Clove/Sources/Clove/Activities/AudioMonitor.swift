import CoreAudio
import Foundation

/// Watches the default audio output and posts:
/// - `.audioDevice` when the output switches to a Bluetooth device (AirPods, speakers…);
/// - `.volume` when the output's volume or mute state changes.
/// Uses Core Audio only, so it needs no Bluetooth or accessibility permission.
@MainActor
final class AudioMonitor {
    private let center: ActivityCenter
    private var device: AudioDeviceID?
    private var lastVolume: Float32?
    private var lastMuted = false
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init(center: ActivityCenter) {
        self.center = center
        // The device and volume at launch are only a baseline; nothing is announced.
        attach(to: AudioHardware.defaultOutputDevice())

        var address = AudioHardware.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioHardware.systemObject, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
    }

    private func defaultOutputChanged() {
        guard let newDevice = AudioHardware.defaultOutputDevice(), newDevice != device else { return }
        attach(to: newDevice)
        if AudioHardware.isBluetooth(newDevice), let name = AudioHardware.name(of: newDevice) {
            center.post(.audioDevice(name: name))
        }
    }

    /// Moves the volume/mute listener to `newDevice` and takes its current level as the baseline,
    /// so switching devices does not itself show a volume change.
    private func attach(to newDevice: AudioDeviceID?) {
        if let device, let deviceListener {
            var volume = AudioHardware.volumeAddress
            var mute = AudioHardware.muteAddress
            AudioObjectRemovePropertyListenerBlock(device, &volume, .main, deviceListener)
            AudioObjectRemovePropertyListenerBlock(device, &mute, .main, deviceListener)
        }
        device = newDevice
        deviceListener = nil
        guard let newDevice else { return }

        lastVolume = AudioHardware.volume(of: newDevice)
        lastMuted = AudioHardware.isMuted(newDevice)

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.volumeChanged() }
        }
        var volume = AudioHardware.volumeAddress
        var mute = AudioHardware.muteAddress
        if AudioObjectHasProperty(newDevice, &volume) {
            AudioObjectAddPropertyListenerBlock(newDevice, &volume, .main, listener)
        }
        if AudioObjectHasProperty(newDevice, &mute) {
            AudioObjectAddPropertyListenerBlock(newDevice, &mute, .main, listener)
        }
        deviceListener = listener
    }

    private func volumeChanged() {
        guard let device, let volume = AudioHardware.volume(of: device) else { return }
        let muted = AudioHardware.isMuted(device)
        // Core Audio can report the same value more than once per key press.
        guard volume != lastVolume || muted != lastMuted else { return }
        lastVolume = volume
        lastMuted = muted
        center.post(.volume(level: volume, muted: muted))
    }
}
