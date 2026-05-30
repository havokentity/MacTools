import AppKit

public enum KeepAwakeSizing {
    public static func preferredSize() -> NSSize {
        let scale = currentScale
        return NSSize(width: (320 * scale).rounded(), height: (430 * scale).rounded())
    }

    static var currentScale: CGFloat {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenScale = visibleFrame.height / 950
        let menuBarScale = NSStatusBar.system.thickness / 26
        return min(1.0, max(0.82, min(screenScale, menuBarScale)))
    }
}
