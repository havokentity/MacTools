import AppKit

public enum KeepAwakeSizing {
    public static func preferredSize() -> NSSize {
        let scale = currentScale
        return NSSize(width: (320 * scale).rounded(), height: (485 * scale).rounded())
    }

    /// The settings overlay, which is centred *over* the panel and therefore must never be wider
    /// than it. A hard-coded size looks right only at `currentScale == 1`; on a Mac whose menu bar
    /// is thinner than 26pt the panel shrinks and the sheet does not, so it overflows equally on
    /// both sides and its first and last characters are clipped.
    ///
    /// Capped at the panel rather than scaled with it. The sheet's contents are laid out at this
    /// size with unscaled padding, so shrinking it further than the panel demands would squeeze
    /// them for no reason — and on the tools whose sheet is already narrower than their panel,
    /// scaling would inset it noticeably while fixing nothing.
    public static func settingsSize() -> NSSize {
        let panel = preferredSize()
        return NSSize(width: min(320, panel.width), height: min(230, panel.height))
    }

    static var currentScale: CGFloat {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenScale = visibleFrame.height / 950
        let menuBarScale = NSStatusBar.system.thickness / 26
        return min(1.0, max(0.82, min(screenScale, menuBarScale)))
    }
}
