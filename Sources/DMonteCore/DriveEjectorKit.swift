import AppKit
import Foundation

/// A snapshot of the volume resource keys the eject-safety rule depends on.
///
/// Every flag is a tri-state `Bool?` on purpose. `URLResourceValues` returns `nil` for any key
/// the filesystem declines to vend, and “the system would not tell us” is a materially different
/// answer from “no” — collapsing the two at read time would let an unclassifiable volume inherit
/// the permissive branch. `DriveEjectorKit.verdict(for:)` keeps them apart and refuses anything
/// it cannot positively clear.
public struct VolumeDescriptor: Identifiable, Sendable, Equatable {
    /// Mount point, always in canonical spelling. Doubles as the identity: only one volume can
    /// occupy a mount point at a time.
    public let url: URL
    /// Display name (`volumeNameKey`), falling back to the mount point's last path component.
    public let name: String
    /// `true` when this is the volume the running system booted from.
    public let isRootFileSystem: Bool?
    /// `true` for disks physically inside the Mac (including the sealed system and Data volumes).
    public let isInternal: Bool?
    /// `true` for media that can be removed from its drive.
    public let isRemovable: Bool?
    /// `true` when the volume can be unmounted and ejected by the user.
    public let isEjectable: Bool?
    /// Total capacity in bytes; `0` when unavailable.
    public let totalBytes: UInt64
    /// Free capacity in bytes; `0` when unavailable.
    public let freeBytes: UInt64

    public var id: String { DriveEjectorKit.volumeIdentity(for: url) }

    /// Bytes in use, clamped at zero so a stale free-space reading can never produce an underflow.
    public var usedBytes: UInt64 {
        totalBytes > freeBytes ? totalBytes - freeBytes : 0
    }

