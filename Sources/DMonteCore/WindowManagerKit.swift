import AppKit
import ApplicationServices

/// A window-snapping action. The raw value is a stable identifier used for hotkey registration
/// and persistence; `title` / `symbol` drive the UI.
public enum WindowAction: String, CaseIterable, Sendable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case firstTwoThirds, lastTwoThirds
    case maximize, center, almostMaximize

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .firstTwoThirds: "Left Two-Thirds"
        case .lastTwoThirds: "Right Two-Thirds"
        case .maximize: "Maximize"
        case .center: "Center"
        case .almostMaximize: "Almost Maximize"
        }
    }

    public var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .leftThird: "rectangle.lefthalf.filled"
        case .centerThird: "rectangle.center.inset.filled"
        case .rightThird: "rectangle.righthalf.filled"
        case .firstTwoThirds: "rectangle.lefthalf.inset.filled"
        case .lastTwoThirds: "rectangle.righthalf.inset.filled"
        case .maximize: "rectangle.fill"
        case .center: "rectangle.center.inset.filled"
        case .almostMaximize: "rectangle.inset.filled"
        }
    }

    /// Default keyboard shortcut. All snap shortcuts use ⌃⌥ (Control+Option) like Rectangle's
    /// defaults, which rarely clash with app shortcuts. Users can remap these; the effective
    /// shortcut comes from `WindowShortcutStore`, with this value as the fallback.
    public var defaultShortcut: WindowShortcut? {
        switch self {
        case .leftHalf: WindowShortcut(keyCode: HotKeyCode.left, modifiers: HotKeyModifier.controlOption)
        case .rightHalf: WindowShortcut(keyCode: HotKeyCode.right, modifiers: HotKeyModifier.controlOption)
        case .topHalf: WindowShortcut(keyCode: HotKeyCode.up, modifiers: HotKeyModifier.controlOption)
        case .bottomHalf: WindowShortcut(keyCode: HotKeyCode.down, modifiers: HotKeyModifier.controlOption)
        case .maximize: WindowShortcut(keyCode: HotKeyCode.returnKey, modifiers: HotKeyModifier.controlOption)
        case .center: WindowShortcut(keyCode: HotKeyCode.c, modifiers: HotKeyModifier.controlOption)
        default: nil
        }
    }
}

/// Carbon virtual key codes used for the default shortcuts. Shared across the tools that claim
/// global hotkeys, not only Window Manager — hence letters that no window action uses.
public enum HotKeyCode {
    public static let left: UInt32 = 0x7B
    public static let right: UInt32 = 0x7C
    public static let down: UInt32 = 0x7D
    public static let up: UInt32 = 0x7E
    public static let returnKey: UInt32 = 0x24
    public static let keypadEnter: UInt32 = 0x4C
    public static let c: UInt32 = 0x08
    public static let g: UInt32 = 0x05
}

/// Carbon modifier masks (mirrors Carbon's `cmdKey`/`shiftKey`/`optionKey`/`controlKey` without
/// importing Carbon here).
public enum HotKeyModifier {
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
    public static let controlOption: UInt32 = control | option
}

/// A global keyboard shortcut as Carbon understands it: virtual key code + modifier mask.
/// Plain data, so it round-trips through UserDefaults and is trivially testable.
public struct WindowShortcut: Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: Persistence codec ("keyCode,modifiers")

    public var storageValue: String { "\(keyCode),\(modifiers)" }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: ",")
        guard parts.count == 2, let code = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: mods)
    }

    // MARK: Validation

    /// Whether the shortcut is safe to claim globally: it must include at least one of ⌘⌃⌥
    /// (⇧ alone would swallow ordinary typing), except function keys, which are fine bare.
    public var isUsableGlobally: Bool {
        let strong = HotKeyModifier.command | HotKeyModifier.control | HotKeyModifier.option
        return (modifiers & strong) != 0 || HotKeyGlyphs.functionKeyCodes.contains(keyCode)
    }

    /// Standard macOS rendering, e.g. "⌃⌥←".
    public var displayString: String {
        HotKeyGlyphs.modifierGlyphs(for: modifiers) + HotKeyGlyphs.glyph(forKeyCode: keyCode)
    }
}

