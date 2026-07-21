import AppKit
import Foundation

/// The three things the Disk Usage Analyzer offers to do with a row of scan
/// results. Modelled as a value rather than three separate call sites so the
/// availability rules below can be stated once and tested once.
public enum DiskItemAction: Sendable, CaseIterable {
    case revealInFinder
    case copyPath
    case moveToTrash
}

/// Whether an action may run against a particular row, and when it may not, the
/// sentence to show the user. Every refusal carries a reason because the
/// alternative — a menu item that quietly does nothing — is indistinguishable
/// from a bug.
public enum DiskItemActionAvailability: Equatable, Sendable {
    case allowed
    case unavailable(reason: String)

    public var isAllowed: Bool {
        self == .allowed
    }

    public var reason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

/// Decides which row actions are safe to offer. Kept pure and separate from the
/// view because two of these rules stop real damage: the reconciliation
/// placeholder would aim a Trash command at the volume root, and a row trashed
/// mid-scan leaves the running scan measuring a directory that no longer exists.
public enum DiskItemActionPolicy {
    public static func availability(
        of action: DiskItemAction,
        for node: DiskNode,
        isScanRoot: Bool,
        isScanInProgress: Bool,
        isTrashInFlight: Bool = false
    ) -> DiskItemActionAvailability {
        // The "Unaccounted / Inaccessible" node carries the volume root's path so
        // the treemap can place it, but it stands for bytes macOS reports that we
        // could not attribute to any file. Acting on it would act on the whole
        // volume — trashing it would target the mount point — so nothing is offered.
        if node.isSynthetic {
            return .unavailable(
                reason: "\(node.name) is an estimate of space we couldn't attribute to a file, so there is nothing to act on."
            )
        }

        switch action {
        case .revealInFinder, .copyPath:
            // Both are read-only and stay useful mid-scan, so the only bar is the
            // synthetic-node check above.
            return .allowed

        case .moveToTrash:
            if isScanRoot {
                return .unavailable(
                    reason: "\(node.name) is the volume being analyzed, so it can't be moved to the Trash from here."
                )
            }
            if isScanInProgress {
                // A scan already walking this volume would keep measuring the
                // directory we just moved, and would then commit a tree built from
                // a mix of before and after. Finishing the scan first is cheaper
                // than trying to patch a half-built tree.
                return .unavailable(
                    reason: "A scan is still running on this volume. Let it finish before moving anything to the Trash."
                )
            }
            if isTrashInFlight {
                // Distinct from the scan case on purpose. Trashing a large folder onto
                // a slow volume takes seconds, and telling the user a scan is running
                // when none is leaves them waiting on something the window never shows.
                return .unavailable(
                    reason: "A Move to Trash is still finishing. Wait for it to complete before starting another one."
                )
            }
            return .allowed
        }
    }
}

/// Why a Move to Trash did not happen. Split into exactly the two cases the UI
/// treats differently: an item that is already gone is not an error the user has
/// to fix — the scan results were simply stale — so the row still disappears.
public enum DiskItemTrashFailure: Error, Equatable, Sendable {
    case alreadyGone
    case systemRefused(String)
}

public enum DiskItemProbe {
    /// Whether the item a scan row describes is still there.
    ///
    /// `lstat`, not `FileManager.fileExists`, which follows symlinks and would
    /// therefore call a dangling link "gone" even though the link itself is a real
    /// directory entry the user can see, reveal and trash.
    public static func exists(atPath path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var info = stat()
        return URL(fileURLWithPath: path).withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return false }
            return lstat(representation, &info) == 0
        }
    }
}

public enum DiskItemTrasher {
    /// Moves the item at `path` to the Trash.
    ///
    /// Always `FileManager.trashItem`, never `removeItem`/`unlink`: a disk
    /// analyzer exists to help people decide what to delete, and a wrong decision
    /// has to stay recoverable. The Trash is that undo.
    public static func moveToTrash(path: String, fileManager: FileManager = .default) -> Result<Void, DiskItemTrashFailure> {
        let url = URL(fileURLWithPath: path)

        // Scan results can be minutes old, so the row may be describing something
        // that Finder or another process already removed. Check first, and map the
        // same condition out of the thrown error below, because the item can also
        // vanish between this check and the call.
        guard DiskItemProbe.exists(atPath: path) else {
            return .failure(.alreadyGone)
        }

        do {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
            return .success(())
        } catch {
            return .failure(failure(from: error))
        }
    }

    /// Classifies an error thrown by `trashItem`. Exposed rather than inlined into
    /// the `catch` so the "it disappeared while we were asking" race can be pinned
    /// by a test without a filesystem to race against.
    public static func failure(from error: Error) -> DiskItemTrashFailure {
        let nsError = error as NSError

        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
            return .alreadyGone
        }

        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return .alreadyGone
        }

        // Anything else — permissions, a read-only volume, a locked file — is a
        // real refusal the user needs to read, so it is passed through verbatim.
        return .systemRefused(nsError.localizedDescription)
    }
}

/// The two lines of a Move to Trash confirmation. A struct rather than a tuple so
/// tests can compare the whole prompt in one assertion.
public struct DiskTrashPrompt: Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// Every sentence the row actions can put in front of the user, in one place so
/// the wording is testable and cannot drift between the menu, the alert and the
/// status line.
public enum DiskItemActionMessage {
    public static func trashPrompt(for node: DiskNode) -> DiskTrashPrompt {
        // Directories are the dangerous case: the size on the row is the whole
        // subtree, and that is exactly what goes to the Trash, so say so.
        let detail = node.isDirectory
            ? "\(node.path)\n\nThis folder and everything inside it — \(node.size.diskBytesString) — will be moved to the Trash."
            : "\(node.path)\n\n\(node.size.diskBytesString) will be moved to the Trash."

        return DiskTrashPrompt(title: "Move \u{201C}\(node.name)\u{201D} to the Trash?", detail: detail)
    }

    public static func trashSucceeded(name: String, bytes: UInt64) -> String {
        "Moved \(name) to the Trash and freed \(bytes.diskBytesString) from the totals."
    }

    public static func trashFailed(name: String, failure: DiskItemTrashFailure) -> String {
        switch failure {
        case .alreadyGone:
            // Not phrased as an error: nothing went wrong, the scan was just old.
            // The caller still prunes the row, and this explains why it vanished.
            return "\(name) was already deleted or moved, so there was nothing to trash. Removed it from the results."
        case .systemRefused(let reason):
            return "Couldn't move \(name) to the Trash: \(reason)"
        }
    }

    public static func pathCopied(_ path: String) -> String {
        "Copied \(path) to the clipboard."
    }

    public static func pathCopyFailed(name: String) -> String {
        "Couldn't copy the path for \(name) to the clipboard."
    }
}

public enum DiskItemPathCopier {
    /// Puts a row's full path on the clipboard. `pasteboard` is injectable so the
    /// contract can be asserted against a private pasteboard instead of trampling
    /// the user's real clipboard during tests.
    @discardableResult
    public static func copy(path: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !path.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(path, forType: .string)
    }
}
