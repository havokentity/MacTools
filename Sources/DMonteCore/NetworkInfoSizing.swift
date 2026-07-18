import AppKit

public enum NetworkInfoSizing {
    public static func preferredSize() -> NSSize {
        let scale = currentScale
        // Wider than the 320-point tools because a full IPv6 literal is 39 characters and
        // truncating the address the user came here to copy would defeat the tool.
        return NSSize(width: (368 * scale).rounded(), height: (520 * scale).rounded())
    }

    static var currentScale: CGFloat {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenScale = visibleFrame.height / 950
        let menuBarScale = NSStatusBar.system.thickness / 26
        return min(1.0, max(0.82, min(screenScale, menuBarScale)))
    }
}