/// Maps Carbon virtual key codes and modifier masks to the glyphs macOS uses in menus.
public enum HotKeyGlyphs {
    /// F1–F19 virtual key codes; these may be registered without ⌘⌃⌥.
    public static let functionKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
        105, 107, 113, 106, 64, 79, 80 // F13–F19
    ]

    private static let keyGlyphs: [UInt32: String] = [
        // Letters
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        // Digits
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9",
        // Punctuation
        0x18: "=", 0x1B: "-", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'", 0x2B: ",",
        0x2F: ".", 0x2C: "/", 0x32: "`",
        // Whitespace / control
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦", 0x47: "⌧",
        0x4C: "⌅",
        // Navigation
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19"
    ]

    /// Display glyph for a Carbon virtual key code ("←", "↩", "F5", …). Unknown codes render as
    /// "Key NN" so the UI never shows an empty shortcut.
    public static func glyph(forKeyCode code: UInt32) -> String {
        keyGlyphs[code] ?? "Key \(code)"
    }

    /// Modifier glyphs in canonical macOS order: ⌃ ⌥ ⇧ ⌘.
    public static func modifierGlyphs(for modifiers: UInt32) -> String {
        var out = ""
        if modifiers & HotKeyModifier.control != 0 { out += "⌃" }
        if modifiers & HotKeyModifier.option != 0 { out += "⌥" }
        if modifiers & HotKeyModifier.shift != 0 { out += "⇧" }
        if modifiers & HotKeyModifier.command != 0 { out += "⌘" }
        return out
    }
}

/// Reads and writes the user's custom shortcut assignments in shared defaults. Stored as a
/// `[action rawValue: "keyCode,modifiers"]` dictionary under `DefaultsKey.windowManagerShortcuts`;
/// actions not present fall back to their built-in default. Pure data in/out, so it is fully
/// testable against a scratch `UserDefaults` suite.
public struct WindowShortcutStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Only the user's explicit overrides (no built-in defaults mixed in).
    public func storedShortcuts() -> [WindowAction: WindowShortcut] {
        guard let raw = defaults.dictionary(forKey: DefaultsKey.windowManagerShortcuts) else { return [:] }
        var result: [WindowAction: WindowShortcut] = [:]
        for (key, value) in raw {
            guard let action = WindowAction(rawValue: key),
                  let stored = value as? String,
                  let shortcut = WindowShortcut(storageValue: stored) else { continue }
            result[action] = shortcut
        }
        return result
    }

    /// The shortcuts that should actually be registered: defaults overlaid with stored overrides.
    public func effectiveShortcuts() -> [WindowAction: WindowShortcut] {
        var result: [WindowAction: WindowShortcut] = [:]
        for action in WindowAction.allCases {
            if let shortcut = action.defaultShortcut { result[action] = shortcut }
        }
        for (action, shortcut) in storedShortcuts() { result[action] = shortcut }
        return result
    }

    /// Persists one override. The full override map is rewritten so the stored dictionary always
    /// reflects exactly the user's current customizations.
    public func save(_ shortcut: WindowShortcut, for action: WindowAction) {
        var overrides = storedShortcuts()
        overrides[action] = shortcut
        write(overrides)
    }

    /// Drops every override, restoring the built-in defaults.
    public func reset() {
        defaults.removeObject(forKey: DefaultsKey.windowManagerShortcuts)
    }

    private func write(_ overrides: [WindowAction: WindowShortcut]) {
        var raw: [String: String] = [:]
        for (action, shortcut) in overrides {
            raw[action.rawValue] = shortcut.storageValue
        }
        defaults.set(raw, forKey: DefaultsKey.windowManagerShortcuts)
    }
}

