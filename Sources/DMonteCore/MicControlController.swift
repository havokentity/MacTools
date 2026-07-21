import CoreAudio
import Foundation

/// Drives the Mic Control popover and its tray glyph: tracks the default *input*
/// device, its mute state and — where the hardware offers one — its input gain.
///
/// Everything is observed rather than polled. A meeting app, Control Center, or
/// System Settings can mute the mic behind our back, and a tray glyph that lies
/// about whether you are muted is worse than no glyph at all, so CoreAudio
/// property listeners push every external change straight back into `state`.
@MainActor
public final class MicControlController: ObservableObject {
    /// The single value the tray glyph and the popover headline both derive from.
    @Published public private(set) var state: MicControlKit.MicState = .noDevice

    /// Name of the current default input device, or `nil` when there is none.
    @Published public private(set) var deviceName: String?

    /// Input gain in `0...1`. Only meaningful while `gainSupported` is `true`.
    @Published public var gain: Float = 0

    /// Whether the device exposes a settable input gain. Many built-in and USB
    /// mics expose mute but no gain (or the reverse), so the two capabilities are
    /// tracked separately instead of being assumed to travel together.
    @Published public private(set) var gainSupported: Bool = false

    /// True while the user is dragging the gain slider. Our own `setVolume` fires
    /// the HAL volume listener, whose refresh would otherwise stamp the hardware's
    /// (quantised, slightly-lagged) reading back onto the value the slider is
    /// bound to, making the thumb stutter under the finger.
    private var isAdjustingGain = false

    /// The default input device we are currently reading and writing.
    private var deviceID: AudioDeviceID?

    /// System-object listeners: the device list plus the default-input selector.
    /// Without them, unplugging a USB mic or switching input in Sound settings
    /// would leave the popover controlling a device that is no longer live.
    private let listeners: [AudioPropertyListenerRegistration]

    /// Follows mute/volume on whichever device is currently the default input.
    private let inputStateListener: DefaultDeviceStateListener

    public init() {
        // Install the listeners before `self` is fully initialized by capturing
        // only plain static functions, then refresh on the main actor.
        listeners = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice
        ].compactMap { selector in
            AudioPropertyListenerRegistration(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: selector,
                scope: kAudioObjectPropertyScopeGlobal
            ) {
                Task { @MainActor in
                    MicControlController.notifyHardwareChanged()
                }
            }
        }
        inputStateListener = DefaultDeviceStateListener(scope: kAudioObjectPropertyScopeInput) {
            Task { @MainActor in
                MicControlController.notifyInputStateChanged()
            }
        }
        refresh()
        MicControlController.activeController = self
    }

    deinit {
        // `deinit` is nonisolated. The listener boxes are `Sendable` and remove the
        // CoreAudio registrations without touching any actor-isolated state.
        listeners.forEach { $0.remove() }
        inputStateListener.remove()
    }

    // A weak handle to the live controller so the (static) listener callbacks can
    // route refreshes back without capturing non-Sendable instance state.
    @MainActor private static weak var activeController: MicControlController?

    @MainActor private static func notifyHardwareChanged() {
        activeController?.refresh()
    }

    @MainActor private static func notifyInputStateChanged() {
        // Mute/gain moved on the device we already track: no need to re-enumerate.
        activeController?.refreshMuteAndGain()
    }

    // MARK: - Public API

    /// Re-reads the default input device, then its mute and gain state.
    public func refresh() {
        let newDeviceID = AudioDeviceKit.defaultInputDeviceID()
        deviceID = newDeviceID
        deviceName = newDeviceID.flatMap { id in
            AudioDeviceKit.allDevices().first(where: { $0.id == id })?.name
        }
        // Mute and gain are properties of the default input device, so the
        // listener has to follow it whenever that default changes.
        inputStateListener.observe(deviceID: newDeviceID)
        refreshMuteAndGain()
    }

    /// Flips the mute state of the default input device. A no-op when the device
    /// exposes no mute control, and `state` is only advanced once CoreAudio has
    /// confirmed the write — a failed write must not leave the tray claiming a
    /// mute that did not happen.
    public func toggleMute() {
        guard let deviceID, MicControlKit.canToggle(state) else { return }
        let newValue = state != .muted
        guard AudioDeviceKit.setMuted(newValue, for: deviceID, scope: kAudioObjectPropertyScopeInput) else {
            // The write was refused after we believed it was settable; re-read so
            // the UI shows what is actually true rather than what we intended.
            refreshMuteAndGain()
            return
        }
        state = newValue ? .muted : .live
    }

    /// Applies a slider value to the default input device's gain.
    public func applyGain(_ value: Float) {
        guard let deviceID, gainSupported else { return }
        AudioDeviceKit.setVolume(
            MicControlKit.clampGain(value),
            for: deviceID,
            scope: kAudioObjectPropertyScopeInput
        )
    }

    /// The slider's `onEditingChanged`: while editing, the HAL listener's refresh
    /// must not overwrite the value being dragged. On release we re-read the
    /// hardware so the control reflects the true final level.
    public func setGainEditing(_ editing: Bool) {
        isAdjustingGain = editing
        if !editing {
            refreshMuteAndGain()
        }
    }

    // MARK: - Private

    private func refreshMuteAndGain() {
        guard let deviceID else {
            state = MicControlKit.state(hasDevice: false, muted: nil)
            gainSupported = false
            gain = 0
            return
        }

        // A device can report a *readable* mute that is read-only, so the reading
        // is only trusted as "mutable" when CoreAudio also says it is settable —
        // otherwise the popover would offer a button that silently does nothing.
        let muted = AudioDeviceKit.isMuted(deviceID, scope: kAudioObjectPropertyScopeInput)
        let canMute = AudioDeviceKit.isMuteSettable(deviceID, scope: kAudioObjectPropertyScopeInput)
        state = MicControlKit.state(hasDevice: true, muted: canMute ? muted : nil)

        if let level = AudioDeviceKit.volume(for: deviceID, scope: kAudioObjectPropertyScopeInput) {
            gainSupported = true
            // Don't yank the slider out from under an active drag.
            if !isAdjustingGain {
                gain = level
            }
        } else {
            gainSupported = false
            if !isAdjustingGain {
                gain = 0
            }
        }
    }
}
