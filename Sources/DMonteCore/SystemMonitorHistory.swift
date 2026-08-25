import Foundation

/// One tick of the rolling history the popover's sparklines are drawn from.
///
/// Deliberately a value type of four scalars rather than a whole `MetricSnapshot`: the history
/// holds one of these per second of the visible window, and keeping it small is what makes the
/// fixed allocation below cheap enough to justify.
public struct MetricHistorySample: Equatable, Sendable {
    /// Fraction of total CPU capacity in use, 0...1.
    public var cpuUsage: Double
    /// Fraction of physical memory in use, 0...1.
    public var memoryUsage: Double
    /// Bytes per second, as measured for this tick.
    public var networkDownRate: Double
    /// Bytes per second, as measured for this tick.
    public var networkUpRate: Double

    public init(
        cpuUsage: Double = 0,
        memoryUsage: Double = 0,
        networkDownRate: Double = 0,
        networkUpRate: Double = 0
    ) {
        self.cpuUsage = cpuUsage
        self.memoryUsage = memoryUsage
        self.networkDownRate = networkDownRate
        self.networkUpRate = networkUpRate
    }

    public init(snapshot: MetricSnapshot) {
        self.init(
            cpuUsage: snapshot.cpuUsage,
            memoryUsage: snapshot.memoryUsage,
            networkDownRate: Double(snapshot.networkDownRate),
            networkUpRate: Double(snapshot.networkUpRate)
        )
    }

    public static let zero = MetricHistorySample()
}

/// A fixed-capacity ring of recent samples.
///
/// System Monitor is a login item that runs for months at a stretch, so a history that grew with
/// uptime would be a slow leak and any monotonically increasing index would eventually wrap — the
/// same shape of bug as the `integer_t` CPU tick counters that went negative after roughly a year
/// and made the load read as zero. So the storage is allocated once at `capacity` elements and
/// never resized, the write cursor is taken modulo `capacity` every append, and the fill level
/// saturates at `capacity`. Nothing in here counts upwards without a bound.
public struct MetricHistory: Equatable, Sendable {
    /// Sixty ticks of the one-second poll, i.e. the last minute. Long enough to show a spike
    /// settling, short enough that the whole ring is a couple of kilobytes.
    public static let defaultCapacity = 60

    public let capacity: Int

    private var storage: [MetricHistorySample]
    /// Slot the next append writes to. Always in `0..<capacity`.
    private var writeIndex: Int
    /// How many slots hold real samples. Saturates at `capacity`.
    private var filled: Int

    /// A capacity below one would leave nothing to write into, so it is raised rather than
    /// trapping: a bad constant should not take the whole monitor down at launch.
    public init(capacity: Int = defaultCapacity) {
        let capacity = max(1, capacity)
        self.capacity = capacity
        self.storage = Array(repeating: .zero, count: capacity)
        self.writeIndex = 0
        self.filled = 0
    }

    public var count: Int {
        filled
    }

    public var isEmpty: Bool {
        filled == 0
    }

    public var isFull: Bool {
        filled == capacity
    }

    public mutating func append(_ sample: MetricHistorySample) {
        storage[writeIndex] = sample
        writeIndex = (writeIndex + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    public mutating func append(snapshot: MetricSnapshot) {
        append(MetricHistorySample(snapshot: snapshot))
    }

    /// Drops the recorded history without giving up the allocation, so a restart of the poll
    /// begins from an empty chart rather than splicing a gap into the old one.
    ///
    /// The slots are overwritten in place rather than replaced with a fresh `Array(repeating:)`,
    /// which would hand the old buffer back to the allocator and take a new one — precisely what
    /// a ring that is allocated once at `capacity` exists to avoid. They are zeroed rather than
    /// merely abandoned because `MetricHistory` is `Equatable` over its whole storage, so leaving
    /// the stale samples behind the reset indices would make a cleared ring compare unequal to a
    /// new one holding the same (empty) history.
    public mutating func removeAll() {
        for index in storage.indices {
            storage[index] = .zero
        }

        writeIndex = 0
        filled = 0
    }

    /// The live samples, oldest first — the order a sparkline is drawn in.
    public var samples: [MetricHistorySample] {
        guard filled > 0 else {
            return []
        }

        // Until the ring wraps for the first time the samples sit in the first `filled` slots in
        // order; afterwards the oldest is whatever the write cursor is about to overwrite.
        guard filled == capacity else {
            return Array(storage[0..<filled])
        }

        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }

    /// One metric pulled out of the history as a plain series, ready for `Sparkline`.
    public func series(_ metric: KeyPath<MetricHistorySample, Double>) -> [Double] {
        samples.map { $0[keyPath: metric] }
    }
}
