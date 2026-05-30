import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Controller

/// Drives the conversion queue and progress for ``ImageConverterWindowView``.
/// Heavy decode/encode work runs in `Task.detached` against the `nonisolated`
/// ``ImageConverterKit`` core; results are published back on the main actor.
@MainActor
public final class ImageConverterController: ObservableObject {
    /// A single source image queued for conversion, plus its live status.
    public struct SourceItem: Identifiable {
        public enum Status: Equatable {
            case ready
            case converting
            case done(savedBytes: Int64, outputName: String, finalBytes: UInt64)
            case failed(reason: String)
        }

        public let id = UUID()
        public var url: URL
        public var originalBytes: UInt64
        public var thumbnail: NSImage?
        public var status: Status = .ready

        public var name: String { url.lastPathComponent }
    }

    @Published public var items: [SourceItem] = []
    @Published public var format: ImageConverterKit.ImageFormat = .jpeg
    @Published public var quality: Double = 0.8
    @Published public var resizeEnabled = false
    @Published public var maxDimension: Double = 2_000
    @Published public var outputDirectory: URL?
    @Published public private(set) var isConverting = false
    @Published public private(set) var completedCount = 0
    @Published public private(set) var totalSavedBytes: Int64 = 0
    @Published public private(set) var statusMessage = "Drop images to begin"

    public init() {}

    public var hasItems: Bool { !items.isEmpty }

    public var canConvert: Bool { !items.isEmpty && !isConverting }

    /// Fraction complete for the progress bar (0...1).
    public var progressFraction: Double {
        guard isConverting, !items.isEmpty else {
            return 0
        }
        return min(1, Double(completedCount) / Double(items.count))
    }

    // MARK: Queue management

    /// Adds image URLs to the queue, ignoring duplicates and non-images. Thumbnails
    /// and sizes are loaded lazily off-main so adding a big batch stays responsive.
    public func addURLs(_ urls: [URL]) {
        let existing = Set(items.map(\.url.standardizedFileURL))
        let newURLs = urls
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0) }
            .filter { Self.isImageURL($0) }

        guard !newURLs.isEmpty else {
            return
        }

        for url in newURLs {
            let size = ImageConverterKit.fileSize(at: url)
            items.append(SourceItem(url: url, originalBytes: size))
        }

        updateIdleMessage()
        loadThumbnails(for: newURLs)
    }

    public func remove(_ item: SourceItem) {
        items.removeAll { $0.id == item.id }
        updateIdleMessage()
    }

    public func clear() {
        guard !isConverting else {
            return
        }
        items.removeAll()
        completedCount = 0
        totalSavedBytes = 0
        updateIdleMessage()
    }

    private func updateIdleMessage() {
        guard !isConverting else {
            return
        }
        if items.isEmpty {
            statusMessage = "Drop images to begin"
        } else {
            statusMessage = "\(items.count) image\(items.count == 1 ? "" : "s") ready"
        }
    }

    // MARK: Conversion

    /// Converts every queued item. Each image is processed in its own detached task
    /// (pure values only cross the boundary), and per-item status, the running saved
    /// total, and the final summary are published back on the main actor.
    public func convertAll() {
        guard canConvert else {
            return
        }

        isConverting = true
        completedCount = 0
        totalSavedBytes = 0

        let chosenFormat = format
        let chosenQuality = quality
        let maxDim = resizeEnabled ? Int(maxDimension.rounded()) : nil

        // Reset statuses up front.
        for index in items.indices {
            items[index].status = .ready
        }

        Task {
            for index in items.indices {
                let item = items[index]
                items[index].status = .converting
                statusMessage = "Converting \(item.name)…"

                let source = item.url
                let originalBytes = item.originalBytes
                let outputDir = outputDirectory ?? Self.defaultOutputDirectory(for: source)

                let result = await Task.detached(priority: .userInitiated) { () -> Result<ImageConverterKit.ConvertedImage, ImageConverterKit.ConvertError> in
                    ImageConverterKit.convert(
                        source: source,
                        to: chosenFormat,
                        quality: chosenQuality,
                        maxDimension: maxDim,
                        outputDirectory: outputDir
                    )
                }.value

                switch result {
                case let .success(converted):
                    let saved = Int64(originalBytes) - Int64(converted.byteCount)
                    totalSavedBytes += saved
                    items[index].status = .done(
                        savedBytes: saved,
                        outputName: converted.outputURL.lastPathComponent,
                        finalBytes: converted.byteCount
                    )
                case let .failure(error):
                    items[index].status = .failed(reason: error.message)
                }

                completedCount += 1
            }

            isConverting = false
            statusMessage = summaryMessage()
        }
    }

    private func summaryMessage() -> String {
        let failures = items.filter { item in
            if case .failed = item.status { return true }
            return false
        }.count
        let succeeded = items.count - failures

        var parts: [String] = []
        if succeeded > 0 {
            parts.append("\(succeeded) converted")
        }
        if failures > 0 {
            parts.append("\(failures) failed")
        }

        let savedText: String
        if totalSavedBytes > 0 {
            savedText = " · saved \(UInt64(totalSavedBytes).diskBytesString)"
        } else if totalSavedBytes < 0 {
            savedText = " · grew \(UInt64(-totalSavedBytes).diskBytesString)"
        } else {
            savedText = ""
        }

        let head = parts.isEmpty ? "Done" : parts.joined(separator: " · ")
        return head + savedText
    }

    // MARK: Helpers

    private func loadThumbnails(for urls: [URL]) {
        for url in urls {
            Task {
                // Decode + re-encode the thumbnail to PNG `Data` off-main. `Data` is
                // Sendable, so it crosses back to the main actor cleanly — unlike
                // NSImage/CGImage, which would trip Swift 6 strict concurrency.
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    Self.makeThumbnailData(for: url, maxPixel: 96)
                }.value

                guard let data,
                      let image = NSImage(data: data),
                      let index = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
                    return
                }
                items[index].thumbnail = image
            }
        }
    }

    /// Builds a downsampled thumbnail and returns it as PNG `Data` so it is safe to
    /// hand back across the actor boundary.
    nonisolated static func makeThumbnailData(for url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    nonisolated static func isImageURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }

    nonisolated static func defaultOutputDirectory(for source: URL) -> URL {
        let parent = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) {
            return parent
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}

