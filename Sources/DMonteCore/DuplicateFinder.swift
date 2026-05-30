import CryptoKit
import Foundation

// MARK: - Duplicate finder core (nonisolated, fully testable)

/// A set of two or more files that share identical content.
public struct DuplicateGroup: Sendable {
    /// Hex-encoded SHA-256 of the shared content.
    public let hash: String
    /// Size in bytes of each file in the group (all members share the same size).
    public let size: UInt64
    /// URLs of the identical files, ordered oldest-first (by creation date).
    public let urls: [URL]

    public init(hash: String, size: UInt64, urls: [URL]) {
        self.hash = hash
        self.size = size
        self.urls = urls
    }
}

/// Pure, Foundation + CryptoKit content-deduplication engine.
///
/// The algorithm groups candidate files by byte size first (cheap), then only
/// hashes files that share a size bucket. Hashing is streamed in fixed-size
/// chunks via `FileHandle` so files are never loaded whole into memory.
public enum DuplicateFinderKit {
    /// Number of bytes read per streamed chunk while hashing.
    private static let chunkSize = 1 << 20 // 1 MiB

    /// Finds duplicate files within `directory`, scanning recursively.
    ///
    /// Zero-byte files and symbolic links are skipped. Only groups containing
    /// two or more identical files are returned.
    ///
    /// - Parameters:
    ///   - directory: The root folder to scan.
    ///   - progress: Optional callback invoked with the running count of files
    ///     examined. It may be called from a background context, so it must be
    ///     `@Sendable`.
    /// - Returns: The duplicate groups, sorted by reclaimable space descending.
    public static func findDuplicates(
        in directory: URL,
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [DuplicateGroup] {
        let candidates = regularFiles(in: directory, progress: progress)

        // Phase 1: bucket by size. Only sizes with 2+ candidates can collide.
        var sizeBuckets: [UInt64: [URL]] = [:]
        for candidate in candidates {
            sizeBuckets[candidate.size, default: []].append(candidate.url)
        }

        // Phase 2: hash only within multi-member size buckets.
        var groups: [DuplicateGroup] = []
        for (size, urls) in sizeBuckets where urls.count > 1 {
            var hashBuckets: [String: [URL]] = [:]
            for url in urls {
                guard let digest = streamedSHA256(of: url) else { continue }
                hashBuckets[digest, default: []].append(url)
            }
            for (hash, matched) in hashBuckets where matched.count > 1 {
                groups.append(
                    DuplicateGroup(hash: hash, size: size, urls: sortedByAge(matched))
                )
            }
        }

        // Largest reclaimable space first; stable secondary order by hash.
        return groups.sorted { lhs, rhs in
            let lhsWaste = lhs.size * UInt64(lhs.urls.count - 1)
            let rhsWaste = rhs.size * UInt64(rhs.urls.count - 1)
            if lhsWaste != rhsWaste { return lhsWaste > rhsWaste }
            return lhs.hash < rhs.hash
        }
    }

    /// Total bytes that could be reclaimed by deleting all but one copy in each
    /// group: `sum(size * (count - 1))`.
    public static func wastedBytes(_ groups: [DuplicateGroup]) -> UInt64 {
        groups.reduce(UInt64.zero) { running, group in
            running + group.size * UInt64(group.urls.count - 1)
        }
    }

    // MARK: - Candidate enumeration

    private struct Candidate {
        let url: URL
        let size: UInt64
    }

    /// Recursively enumerates non-empty regular files, skipping symlinks,
    /// directories, and zero-byte files.
    private static func regularFiles(
        in directory: URL,
        progress: (@Sendable (Int) -> Void)?
    ) -> [Candidate] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
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

            candidates.append(Candidate(url: fileURL, size: size))
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

    /// Orders URLs oldest-first by creation date, so the first element is the
    /// natural "original" to keep. Falls back to path order when dates are
    /// unavailable so results are deterministic.
    private static func sortedByAge(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let lhsDate = creationDate(of: lhs)
            let rhsDate = creationDate(of: rhs)
            switch (lhsDate, rhsDate) {
            case let (l?, r?) where l != r:
                return l < r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.path < rhs.path
            }
        }
    }

    private static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
