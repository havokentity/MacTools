import AppKit

public enum GrabTextSizing {
    public static func preferredSize() -> NSSize {
        let scale = currentScale
        return NSSize(width: (460 * scale).rounded(), height: (420 * scale).rounded())
    }

    /// The settings overlay, which is centred *over* the panel and therefore must never be wider
    /// than it. A hard-coded size looks right only at `currentScale == 1`; on a Mac whose menu bar
    /// is thinner than 26pt the panel shrinks and the sheet does not, so it overflows equally on
    /// both sides and its first and last characters are clipped.
    public static func settingsSize() -> NSSize {
        let panel = preferredSize()
        // Leave room for the 18pt padding PreferencesOverlay adds around the sheet on every
        // side: a sheet sized to the full panel becomes panel+36 once padded and spills
        // the panel, dragging the content behind it off both edges.
        let overlayChrome: CGFloat = 36
        return NSSize(width: min(400, panel.width - overlayChrome), height: min(360, panel.height - overlayChrome))
    }

    static var currentScale: CGFloat {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenScale = visibleFrame.height / 950
        let menuBarScale = NSStatusBar.system.thickness / 26
        return min(1.0, max(0.82, min(screenScale, menuBarScale)))
    }
}
