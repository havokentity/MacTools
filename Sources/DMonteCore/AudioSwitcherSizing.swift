import CoreGraphics
import SwiftUI

/// Centralized sizing constants for the Audio Switcher popover so the layout
/// stays consistent and is easy to tweak in one place.
public enum AudioSwitcherSizing {
    // Base canvas
    public static let panelWidth: CGFloat = 340
    public static let panelHeight: CGFloat = 460

    // Spacing scale
    public static let outerPadding: CGFloat = 16
    public static let sectionSpacing: CGFloat = 12
    public static let rowSpacing: CGFloat = 6

    // Rows
    public static let rowVerticalPadding: CGFloat = 8
    public static let rowHorizontalPadding: CGFloat = 12
    public static let rowCornerRadius: CGFloat = 10
    public static let rowMinHeight: CGFloat = 40

    // Typography
    public static let titleSize: CGFloat = 15
    public static let sectionHeaderSize: CGFloat = 12
    public static let bodySize: CGFloat = 13
    public static let captionSize: CGFloat = 11

    // Controls
    public static let iconButtonSize: CGFloat = 28
    public static let checkmarkSize: CGFloat = 13
    public static let scrollMaxHeight: CGFloat = 240

    // Scale helper used by SwiftUI views (s(_:))
    public static func s(_ value: CGFloat) -> CGFloat {
        value
    }
}
