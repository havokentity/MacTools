import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

public extension DefaultsKey {
    /// Clip cap in seconds, one of ``VideoSplitterKit/clipLengthChoices``. The
    /// integrator registers a default of `60`.
    static let videoSplitterClipSeconds = "tool.videoSplitter.clipSeconds"

    /// Which encoder cuts the clips — a ``VideoSplitterKit/Encoder`` raw value. Defaults
    /// to the CPU: it is the faster of the two on a many-core Mac, and it is the only
    /// one guaranteed to exist.
    static let videoSplitterEncoder = "tool.videoSplitter.encoder"
}

// MARK: - Controller

/// Drives the split queue for ``VideoSplitterWindowView``.
///
/// The work is an ffmpeg re-encode per clip, so it runs in `Task.detached` against
/// ``VideoSplitterRunner``; only durations, counts and messages come back to the main
/// actor. Missing tools are surfaced up front rather than at the first failed split.
@MainActor
public final class VideoSplitterController: ObservableObject {
    /// A queued video and its live status.
    public struct SourceItem: Identifiable {
        public enum Status: Equatable {
            case ready
            case splitting
            case done(clipCount: Int, outputDirectory: URL)
            case failed(reason: String)
        }

        public let id = UUID()
        public var url: URL
        /// Seconds, or 0 while it is still being probed (or if ffprobe couldn't read it).
        public var duration: TimeInterval = 0
        public var status: Status = .ready

        public var name: String { url.lastPathComponent }
    }

    @Published public var items: [SourceItem] = []
    @Published public var clipSeconds: Int {
        didSet {
            guard clipSeconds != oldValue else {
                return
            }
            AppDefaults.shared.set(clipSeconds, forKey: DefaultsKey.videoSplitterClipSeconds)
        }
    }
    @Published public var encoder: VideoSplitterKit.Encoder {
        didSet {
            guard encoder != oldValue else {
                return
            }
            AppDefaults.shared.set(encoder.rawValue, forKey: DefaultsKey.videoSplitterEncoder)
        }
    }
    /// Whether this ffmpeg has the VideoToolbox encoder. Probed once, off-main, at
    /// launch; until it answers the GPU option stays disabled rather than offering a
    /// mode that might fail every clip.
    @Published public private(set) var isHardwareEncodingAvailable = false
    @Published public var destination: URL?
    @Published public private(set) var isSplitting = false
    @Published public private(set) var progressFraction: Double = 0
    @Published public private(set) var statusMessage: String
    @Published public private(set) var lastOutputDirectory: URL?

    /// Where ffmpeg/ffprobe were found, or nil — in which case the tool can only
    /// explain itself, and every control that would spawn ffmpeg stays disabled.
    public let tools: VideoSplitterTools?

    private let runner = VideoSplitterRunner()

    public init(tools: VideoSplitterTools? = VideoSplitterTools.locate()) {
        self.tools = tools
        let stored = AppDefaults.shared.integer(forKey: DefaultsKey.videoSplitterClipSeconds)
        clipSeconds = VideoSplitterKit.clipLengthChoices.contains(stored)
            ? stored
            : VideoSplitterKit.defaultClipLengthSeconds
        encoder = AppDefaults.shared.string(forKey: DefaultsKey.videoSplitterEncoder)
            .flatMap(VideoSplitterKit.Encoder.init(rawValue:)) ?? .cpu
        statusMessage = tools == nil
            ? "ffmpeg not found — install it with: brew install ffmpeg"
            : "Drop videos to begin"

        detectHardwareEncoding()
    }

    /// Asks ffmpeg once whether it can encode on the media engine. If a stored
    /// preference says GPU on a machine that no longer offers it, it falls back to the
    /// CPU rather than failing every clip.
    private func detectHardwareEncoding() {
        guard let tools else {
            return
        }

        Task {
            let runner = self.runner
            let available = await Task.detached(priority: .utility) {
                runner.supportsHardwareEncoding(tools: tools)
            }.value

            isHardwareEncodingAvailable = available
            if !available, encoder == .hardware {
                encoder = .cpu
            }
        }
    }

