import Foundation
import CoreGraphics

/// Sizing constants for the Maintenance popover, scaled by a single factor so
/// the whole UI can grow/shrink consistently. Mirrors `ClipboardSizing`.
public enum MaintenanceSizing {

    /// Global scale multiplier for the Maintenance UI.
    public static let currentScale: CGFloat = 1.0

    /// Convenience: scale a base point value by `currentScale`.
    public static func s(_ value: CGFloat) -> CGFloat {
        value * currentScale
    }

    // Base (unscaled) metrics.
    public static let basePopoverWidth: CGFloat = 360
    public static let baseHorizontalPadding: CGFloat = 16
    public static let baseVerticalPadding: CGFloat = 14
    public static let baseSectionSpacing: CGFloat = 18
    public static let baseRowSpacing: CGFloat = 10
    public static let baseCornerRadius: CGFloat = 12

    // Scaled accessors.
    public static var popoverWidth: CGFloat { s(basePopoverWidth) }
    public static var horizontalPadding: CGFloat { s(baseHorizontalPadding) }
    public static var verticalPadding: CGFloat { s(baseVerticalPadding) }
    public static var sectionSpacing: CGFloat { s(baseSectionSpacing) }
    public static var rowSpacing: CGFloat { s(baseRowSpacing) }
    public static var cornerRadius: CGFloat { s(baseCornerRadius) }
}
