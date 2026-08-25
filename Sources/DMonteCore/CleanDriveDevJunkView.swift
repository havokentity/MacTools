import AppKit
import SwiftUI

/// The developer-junk sheet: eleven categories, each expandable into the individual directories
/// that make up its total so the user can keep the one project they still care about. It is a
/// separate surface from the main Clean Drive list because the interaction is different — the
/// system categories are a checkbox each, these need drilling into.
struct CleanDriveDevJunkPanel: View {
    var onClose: () -> Void

    @State private var reports: [DevJunkCategoryReport] = []
    @State private var selection = DevJunkSelection()
    @State private var expanded: Set<DevJunkCategoryID> = []
    @State private var isScanning = true
    @State private var scanFraction: Double = 0
    @State private var scanLabel = ""
    @State private var statusMessage = "Scanning..."
    @State private var isTrashing = false
    @State private var didStopScan = false
    @State private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScan`. A cancelled scan's loop still has a tail to run, and trashing
    /// starts a fresh scan, so the outgoing task has to be able to tell that the state it is about
    /// to write belongs to somebody else now.
    @State private var scanGeneration = 0

    private let home = NSHomeDirectory()
    private let layout = DevJunkLayout.current

    var body: some View {
        VStack(spacing: 0) {
            header
            summary
            categoryList
            footer
        }
        .frame(width: layout.sheetSize.width, height: layout.sheetSize.height)
        .task {
            startScan()
        }
        .onDisappear {
            // Closing the sheet mid-scan must stop the walk; a node_modules sweep left running in
            // the background would keep spinning a core for a panel nobody is looking at.
            scanTask?.cancel()
        }
    }

    private var header: some View {
        HStack {
            Text("Developer Junk")
                .font(.system(size: layout.titleFontSize, weight: .bold))

            Spacer()

            Button {
                scanTask?.cancel()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: layout.closeIconSize, weight: .bold))
                    .frame(width: layout.closeButtonSize, height: layout.closeButtonSize)
            }
            .buttonStyle(.plain)
            .disabled(isTrashing)
            .help("Close")
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, layout.verticalPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: layout.summarySpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedBytes.diskBytesString)
                    .font(.system(size: layout.summaryValueFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Text("selected of \(totalBytes.diskBytesString) found")
                    .font(.system(size: layout.captionFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()
            }

            if isScanning {
                HStack(spacing: layout.rowSpacing) {
                    ProgressView(value: scanFraction)
                        .progressViewStyle(.linear)

                    Button("Stop") {
                        stopScan()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: layout.captionFontSize, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
            }

            Text(isScanning && !scanLabel.isEmpty ? "Scanning \(scanLabel)..." : statusMessage)
                .font(.system(size: layout.captionFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, layout.summaryBottomPadding)
    }

    private var categoryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: layout.rowSpacing) {
                ForEach(reports) { report in
                    categoryRow(report)

                    if expanded.contains(report.category) {
                        detailBlock(report)
                    }
                }
            }
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.vertical, layout.listVerticalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func categoryRow(_ report: DevJunkCategoryReport) -> some View {
        HStack(spacing: layout.rowSpacing) {
            Button {
                selection.toggle(report)
            } label: {
                DevJunkCheckbox(state: selection.state(for: report), size: layout.checkboxSize)
            }
            .buttonStyle(.plain)
            .disabled(report.entries.isEmpty || isTrashing)
            .help(report.entries.isEmpty ? "Nothing found" : "Select every entry in this category")

            Button {
                toggleExpansion(report.category)
            } label: {
                HStack(spacing: layout.rowSpacing) {
                    Image(systemName: expanded.contains(report.category) ? "chevron.down" : "chevron.right")
                        .font(.system(size: layout.chevronFontSize, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: layout.chevronWidth, alignment: .leading)

                    Text(report.category.title)
                        .font(.system(size: layout.rowTitleFontSize, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: layout.rowSpacing)

                    Text(report.entries.isEmpty ? "—" : report.totalSize.diskBytesString)
                        .font(.system(size: layout.rowValueFontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(report.entries.isEmpty)
        }
        .opacity(report.entries.isEmpty ? 0.45 : 1)
    }

    private func detailBlock(_ report: DevJunkCategoryReport) -> some View {
        VStack(alignment: .leading, spacing: layout.rowSpacing) {
            Text(report.category.detail)
                .font(.system(size: layout.captionFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(report.entries) { entry in
                Button {
                    selection.toggle(entry)
                } label: {
                    HStack(spacing: layout.rowSpacing) {
                        DevJunkCheckbox(
                            state: selection.isSelected(entry) ? .all : .none,
                            size: layout.checkboxSize
                        )

                        Text(entry.displayName)
                            .font(.system(size: layout.entryFontSize, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: layout.rowSpacing)

                        Text(entry.size.diskBytesString)
                            .font(.system(size: layout.entryFontSize, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isTrashing)
                .help(DevJunkPaths.abbreviate(entry.path, home: home))
            }
        }
        .padding(.leading, layout.detailIndent)
        .padding(.bottom, layout.detailBottomPadding)
    }

    private var footer: some View {
        VStack(spacing: layout.summarySpacing) {
            Text("Selected items are moved to the Trash. The space is reclaimed once you empty it.")
                .font(.system(size: layout.captionFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                confirmAndTrash()
            } label: {
                Text(isTrashing ? "Moving to Trash..." : "Move to Trash")
                    .font(.system(size: layout.buttonFontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, layout.buttonHorizontalPadding)
                    .frame(height: layout.buttonHeight)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: layout.buttonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedBytes == 0 || isTrashing)
            .opacity(selectedBytes == 0 || isTrashing ? 0.45 : 1)
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, layout.verticalPadding)
        .padding(.top, layout.footerTopPadding)
    }

    private var selectedBytes: UInt64 {
        selection.selectedBytes(in: reports)
    }

    private var totalBytes: UInt64 {
        reports.reduce(UInt64(0)) { $0 &+ $1.totalSize }
    }

    private func toggleExpansion(_ category: DevJunkCategoryID) {
        if expanded.contains(category) {
            expanded.remove(category)
        } else {
            expanded.insert(category)
        }
    }

    /// - Parameter preservingSelection: `true` only for the rescan that follows a trash. What is
    ///   still on disk there is, by definition, what the user chose *not* to delete, so re-seeding
    ///   the defaults would re-tick the one project they took the trouble to uncheck — and re-arm
    ///   the Move to Trash button over it. Every other scan starts from a clean selection so the
    ///   defaults land on all eleven categories consistently: seeding the default-on categories on
    ///   top of a kept selection used to leave the sheet showing a mixture of the two that no
    ///   single scan could have produced (a stale Archives tick beside force-reselected defaults).
    private func startScan(preservingSelection: Bool = false) {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        let seedsDefaults = !preservingSelection
        reports = []
        if seedsDefaults {
            selection = DevJunkSelection()
        }
        isScanning = true
        didStopScan = false
        scanFraction = 0
        scanLabel = ""
        statusMessage = "Scanning..."

        scanTask = Task {
            for await event in DevJunkScanner.scanStream(home: home) {
                // Trashing restarts the scan, which cancels this task; anything still buffered in
                // its stream belongs to a scan the user has moved on from and must not be written
                // into the successor's state.
                guard generation == scanGeneration else {
                    return
                }

                switch event {
                case let .progress(fraction, label):
                    scanFraction = fraction
                    scanLabel = label
                case let .category(report):
                    // Categories land one at a time so the list fills in as it goes; seeding the
                    // selection per category keeps the "will free" total honest during the scan.
                    reports.append(report)
                    if seedsDefaults {
                        selection.seedDefaults(for: report)
                    }
                case let .finished(finished):
                    reports = finished
                    selection.reconcile(with: finished)
                }
            }

            // The tail is the dangerous part: a cancelled scan reaches it too, and clearing
            // `isScanning` there would take the progress bar and the Stop button away from the scan
            // that replaced it while announcing that scan's half-filled results as final.
            guard generation == scanGeneration else {
                return
            }

            isScanning = false
            scanLabel = ""
            // Cancelling makes the stream finish exactly as a completed scan does, so the stopped
            // case has to be remembered explicitly — otherwise a partial total would be announced
            // as if it were the whole picture.
            statusMessage = didStopScan ? "Scan stopped — showing what was found so far" : summaryMessage()
        }
    }

    private func stopScan() {
        didStopScan = true
        scanTask?.cancel()
    }

    private func summaryMessage() -> String {
        let found = reports.reduce(0) { $0 + $1.entries.count }
        guard found > 0 else {
            return "No developer junk found"
        }
        return "\(found) item\(found == 1 ? "" : "s") found"
    }

    private func confirmAndTrash() {
        let entries = selection.selectedEntries(in: reports)
        guard !entries.isEmpty else {
            return
        }

        let alert = NSAlert()
        alert.messageText = DevJunkRemover.confirmationMessage(for: entries)
        alert.informativeText = "You can put them back from the Trash if you change your mind. Anything still in use by a running build may fail to move."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        isTrashing = true
        statusMessage = "Moving to Trash..."

        Task {
            var result = DevJunkRemovalResult(trashedBytes: 0, trashedCount: 0, failures: [])

            for await event in DevJunkRemover.trashStream(entries: entries, home: home) {
                switch event {
                case let .progress(_, currentPath):
                    statusMessage = "Trashing \(DevJunkPaths.abbreviate(currentPath, home: home))"
                case let .finished(finished):
                    result = finished
                }
            }

            isTrashing = false
            // The result is reported before the rescan, not after: `startScan` overwrites the
            // status line with "Scanning...", so a report published afterwards would be the only
            // trace of a bulk move and would vanish immediately.
            presentResult(result)
            // Whatever survived the move is what the user left unticked, so the rescan keeps their
            // choices instead of handing the defaults a second chance at them.
            startScan(preservingSelection: true)
        }
    }

    private func presentResult(_ result: DevJunkRemovalResult) {
        // Nothing moved and nothing failed means every entry was already gone — usually a stale
        // selection from a previous pass — and there is nothing to acknowledge.
        guard result.trashedCount > 0 || !result.failures.isEmpty else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Moved \(result.trashedCount) item\(result.trashedCount == 1 ? "" : "s") "
            + "(\(result.trashedBytes.diskBytesString)) to the Trash"

        if result.failures.isEmpty {
            // A wholly successful bulk move used to pass in silence, which is the wrong ending for
            // an action that looks irreversible: the user needs to be told it happened and that the
            // space is still sitting in the Trash.
            alert.informativeText = "The space is reclaimed once you empty the Trash."
        } else {
            let details = result.failures.prefix(6).map {
                "• \(DevJunkPaths.abbreviate($0.path, home: home)) — \($0.reason)"
            }.joined(separator: "\n")
            let more = result.failures.count > 6 ? "\n…and \(result.failures.count - 6) more" : ""
            alert.informativeText = "These were left in place:\n\n\(details)\(more)"
        }

        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Tri-state checkbox. The half-filled state is what makes drill-down legible: a category the user
/// has partly deselected must not look identical to one they left alone.
private struct DevJunkCheckbox: View {
    var state: DevJunkSelectionState
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(state == .none ? Color.secondary.opacity(0.28) : Color.accentColor)
            .frame(width: size, height: size)
            .overlay {
                switch state {
                case .none:
                    EmptyView()
                case .partial:
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.white)
                        .frame(width: size * 0.52, height: max(1.5, size * 0.14))
                case .all:
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.62, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
            }
    }
}

private struct DevJunkLayout {
    let scale: CGFloat

    static var current: DevJunkLayout {
        DevJunkLayout(scale: CleanDriveSizing.currentScale)
    }

    var sheetSize: NSSize { CleanDriveSizing.devJunkSize() }
    var horizontalPadding: CGFloat { 16 * scale }
    var verticalPadding: CGFloat { 14 * scale }
    var headerBottomPadding: CGFloat { 8 * scale }
    var summarySpacing: CGFloat { 6 * scale }
    var summaryBottomPadding: CGFloat { 8 * scale }
    var summaryValueFontSize: CGFloat { 20 * scale }
    var titleFontSize: CGFloat { 16 * scale }
    var closeIconSize: CGFloat { 11 * scale }
    var closeButtonSize: CGFloat { 24 * scale }
    var captionFontSize: CGFloat { 11 * scale }
    var rowSpacing: CGFloat { 8 * scale }
    var listVerticalPadding: CGFloat { 4 * scale }
    var checkboxSize: CGFloat { 15 * scale }
    var chevronFontSize: CGFloat { 10 * scale }
    var chevronWidth: CGFloat { 12 * scale }
    var rowTitleFontSize: CGFloat { 13 * scale }
    var rowValueFontSize: CGFloat { 12 * scale }
    var entryFontSize: CGFloat { 11 * scale }
    var detailIndent: CGFloat { 23 * scale }
    var detailBottomPadding: CGFloat { 6 * scale }
    var footerTopPadding: CGFloat { 8 * scale }
    var buttonFontSize: CGFloat { 13 * scale }
    var buttonHorizontalPadding: CGFloat { 18 * scale }
    var buttonHeight: CGFloat { 28 * scale }
    var buttonCornerRadius: CGFloat { 7 * scale }
}
