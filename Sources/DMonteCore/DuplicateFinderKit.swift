import CryptoKit
import Foundation

// MARK: - Duplicate finder core (nonisolated, fully testable)
//
// NOTE: This branch already ships a separate "Duplicate Finder" helper whose
// core lives in DuplicateFinder.swift and publicly defines `DuplicateFinderKit`,
// `DuplicateGroup`, etc. To add the "DMonte Duplicates" tool as a *new* sibling
// without editing or breaking that pre-existing tool, this file uses the
// distinct `Duplicates*` symbol family. The public surface is otherwise exactly
// the engine requested: a nonisolated `findDuplicates(in:progress:)` plus
// `DuplicatesFile` / `DuplicatesGroup` value types.

/// A single file participating in a duplicate group.
public struct DuplicatesFile: Identifiable, Sendable {
    public let id: URL
    public let url: URL
    public let size: UInt64
    public let modified: Date

    public init(url: URL, size: UInt64, modified: Date) {
        self.id = url
        self.url = url
        self.size = size
        self.modified = modified
    }
}

/// A set of two or more files that share identical content (same SHA-256).
public struct DuplicatesGroup: Identifiable, Sendable {
    /// Hex-encoded SHA-256 of the shared content — also the group identity.
    public let id: String
    /// The byte-identical files, ordered newest-first so the first element is the
    /// natural "keep" candidate.
    public let files: [DuplicatesFile]
    /// Size in bytes of each file in the group (all members share this size).
    public var size: UInt64

    /// Bytes that could be reclaimed by deleting all but one copy: `size * (count - 1)`.
    public var reclaimable: UInt64 {
        size * UInt64(max(0, files.count - 1))
    }

    public init(id: String, files: [DuplicatesFile], size: UInt64) {
        self.id = id
        self.files = files
        self.size = size
    }
}

/// Pure, Foundation + CryptoKit content-deduplication engine.
///
/// The algorithm groups candidate files by byte size first (cheap), then only
/// hashes files that share a size bucket. Hashing is streamed in fixed-size
/// chunks via `FileHandle` so files are never loaded whole into memory.
public enum DuplicatesKit {
    /// Number of bytes read per streamed chunk while hashing.
    private static let chunkSize = 1 << 20 // 1 MiB

    /// Finds duplicate files within `root`, scanning recursively.
    ///
    /// Zero-byte files, symbolic links, packages, and hidden files are skipped.
    /// Only groups containing two or more identical files are returned, sorted
    /// by reclaimable space (size × (count − 1)) descending.
    ///
    /// - Parameters:
    ///   - root: The root folder to scan.
    ///   - progress: Optional callback invoked with the running count of files
    ///     examined. It may be called from a background context, so it must be
    ///     `@Sendable`.
    /// - Returns: The duplicate groups, sorted by reclaimable space descending.
    public static func findDuplicates(
        in root: URL,
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [DuplicatesGroup] {
        let candidates = regularFiles(in: root, progress: progress)

        // Phase 1: bucket by size. Only sizes with 2+ candidates can collide.
        var sizeBuckets: [UInt64: [Candidate]] = [:]
        for candidate in candidates {
            sizeBuckets[candidate.size, default: []].append(candidate)
        }

        // Phase 2: hash only within multi-member size buckets.
        var groups: [DuplicatesGroup] = []
        for (size, bucket) in sizeBuckets where bucket.count > 1 {
            var hashBuckets: [String: [Candidate]] = [:]
            for candidate in bucket {
                guard let digest = streamedSHA256(of: candidate.url) else { continue }
                hashBuckets[digest, default: []].append(candidate)
            }
            for (hash, matched) in hashBuckets where matched.count > 1 {
                let files = sortedByRecency(matched).map { candidate in
                    DuplicatesFile(url: candidate.url, size: candidate.size, modified: candidate.modified)
                }
                groups.append(DuplicatesGroup(id: hash, files: files, size: size))
            }
        }

        // Largest reclaimable space first; stable secondary order by hash.
        return groups.sorted { lhs, rhs in
            if lhs.reclaimable != rhs.reclaimable { return lhs.reclaimable > rhs.reclaimable }
            return lhs.id < rhs.id
        }
    }

    /// Total bytes that could be reclaimed by deleting all but one copy in each
    /// group: `sum(size * (count - 1))`.
    public static func wastedBytes(_ groups: [DuplicatesGroup]) -> UInt64 {
        groups.reduce(UInt64.zero) { $0 + $1.reclaimable }
    }

    // MARK: - Candidate enumeration

    private struct Candidate {
        let url: URL
        let size: UInt64
        let modified: Date
    }

    /// Recursively enumerates non-empty regular files, skipping symlinks,
    /// directories, packages, hidden files, and zero-byte files.
    private static func regularFiles(
        in root: URL,
        progress: (@Sendable (Int) -> Void)?
    ) -> [Candidate] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var candidates: [Candidate] = []
        var examined = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            // Skip symbolic links explicitly so we never hash the same bytes
            // twice or follow links pointing outside the tree.
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }

            examined += 1
            progress?(examined)

            let size = UInt64(values?.fileSize ?? 0)
            guard size > 0 else { continue } // skip zero-byte files

            let modified = values?.contentModificationDate ?? Date.distantPast
            candidates.append(Candidate(url: fileURL, size: size, modified: modified))
        }
        return candidates
    }

    // MARK: - Streamed hashing

    /// Computes the SHA-256 of a file by streaming fixed-size chunks, never
    /// loading the whole file into memory. Returns `nil` if the file cannot be
    /// opened or read.
    private static func streamedSHA256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Ordering

    /// Orders candidates newest-first by modification date, so the first element
    /// is the most recent copy (the natural one to keep). Falls back to path
    /// order when dates are equal so results are deterministic.
    private static func sortedByRecency(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.path < rhs.url.path
        }
    }
}