    public init(
        url: URL,
        name: String,
        isRootFileSystem: Bool?,
        isInternal: Bool?,
        isRemovable: Bool?,
        isEjectable: Bool?,
        totalBytes: UInt64,
        freeBytes: UInt64
    ) {
        // Canonicalised on the way in so that the mount point handed to `unmountAndEjectDevice`,
        // the path the safety rule compares, and the identity the busy-marker bookkeeping keys on
        // are the same string. A row whose ID disagreed with an in-flight unmount marker would
        // re-enable itself mid-unmount, which on this tool means offering to eject a disk twice.
        self.url = url.standardizedFileURL
        self.name = name
        self.isRootFileSystem = isRootFileSystem
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

/// Why a volume may or may not be offered for ejection.
///
/// A separate reason (rather than a bare `Bool`) exists so the re-check performed immediately
/// before unmounting can tell the user *why* a row that looked ejectable a moment ago is not.
public enum VolumeEjectionVerdict: Sendable, Equatable {
    /// External, removable, and demonstrably not the startup disk.
    case eligible
    /// The volume the system booted from. Never ejectable, regardless of its other flags.
    case bootVolume
    /// A disk inside the Mac (including the sealed system and Data volumes).
    case internalDisk
    /// External but fixed — nothing about it says it can be detached.
    case notRemovable
    /// The filesystem did not vend the flags needed to clear it. Excluded by default.
    case undetermined

    /// Plain-language explanation for the inline status line; `nil` when the volume is eligible.
    public var blockedReason: String? {
        switch self {
        case .eligible: nil
        case .bootVolume: "it’s the startup disk"
        case .internalDisk: "it’s an internal disk"
        case .notRemovable: "it isn’t a removable volume"
        case .undetermined: "macOS wouldn’t confirm it’s safe to eject"
        }
    }
}

/// What happened when an eject was attempted.
public enum EjectionOutcome: Sendable, Equatable {
    /// The volume was unmounted and the device ejected.
    case ejected
    /// The safety re-check refused. The volume is untouched and still mounted.
    case blocked(VolumeEjectionVerdict)
    /// macOS refused the unmount — almost always because something still holds the volume.
    /// The volume is still mounted.
    case failed(String)
}

/// The eject-safety layer for the Drive Ejector tool.
///
/// The entire point of this tool is that it can only ever act on external, removable media, so
/// the eligibility rule lives here as a pure function over `VolumeDescriptor` and is exercised
/// directly by the test target. The I/O entry points (`mountedVolumeDescriptors()`,
/// `eject(volumeAt:)`) are thin: they gather resource values, then defer to the same rule.
public enum DriveEjectorKit {

    // MARK: - The safety rule

    /// Resource keys the tool reads for every mounted volume. Kept in one place so the list
    /// enumeration and the pre-eject re-check can never diverge on what they inspect.
    public static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeIsRootFileSystemKey,
        .volumeIsInternalKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey
    ]

    /// The directory macOS reserves for the running system's own volume group — the Data volume,
    /// `VM`, `Preboot`, `Update`, `xarts`, `iSCPreboot`, `Hardware`.
    ///
    /// The enumeration keeps these off the list via `.skipHiddenVolumes`, but that is an option on
    /// one call site rather than a property of the rule, and `eject(volumeAt:)` re-derives its
    /// verdict from a bare mount point without going near it. On a Mac booted from external media
    /// every one of these reports `isInternal == false` plus removable and ejectable, and only
    /// `/System/Volumes/Data` also carries the root-filesystem flag — so the siblings would clear
    /// the rule outright. Stated here so both paths inherit the same guarantee.
    private static let systemVolumeGroupRoot = "/System/Volumes"

    /// The one definition of “which volume is this”, shared by the descriptors, the safety rule and
    /// the controller's busy markers.
    ///
    /// Mount-point URLs reach the tool from three unrelated sources — `mountedVolumeURLs`, the
    /// `NSWorkspace` unmount notifications, and whatever a caller passes to `eject(volumeAt:)` — and
    /// nothing guarantees they spell the same mount point identically. Every comparison in the tool
    /// goes through here so a `..`, a trailing slash or a stray `.` cannot make two names for one
    /// disk look like two disks.
    public static func volumeIdentity(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Decides whether a volume may be ejected. Deliberately biased towards refusing.
    ///
    /// Order matters: the catastrophic case is checked first and by three independent signals, so
    /// a filesystem that vends nothing useful still cannot get a system volume onto the list.
    public static func verdict(for descriptor: VolumeDescriptor) -> VolumeEjectionVerdict {
        // A mount point of "/" is a fact no missing resource key can hide, and the root-filesystem
        // flag catches the same volume when it is reached through a symlinked or relative URL.
        // Checked before the removable flags because a Mac booted from an external USB disk reports
        // that disk as removable *and* ejectable — exactly the combination that would otherwise
        // wave the startup disk straight through.
        let path = volumeIdentity(for: descriptor.url)
        if path == "/" || descriptor.isRootFileSystem == true {
            return .bootVolume
        }

        if path == systemVolumeGroupRoot || path.hasPrefix(systemVolumeGroupRoot + "/") {
            return .bootVolume
        }

        // All three classification flags must be present. A volume nobody will classify is one
        // this tool declines to touch: guessing costs the user a disk, refusing costs a click.
        guard let isInternal = descriptor.isInternal,
              let isRemovable = descriptor.isRemovable,
              let isEjectable = descriptor.isEjectable else {
            return .undetermined
        }

        if isInternal {
            return .internalDisk
        }

        // Either flag alone is enough: USB sticks and card media report removable, while disk
        // images and most external SSDs report only ejectable.
        guard isRemovable || isEjectable else {
            return .notRemovable
        }

        return .eligible
    }

    /// Convenience predicate over `verdict(for:)` for call sites that only need yes/no.
    public static func isEligibleForEjection(_ descriptor: VolumeDescriptor) -> Bool {
        verdict(for: descriptor) == .eligible
    }

    /// The subset of `descriptors` this tool is willing to offer, sorted for stable display.
    public static func eligibleVolumes(from descriptors: [VolumeDescriptor]) -> [VolumeDescriptor] {
        descriptors
            .filter(isEligibleForEjection)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Enumeration

    /// Every mounted volume the tool is willing to offer, already filtered and sorted.
    public static func ejectableVolumes() -> [VolumeDescriptor] {
        eligibleVolumes(from: mountedVolumeDescriptors())
    }

    /// Reads a descriptor for every mounted volume. Unreadable volumes are dropped rather than
    /// synthesised with default flags, so a read failure can never look like “external and safe”.
    public static func mountedVolumeDescriptors() -> [VolumeDescriptor] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap(descriptor(forVolumeAt:))
    }

    /// Reads the safety-relevant resource values for one mount point, or `nil` if the volume
    /// cannot be inspected at all (it vanished, or the path is not a mount point).
    public static func descriptor(forVolumeAt url: URL) -> VolumeDescriptor? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
            return nil
        }

        // `volumeAvailableCapacityKey` rather than the “important usage” variant: this is a
        // headline figure for an external disk, and the purgeable-space estimate that variant
        // adds is a local-snapshot concept that means little on removable media.
        let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        let free = UInt64(max(0, values.volumeAvailableCapacity ?? 0))

        return VolumeDescriptor(
            url: url,
            name: values.volumeName ?? url.lastPathComponent,
            isRootFileSystem: values.volumeIsRootFileSystem,
            isInternal: values.volumeIsInternal,
            isRemovable: values.volumeIsRemovable,
            isEjectable: values.volumeIsEjectable,
            totalBytes: total,
            freeBytes: free
        )
    }

