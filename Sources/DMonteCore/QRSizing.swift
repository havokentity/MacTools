import AppKit

public enum QRSizing {
    public static func preferredSize() -> NSSize {
        let scale = currentScale
        // 640 rather than the original 560: the Generate tab now stacks a template picker,
        // the preview and a multi-row form, and clipping the Copy/Save row would strand the
        // only way to get the code out of the app.
        return NSSize(width: (420 * scale).rounded(), height: (640 * scale).rounded())
    }

    static var currentScale: CGFloat {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenScale = visibleFrame.height / 950
        let menuBarScale = NSStatusBar.system.thickness / 26
        return min(1.0, max(0.82, min(screenScale, menuBarScale)))
    }
}