/// Window-snapping logic. The geometry is **pure and fully testable**: `frame(for:in:)` takes a
/// usable area and returns the target rect, both in a top-left origin space (x grows right, y grows
/// down — the same space AppKit's Accessibility API uses). The actual reading/writing of a window's
/// position lives in `WindowManagerController`, which converts AppKit's bottom-left screen
/// coordinates to this space at the boundary and applies the result through the Accessibility API.
public enum WindowManagerKit {

    /// Computes the target frame for `action` within `area` (a top-left-origin rect: y grows down).
    /// Pure arithmetic — no global state — so it is exhaustively unit-tested.
    public static func frame(for action: WindowAction, in area: CGRect) -> CGRect {
        let x = area.minX
        let y = area.minY
        let w = area.width
        let h = area.height
        let halfW = w / 2
        let halfH = h / 2
        let thirdW = w / 3

        switch action {
        case .leftHalf:        return CGRect(x: x, y: y, width: halfW, height: h)
        case .rightHalf:       return CGRect(x: x + halfW, y: y, width: w - halfW, height: h)
        case .topHalf:         return CGRect(x: x, y: y, width: w, height: halfH)
        case .bottomHalf:      return CGRect(x: x, y: y + halfH, width: w, height: h - halfH)
        case .topLeft:         return CGRect(x: x, y: y, width: halfW, height: halfH)
        case .topRight:        return CGRect(x: x + halfW, y: y, width: w - halfW, height: halfH)
        case .bottomLeft:      return CGRect(x: x, y: y + halfH, width: halfW, height: h - halfH)
        case .bottomRight:     return CGRect(x: x + halfW, y: y + halfH, width: w - halfW, height: h - halfH)
        case .leftThird:       return CGRect(x: x, y: y, width: thirdW, height: h)
        case .centerThird:     return CGRect(x: x + thirdW, y: y, width: thirdW, height: h)
        case .rightThird:      return CGRect(x: x + 2 * thirdW, y: y, width: w - 2 * thirdW, height: h)
        case .firstTwoThirds:  return CGRect(x: x, y: y, width: 2 * thirdW, height: h)
        case .lastTwoThirds:   return CGRect(x: x + thirdW, y: y, width: w - thirdW, height: h)
        case .maximize:        return area
        case .center:
            // Center at 60% size, clamped so it never exceeds the area.
            let cw = min(w, w * 0.6)
            let ch = min(h, h * 0.6)
            return CGRect(x: x + (w - cw) / 2, y: y + (h - ch) / 2, width: cw, height: ch)
        case .almostMaximize:
            let inset = min(w, h) * 0.05
            return CGRect(x: x + inset, y: y + inset, width: w - 2 * inset, height: h - 2 * inset)
        }
    }

    // MARK: - Frame verification (pure)

    /// Per-component tolerance, in points, within which an achieved window frame counts as
    /// matching the requested target. Not zero because some apps legitimately round the request
    /// (terminals snap their size to character-cell multiples, ~8–20 pt), and calling those
    /// visually perfect snaps "failed" would be wrong. Real failures are far outside this band:
    /// the live-diagnosed Electron case kept its old size, hundreds of points off target.
    public static let frameMatchTolerance: CGFloat = 24

    /// Whether `achieved` is close enough to `target`: every component (origin and size) within
    /// `tolerance`. Pure, so the verify-and-retry decision is unit-testable.
    public static func frameMatches(_ achieved: CGRect, target: CGRect, tolerance: CGFloat = frameMatchTolerance) -> Bool {
        abs(achieved.minX - target.minX) <= tolerance &&
            abs(achieved.minY - target.minY) <= tolerance &&
            abs(achieved.width - target.width) <= tolerance &&
            abs(achieved.height - target.height) <= tolerance
    }

    /// The order in which one apply attempt writes position and size through AX.
    public enum FrameSetOrder: Equatable, Sendable {
        /// position → size → position (the historical order: moving first lets a window cross to
        /// a smaller display before its final size is set, which a single pass can clamp).
        case positionFirst
        /// size → position → size (the alternate: live diagnosis against Claude Desktop showed
        /// that when `AXEnhancedUserInterface` animates moves, a size set issued *after* a
        /// position set is acknowledged and then dropped, while size-first applies).
        case sizeFirst
    }