// MARK: - Window view

public struct ImageConverterWindowView: View {
    var onQuit: () -> Void

    @StateObject private var controller = ImageConverterController()
    @State private var isShowingSettings = false
    @State private var isDropTargeted = false
    private let layout = ImageConverterLayout.current

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                VStack(spacing: layout.contentSpacing) {
                    dropZone
                    sourceList
                    controls
                    progressBar
                    convertButton
                    Text(controller.statusMessage)
                        .font(.system(size: layout.statusFontSize, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, layout.contentHorizontalPadding)
                .padding(.bottom, layout.contentBottomPadding)
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    ImageConverterSettingsView(
                        onQuit: requestQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: requestQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: layout.closeIconSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Quit Image Converter")

            Spacer()

            Text("Image Converter")
                .font(.system(size: layout.titleFontSize, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.82))

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: layout.settingsIconSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.top, layout.headerTopPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    // MARK: Drop zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: layout.dropCornerRadius, style: .continuous)
                .fill(Color.teal.opacity(isDropTargeted ? 0.22 : 0.10))

            RoundedRectangle(cornerRadius: layout.dropCornerRadius, style: .continuous)
                .strokeBorder(
                    Color.teal.opacity(isDropTargeted ? 0.9 : 0.45),
                    style: StrokeStyle(lineWidth: 1.4, dash: [6, 4])
                )

            VStack(spacing: layout.dropSpacing) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: layout.dropIconSize, weight: .regular))
                    .foregroundStyle(Color.teal.opacity(0.9))

                Text("Drop images here")
                    .font(.system(size: layout.dropTitleFontSize, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))

                Button(action: presentAddPanel) {
                    Text("Add…")
                        .font(.system(size: layout.dropButtonFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, layout.dropButtonHorizontalPadding)
                        .frame(height: layout.dropButtonHeight)
                        .background(Color.teal)
                        .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: layout.dropHeight)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: Source list

    private var sourceList: some View {
        ScrollView {
            VStack(spacing: layout.rowSpacing) {
                ForEach(controller.items) { item in
                    sourceRow(item)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: layout.listHeight)
        .background(
            RoundedRectangle(cornerRadius: layout.listCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.14))
        )
        .overlay {
            if !controller.hasItems {
                Text("No images yet")
                    .font(.system(size: layout.emptyFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: layout.listCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func sourceRow(_ item: ImageConverterController.SourceItem) -> some View {
        HStack(spacing: layout.rowHorizontalSpacing) {
            thumbnail(for: item)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: layout.rowTitleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(rowDetail(for: item))
                    .font(.system(size: layout.rowDetailFontSize, weight: .medium))
                    .foregroundStyle(rowDetailColor(for: item))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            statusBadge(for: item)

            if !controller.isConverting {
                Button {
                    controller.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: layout.rowRemoveSize, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, layout.rowPadding)
        .padding(.vertical, layout.rowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: layout.rowCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func thumbnail(for item: ImageConverterController.SourceItem) -> some View {
        RoundedRectangle(cornerRadius: layout.thumbCornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.25))
            .frame(width: layout.thumbSize, height: layout.thumbSize)
            .overlay {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: layout.thumbSize, height: layout.thumbSize)
                        .clipShape(RoundedRectangle(cornerRadius: layout.thumbCornerRadius, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: layout.thumbSize * 0.42, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
    }

    @ViewBuilder
    private func statusBadge(for item: ImageConverterController.SourceItem) -> some View {
        switch item.status {
        case .ready:
            EmptyView()
        case .converting:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: layout.badgeSize, weight: .bold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: layout.badgeSize, weight: .bold))
                .foregroundStyle(.orange)
        }
    }

    private func rowDetail(for item: ImageConverterController.SourceItem) -> String {
        switch item.status {
        case .ready, .converting:
            return item.originalBytes.diskBytesString
        case let .done(savedBytes, outputName, finalBytes):
            let savedText: String
            if savedBytes > 0 {
                savedText = "−\(UInt64(savedBytes).diskBytesString)"
            } else if savedBytes < 0 {
                savedText = "+\(UInt64(-savedBytes).diskBytesString)"
            } else {
                savedText = "no change"
            }
            return "\(item.originalBytes.diskBytesString) → \(finalBytes.diskBytesString)  (\(savedText)) · \(outputName)"
        case let .failed(reason):
            return reason
        }
    }

    private func rowDetailColor(for item: ImageConverterController.SourceItem) -> Color {
        switch item.status {
        case .failed: .orange
        case .done: .secondary
        default: .secondary
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: layout.controlRowSpacing) {
            HStack(spacing: layout.controlSpacing) {
                Text("Format")
                    .font(.system(size: layout.controlLabelFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: layout.controlLabelWidth, alignment: .leading)

                Picker("", selection: $controller.format) {
                    ForEach(ImageConverterKit.ImageFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }

            HStack(spacing: layout.controlSpacing) {
                Text("Quality")
                    .font(.system(size: layout.controlLabelFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(controller.format.isLossy ? 0.85 : 0.4))
                    .frame(width: layout.controlLabelWidth, alignment: .leading)

                Slider(value: $controller.quality, in: 0...1)
                    .controlSize(.small)
                    .tint(.teal)
                    .disabled(!controller.format.isLossy)

                Text("\(Int((controller.quality * 100).rounded()))%")
                    .font(.system(size: layout.controlValueFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: layout.controlValueWidth, alignment: .trailing)
            }
            .opacity(controller.format.isLossy ? 1 : 0.5)

            HStack(spacing: layout.controlSpacing) {
                Toggle(isOn: $controller.resizeEnabled) {
                    Text("Resize")
                        .font(.system(size: layout.controlLabelFontSize, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.teal)
                .frame(width: layout.controlLabelWidth + 24, alignment: .leading)

                Slider(value: $controller.maxDimension, in: 64...8_000, step: 1)
                    .controlSize(.small)
                    .tint(.teal)
                    .disabled(!controller.resizeEnabled)

                Text(controller.resizeEnabled ? "\(Int(controller.maxDimension.rounded()))px" : "none")
                    .font(.system(size: layout.controlValueFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: layout.controlValueWidth + 14, alignment: .trailing)
            }

            HStack(spacing: layout.controlSpacing) {
                Text("Output")
                    .font(.system(size: layout.controlLabelFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: layout.controlLabelWidth, alignment: .leading)

                Text(outputDirectoryLabel)
                    .font(.system(size: layout.controlValueFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: presentOutputPanel) {
                    Text("Choose…")
                        .font(.system(size: layout.controlValueFontSize, weight: .semibold))
                        .foregroundStyle(Color.teal)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(layout.controlsPadding)
        .background(
            RoundedRectangle(cornerRadius: layout.listCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: layout.listCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private var outputDirectoryLabel: String {
        guard let directory = controller.outputDirectory else {
            return "Same folder as each image"
        }
        return (directory.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Progress + convert

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: layout.progressCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.22))

                RoundedRectangle(cornerRadius: layout.progressCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.teal, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * controller.progressFraction)
                    .animation(.easeOut(duration: 0.25), value: controller.progressFraction)
            }
        }
        .frame(height: layout.progressHeight)
        .overlay {
            RoundedRectangle(cornerRadius: layout.progressCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        }
        .opacity(controller.isConverting ? 1 : 0.35)
    }

    private var convertButton: some View {
        HStack(spacing: layout.controlSpacing) {
            Button(action: { controller.clear() }) {
                Text("Clear")
                    .font(.system(size: layout.convertButtonFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, layout.convertButtonHorizontalPadding)
                    .frame(height: layout.convertButtonHeight)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!controller.hasItems || controller.isConverting)
            .opacity(!controller.hasItems || controller.isConverting ? 0.45 : 1)

            Button(action: { controller.convertAll() }) {
                Text(controller.isConverting ? "Converting…" : "Convert")
                    .font(.system(size: layout.convertButtonFontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: layout.convertButtonHeight)
                    .background(Color.teal)
                    .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!controller.canConvert)
            .opacity(controller.canConvert ? 1 : 0.45)
        }
    }

    // MARK: Actions

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            controller.addURLs(collected)
        }
    }

    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        panel.message = "Choose images to convert"

        if panel.runModal() == .OK {
            controller.addURLs(panel.urls)
        }
    }

    private func presentOutputPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where converted images are saved"

        if panel.runModal() == .OK, let url = panel.url {
            controller.outputDirectory = url
        }
    }

    private func requestQuit() {
        guard !controller.isConverting else {
            let alert = NSAlert()
            alert.messageText = "Image Converter is still working"
            alert.informativeText = "Wait for the current batch to finish before quitting so no file is left half-written."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        onQuit()
    }
}

// MARK: - Layout

private struct ImageConverterLayout {
    let scale: CGFloat

    static var current: ImageConverterLayout {
        ImageConverterLayout(scale: ImageConverterSizing.currentScale)
    }

    var windowSize: NSSize { ImageConverterSizing.preferredSize() }

    var contentSpacing: CGFloat { 12 * scale }
    var contentHorizontalPadding: CGFloat { 22 * scale }
    var contentBottomPadding: CGFloat { 18 * scale }

    var headerButtonSize: CGFloat { 30 * scale }
    var closeIconSize: CGFloat { 16 * scale }
    var settingsIconSize: CGFloat { 17 * scale }
    var titleFontSize: CGFloat { 18 * scale }
    var headerHorizontalPadding: CGFloat { 18 * scale }
    var headerTopPadding: CGFloat { 14 * scale }
    var headerBottomPadding: CGFloat { 8 * scale }

    var dropHeight: CGFloat { 110 * scale }
    var dropCornerRadius: CGFloat { 12 * scale }
    var dropSpacing: CGFloat { 6 * scale }
    var dropIconSize: CGFloat { 26 * scale }
    var dropTitleFontSize: CGFloat { 14 * scale }
    var dropButtonFontSize: CGFloat { 12 * scale }
    var dropButtonHorizontalPadding: CGFloat { 16 * scale }
    var dropButtonHeight: CGFloat { 26 * scale }

    var listHeight: CGFloat { 168 * scale }
    var listCornerRadius: CGFloat { 10 * scale }
    var emptyFontSize: CGFloat { 12 * scale }
    var rowSpacing: CGFloat { 6 * scale }
    var rowHorizontalSpacing: CGFloat { 10 * scale }
    var rowPadding: CGFloat { 8 * scale }
    var rowVerticalPadding: CGFloat { 6 * scale }
    var rowCornerRadius: CGFloat { 8 * scale }
    var rowTitleFontSize: CGFloat { 12.5 * scale }
    var rowDetailFontSize: CGFloat { 10.5 * scale }
    var rowRemoveSize: CGFloat { 14 * scale }
    var badgeSize: CGFloat { 15 * scale }
    var thumbSize: CGFloat { 38 * scale }
    var thumbCornerRadius: CGFloat { 6 * scale }

    var controlsPadding: CGFloat { 12 * scale }
    var controlRowSpacing: CGFloat { 10 * scale }
    var controlSpacing: CGFloat { 10 * scale }
    var controlLabelFontSize: CGFloat { 12.5 * scale }
    var controlValueFontSize: CGFloat { 12 * scale }
    var controlLabelWidth: CGFloat { 58 * scale }
    var controlValueWidth: CGFloat { 42 * scale }

    var progressHeight: CGFloat { 8 * scale }
    var progressCornerRadius: CGFloat { 3 * scale }

    var convertButtonFontSize: CGFloat { 14 * scale }
    var convertButtonHorizontalPadding: CGFloat { 18 * scale }
    var convertButtonHeight: CGFloat { 32 * scale }

    var buttonCornerRadius: CGFloat { 7 * scale }
    var statusFontSize: CGFloat { 12 * scale }
}

// MARK: - Settings overlay

private struct ImageConverterSettingsView: View {
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Image Converter Settings")
                    .font(.system(size: 18, weight: .bold))

                Spacer()

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }

            Text("Quit closes Image Converter. You can launch it again from D'Monte's Toolbox.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Image Converter", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 340, height: 190)
    }
}