    public var hasItems: Bool { !items.isEmpty }

    public var canSplit: Bool { !items.isEmpty && !isSplitting && tools != nil }

    public var maxClipLength: TimeInterval { TimeInterval(clipSeconds) }

    // MARK: Queue management

    /// Adds videos to the queue, ignoring duplicates and unsupported containers, and
    /// probes each one's duration off-main so a long list stays responsive.
    public func addURLs(_ urls: [URL]) {
        let existing = Set(items.map(\.url.standardizedFileURL))
        let newURLs = urls
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0) }
            .filter(VideoSplitterKit.isSupportedVideo)

        guard !newURLs.isEmpty else {
            if !urls.isEmpty, !isSplitting {
                statusMessage = "Only MP4, M4V, MOV, and MKV can be split"
            }
            return
        }

        items += newURLs.map { SourceItem(url: $0) }
        updateIdleMessage()
        loadDurations(for: newURLs)
    }

    public func remove(_ item: SourceItem) {
        guard !isSplitting else {
            return
        }
        items.removeAll { $0.id == item.id }
        updateIdleMessage()
    }

    public func clear() {
        guard !isSplitting else {
            return
        }
        items.removeAll()
        progressFraction = 0
        lastOutputDirectory = nil
        updateIdleMessage()
    }

    /// The footnote under the controls: where clips land, and how many are cut at once
    /// with the current encoder and queue. Concrete rather than a boast — "4 at a time"
    /// is checkable; "parallel and fast" is not.
    public var throughputSummary: String {
        let clipCount = items.compactMap(plannedClipCount).reduce(0, +)
        let plan = VideoSplitterKit.encodePlan(clipCount: max(clipCount, 1), encoder: encoder)
        let workers = plan.workerCount == 1
            ? "one clip at a time"
            : "\(plan.workerCount) clips at a time"
        return "Own “…_\(clipSeconds)s_clips” folder per video · \(workers) on the \(encoder.displayName)"
    }

    /// The clips this video will produce at the current cap, or nil until its duration
    /// is known.
    public func plannedClipCount(for item: SourceItem) -> Int? {
        guard item.duration > 0 else {
            return nil
        }
        return VideoSplitterKit.plan(duration: item.duration, maxClipLength: maxClipLength).count
    }

    private func updateIdleMessage() {
        guard !isSplitting else {
            return
        }
        guard tools != nil else {
            statusMessage = "ffmpeg not found — install it with: brew install ffmpeg"
            return
        }
        statusMessage = items.isEmpty
            ? "Drop videos to begin"
            : "\(items.count) video\(items.count == 1 ? "" : "s") ready"
    }

    // MARK: Splitting

    /// Splits every queued video, one after another. Each is cut in its own detached
    /// task; per-item status and overall progress are published back on the main actor.
    public func splitAll() {
        guard canSplit, let tools else {
            return
        }

        isSplitting = true
        progressFraction = 0
        lastOutputDirectory = nil
        runner.reset()

        for index in items.indices {
            items[index].status = .ready
        }

        // Snapshot by id: the drop zone stays live while a run is going, so anything
        // added mid-run belongs to the next one and must not skew this run's progress.
        let batch = items.map(\.id)
        let clipLength = maxClipLength
        let chosenDestination = destination
        let chosenEncoder = encoder

        Task {
            var succeeded = 0
            var failed = 0
            var cancelled = false

            for (position, id) in batch.enumerated() {
                guard let index = items.firstIndex(where: { $0.id == id }) else {
                    continue
                }

                let source = items[index].url
                items[index].status = .splitting
                statusMessage = "Splitting \(items[index].name)…"

                let outputDirectory = VideoSplitterKit.outputDirectory(
                    for: source,
                    maxClipLength: clipLength,
                    destination: chosenDestination
                )

                let runner = self.runner
                let batchCount = batch.count
                // `self` is captured strongly: a `@MainActor` class is Sendable, so this is
                // the sanctioned way to hop back, and the task always completes — a weak
                // capture would only add an optional binding the detached closure can't hold.
                let result = await Task.detached(priority: .userInitiated) {
                    runner.split(
                        source: source,
                        maxClipLength: clipLength,
                        outputDirectory: outputDirectory,
                        encoder: chosenEncoder,
                        tools: tools
                    ) { fraction in
                        let overall = (Double(position) + fraction) / Double(batchCount)
                        Task { @MainActor in
                            self.progressFraction = overall
                        }
                    }
                }.value

                guard let resultIndex = items.firstIndex(where: { $0.id == id }) else {
                    continue
                }

                switch result {
                case let .success(summary):
                    succeeded += 1
                    lastOutputDirectory = summary.outputDirectory
                    items[resultIndex].status = .done(
                        clipCount: summary.clipCount,
                        outputDirectory: summary.outputDirectory
                    )
                case let .failure(failure):
                    items[resultIndex].status = .failed(reason: failure.message)
                    if failure == .cancelled {
                        cancelled = true
                    } else {
                        failed += 1
                    }
                }

                if cancelled {
                    break
                }
            }

            isSplitting = false
            progressFraction = cancelled ? 0 : 1
            statusMessage = summaryMessage(succeeded: succeeded, failed: failed, cancelled: cancelled)
        }
    }

    /// Stops the ffmpeg that is running now and abandons the rest of the queue. The
    /// clips of the interrupted video are removed, so no half-length clip is left
    /// looking like a finished one.
    public func cancel() {
        guard isSplitting else {
            return
        }
        statusMessage = "Cancelling…"
        runner.cancel()
    }

    public func revealClips() {
        guard let lastOutputDirectory else {
            return
        }
        NSWorkspace.shared.open(lastOutputDirectory)
    }

    private func summaryMessage(succeeded: Int, failed: Int, cancelled: Bool) -> String {
        var parts: [String] = []
        if succeeded > 0 {
            parts.append("\(succeeded) split")
        }
        if failed > 0 {
            parts.append("\(failed) failed")
        }
        if cancelled {
            parts.append("cancelled")
        }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: " · ")
    }

    // MARK: Helpers

    private func loadDurations(for urls: [URL]) {
        guard let tools else {
            return
        }

        for url in urls {
            Task {
                let runner = self.runner
                let seconds = await Task.detached(priority: .utility) {
                    runner.duration(of: url, tools: tools)
                }.value

                guard let index = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
                    return
                }
                items[index].duration = seconds
            }
        }
    }

    /// "1:04:09" / "3:21" — the timestamp shape a video length is read in.
    public static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else {
            return "—"
        }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

