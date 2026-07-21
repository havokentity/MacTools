import AppKit

public enum CleanDriveSizing {
    public static func preferredSize() -> NSSize {
        let scale = currentScale
        return NSSize(width: (420 * scale).rounded(), height: (500 * scale).rounded())
    }

    /// The developer-junk sheet, which is centred *over* the panel by `PreferencesOverlay` and so
    /// must never exceed it. Unlike the settings sheet this one wants every point it can get: it
    /// lists eleven categories that each expand into a drill-down, so it is sized to fill the panel
    /// right up to the overlay's own padding rather than to a comfortable fixed size.
    public static func devJunkSize() -> NSSize {
        let panel = preferredSize()
        // PreferencesOverlay adds 18pt of padding on every side; a sheet sized to the full panel
        // becomes panel+36 once padded and spills out of it.
        let overlayChrome: CGFloat = 36
        return NSSize(width: panel.width - overlayChrome, height: panel.height - overlayChrome)
    }

    static var currentScale: CGFloat {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenScale = visibleFrame.height / 950
        let menuBarScale = NSStatusBar.system.thickness / 26
        return min(1.0, max(0.82, min(screenScale, menuBarScale)))
    }
}
