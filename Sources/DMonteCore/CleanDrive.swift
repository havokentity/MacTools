import AppKit
import SwiftUI

public enum CleanDriveCategoryID: String, CaseIterable, Identifiable, Sendable {
    case logs
    case caches
    case trash
    case browserData
    case mailCache
    case mobileApps
    case iTunesTemp
    case iOSBackups
    case oldUpdates

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .logs: "Log files"
        case .caches: "Cache files"
        case .trash: "Trash"
        case .browserData: "Browser data"
        case .mailCache: "Mail cache"
        case .mobileApps: "Mobile apps"
        case .iTunesTemp: "iTunes temp files"
        case .iOSBackups: "iOS device backups"
        case .oldUpdates: "Old updates"
        }
    }

    var defaultSelected: Bool {
        self == .logs || self == .caches
    }

    var tint: Color {
        switch self {
        case .logs: .red
        case .caches: .yellow
        default: .secondary
        }
    }

    var targets: [CleanDriveTarget] {
        switch self {
        case .logs:
            [
                CleanDriveTarget("~/Library/Logs", mode: .contents)
            ]
        case .caches:
            [
                CleanDriveTarget("~/Library/Caches", mode: .contents)
            ]
        case .trash:
            [
                CleanDriveTarget("~/.Trash", mode: .contents)
            ]
        case .browserData:
            [
                CleanDriveTarget("~/Library/Caches/Google/Chrome", mode: .item),
                CleanDriveTarget("~/Library/Caches/com.google.Chrome", mode: .item),
                CleanDriveTarget("~/Library/Application Support/Google/Chrome/*/Cache", mode: .item),
                CleanDriveTarget("~/Library/Application Support/Google/Chrome/*/Code Cache", mode: .item),
                CleanDriveTarget("~/Library/Caches/Firefox", mode: .item),
                CleanDriveTarget("~/Library/Application Support/Firefox/Profiles/*/cache2", mode: .item),
                CleanDriveTarget("~/Library/Containers/com.apple.Safari/Data/Library/Caches", mode: .contents)
            ]
        case .mailCache:
            [
                CleanDriveTarget("~/Library/Containers/com.apple.mail/Data/Library/Caches", mode: .contents),
                CleanDriveTarget("~/Library/Containers/com.apple.MailCacheDelete", mode: .contents)
            ]
        case .mobileApps:
            [
                CleanDriveTarget("~/Music/iTunes/iTunes Media/Mobile Applications", mode: .contents)
            ]
        case .iTunesTemp:
            [
                CleanDriveTarget("~/Music/iTunes/iTunes Media/Downloads", mode: .contents),
                CleanDriveTarget("~/Music/Music/Media.localized/Downloads", mode: .contents),
                CleanDriveTarget("~/Library/Caches/com.apple.iTunes", mode: .contents)
            ]
        case .iOSBackups:
            [
                CleanDriveTarget("~/Library/Application Support/MobileSync/Backup", mode: .contents)
            ]
        case .oldUpdates:
            [
                CleanDriveTarget("~/Library/Caches/com.apple.SoftwareUpdate", mode: .contents)
            ]
        }
    }
}

public struct CleanDriveItem: Identifiable, Equatable, Sendable {
    public var id: CleanDriveCategoryID
    public var size: UInt64
    public var targetCount: Int

    public var title: String {
        id.title
    }

    public var defaultSelected: Bool {
        id.defaultSelected
    }
}

struct CleanDriveTarget: Sendable {
    enum Mode: Sendable {
        case item
        case contents
    }

    var path: String
    var mode: Mode

    init(_ path: String, mode: Mode) {
        self.path = path
        self.mode = mode
    }
}

public enum CleanDriveScanner {
    public static func scan() -> [CleanDriveItem] {
        CleanDriveCategoryID.allCases.map { category in
            let expandedTargets = category.targets.flatMap { target in
                resolvedURLs(for: target).map { (url: $0, mode: target.mode) }
            }
            let categorySize = expandedTargets.reduce(UInt64(0)) { total, target in
                total + size(of: target.url, mode: target.mode)
            }

            return CleanDriveItem(id: category, size: categorySize, targetCount: expandedTargets.count)
        }
    }

