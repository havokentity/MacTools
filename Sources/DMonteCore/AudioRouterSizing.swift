import AppKit
import CoreGraphics

/// Centralized sizing for the Audio Router popover. Every metric is scaled by
/// `currentScale` so the panel shrinks on small displays / thin menu bars, the
/// same formula the other audio tools use.
public enum AudioRouterSizing {
    /// Display/menu-bar-aware scale multiplier, clamped to 0.82…1.0.
    public static var currentScale: CGFloat {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenScale = visibleFrame.height / 950
        let menuBarScale = NSStatusBar.system.thickness / 26
        return min(1.0, max(0.82, min(screenScale, menuBarScale)))
    }

    /// Scale a base point value by `currentScale`.
    public static func s(_ value: CGFloat) -> CGFloat {
        value * currentScale
    }

    /// The fully-scaled panel size, for the hosting panel's content rect.
    public static func preferredSize() -> NSSize {
        NSSize(width: panelWidth.rounded(), height: panelHeight.rounded())
    }

    // Base canvas — a touch wider/taller than the switcher to fit the builder.
    public static var panelWidth: CGFloat { s(360) }
    public static var panelHeight: CGFloat { s(520) }

    // Spacing scale
    public static var outerPadding: CGFloat { s(16) }
    public static var sectionSpacing: CGFloat { s(12) }
    public static var rowSpacing: CGFloat { s(6) }

    // Rows
    public static var rowVerticalPadding: CGFloat { s(8) }
    public static var rowHorizontalPadding: CGFloat { s(12) }
    public static var rowCornerRadius: CGFloat { s(10) }
    public static var rowMinHeight: CGFloat { s(38) }

    // Typography
    public static var titleSize: CGFloat { s(15) }
    public static var sectionHeaderSize: CGFloat { s(12) }
    public static var bodySize: CGFloat { s(13) }
    public static var captionSize: CGFloat { s(11) }

    // Controls
    public static var iconButtonSize: CGFloat { s(28) }
    public static var checkmarkSize: CGFloat { s(13) }
    public static var scrollMaxHeight: CGFloat { s(300) }
}
