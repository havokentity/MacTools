import AppKit

public final class SystemMonitorStatusView: NSControl {
    public static let iconWidth: CGFloat = 25
    public static let statusWidth: CGFloat = 165
    public static let statusWidthWithoutIcon: CGFloat = statusWidth - iconWidth
    private static let highlightRightInset: CGFloat = 0
    private static let contrastGreen = NSColor(srgbRed: 0.00, green: 0.58, blue: 0.24, alpha: 1)

    public var onClick: (() -> Void)?
    public var showsIcon = true {
        didSet {
            updateIconVisibility()
        }
    }

    private let highlightLayer = CALayer()
    private let iconView = NSImageView()
    private let downLabel = NSTextField(labelWithString: "--")
    private let upLabel = NSTextField(labelWithString: "--")
    private let cpuValueLabel = NSTextField(labelWithString: "--")
    private let ramValueLabel = NSTextField(labelWithString: "--")
    private let ssdValueLabel = NSTextField(labelWithString: "--")
    private var trackingArea: NSTrackingArea?
    private var widthConstraint: NSLayoutConstraint?
    private var iconWidthConstraint: NSLayoutConstraint?

    public static func statusWidth(showsIcon: Bool) -> CGFloat {
        showsIcon ? statusWidth : statusWidthWithoutIcon
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    public func update(snapshot: MetricSnapshot) {
        downLabel.stringValue = "↓ \(snapshot.networkDownRate.statusRateString)"
        upLabel.stringValue = "↑ \(snapshot.networkUpRate.statusRateString)"
        cpuValueLabel.stringValue = snapshot.cpuUsage.percentString
        ramValueLabel.stringValue = snapshot.memoryUsage.percentString
        ssdValueLabel.stringValue = snapshot.diskAvailable.diskStatusBytesString
    }

    public override func mouseDown(with event: NSEvent) {
        // Cmd-drag reorders or removes the status item, a gesture implemented by the hosting
        // NSStatusBarButton's own tracking loop. This view covers the button, so hand the event
        // over untouched instead of treating it as a click on the strip.
        if event.modifierFlags.contains(.command) {
            enclosingStatusBarButton()?.mouseDown(with: event)
            return
        }

        isHighlighted = true
        // The view is hosted as a subview of the status item's NSStatusBarButton. Forward the
        // click to that button's target/action (set by the app delegate) so the popover toggles,
        // while preserving the legacy `onClick` closure if a caller still wires one up.
        onClick?()
        forwardClickToStatusBarButton()
    }

    public override func rightMouseDown(with event: NSEvent) {
        forwardClickToStatusBarButton()
    }

    private func forwardClickToStatusBarButton() {
        if let button = enclosingStatusBarButton(), let action = button.action {
            NSApp.sendAction(action, to: button.target, from: button)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        isHighlighted = false
    }

    private func enclosingStatusBarButton() -> NSStatusBarButton? {
        var view: NSView? = superview
        while let current = view {
            if let button = current as? NSStatusBarButton {
                return button
            }
            view = current.superview
        }
        return nil
    }

    public override func layout() {
        super.layout()
        let highlightWidth = max(0, bounds.width - Self.highlightRightInset)
        highlightLayer.frame = NSRect(x: 0, y: 0, width: highlightWidth, height: bounds.height)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        highlightLayer.isHidden = false
    }

    public override func mouseExited(with event: NSEvent) {
        highlightLayer.isHidden = true
    }

    private func setup() {
        wantsLayer = true
        highlightLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        highlightLayer.cornerRadius = 8
        highlightLayer.masksToBounds = true
        highlightLayer.isHidden = true
        layer?.insertSublayer(highlightLayer, at: 0)
        frame = NSRect(x: 0, y: 0, width: Self.statusWidth(showsIcon: showsIcon), height: NSStatusBar.system.thickness)
        toolTip = "System Monitor"

        iconView.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "System Monitor")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        iconView.contentTintColor = Self.contrastGreen
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let networkStack = NSStackView(views: [downLabel, upLabel])
        networkStack.orientation = .vertical
        networkStack.alignment = .leading
        networkStack.spacing = -2
        networkStack.translatesAutoresizingMaskIntoConstraints = false

        let metricsStack = NSStackView(views: [
            metricStack(title: "CPU", valueLabel: cpuValueLabel),
            metricStack(title: "RAM", valueLabel: ramValueLabel),
            metricStack(title: "SSD", valueLabel: ssdValueLabel)
        ])
        metricsStack.orientation = .horizontal
        metricsStack.alignment = .centerY
        metricsStack.spacing = -1
        metricsStack.translatesAutoresizingMaskIntoConstraints = false

        let networkMetricsSpacer = NSView()
        networkMetricsSpacer.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView(views: [iconView, networkStack, networkMetricsSpacer, metricsStack])
        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = -1
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rootStack)

        [downLabel, upLabel, cpuValueLabel, ramValueLabel, ssdValueLabel].forEach(configureValueLabel)

        let widthConstraint = widthAnchor.constraint(equalToConstant: Self.statusWidth(showsIcon: showsIcon))
        let iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: Self.iconWidth)
        self.widthConstraint = widthConstraint
        self.iconWidthConstraint = iconWidthConstraint

        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            rootStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            networkStack.widthAnchor.constraint(equalToConstant: 46),
            networkMetricsSpacer.widthAnchor.constraint(equalToConstant: 10),
            iconWidthConstraint,
            iconView.heightAnchor.constraint(equalToConstant: 40)
        ])
        updateIconVisibility()
    }

    public func applyShowsIcon(_ showsIcon: Bool) {
        self.showsIcon = showsIcon
    }

    private func updateIconVisibility() {
        iconView.isHidden = !showsIcon
        iconWidthConstraint?.constant = showsIcon ? Self.iconWidth : 0
        widthConstraint?.constant = Self.statusWidth(showsIcon: showsIcon)
        frame.size.width = Self.statusWidth(showsIcon: showsIcon)
        needsLayout = true
    }

    private func metricStack(title: String, valueLabel: NSTextField) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        configureTitleLabel(titleLabel)

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = -2
        stack.widthAnchor.constraint(equalToConstant: title == "SSD" ? 38 : 28).isActive = true
        return stack
    }

    private func configureTitleLabel(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byClipping
        label.allowsDefaultTighteningForTruncation = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureValueLabel(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byClipping
        label.allowsDefaultTighteningForTruncation = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
}