    /// The attempt sequence `apply` walks until the achieved frame verifies against the target:
    /// the initial attempt plus up to two retries, alternating orderings so a window that rejects
    /// one ordering gets the other before we report failure.
    public static let frameSetAttempts: [FrameSetOrder] = [.positionFirst, .sizeFirst, .positionFirst]

    // MARK: - Screen matching (pure)

    /// Converts a Cocoa global rect (origin bottom-left of the primary screen, y up) to AX/Quartz
    /// global space (origin top-left of the primary screen, y down). Pure: the caller supplies the
    /// primary screen's height.
    public static func axRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Picks the screen area (all rects in AX top-left space) that `windowRect` belongs to:
    /// the area containing the window's center, else the area with the largest positive overlap.
    /// Returns `nil` when the window overlaps no area at all — the caller decides the fallback
    /// (the controller uses the primary screen, never the popover's screen).
    public static func areaIndex(forWindow windowRect: CGRect, in areas: [CGRect]) -> Int? {
        let center = CGPoint(x: windowRect.midX, y: windowRect.midY)
        if let hit = areas.firstIndex(where: { $0.contains(center) }) { return hit }

        var best: (index: Int, overlap: CGFloat)?
        for (index, area) in areas.enumerated() {
            let intersection = area.intersection(windowRect)
            let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (index, overlap)
            }
        }
        return best?.index
    }

    // MARK: - Corner chords (pure)

    /// The four half-snaps that can chain into a corner.
    public static let halfSnaps: Set<WindowAction> = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]

    /// How long after a half-snap hotkey a second, perpendicular half-snap still reads as a corner
    /// chord (⌃⌥→ then ⌃⌥↑ = top-right) rather than two independent half-snaps.
    public static let cornerChordWindow: TimeInterval = 0.35

    /// The corner two half-snaps combine into, if they are on perpendicular axes. Order-independent
    /// (right+top and top+right both give top-right); same-axis or non-half pairs return nil. Pure.
    public static func cornerCombining(_ first: WindowAction, _ second: WindowAction) -> WindowAction? {
        let horizontals: Set<WindowAction> = [.leftHalf, .rightHalf]
        let verticals: Set<WindowAction> = [.topHalf, .bottomHalf]
        let pair = [first, second]
        guard let horizontal = pair.first(where: horizontals.contains),
              let vertical = pair.first(where: verticals.contains) else {
            return nil // both on the same axis (or not halves): no corner
        }
        switch (horizontal, vertical) {
        case (.leftHalf, .topHalf):     return .topLeft
        case (.rightHalf, .topHalf):    return .topRight
        case (.leftHalf, .bottomHalf):  return .bottomLeft
        case (.rightHalf, .bottomHalf): return .bottomRight
        default:                        return nil
        }
    }

    /// The half-snap fired just before the current one, for chord detection.
    public struct ChordState: Equatable, Sendable {
        public let action: WindowAction
        public let at: Date
        public init(action: WindowAction, at: Date) {
            self.action = action
            self.at = at
        }
    }

    /// What a hotkey-fired half-snap should do given the previous one.
    public enum ChordOutcome: Equatable, Sendable {
        /// Apply this corner and clear the chord state.
        case corner(WindowAction)
        /// Apply this half and remember it (with `now`) as the new chord state.
        case half(WindowAction)
    }

    /// Promote to a corner when the previous half is recent and perpendicular, else apply the half
    /// itself. Pure, so the timing is unit-tested without real hotkeys.
    public static func resolveChord(
        previous: ChordState?,
        current: WindowAction,
        now: Date,
        window: TimeInterval = cornerChordWindow
    ) -> ChordOutcome {
        if let previous,
           now.timeIntervalSince(previous.at) <= window,
           let corner = cornerCombining(previous.action, current) {
            return .corner(corner)
        }
        return .half(current)
    }
}