    /// Streams cleanup progress as each item is removed so the UI can stay responsive and
    /// drain its progress bar live. Emits `.progress` events while deleting and a final
    /// `.finished` event carrying the byte total and the reason each item was skipped.
    public static func cleanStream(categories: Set<CleanDriveCategoryID>) -> AsyncStream<CleanDriveEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let work = workItems(for: categories)
                let totalBytes = work.reduce(UInt64(0)) { $0 + $1.bytes }
                let reportStep = max(totalBytes / 200, 1)

                var cleanedBytes: UInt64 = 0
                var skipped: [CleanDriveSkip] = []
                var lastReportedBytes: UInt64 = 0
                var lastCategory = ""

                for item in work {
                    if Task.isCancelled {
                        break
                    }

                    let itemSkips = bestEffortRemove(at: item.url)
                    // Count what actually left disk: full size on success, or the freed
                    // portion if a recurse left some stubborn files behind.
                    let remaining = directorySize(at: item.url)
                    cleanedBytes += item.bytes > remaining ? item.bytes - remaining : 0
                    skipped.append(contentsOf: itemSkips)

                    // Throttle UI updates: report on every category change, or once the
                    // cleaned total advances by a visible step, so large caches don't flood
                    // the main actor with thousands of tiny updates.
                    if item.categoryTitle != lastCategory || cleanedBytes - lastReportedBytes >= reportStep {
                        lastCategory = item.categoryTitle
                        lastReportedBytes = cleanedBytes
                        continuation.yield(.progress(cleanedBytes: cleanedBytes, currentItem: item.categoryTitle))
                    }
                }

                continuation.yield(.finished(CleanDriveResult(cleanedBytes: cleanedBytes, skipped: skipped)))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Flattens the selected categories into the individual filesystem items to remove,
    /// each tagged with its size up front so progress can be reported as work proceeds.
    /// Categories are visited in a stable order so progress reads predictably.
    private static func workItems(for categories: Set<CleanDriveCategoryID>) -> [CleanDriveWorkItem] {
        var items: [CleanDriveWorkItem] = []

        for category in CleanDriveCategoryID.allCases where categories.contains(category) {
            for target in category.targets {
                for url in resolvedURLs(for: target) {
                    let leaves: [URL] = switch target.mode {
                    case .item:
                        [url]
                    case .contents:
                        directoryContents(at: url)
                    }

                    for leaf in leaves where FileManager.default.fileExists(atPath: leaf.path) {
                        items.append(
                            CleanDriveWorkItem(
                                url: leaf,
                                bytes: directorySize(at: leaf),
                                categoryTitle: category.title
                            )
                        )
                    }
                }
            }
        }

        return items
    }

    /// Permanently removes an item so its space is actually freed. (Moving to Trash just
    /// relocates the data and frees nothing until the Trash is emptied, and running apps
    /// regenerate caches immediately — which is why a trash-based clean looks like it did
    /// nothing.) If a directory can't be removed wholesale because one file inside is locked
    /// or root-owned, it recurses and deletes everything it can, returning a skip entry only
    /// for each leaf that genuinely resisted.
    private static func bestEffortRemove(at url: URL) -> [CleanDriveSkip] {
        do {
            try FileManager.default.removeItem(at: url)
            return []
        } catch {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let children = exists && isDirectory.boolValue ? directoryContents(at: url) : []

            guard !children.isEmpty else {
                return [CleanDriveSkip(path: url.path, reason: skipReason(for: error))]
            }

            var skips: [CleanDriveSkip] = []
            for child in children {
                skips.append(contentsOf: bestEffortRemove(at: child))
            }

            // Drop the now-empty directory shell once its deletable contents are gone.
            try? FileManager.default.removeItem(at: url)
            return skips
        }
    }

