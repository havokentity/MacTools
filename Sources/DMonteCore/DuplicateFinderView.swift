import AppKit
import SwiftUI

// MARK: - Duplicate Finder window

public struct DuplicateFinderWindowView: View {
    @StateObject private var controller = DuplicateFinderController()
    private let onQuit: () -> Void
    private let layout = DuplicateFinderLayout.current

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: layout.contentSpacing) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, layout.contentHorizontalPadding)
            .padding(.bottom, layout.contentBottomPadding)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button(action: onQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: layout.closeIconSize, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Quit Duplicate Finder")
            .keyboardShortcut("w", modifiers: .command)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: layout.titleIconSize, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Duplicate Finder")
                    .font(.system(size: layout.titleFontSize, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }

            Spacer()

            // Balances the close button so the title stays centred.
            Color.clear.frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.top, layout.headerTopPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            idleView
        case .scanning:
            scanningView
        case .results:
            resultsView
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a folder to scan recursively for files with identical content. Extra copies can be moved to the Trash, where they remain recoverable.")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FilledButton(title: "Choose Folder…", systemImage: "folder", layout: layout) {
                controller.chooseFolder()
            }

            Spacer(minLength: 0)
        }
        .padding(.top, layout.contentSpacing)
    }

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(controller.progressText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, layout.contentSpacing)
    }

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            resultsHeader

            if controller.groups.isEmpty {
                emptyResults
            } else {
                resultsList
                Divider().overlay(Color.white.opacity(0.10))
                footer
            }
        }
    }

    private var resultsHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.scannedPathName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(controller.summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }

            Spacer()

            OutlineButton(title: "Choose Another", layout: layout) {
                controller.chooseFolder()
            }
        }
    }

    private var emptyResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No duplicate files were found.")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary)
            if let skips = controller.skipNotice {
                Text(skips)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: layout.groupSpacing) {
                ForEach(controller.groups) { group in
                    DuplicateGroupView(
                        group: group,
                        isSelected: { controller.isSelected($0) },
                        onToggle: { controller.toggle($0) }
                    )
                }

                if let skips = controller.skipNotice {
                    Text(skips)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(controller.selectionText)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)

            Spacer()

            FilledButton(
                title: "Delete Selected",
                systemImage: "trash",
                layout: layout,
                isEnabled: !controller.selectedURLs.isEmpty
            ) {
                controller.deleteSelected()
            }
        }
    }
}

// MARK: - Group view

