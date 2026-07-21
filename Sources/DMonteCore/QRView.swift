import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct QRWindowView: View {
    var onQuit: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case generate
        case scan
        case file

        var id: String { rawValue }

        var title: String {
            switch self {
            case .generate: "Generate"
            case .scan: "Scan"
            case .file: "File"
            }
        }
    }

    @State private var mode: Mode = .generate

    // Generate state
    @AppStorage(DefaultsKey.qrTemplate, store: AppDefaults.shared) private var template: QRTemplate = .text
    @State private var draft = QRTemplateDraft()
    @State private var qrImage: NSImage?

    // Scan state
    @State private var isScanning = false
    @State private var scannedPayloads: [String] = []
    @State private var scanMessage = "Scan a QR code or barcode from anywhere on screen."

    // Decode-from-file state
    @State private var isDecodingFile = false
    @State private var isDropTargeted = false
    @State private var decodedPayloads: [String] = []
    @State private var fileMessage = "Open or drop an image to read the codes inside it."

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
                case .file:
                    fileSection
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
            templatePicker

            qrPreview

            templateFields

            HStack(spacing: layout.buttonRowSpacing) {
                actionButton(title: "Copy", systemImage: "doc.on.doc", isEnabled: qrImage != nil) {
                    copyGeneratedImage()
                }
                actionButton(title: "Save…", systemImage: "square.and.arrow.down", isEnabled: qrImage != nil) {
                    saveGeneratedImage()
                }
            }
        }
        // The template choice is persisted, so a restored non-text template needs its preview
        // rebuilt from the (empty) draft rather than showing the previous session's code.
        .onAppear { regenerate() }
        .onChange(of: draft) { _, _ in regenerate() }
        .onChange(of: template) { _, _ in regenerate() }
    }

    private var templatePicker: some View {
        Picker("", selection: $template) {
            ForEach(QRTemplate.allCases) { template in
                Label(template.title, systemImage: template.iconName).tag(template)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    @ViewBuilder
    private var templateFields: some View {
        switch template {
        case .text:
            inputField
        case .url:
            formRows {
                labelledField("URL", placeholder: "example.com", text: $draft.url)
            }
        case .wifi:
            formRows {
                labelledField("Network", placeholder: "SSID", text: $draft.wifiSSID)
                // Shown in the clear on purpose: the password is about to be encoded into a
                // code anyone can scan, so masking it would hide typos and protect nothing.
                labelledField("Password", placeholder: "Password", text: $draft.wifiPassword)
                    .disabled(draft.wifiSecurity == .none)
                    .opacity(draft.wifiSecurity == .none ? 0.45 : 1)
                labelledControl("Security") {
                    Picker("", selection: $draft.wifiSecurity) {
                        ForEach(QRWiFiSecurity.allCases) { security in
                            Text(security.title).tag(security)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                labelledControl("Hidden") {
                    Toggle("", isOn: $draft.wifiIsHidden)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .email:
            formRows {
                labelledField("To", placeholder: "name@example.com", text: $draft.emailAddress)
                labelledField("Subject", placeholder: "Optional", text: $draft.emailSubject)
                labelledField("Body", placeholder: "Optional", text: $draft.emailBody)
            }
        case .sms:
            formRows {
                labelledField("Number", placeholder: "+1 555 0100", text: $draft.smsNumber)
                labelledField("Message", placeholder: "Optional", text: $draft.smsMessage)
            }
        case .phone:
            formRows {
                labelledField("Number", placeholder: "+1 555 0100", text: $draft.phoneNumber)
            }
        case .contact:
            formRows {
                labelledField("First", placeholder: "Given name", text: $draft.contact.firstName)
                labelledField("Last", placeholder: "Family name", text: $draft.contact.lastName)
                labelledField("Company", placeholder: "Optional", text: $draft.contact.organization)
                labelledField("Title", placeholder: "Optional", text: $draft.contact.jobTitle)
                labelledField("Phone", placeholder: "Optional", text: $draft.contact.phone)
                labelledField("Email", placeholder: "Optional", text: $draft.contact.email)
                labelledField("Website", placeholder: "Optional", text: $draft.contact.url)
                labelledField("Note", placeholder: "Optional", text: $draft.contact.note)
            }
        }
    }

    /// Templates have between one and eight fields, so the form scrolls inside a fixed frame
    /// rather than resizing the window every time the template changes.
    private func formRows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: layout.formRowSpacing) {
                content()
            }
            .padding(.vertical, 2)
        }
        .frame(height: layout.fieldHeight)
    }

    private func labelledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        labelledControl(title) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: layout.fieldFontSize, weight: .regular))
                .foregroundStyle(.primary)
                .padding(.horizontal, layout.fieldHorizontalPadding)
                .frame(height: layout.formRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: layout.fieldCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: layout.fieldCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                }
        }
    }

    private func labelledControl<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: layout.buttonRowSpacing) {
            Text(title)
                .font(.system(size: layout.formLabelFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: layout.formLabelWidth, alignment: .leading)

            content()
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
                    Text(previewPlaceholder)
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

            if draft.text.isEmpty {
                Text("https://example.com")
                    .font(.system(size: layout.fieldFontSize, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .padding(.horizontal, layout.fieldHorizontalPadding + 4)
                    .padding(.vertical, layout.fieldVerticalPadding + 1)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $draft.text)
                .font(.system(size: layout.fieldFontSize, weight: .regular))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, layout.fieldHorizontalPadding)
                .padding(.vertical, layout.fieldVerticalPadding)
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
                            payloadCard(payload)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Decode from file

    private var fileSection: some View {
        VStack(spacing: layout.contentSpacing) {
            dropTarget

            if decodedPayloads.isEmpty {
                Text(fileMessage)
                    .font(.system(size: layout.fieldFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, layout.contentSpacing)
            } else {
                // A photo of a page can hold several codes; every one of them is shown.
                ScrollView {
                    VStack(spacing: layout.contentSpacing) {
                        ForEach(Array(decodedPayloads.enumerated()), id: \.offset) { _, payload in
                            payloadCard(payload)
                        }
                    }
                }
            }
        }
    }

    private var dropTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: layout.previewCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(isDropTargeted ? 0.22 : 0.10))

            RoundedRectangle(cornerRadius: layout.previewCornerRadius, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(isDropTargeted ? 0.9 : 0.45),
                    style: StrokeStyle(lineWidth: 1.4, dash: [6, 4])
                )

            VStack(spacing: layout.buttonRowSpacing) {
                Image(systemName: isDecodingFile ? "hourglass" : "photo.on.rectangle.angled")
                    .font(.system(size: layout.dropIconSize, weight: .regular))
                    .foregroundStyle(Color.accentColor.opacity(0.9))

                Text(isDecodingFile ? "Decoding…" : "Drop an image here")
                    .font(.system(size: layout.primaryButtonFontSize, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))

                Button(action: presentOpenPanel) {
                    Text("Open…")
                        .font(.system(size: layout.secondaryButtonFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, layout.dropButtonHorizontalPadding)
                        .frame(height: layout.secondaryButtonHeight)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isDecodingFile)
                .opacity(isDecodingFile ? 0.5 : 1)
            }
        }
        .frame(height: layout.dropHeight)
        .padding(.top, layout.previewTopPadding)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func payloadCard(_ payload: String) -> some View {
        VStack(alignment: .leading, spacing: layout.buttonRowSpacing) {
            // A WIFI:/vCard payload is unreadable as raw text, so name what it is above it.
            if let summary = QRKit.payloadSummary(payload) {
                Text(summary)
                    .font(.system(size: layout.formLabelFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

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

                if let url = QRKit.openableURL(from: payload) {
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

    private var previewPlaceholder: String {
        switch template {
        case .text: "Enter text or a URL"
        case .url: "Enter a URL"
        case .wifi: "Enter the network name"
        case .email: "Enter an email address"
        case .sms: "Enter a phone number"
        case .phone: "Enter a phone number"
        case .contact: "Enter contact details"
        }
    }

    private func regenerate() {
        qrImage = QRKit.generate(QRKit.payload(for: template, draft: draft), scale: 12)
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

    /// Returns whether the drop was taken, so a drag carrying no file lands with the standard
    /// rejection animation instead of being swallowed with no result and no explanation.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isDecodingFile else {
            return false
        }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            decodedPayloads = []
            fileMessage = "That isn't a file. Drop an image, or use Open… to pick one."
            return false
        }

        // Only the first file is decoded: the result list already shows every code found in
        // one image, and a queue of files would need a picker this panel has no room for.
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                guard let url else {
                    decodedPayloads = []
                    fileMessage = "Couldn't read the dropped item."
                    return
                }
                decodeFile(at: url)
            }
        }
        return true
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Decode"
        panel.message = "Choose an image containing a QR code or barcode"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        decodeFile(at: url)
    }

    private func decodeFile(at url: URL) {
        guard !isDecodingFile else {
            return
        }

        isDecodingFile = true
        decodedPayloads = []
        fileMessage = "Reading \(url.lastPathComponent)…"

        Task {
            // A full-resolution photo can keep Vision busy for seconds; detaching keeps the
            // window responsive instead of freezing mid-drop.
            let outcome = await Task.detached(priority: .userInitiated) {
                QRKit.decodeResult(imageAt: url)
            }.value

            // Back on the main actor here — safe to touch @State.
            isDecodingFile = false

            switch outcome {
            case .unreadable:
                fileMessage = "Couldn't read “\(url.lastPathComponent)”. It may have moved or be unreadable."
            case .notAnImage:
                fileMessage = "“\(url.lastPathComponent)” isn't an image file."
            case let .payloads(payloads):
                if payloads.isEmpty {
                    fileMessage = "No QR code or barcode found in “\(url.lastPathComponent)”."
                } else {
                    decodedPayloads = payloads
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

    // Smaller than the old 240 so the template form fits below it without a taller window.
    var previewSize: CGFloat { 208 * scale }
    var previewCornerRadius: CGFloat { 12 * scale }
    var previewInset: CGFloat { 14 * scale }
    var previewTopPadding: CGFloat { 6 * scale }
    var placeholderIconSize: CGFloat { 56 * scale }
    var placeholderFontSize: CGFloat { 12 * scale }

    // Tall enough for four rows; the contact template scrolls the rest.
    var fieldHeight: CGFloat { 132 * scale }
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

    var formRowSpacing: CGFloat { 6 * scale }
    var formRowHeight: CGFloat { 26 * scale }
    var formLabelWidth: CGFloat { 68 * scale }
    var formLabelFontSize: CGFloat { 11 * scale }

    var dropHeight: CGFloat { 150 * scale }
    var dropIconSize: CGFloat { 34 * scale }
    var dropButtonHorizontalPadding: CGFloat { 18 * scale }
}
