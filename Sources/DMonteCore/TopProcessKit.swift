import Foundation

/// One row of the popover's top-process list.
public struct ProcessUsage: Equatable, Sendable, Identifiable {
    public let pid: Int32
    /// The leaf of the executable path, which is what the user recognises — "Safari" rather than
    /// "/Applications/Safari.app/Contents/MacOS/Safari".
    public let name: String
    /// Percent of one core's worth of CPU, as `ps` reports it. Sums above 100 on a busy machine
    /// because a threaded process can occupy more than one core.
    public let cpuPercent: Double
    /// Percent of physical memory resident.
    public let memoryPercent: Double

    public var id: Int32 {
        pid
    }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryPercent: Double) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
    }
}

/// Which column the top-process list is ranked by.
public enum TopProcessSortKey: String, CaseIterable, Sendable {
    case cpu
    case memory

    public var label: String {
        switch self {
        case .cpu:
            return "CPU"
        case .memory:
            return "MEM"
        }
    }
}

/// Both rankings from a single `ps` run, so switching the segmented control does not have to wait
/// for the next poll to show anything.
public struct TopProcessSnapshot: Equatable, Sendable {
    public var byCPU: [ProcessUsage]
    public var byMemory: [ProcessUsage]

    public init(byCPU: [ProcessUsage] = [], byMemory: [ProcessUsage] = []) {
        self.byCPU = byCPU
        self.byMemory = byMemory
    }

    public static let empty = TopProcessSnapshot()

    public var isEmpty: Bool {
        byCPU.isEmpty && byMemory.isEmpty
    }

    public func processes(for key: TopProcessSortKey) -> [ProcessUsage] {
        switch key {
        case .cpu:
            return byCPU
        case .memory:
            return byMemory
        }
    }
}

/// Reads and ranks the busiest processes.
///
/// Everything here is `nonisolated`: the parsing half is pure so it can be tested against fixture
/// text, and the reading half launches a subprocess and blocks on its exit, which must never
/// happen on the main actor.
public enum TopProcessKit {
    /// How many rows the popover shows per ranking.
    public static let listLimit = 5

    /// How many one-second polls pass between `ps` runs.
    ///
    /// Enumerating every process is orders of magnitude more expensive than the Mach counters the
    /// rest of the monitor reads, and a process list that reshuffles every second is unreadable
    /// anyway. This divides the existing poll rather than adding a timer of its own, so there is
    /// still exactly one timer in the app.
    public static let pollDivider = 5

    // MARK: - Cadence

    /// Whether this poll is the one that runs `ps`, and what the countdown becomes afterwards.
    ///
    /// Pulled out of the controller so the cadence can be proved over thousands of polls without
    /// launching a single subprocess. The result is deliberately a countdown rather than a tick
    /// total: on a monitor that has been up for months a total would be the one number in the app
    /// still growing, and this tool has already shipped one overflow bug of exactly that shape.
    public nonisolated static func processRefreshDecision(
        pollsRemaining: Int,
        divider: Int = pollDivider
    ) -> (shouldRefresh: Bool, pollsRemaining: Int) {
        // A divider below one would mean "every poll", which is what the countdown of zero already
        // expresses; clamping keeps a bad constant from producing a negative reload interval.
        let divider = max(1, divider)

        guard pollsRemaining <= 0 else {
            return (shouldRefresh: false, pollsRemaining: pollsRemaining - 1)
        }

        return (shouldRefresh: true, pollsRemaining: divider - 1)
    }

    // MARK: - Reading

    /// Runs `ps` off the main actor and returns both rankings.
    public nonisolated static func sample(limit: Int = listLimit) async -> TopProcessSnapshot {
        // Detached rather than a bare `await`: the body launches a subprocess and waits for it to
        // exit, and detaching states outright that the wait happens on the concurrent pool no
        // matter which actor asked for the sample.
        await Task.detached(priority: .utility) {
            snapshot(fromProcessListing: runProcessListing(), limit: limit)
        }.value
    }