private struct DuplicateGroupView: View {
    let group: DuplicateFinderGroup
    let isSelected: (URL) -> Bool
    let onToggle: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.files.count) identical files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
                Text(group.size.diskBytesString + " each")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }

            ForEach(group.files) { file in
                DuplicateFileRow(
                    file: file,
                    isSelected: isSelected(file.url),
                    onToggle: { onToggle(file.url) }
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}

// MARK: - File row

private struct DuplicateFileRow: View {
    let file: DuplicateFinderFile
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.parentPath)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if file.isOriginal {
                    Text("keep")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.green)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Buttons

private struct FilledButton: View {
    let title: String
    var systemImage: String?
    let layout: DuplicateFinderLayout
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: layout.buttonFontSize, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, layout.buttonHorizontalPadding)
            .frame(height: layout.buttonHeight)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct OutlineButton: View {
    let title: String
    let layout: DuplicateFinderLayout
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: layout.buttonFontSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, layout.buttonHorizontalPadding)
                .frame(height: layout.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Layout

private struct DuplicateFinderLayout {
    let scale: CGFloat

    static var current: DuplicateFinderLayout {
        DuplicateFinderLayout(scale: DuplicateFinderSizing.currentScale)
    }

    var windowSize: NSSize { DuplicateFinderSizing.preferredSize() }
    var contentSpacing: CGFloat { 12 * scale }
    var contentHorizontalPadding: CGFloat { 24 * scale }
    var contentBottomPadding: CGFloat { 20 * scale }
    var groupSpacing: CGFloat { 14 * scale }
    var headerButtonSize: CGFloat { 30 * scale }
    var closeIconSize: CGFloat { 16 * scale }
    var titleIconSize: CGFloat { 16 * scale }
    var titleFontSize: CGFloat { 18 * scale }
    var headerHorizontalPadding: CGFloat { 18 * scale }
    var headerTopPadding: CGFloat { 14 * scale }
    var headerBottomPadding: CGFloat { 10 * scale }
    var buttonFontSize: CGFloat { 13 * scale }
    var buttonHorizontalPadding: CGFloat { 16 * scale }
    var buttonHeight: CGFloat { 30 * scale }
    var buttonCornerRadius: CGFloat { 7 * scale }
}

// MARK: - Controller

@MainActor
final class DuplicateFinderController: ObservableObject {
    @Published var phase: DuplicateFinderPhase = .idle
    @Published var groups: [DuplicateFinderGroup] = []
    @Published var selectedURLs: Set<URL> = []
    @Published var progressText: String = ""
    @Published var scannedPathName: String = ""
    @Published var skipNotice: String?

    private var wastedBytes: UInt64 = 0

    var summaryText: String {
        guard !groups.isEmpty else { return "No duplicates found" }
        let copies = groups.reduce(0) { $0 + ($1.files.count - 1) }
        let groupWord = groups.count == 1 ? "group" : "groups"
        let copyWord = copies == 1 ? "copy" : "copies"
        return "\(groups.count) \(groupWord) · \(copies) extra \(copyWord) · \(wastedBytes.diskBytesString) reclaimable"
    }

    var selectionText: String {
        let count = selectedURLs.count
        guard count > 0 else { return "Select files to delete" }
        let fileWord = count == 1 ? "file" : "files"
        return "\(count) \(fileWord) selected · \(reclaimableForSelection().diskBytesString)"
    }

    func isSelected(_ url: URL) -> Bool {
        selectedURLs.contains(url)
    }

    func toggle(_ url: URL) {
        if selectedURLs.contains(url) {
            selectedURLs.remove(url)
        } else {
            selectedURLs.insert(url)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(url: url)
    }

    func startScan(url: URL) {
        phase = .scanning
        scannedPathName = url.path
        progressText = "Scanning…"
        selectedURLs = []
        skipNotice = nil

        let target = url
        Task.detached { [weak self] in
            // Capture the weak reference into an immutable local so the @Sendable
            // progress sink does not capture the task's mutable `self` binding.
            let controller = self
            let report: @Sendable (Int) -> Void = { count in
                Task { @MainActor in
                    let fileWord = count == 1 ? "file" : "files"
                    controller?.progressText = "Scanned \(count) \(fileWord)…"
                }
            }
            let found = DuplicateFinderKit.findDuplicates(in: target, progress: report)
            let waste = DuplicateFinderKit.wastedBytes(found)
            let mapped = found.map { DuplicateFinderGroup(group: $0) }
            await MainActor.run {
                guard let self else { return }
                self.groups = mapped
                self.wastedBytes = waste
                // Pre-select every copy except the kept original in each group.
                self.selectedURLs = Set(
                    mapped.flatMap { group in
                        group.files.filter { !$0.isOriginal }.map(\.url)
                    }
                )
                self.phase = .results
            }
        }
    }

    func deleteSelected() {
        let targets = Array(selectedURLs)
        guard !targets.isEmpty else { return }
        let bytes = reclaimableForSelection()

        let alert = NSAlert()
        let fileWord = targets.count == 1 ? "file" : "files"
        alert.messageText = "Move \(targets.count) \(fileWord) to Trash?"
        alert.informativeText = "This will reclaim about \(bytes.diskBytesString). Files are moved to the Trash and can be recovered."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task.detached { [weak self] in
            var trashed: Set<URL> = []
            var failures: [String] = []
            let fileManager = FileManager.default
            for target in targets {
                do {
                    try fileManager.trashItem(at: target, resultingItemURL: nil)
                    trashed.insert(target)
                } catch {
                    failures.append("\(target.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let removed = trashed
            let skipped = failures
            await MainActor.run {
                self?.applyDeletion(removed: removed, failures: skipped)
            }
        }
    }

    // MARK: Private helpers

    private func reclaimableForSelection() -> UInt64 {
        var total: UInt64 = 0
        for group in groups {
            for file in group.files where selectedURLs.contains(file.url) {
                total += group.size
            }
        }
        return total
    }

    /// Rebuilds the result set after a deletion, dropping trashed files and any
    /// group that no longer has 2+ remaining copies.
    private func applyDeletion(removed: Set<URL>, failures: [String]) {
        var rebuilt: [DuplicateFinderGroup] = []
        for group in groups {
            let remaining = group.files.filter { !removed.contains($0.url) }
            guard remaining.count > 1 else { continue }
            // Re-mark the first remaining file as the kept original.
            let refreshed = remaining.enumerated().map { index, file in
                DuplicateFinderFile(url: file.url, isOriginal: index == 0)
            }
            rebuilt.append(
                DuplicateFinderGroup(hash: group.hash, size: group.size, files: refreshed)
            )
        }
        groups = rebuilt
        wastedBytes = rebuilt.reduce(UInt64.zero) { $0 + $1.size * UInt64($1.files.count - 1) }
        let survivingURLs = Set(rebuilt.flatMap { $0.files.map(\.url) })
        selectedURLs = selectedURLs.subtracting(removed).intersection(survivingURLs)

        if failures.isEmpty {
            skipNotice = nil
        } else {
            let fileWord = failures.count == 1 ? "file" : "files"
            skipNotice = "Could not trash \(failures.count) \(fileWord): " + failures.joined(separator: "; ")
        }
    }
}

// MARK: - Phase

enum DuplicateFinderPhase {
    case idle
    case scanning
    case results
}

// MARK: - View models

struct DuplicateFinderGroup: Identifiable {
    let id = UUID()
    let hash: String
    let size: UInt64
    let files: [DuplicateFinderFile]

    init(hash: String, size: UInt64, files: [DuplicateFinderFile]) {
        self.hash = hash
        self.size = size
        self.files = files
    }

    init(group: DuplicateGroup) {
        self.hash = group.hash
        self.size = group.size
        self.files = group.urls.enumerated().map { index, url in
            DuplicateFinderFile(url: url, isOriginal: index == 0)
        }
    }
}

struct DuplicateFinderFile: Identifiable {
    var id: URL { url }
    let url: URL
    /// The first (oldest) file in the group, kept by default.
    let isOriginal: Bool

    var parentPath: String {
        url.deletingLastPathComponent().path
    }
}