private final class URLDropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Window view

public struct VideoSplitterWindowView: View {
    var onQuit: () -> Void

    @StateObject private var controller = VideoSplitterController()
    @State private var isShowingSettings = false
    @State private var isDropTargeted = false
    private let layout = VideoSplitterLayout.current

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
                    actionButtons
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
                    VideoSplitterSettingsView(
                        hasTools: controller.tools != nil,
                        hasHardwareEncoding: controller.isHardwareEncodingAvailable,
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
            .help("Quit Video Splitter")

            Spacer()

            Text("Video Splitter")
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
                .fill(Color.pink.opacity(isDropTargeted ? 0.22 : 0.10))

            RoundedRectangle(cornerRadius: layout.dropCornerRadius, style: .continuous)
                .strokeBorder(
                    Color.pink.opacity(isDropTargeted ? 0.9 : 0.45),
                    style: StrokeStyle(lineWidth: 1.4, dash: [6, 4])
                )

            VStack(spacing: layout.dropSpacing) {
                Image(systemName: "scissors")
                    .font(.system(size: layout.dropIconSize, weight: .regular))
                    .foregroundStyle(Color.pink.opacity(0.9))

                Text("Drop videos here")
                    .font(.system(size: layout.dropTitleFontSize, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))

                Button(action: presentAddPanel) {
                    Text("Add…")
                        .font(.system(size: layout.dropButtonFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, layout.dropButtonHorizontalPadding)
                        .frame(height: layout.dropButtonHeight)
                        .background(Color.pink)
                        .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: layout.dropHeight)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
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
                Text("No videos yet")
                    .font(.system(size: layout.emptyFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: layout.listCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func sourceRow(_ item: VideoSplitterController.SourceItem) -> some View {
        HStack(spacing: layout.rowHorizontalSpacing) {
            Image(systemName: "film")
                .font(.system(size: layout.rowIconSize, weight: .regular))
                .foregroundStyle(Color.pink.opacity(0.85))
                .frame(width: layout.rowIconSize + 6)

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

            if !controller.isSplitting {
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

    @ViewBuilder
    private func statusBadge(for item: VideoSplitterController.SourceItem) -> some View {
        switch item.status {
        case .ready:
            EmptyView()
        case .splitting:
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

    private func rowDetail(for item: VideoSplitterController.SourceItem) -> String {
        switch item.status {
        case .ready, .splitting:
            let length = VideoSplitterController.durationText(item.duration)
            guard let clipCount = controller.plannedClipCount(for: item) else {
                return length
            }
            return "\(length) → \(clipCount) clip\(clipCount == 1 ? "" : "s")"
        case let .done(clipCount, outputDirectory):
            return "\(clipCount) clip\(clipCount == 1 ? "" : "s") in \(outputDirectory.lastPathComponent)"
        case let .failed(reason):
            return reason
        }
    }

    private func rowDetailColor(for item: VideoSplitterController.SourceItem) -> Color {
        switch item.status {
        case .failed: .orange
        default: .secondary
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: layout.controlRowSpacing) {
            HStack(spacing: layout.controlSpacing) {
                Text("Clip cap")
                    .font(.system(size: layout.controlLabelFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: layout.controlLabelWidth, alignment: .leading)

                Picker("", selection: $controller.clipSeconds) {
                    ForEach(VideoSplitterKit.clipLengthChoices, id: \.self) { seconds in
                        Text("\(seconds)s").tag(seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .disabled(controller.isSplitting)
            }

            HStack(spacing: layout.controlSpacing) {
                Text("Encoder")
                    .font(.system(size: layout.controlLabelFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: layout.controlLabelWidth, alignment: .leading)

                Picker("", selection: $controller.encoder) {
                    ForEach(VideoSplitterKit.Encoder.allCases) { encoder in
                        Text(encoder.displayName)
                            .tag(encoder)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .disabled(controller.isSplitting || !controller.isHardwareEncodingAvailable)
                .help(controller.isHardwareEncodingAvailable
                      ? controller.encoder.detail
                      : "This ffmpeg has no VideoToolbox encoder, so only the CPU is available.")
            }

            HStack(spacing: layout.controlSpacing) {
                Text("Output")
                    .font(.system(size: layout.controlLabelFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: layout.controlLabelWidth, alignment: .leading)

                Text(destinationLabel)
                    .font(.system(size: layout.controlValueFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: presentDestinationPanel) {
                    Text("Choose…")
                        .font(.system(size: layout.controlValueFontSize, weight: .semibold))
                        .foregroundStyle(Color.pink)
                }
                .buttonStyle(.plain)
                .disabled(controller.isSplitting)
            }

            Text(controller.throughputSummary)
                .font(.system(size: layout.footnoteFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var destinationLabel: String {
        guard let destination = controller.destination else {
            return "Beside each video"
        }
        return (destination.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Progress + actions

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: layout.progressCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.22))

                RoundedRectangle(cornerRadius: layout.progressCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.pink, .purple],
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
        .opacity(controller.isSplitting ? 1 : 0.35)
    }

    private var actionButtons: some View {
        HStack(spacing: layout.controlSpacing) {
            Button(action: secondaryAction) {
                Text(controller.isSplitting ? "Cancel" : "Clear")
                    .font(.system(size: layout.actionButtonFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, layout.actionButtonHorizontalPadding)
                    .frame(height: layout.actionButtonHeight)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!controller.isSplitting && !controller.hasItems)
            .opacity(!controller.isSplitting && !controller.hasItems ? 0.45 : 1)

            Button(action: { controller.revealClips() }) {
                Text("Reveal")
                    .font(.system(size: layout.actionButtonFontSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, layout.actionButtonHorizontalPadding)
                    .frame(height: layout.actionButtonHeight)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(controller.lastOutputDirectory == nil)
            .opacity(controller.lastOutputDirectory == nil ? 0.45 : 1)
            .help("Open the clips folder")

            Button(action: { controller.splitAll() }) {
                Text(controller.isSplitting ? "Splitting…" : "Split")
                    .font(.system(size: layout.actionButtonFontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: layout.actionButtonHeight)
                    .background(Color.pink)
                    .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!controller.canSplit)
            .opacity(controller.canSplit ? 1 : 0.45)
        }
    }

    // MARK: Actions

    private func secondaryAction() {
        if controller.isSplitting {
            controller.cancel()
        } else {
            controller.clear()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collected = URLDropCollector()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    collected.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            controller.addURLs(collected.urls)
        }
    }

    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = VideoSplitterKit.supportedExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        panel.message = "Choose videos to split"

        if panel.runModal() == .OK {
            controller.addURLs(panel.urls)
        }
    }

    private func presentDestinationPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where each video's clips folder is created"

        if panel.runModal() == .OK, let url = panel.url {
            controller.destination = url
        }
    }

    private func requestQuit() {
        guard !controller.isSplitting else {
            let alert = NSAlert()
            alert.messageText = "Video Splitter is still working"
            alert.informativeText = "Cancel the split, or wait for it to finish, so no clip is left half-written."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        onQuit()
    }
}

// MARK: - Layout

private struct VideoSplitterLayout {
    let scale: CGFloat

    static var current: VideoSplitterLayout {
        VideoSplitterLayout(scale: VideoSplitterSizing.currentScale)
    }

    var windowSize: NSSize { VideoSplitterSizing.preferredSize() }

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

    var listHeight: CGFloat { 176 * scale }
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
    var rowIconSize: CGFloat { 18 * scale }
    var badgeSize: CGFloat { 15 * scale }

    var controlsPadding: CGFloat { 12 * scale }
    var controlRowSpacing: CGFloat { 10 * scale }
    var controlSpacing: CGFloat { 10 * scale }
    var controlLabelFontSize: CGFloat { 12.5 * scale }
    var controlValueFontSize: CGFloat { 12 * scale }
    var controlLabelWidth: CGFloat { 58 * scale }
    var footnoteFontSize: CGFloat { 10.5 * scale }

    var progressHeight: CGFloat { 8 * scale }
    var progressCornerRadius: CGFloat { 3 * scale }

    var actionButtonFontSize: CGFloat { 14 * scale }
    var actionButtonHorizontalPadding: CGFloat { 14 * scale }
    var actionButtonHeight: CGFloat { 32 * scale }

    var buttonCornerRadius: CGFloat { 7 * scale }
    var statusFontSize: CGFloat { 12 * scale }
}

// MARK: - Settings overlay

private struct VideoSplitterSettingsView: View {
    var hasTools: Bool
    var hasHardwareEncoding: Bool
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Video Splitter Settings")
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

            if hasTools {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Clips are re-encoded with ffmpeg so each one lands just under the cap — a stream copy could only cut on keyframes, which overshoots.")

                    Text(hasHardwareEncoding
                         ? "CPU (x264) is usually the quicker of the two on a many-core Mac. GPU (VideoToolbox) encodes on the media engine instead, so the machine stays responsive and the battery lasts — and on a Mac with fewer performance cores it is also the faster one."
                         : "This ffmpeg has no VideoToolbox encoder, so clips are always cut on the CPU.")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("ffmpeg wasn't found. The Tool Box ships it with the Download Video tool; running this helper on its own needs a system install — brew install ffmpeg.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Video Splitter", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 340, height: 320)
    }
}