    // MARK: - Foreign unmount announcements

    /// Filters "someone else started unmounting this" markers down to the ones still worth honouring.
    ///
    /// `NSWorkspace.willUnmountNotification` is an announcement, not a promise: any app holding the
    /// volume can dissent, in which case the unmount is abandoned and no `didUnmountNotification`
    /// ever arrives. A marker kept on that basis alone would disable its row — and exclude it from
    /// Eject All — for the lifetime of the process, so a volume that is *still mounted* once `grace`
    /// has elapsed is released. A marker whose volume has gone is dropped immediately: the unmount
    /// succeeded and there is no row left to protect.
    static func liveUnmountAnnouncements(
        _ announcements: [String: Date],
        mountedIDs: Set<String>,
        now: Date,
        grace: TimeInterval
    ) -> [String: Date] {
        announcements.filter { id, announcedAt in
            mountedIDs.contains(id) && now.timeIntervalSince(announcedAt) < grace
        }
    }

    // MARK: - Ejection

    /// Unmounts and ejects the device backing `url`, but only after re-deriving the verdict from
    /// fresh resource values.
    ///
    /// The listed snapshot is treated as a hint, never as authorisation: between the user seeing
    /// a row and pressing its button the mount table can change — a disk image detaches and its
    /// mount point is reused, a volume is remounted, the machine is rebooted from that very disk.
    /// This re-check is the only thing standing between a stale row and an unmounted system disk,
    /// so it runs unconditionally on every single volume, including inside Eject All.
    ///
    /// Never force-unmounts and never retries: a refusal means something is still using the
    /// volume, and the honest outcome is a mounted disk plus an explanation.
    ///
    /// Synchronous and blocking — an unmount can take seconds on a busy disk — so callers run it
    /// off the main actor and report progress through their own state.
    public static func eject(volumeAt url: URL) -> EjectionOutcome {
        guard let descriptor = descriptor(forVolumeAt: url) else {
            return .blocked(.undetermined)
        }

        let verdict = verdict(for: descriptor)
        guard verdict == .eligible else {
            return .blocked(verdict)
        }

        do {
            // The descriptor's canonical mount point, not the caller's spelling: the volume that
            // was cleared and the volume that gets unmounted must be named by the same string.
            try NSWorkspace.shared.unmountAndEjectDevice(at: descriptor.url)
            return .ejected
        } catch {
            return .failed(failureMessage(for: error))
        }
    }

    /// Turns an unmount error into a sentence worth showing.
    ///
    /// macOS puts the useful part — often the name of the app holding the volume — in the
    /// recovery suggestion rather than the description, so both are surfaced when they differ.
    static func failureMessage(for error: Error) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestion = (nsError.localizedRecoverySuggestion ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !suggestion.isEmpty, suggestion != description else {
            return description.isEmpty ? "macOS refused the eject" : description
        }

        return description.isEmpty ? suggestion : "\(description) \(suggestion)"
    }
}