    private static func skipReason(for error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.localizedDescription
        }
        return nsError.localizedDescription
    }

    private static func resolvedURLs(for target: CleanDriveTarget) -> [URL] {
        let expandedPath = NSString(string: target.path).expandingTildeInPath
        let components = expandedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        var urls = [URL(fileURLWithPath: "/")]
        for component in components where !component.isEmpty {
            if component == "*" {
                urls = urls.flatMap { directoryContents(at: $0) }
            } else {
                urls = urls.map { $0.appendingPathComponent(component) }
            }
        }

        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func size(of url: URL, mode: CleanDriveTarget.Mode) -> UInt64 {
        switch mode {
        case .item:
            directorySize(at: url)
        case .contents:
            directoryContents(at: url).reduce(UInt64(0)) { $0 + directorySize(at: $1) }
        }
    }

    private static func directoryContents(at url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: []
        )) ?? []
    }

    private static func directorySize(at url: URL) -> UInt64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return 0
        }

        return enumerator.reduce(UInt64(0)) { partialResult, entry in
            guard let fileURL = entry as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
                return partialResult
            }

            return partialResult + UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
    }
}

public struct CleanDriveSkip: Sendable, Equatable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct CleanDriveResult: Sendable {
    public var cleanedBytes: UInt64
    public var skipped: [CleanDriveSkip]

    public init(cleanedBytes: UInt64, skipped: [CleanDriveSkip]) {
        self.cleanedBytes = cleanedBytes
        self.skipped = skipped
    }
}

public enum CleanDriveEvent: Sendable {
    case progress(cleanedBytes: UInt64, currentItem: String)
    case finished(CleanDriveResult)
}

private struct CleanDriveWorkItem: Sendable {
    var url: URL
    var bytes: UInt64
    var categoryTitle: String
}

public struct CleanDriveWindowView: View {
    var onQuit: () -> Void

    @State private var items: [CleanDriveItem] = []
    @State private var selectedCategories = Set(CleanDriveCategoryID.allCases.filter(\.defaultSelected))
    @State private var isScanning = true
    @State private var isCleaning = false
    @State private var cleaningTotalBytes: UInt64 = 0
    @State private var cleanedBytes: UInt64 = 0
    @State private var message = "Scanning..."
    @State private var isShowingSettings = false
    private let layout = CleanDriveLayout.current

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                VStack(spacing: layout.contentSpacing) {
                    summary
                    progressBar
                    categoryList
                    cleanButton
                    storageButton
                }
                .padding(.horizontal, layout.contentHorizontalPadding)
                .padding(.bottom, layout.contentBottomPadding)
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    CleanDriveSettingsView(
                        onQuit: requestQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
        .frostedPanel(cornerRadius: 18)
        .task {
            await reload()
        }
    }

