import AppKit

public enum NetworkInfoSizing {
    public static func preferredSize() -> NSSize {
        let scale = currentScale
        // Wider than the 320-point tools because a full IPv6 literal is 39 characters and
        // truncating the address the user came here to copy would defeat the tool.
        return NSSize(width: (368 * scale).rounded(), height: (520 * scale).rounded())
    }

    /// The settings overlay, which is centred *over* the panel and therefore must never be wider
    /// than it. A hard-coded width looks right only at `currentScale == 1`; on a Mac whose menu
    /// bar is thinner than 26pt the panel shrinks and the sheet does not, so it overflows equally
    /// on both sides and its first and last characters are clipped. Width is capped at the panel
    /// so that cannot happen at any scale.
    public static func settingsSize() -> NSSize {
        let scale = currentScale
        return NSSize(
            width: min((340 * scale).rounded(), preferredSize().width),
            height: (300 * scale).rounded()
        )
    }

    static var currentScale: CGFloat {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenScale = visibleFrame.height / 950
        let menuBarScale = NSStatusBar.system.thickness / 26
        return min(1.0, max(0.82, min(screenScale, menuBarScale)))
    }
}