    /// The raw `ps` output, or an empty string if it could not be run.
    nonisolated static func runProcessListing() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // `-A` covers every user's processes, `-r` sorts by CPU so the busiest rows survive even
        // if the output is somehow truncated, and the trailing `=` on each `-o` column suppresses
        // the header row.
        process.arguments = ["-Ao", "pid=,pcpu=,pmem=,comm=", "-r"]
        // `ps` formats its percentages with the C library's locale-aware printf, so under a locale
        // that uses a decimal comma every figure would fail to parse as a Double. Pin the numeric
        // locale rather than teaching the parser about separators.
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]

        let pipe = Pipe()
        process.standardOutput = pipe
        // A diagnostic on stderr would otherwise land in the terminal; discard it, since a failed
        // run is already reported by the empty parse below.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        // Drain before waiting: the listing runs to tens of kilobytes on a busy Mac, far more than
        // a pipe buffer holds, so waiting first would deadlock against a child blocked on write.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Parsing

    public nonisolated static func snapshot(fromProcessListing listing: String, limit: Int = listLimit) -> TopProcessSnapshot {
        let processes = parse(processListing: listing)

        return TopProcessSnapshot(
            byCPU: top(processes, by: .cpu, limit: limit),
            byMemory: top(processes, by: .memory, limit: limit)
        )
    }

    /// Parses `pid pcpu pmem comm` rows. Anything that does not have all four fields in that shape
    /// — a header row, a blank line, a truncated final line — is skipped rather than failing the
    /// whole listing, because one unreadable row should not empty the panel.
    public nonisolated static func parse(processListing listing: String) -> [ProcessUsage] {
        listing.split(separator: "\n", omittingEmptySubsequences: true).compactMap(parse(row:))
    }

    nonisolated static func parse(row: Substring) -> ProcessUsage? {
        var remainder = row

        guard let pidField = takeField(&remainder),
              let pid = Int32(pidField),
              let cpuField = takeField(&remainder),
              let cpuPercent = Double(cpuField),
              let memoryField = takeField(&remainder),
              let memoryPercent = Double(memoryField) else {
            return nil
        }

        // Whatever is left is the command, which keeps its internal spaces: plenty of executables
        // live at paths like ".../Claude Helper (Renderer)".
        let command = remainder.drop(while: isFieldSeparator)
        let name = displayName(forCommand: String(command))

        guard !name.isEmpty else {
            return nil
        }

        return ProcessUsage(pid: pid, name: name, cpuPercent: cpuPercent, memoryPercent: memoryPercent)
    }

    /// The recognisable part of an executable path.
    public nonisolated static func displayName(forCommand command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return ""
        }

        let leaf = (trimmed as NSString).lastPathComponent

        // A command that is nothing but slashes has no leaf; show it verbatim instead of blank.
        return leaf.isEmpty ? trimmed : leaf
    }

    /// The `limit` heaviest processes by `key`.
    public nonisolated static func top(_ processes: [ProcessUsage], by key: TopProcessSortKey, limit: Int) -> [ProcessUsage] {
        guard limit > 0 else {
            return []
        }

        let ranked = processes.sorted { lhs, rhs in
            let left = usage(of: lhs, by: key)
            let right = usage(of: rhs, by: key)

            guard left == right else {
                return left > right
            }

            // Swift's sort is not stable, so the dozens of processes tied at 0.0% would otherwise
            // reshuffle on every run and make the list flicker. pid is arbitrary but fixed.
            return lhs.pid < rhs.pid
        }

        return Array(ranked.prefix(limit))
    }

    private nonisolated static func usage(of process: ProcessUsage, by key: TopProcessSortKey) -> Double {
        switch key {
        case .cpu:
            return process.cpuPercent
        case .memory:
            return process.memoryPercent
        }
    }

    /// Pops the next whitespace-delimited field. `ps` right-aligns its numeric columns, so the
    /// runs of spaces between them vary in width from row to row and a fixed split will not do.
    private nonisolated static func takeField(_ text: inout Substring) -> Substring? {
        text = text.drop(while: isFieldSeparator)

        guard !text.isEmpty else {
            return nil
        }

        let end = text.firstIndex(where: isFieldSeparator) ?? text.endIndex
        let field = text[text.startIndex..<end]
        text = text[end...]

        return field
    }

    private nonisolated static func isFieldSeparator(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\r"
    }
}