    private var header: some View {
        HStack {
            Button(action: requestQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: layout.closeIconSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Quit Clean Drive")

            Spacer()

            Text("Clean Drive")
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

    private var summary: some View {
        VStack(spacing: layout.summarySpacing) {
            Text(displaySize.diskBytesString)
                .font(.system(size: layout.summaryValueFontSize, weight: .light, design: .rounded))
                .foregroundStyle(.primary.opacity(0.84))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(message)
                .font(.system(size: layout.summaryLabelFontSize, weight: .bold))
                .foregroundStyle(.primary.opacity(0.82))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, layout.summaryTopPadding)
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: layout.progressCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.22))

                RoundedRectangle(cornerRadius: layout.progressCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.orange, .yellow],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * progressFraction)
                    .animation(.easeOut(duration: 0.3), value: progressFraction)
            }
        }
        .frame(height: layout.progressHeight)
        .overlay {
            RoundedRectangle(cornerRadius: layout.progressCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var categoryList: some View {
        VStack(spacing: layout.rowSpacing) {
            ForEach(items) { item in
                Button {
                    toggle(item.id)
                } label: {
                    HStack(spacing: layout.rowHorizontalSpacing) {
                        CleanDriveCheckbox(
                            isSelected: selectedCategories.contains(item.id),
                            tint: item.id.tint,
                            size: layout.checkboxSize,
                            checkmarkFontSize: layout.checkmarkFontSize
                        )

                        Text(item.title)
                            .font(.system(size: layout.rowTitleFontSize, weight: .bold))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text(item.size.diskBytesString)
                            .font(.system(size: layout.rowValueFontSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(isScanning ? 0.6 : 1)
    }

    private var cleanButton: some View {
        Button {
            startCleaning()
        } label: {
            Text(isCleaning ? "Cleaning..." : "Clean Up")
                .font(.system(size: layout.cleanButtonFontSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, layout.cleanButtonHorizontalPadding)
                .frame(height: layout.cleanButtonHeight)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(selectedSize == 0 || isScanning || isCleaning)
        .opacity(selectedSize == 0 || isScanning || isCleaning ? 0.45 : 1)
        .padding(.top, layout.cleanButtonTopPadding)
    }

    private var storageButton: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
        } label: {
            Text("Manage Storage...")
                .font(.system(size: layout.storageFontSize, weight: .medium))
                .underline()
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private var selectedSize: UInt64 {
        items
            .filter { selectedCategories.contains($0.id) }
            .reduce(UInt64(0)) { $0 + $1.size }
    }

    private var totalSize: UInt64 {
        max(items.reduce(UInt64(0)) { $0 + $1.size }, 1)
    }

    /// Bytes still pending: the big counter and the bar both drain toward zero while cleaning.
    private var remainingBytes: UInt64 {
        cleaningTotalBytes > cleanedBytes ? cleaningTotalBytes - cleanedBytes : 0
    }

    private var displaySize: UInt64 {
        isCleaning ? remainingBytes : selectedSize
    }

    private var progressFraction: Double {
        guard !items.isEmpty else {
            return 0
        }

        // While cleaning, the orange fill represents what is left to remove and unfills as
        // data is deleted; otherwise it reflects how much of the drive's junk is selected.
        if isCleaning {
            return min(1, Double(remainingBytes) / Double(totalSize))
        }

        return max(0.04, min(Double(selectedSize) / Double(totalSize), 1))
    }

    private func toggle(_ id: CleanDriveCategoryID) {
        if selectedCategories.contains(id) {
            selectedCategories.remove(id)
        } else {
            selectedCategories.insert(id)
        }

        updateMessage()
    }

    private func updateMessage() {
        message = selectedSize > 0 ? "Ready for Cleanup" : "Nothing Selected"
    }

    private func reload() async {
        isScanning = true
        message = "Scanning..."
        let scannedItems = await Task.detached(priority: .userInitiated) {
            CleanDriveScanner.scan()
        }.value
        items = scannedItems
        isScanning = false
        updateMessage()
    }

    private func startCleaning() {
        isCleaning = true
        cleaningTotalBytes = selectedSize
        cleanedBytes = 0
        message = "Cleaning..."
        let selected = selectedCategories

        Task {
            var result = CleanDriveResult(cleanedBytes: 0, skipped: [])

            for await event in CleanDriveScanner.cleanStream(categories: selected) {
                switch event {
                case let .progress(bytes, currentItem):
                    cleanedBytes = bytes
                    if !currentItem.isEmpty {
                        message = "Cleaning \(currentItem)..."
                    }
                case let .finished(finished):
                    result = finished
                    // Snap the bar fully empty even if measured bytes drift from the scan.
                    cleanedBytes = cleaningTotalBytes
                }
            }

            // Rescan while still in the cleaning state so the drained bar stays empty
            // instead of flashing back to the pre-clean fill during the rescan.
            await reload()
            isCleaning = false
            message = summaryMessage(for: result)

            if !result.skipped.isEmpty {
                presentSkipReport(result.skipped)
            }
        }
    }

    private func summaryMessage(for result: CleanDriveResult) -> String {
        guard !result.skipped.isEmpty else {
            return "Cleaned \(result.cleanedBytes.diskBytesString)"
        }

        return "Cleaned \(result.cleanedBytes.diskBytesString) · \(result.skipped.count) skipped"
    }

    private func presentSkipReport(_ skipped: [CleanDriveSkip]) {
        let grouped = Dictionary(grouping: skipped, by: \.reason)
            .sorted { $0.value.count > $1.value.count }

        let details = grouped.map { reason, skips -> String in
            let examples = skips.prefix(3).map { ($0.path as NSString).abbreviatingWithTildeInPath }
            var line = "• \(reason) — \(skips.count) item\(skips.count == 1 ? "" : "s")"
            if !examples.isEmpty {
                line += "\n    " + examples.joined(separator: "\n    ")
            }
            if skips.count > examples.count {
                line += "\n    …and \(skips.count - examples.count) more"
            }
            return line
        }.joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "\(skipped.count) item\(skipped.count == 1 ? "" : "s") skipped"
        alert.informativeText = "These items couldn't be removed and were left in place:\n\n\(details)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func requestQuit() {
        guard !isCleaning else {
            let alert = NSAlert()
            alert.messageText = "Clean Drive is still cleaning"
            alert.informativeText = "Wait for cleanup to finish before quitting so file operations are not interrupted."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        onQuit()
    }
}

private struct CleanDriveCheckbox: View {
    var isSelected: Bool
    var tint: Color
    var size: CGFloat
    var checkmarkFontSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? tint : Color.secondary.opacity(0.28))
            .frame(width: size, height: size)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: checkmarkFontSize, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
            }
    }
}

private struct CleanDriveLayout {
    let scale: CGFloat

    static var current: CleanDriveLayout {
        CleanDriveLayout(scale: CleanDriveSizing.currentScale)
    }

    var windowSize: NSSize { CleanDriveSizing.preferredSize() }
    var contentSpacing: CGFloat { 12 * scale }
    var contentHorizontalPadding: CGFloat { 24 * scale }
    var contentBottomPadding: CGFloat { 18 * scale }
    var headerButtonSize: CGFloat { 30 * scale }
    var closeIconSize: CGFloat { 16 * scale }
    var settingsIconSize: CGFloat { 17 * scale }
    var titleFontSize: CGFloat { 18 * scale }
    var headerHorizontalPadding: CGFloat { 18 * scale }
    var headerTopPadding: CGFloat { 14 * scale }
    var headerBottomPadding: CGFloat { 8 * scale }
    var summarySpacing: CGFloat { 6 * scale }
    var summaryValueFontSize: CGFloat { 34 * scale }
    var summaryLabelFontSize: CGFloat { 13 * scale }
    var summaryTopPadding: CGFloat { 6 * scale }
    var progressHeight: CGFloat { 12 * scale }
    var progressCornerRadius: CGFloat { 3 * scale }
    var rowSpacing: CGFloat { 10 * scale }
    var rowHorizontalSpacing: CGFloat { 11 * scale }
    var checkboxSize: CGFloat { 18 * scale }
    var checkmarkFontSize: CGFloat { 11 * scale }
    var rowTitleFontSize: CGFloat { 14 * scale }
    var rowValueFontSize: CGFloat { 13 * scale }
    var cleanButtonFontSize: CGFloat { 14 * scale }
    var cleanButtonHorizontalPadding: CGFloat { 18 * scale }
    var cleanButtonHeight: CGFloat { 30 * scale }
    var cleanButtonTopPadding: CGFloat { 4 * scale }
    var buttonCornerRadius: CGFloat { 7 * scale }
    var storageFontSize: CGFloat { 12 * scale }
}

private struct CleanDriveSettingsView: View {
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Clean Drive Settings")
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

            Text("Quit closes Clean Drive. You can launch it again from D'Monte's Toolbox.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Clean Drive", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 330, height: 190)
    }
}

private struct SettingsToggleRow: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Spacer()

            GreenSwitch(isOn: $isOn)
        }
    }
}
