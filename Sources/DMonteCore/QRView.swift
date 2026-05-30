import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct QRWindowView: View {
    var onQuit: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case generate
        case scan

        var id: String { rawValue }

        var title: String {
            switch self {
            case .generate: "Generate"
            case .scan: "Scan"
            }
        }
    }

    @State private var mode: Mode = .generate

    // Generate state
    @State private var inputText = ""
    @State private var qrImage: NSImage?

    // Scan state
    @State private var isScanning = false
    @State private var scannedPayloads: [String] = []
    @State private var scanMessage = "Scan a QR code or barcode from anywhere on screen."

    private let layout = QRLayout.current

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: layout.contentSpacing) {
                modePicker

                switch mode {
                case .generate:
                    generateSection
                case .scan:
                    scanSection
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, layout.contentHorizontalPadding)
            .padding(.bottom, layout.contentBottomPadding)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: layout.closeIconSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Quit DMonte QR")

            Spacer()

            Text("DMonte QR")
                .font(.system(size: layout.titleFontSize, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.82))

            Spacer()

            // Invisible spacer matching the close button so the title stays centred.
            Color.clear
                .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.top, layout.headerTopPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.top, layout.pickerTopPadding)
    }

    // MARK: - Generate

    private var generateSection: some View {
        VStack(spacing: layout.contentSpacing) {
            qrPreview

            inputField

            HStack(spacing: layout.buttonRowSpacing) {
                actionButton(title: "Copy", systemImage: "doc.on.doc", isEnabled: qrImage != nil) {
                    copyGeneratedImage()
                }
                actionButton(title: "Save…", systemImage: "square.and.arrow.down", isEnabled: qrImage != nil) {
                    saveGeneratedImage()
                }
            }
        }
    }

    private var qrPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: layout.previewCornerRadius, style: .continuous)
                .fill(Color.white)
                .overlay {
                    RoundedRectangle(cornerRadius: layout.previewCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                }

            if let qrImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .padding(layout.previewInset)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: layout.placeholderIconSize, weight: .regular))
                        .foregroundStyle(.black.opacity(0.18))
                    Text("Enter text or a URL")
                        .font(.system(size: layout.placeholderFontSize, weight: .medium))
                        .foregroundStyle(.black.opacity(0.32))
                }
            }
        }
        .frame(width: layout.previewSize, height: layout.previewSize)
        .frame(maxWidth: .infinity)
        .padding(.top, layout.previewTopPadding)
    }

    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: layout.fieldCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: layout.fieldCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                }

            if inputText.isEmpty {
                Text("https://example.com")
                    .font(.system(size: layout.fieldFontSize, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .padding(.horizontal, layout.fieldHorizontalPadding + 4)
                    .padding(.vertical, layout.fieldVerticalPadding + 1)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $inputText)
                .font(.system(size: layout.fieldFontSize, weight: .regular))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, layout.fieldHorizontalPadding)
                .padding(.vertical, layout.fieldVerticalPadding)
                .onChange(of: inputText) { _, newValue in
                    regenerate(from: newValue)
                }
        }
        .frame(height: layout.fieldHeight)
    }

    // MARK: - Scan

    private var scanSection: some View {
        VStack(spacing: layout.contentSpacing) {
            Button {
                startScan()
            } label: {
                Label(isScanning ? "Selecting region…" : "Scan Region", systemImage: "viewfinder")
                    .font(.system(size: layout.primaryButtonFontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: layout.primaryButtonHeight)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isScanning)
            .opacity(isScanning ? 0.5 : 1)
            .padding(.top, layout.previewTopPadding)

            if scannedPayloads.isEmpty {
                Text(scanMessage)
                    .font(.system(size: layout.fieldFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, layout.contentSpacing)
            } else {
                ScrollView {
                    VStack(spacing: layout.contentSpacing) {
                        ForEach(Array(scannedPayloads.enumerated()), id: \.offset) { _, payload in
                            scanResultCard(payload)
                        }
                    }
                }
            }
        }
    }

    private func scanResultCard(_ payload: String) -> some View {
        VStack(alignment: .leading, spacing: layout.buttonRowSpacing) {
            Text(payload)
                .font(.system(size: layout.fieldFontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(5)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: layout.buttonRowSpacing) {
                actionButton(title: "Copy", systemImage: "doc.on.doc", isEnabled: true) {
                    copyToPasteboard(payload)
                }

                if let url = openableURL(from: payload) {
                    actionButton(title: "Open", systemImage: "arrow.up.right.square", isEnabled: true) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(layout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: layout.fieldCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        .overlay {
            RoundedRectangle(cornerRadius: layout.fieldCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        }
    }

    // MARK: - Shared button

    private func actionButton(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: layout.secondaryButtonFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: layout.secondaryButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    // MARK: - Actions

    private func regenerate(from text: String) {
        qrImage = QRKit.generate(text, scale: 12)
    }

    private func copyGeneratedImage() {
        guard let qrImage else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([qrImage])
    }

    private func saveGeneratedImage() {
        guard let qrImage else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "QRCode.png"
        panel.canCreateDirectories = true
        panel.title = "Save QR Code"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        if !QRKit.writePNG(qrImage, to: url) {
            presentError("Couldn't save", "The QR image could not be written to that location.")
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func openableURL(from payload: String) -> URL? {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme,
              !scheme.isEmpty,
              url.host != nil || scheme == "mailto" || scheme == "tel" else {
            return nil
        }
        return url
    }

    private func startScan() {
        guard !isScanning else {
            return
        }

        isScanning = true
        scannedPayloads = []
        scanMessage = "Drag to select the region containing the code…"

        Task {
            let result = await QRScanRunner.scanRegion()
            // Back on the main actor here — safe to touch @State.
            isScanning = false

            switch result {
            case .cancelled:
                scanMessage = "Scan cancelled. Drag to select a region to try again."
            case let .failure(reason):
                scanMessage = reason
            case let .success(payloads):
                if payloads.isEmpty {
                    scanMessage = "No QR code or barcode found in that region. Try again."
                } else {
                    scannedPayloads = payloads
                }
            }
        }
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Runs the interactive screen capture and Vision decode off the main actor. The heavy work
/// (spawning `screencapture` and running Vision) happens in a detached task; the result is
/// returned to the awaiting caller, which is back on its original actor.
private enum QRScanRunner {
    enum Outcome: Sendable {
        case success([String])
        case cancelled
        case failure(String)
    }

    static func scanRegion() async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("dmonte-qr-\(UUID().uuidString).png")

            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: interactive region selection, -x: silence the capture sound.
            process.arguments = ["-i", "-x", tempURL.path]

            do {
                try process.run()
            } catch {
                return .failure("Couldn't start screen capture: \(error.localizedDescription)")
            }

            process.waitUntilExit()

            // screencapture writes no file when the user presses Escape to cancel.
            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                return .cancelled
            }

            let payloads = QRKit.decode(imageAt: tempURL)
            return .success(payloads)
        }.value
    }
}

private struct QRLayout {
    let scale: CGFloat

    static var current: QRLayout {
        QRLayout(scale: QRSizing.currentScale)
    }

    var windowSize: NSSize { QRSizing.preferredSize() }

    var contentSpacing: CGFloat { 12 * scale }
    var contentHorizontalPadding: CGFloat { 24 * scale }
    var contentBottomPadding: CGFloat { 18 * scale }

    var headerButtonSize: CGFloat { 30 * scale }
    var closeIconSize: CGFloat { 16 * scale }
    var titleFontSize: CGFloat { 18 * scale }
    var headerHorizontalPadding: CGFloat { 18 * scale }
    var headerTopPadding: CGFloat { 14 * scale }
    var headerBottomPadding: CGFloat { 8 * scale }

    var pickerTopPadding: CGFloat { 2 * scale }

    var previewSize: CGFloat { 240 * scale }
    var previewCornerRadius: CGFloat { 12 * scale }
    var previewInset: CGFloat { 14 * scale }
    var previewTopPadding: CGFloat { 6 * scale }
    var placeholderIconSize: CGFloat { 56 * scale }
    var placeholderFontSize: CGFloat { 12 * scale }

    var fieldHeight: CGFloat { 64 * scale }
    var fieldCornerRadius: CGFloat { 8 * scale }
    var fieldHorizontalPadding: CGFloat { 10 * scale }
    var fieldVerticalPadding: CGFloat { 8 * scale }
    var fieldFontSize: CGFloat { 13 * scale }

    var buttonRowSpacing: CGFloat { 10 * scale }
    var buttonCornerRadius: CGFloat { 7 * scale }

    var primaryButtonHeight: CGFloat { 36 * scale }
    var primaryButtonFontSize: CGFloat { 14 * scale }

    var secondaryButtonHeight: CGFloat { 32 * scale }
    var secondaryButtonFontSize: CGFloat { 13 * scale }

    var cardPadding: CGFloat { 12 * scale }
}
