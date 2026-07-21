import Foundation

/// Pure presentation logic for the Mic Control tool: it turns the three facts the
/// controller reads from CoreAudio (is there a default input, can it be muted, is
/// it muted) into the one glyph, title and sentence the UI shows.
///
/// It is deliberately free of AppKit/CoreAudio so the headless test target can
/// pin the tray glyph — the whole point of the tool is that the menu bar tells you
/// at a glance whether you are muted, so "which glyph for which state" is the
/// behaviour most worth locking down.
public enum MicControlKit {

    /// Everything the UI needs to know about the default input device, collapsed
    /// into the four cases that read differently to a user mid-meeting.
    public enum MicState: String, Sendable, Equatable, CaseIterable {
        /// A default input exists and is muted — nobody can hear you.
        case muted
        /// A default input exists and is live — you are being heard.
        case live
        /// A default input exists but exposes no mute control, so this tool
        /// cannot mute it. Reported rather than hidden: silently showing a live
        /// mic glyph that never changes would be worse than admitting the limit.
        case unsupported
        /// There is no default input device at all (unplugged, or none configured).
        case noDevice
    }

    // MARK: - State

    /// Collapses the raw CoreAudio readings into a `MicState`.
    /// - Parameters:
    ///   - hasDevice: whether `AudioDeviceKit.defaultInputDeviceID()` returned an id.
    ///   - muted: the device's mute reading, or `nil` when it exposes no *settable*
    ///     mute control. Callers pass `nil` both for a device with no mute property
    ///     at all and for one whose mute is read-only, since neither can be toggled.
    public static func state(hasDevice: Bool, muted: Bool?) -> MicState {
        guard hasDevice else { return .noDevice }
        guard let muted else { return .unsupported }
        return muted ? .muted : .live
    }

    /// `true` only when toggling can actually change something, so the view can
    /// disable the control instead of offering a button that does nothing.
    public static func canToggle(_ state: MicState) -> Bool {
        state == .muted || state == .live
    }

    // MARK: - Tray

    /// The menu-bar glyph. The slashed mic has to be unmistakable at 18pt in the
    /// corner of a screen, so muted gets the slash and every non-muted case gets a
    /// plain mic — a user glancing up must never read "muted" when they are live.
    /// The two states this tool cannot act on (no device, no mute control) use the
    /// hollow outline mic: visibly "not armed", but still clearly not a slash, so
    /// it is never mistaken for muted either.
    public static func trayGlyphName(for state: MicState) -> String {
        switch state {
        case .muted:
            return "mic.slash.fill"
        case .live:
            return "mic.fill"
        case .unsupported, .noDevice:
            return "mic"
        }
    }

    /// Tooltip for the status item, naming the device so a user with several
    /// interfaces can tell which one the glyph is reporting on.
    public static func trayTooltip(for state: MicState, deviceName: String?) -> String {
        let name = displayName(deviceName)
        switch state {
        case .muted:
            return "Mic Control — \(name) is muted"
        case .live:
            return "Mic Control — \(name) is live"
        case .unsupported:
            return "Mic Control — \(name) cannot be muted"
        case .noDevice:
            return "Mic Control — no input device"
        }
    }

    // MARK: - Popover copy

    /// The large headline inside the popover.
    public static func title(for state: MicState) -> String {
        switch state {
        case .muted:
            return "Muted"
        case .live:
            return "Live"
        case .unsupported:
            return "Can’t Mute"
        case .noDevice:
            return "No Microphone"
        }
    }

    /// The explanatory line under the headline. The `unsupported` and `noDevice`
    /// wording says *why* the control is dead, because a disabled button with no
    /// explanation reads as a bug.
    public static func subtitle(for state: MicState, deviceName: String?) -> String {
        let name = displayName(deviceName)
        switch state {
        case .muted:
            return "\(name) is muted — nobody can hear you"
        case .live:
            return "\(name) is picking up sound"
        case .unsupported:
            return "\(name) exposes no mute control, so it can’t be muted from here. Mute inside your meeting app instead."
        case .noDevice:
            return "No input device is selected in Sound settings. Connect a microphone to use Mic Control."
        }
    }

    /// The label on the toggle button.
    public static func actionTitle(for state: MicState) -> String {
        switch state {
        case .muted:
            return "Unmute"
        case .live:
            return "Mute"
        case .unsupported, .noDevice:
            return "Unavailable"
        }
    }

    // MARK: - Input gain

    /// Clamps a gain to the `0...1` range CoreAudio's scalar volume uses, so a
    /// slider that overshoots (or a `NaN` from a divide-by-zero layout pass)
    /// never reaches the hardware.
    public static func clampGain(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// The "72%" readout beside the gain slider. Rounds rather than truncates so
    /// a slider dragged fully right reads 100%, not 99%.
    public static func gainPercentLabel(_ value: Float) -> String {
        "\(Int((clampGain(value) * 100).rounded()))%"
    }

    // MARK: - Private

    /// Devices always have a name in practice, but CoreAudio can withhold one; the
    /// fallback keeps every sentence above grammatical instead of leaking "".
    private static func displayName(_ deviceName: String?) -> String {
        guard let deviceName, !deviceName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "The microphone"
        }
        return deviceName
    }
}
