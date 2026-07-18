import Foundation
import IOKit.ps
import MachO
import Darwin

final class SystemMetricsProvider {
    private var previousCPU: (idle: UInt64, total: UInt64)?
    private var previousNetwork: (timestamp: Date, down: UInt64, up: UInt64)?
    private var previousInterfaceCounters: [String: (down: UInt32, up: UInt32)] = [:]
    private var cumulativeNetwork: (down: UInt64, up: UInt64) = (down: 0, up: 0)
    private let thermalSensorReader = ThermalSensorReader()

    func sample() -> MetricSnapshot {
        let timestamp = Date()
        let memory = memoryUsage()
        let disk = diskUsage()
        let network = networkRates(at: timestamp)
        let battery = batteryStatus()

        return MetricSnapshot(
            timestamp: timestamp,
            cpuUsage: cpuUsage(),
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            diskUsed: disk.used,
            diskTotal: disk.total,
            networkDownRate: network.downRate,
            networkUpRate: network.upRate,
            batteryPercent: battery.percent,
            isCharging: battery.isCharging,
            uptime: ProcessInfo.processInfo.systemUptime,
            cpuTemperatureCelsius: thermalSensorReader.cpuTemperatureCelsius()
        )
    }

    private func cpuUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let cpuInfo else {
            return 0
        }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: cpuInfo),
                vm_size_t(Int(cpuInfoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        var idle: UInt64 = 0
        var total: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)

        for cpuIndex in 0..<Int(processorCount) {
            // The kernel's tick counters are unsigned, but `processor_info_array_t` types them as
            // `integer_t` (Int32), so each one reads back negative once it passes 2^31 — roughly a
            // year of uptime. Reinterpret the bits rather than converting the signed value.
            let offset = cpuIndex * stride
            let user = UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_NICE)]))
            let cpuIdle = UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_IDLE)]))

            idle += cpuIdle
            total += user + system + nice + cpuIdle
        }

        defer {
            previousCPU = (idle: idle, total: total)
        }

        guard let previousCPU else {
            return 0
        }

        let totalDelta = total.subtractingReportingOverflow(previousCPU.total)
        let idleDelta = idle.subtractingReportingOverflow(previousCPU.idle)

        guard !totalDelta.overflow, !idleDelta.overflow, totalDelta.partialValue > 0 else {
            return 0
        }

        let busy = totalDelta.partialValue - idleDelta.partialValue
        return min(max(Double(busy) / Double(totalDelta.partialValue), 0), 1)
    }

    private func memoryUsage() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        let total = ProcessInfo.processInfo.physicalMemory

        guard result == KERN_SUCCESS else {
            return (used: 0, total: total)
        }

        let pageSize = UInt64(getpagesize())
        let appMemory = UInt64(stats.internal_page_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = min(appMemory + wired + compressed, total)

        return (used: used, total: total)
    }

    private func diskUsage() -> (used: UInt64, total: UInt64) {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ])

            let total = UInt64(values.volumeTotalCapacity ?? 0)
            let available = UInt64(values.volumeAvailableCapacity ?? 0)
            let importantAvailable = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let bestAvailable = available > 0 ? available : importantAvailable
            return (used: total > bestAvailable ? total - bestAvailable : 0, total: total)
        } catch {
            return (used: 0, total: 0)
        }
    }

    private func networkRates(at timestamp: Date) -> (downRate: UInt64, upRate: UInt64) {
        let totals = networkTotals()

        defer {
            previousNetwork = (timestamp: timestamp, down: totals.down, up: totals.up)
        }

        guard let previousNetwork else {
            return (downRate: 0, upRate: 0)
        }

        let elapsed = max(timestamp.timeIntervalSince(previousNetwork.timestamp), 0.1)
        let downDelta = totals.down >= previousNetwork.down ? totals.down - previousNetwork.down : 0
        let upDelta = totals.up >= previousNetwork.up ? totals.up - previousNetwork.up : 0

        return (
            downRate: UInt64(Double(downDelta) / elapsed),
            upRate: UInt64(Double(upDelta) / elapsed)
        )
    }

    /// Deltas above this are read as an interface reset rather than a counter wrap. A wrap yields a
    /// wrapping delta equal to the real traffic since the last sample, whereas a `utun` that was
    /// destroyed and recreated under the same name restarts near zero and yields a wrapping delta of
    /// nearly the whole 32-bit range. The bound sits just below that range rather than at a plausible
    /// line rate, because 10GbE and Thunderbolt bridge interfaces can move more than a GiB in one
    /// sample, and a real delta big enough to reach here would be indistinguishable from a wrap anyway.
    private static let maxPlausibleOctetDelta: UInt32 = 0xF000_0000

    /// Monotonic 64-bit octet totals across the monitored interfaces. `if_data` only exposes 32-bit
    /// counters, which wrap every 4 GiB, so each interface is diffed against its own previous
    /// reading with wrapping subtraction and the deltas accumulate here. Interfaces contribute
    /// nothing for the sample in which they first appear, and nothing for a sample whose delta is
    /// too large to be real — which is how a recreated interface's restarted counters are kept from
    /// landing as a ~4 GiB spike.
    private func networkTotals() -> (down: UInt64, up: UInt64) {
        var addresses: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&addresses) == 0, let firstAddress = addresses else {
            return cumulativeNetwork
        }

        defer {
            freeifaddrs(addresses)
        }

        var counters: [String: (down: UInt32, up: UInt32)] = [:]

        for pointer in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee

            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else {
                continue
            }

            let name = String(cString: interface.ifa_name)

            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("utun") else {
                continue
            }

            counters[name] = (down: data.ifi_ibytes, up: data.ifi_obytes)
        }

        for (name, current) in counters {
            guard let previous = previousInterfaceCounters[name] else {
                continue
            }

            cumulativeNetwork.down += UInt64(Self.octetDelta(current: current.down, previous: previous.down))
            cumulativeNetwork.up += UInt64(Self.octetDelta(current: current.up, previous: previous.up))
        }

        previousInterfaceCounters = counters

        return cumulativeNetwork
    }

    /// Octets transferred between two readings of one interface's 32-bit counter. Wrapping
    /// subtraction recovers the true delta across the 4 GiB wrap; an implausibly large result means
    /// the counter restarted rather than wrapped, and is dropped.
    private static func octetDelta(current: UInt32, previous: UInt32) -> UInt32 {
        let delta = current &- previous
        return delta > maxPlausibleOctetDelta ? 0 : delta
    }

    private func batteryStatus() -> (percent: Double?, isCharging: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return (percent: nil, isCharging: false)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let max = description[kIOPSMaxCapacityKey] as? Double,
                  max > 0 else {
                continue
            }

            let state = description[kIOPSPowerSourceStateKey] as? String
            return (
                percent: current / max,
                isCharging: state == kIOPSACPowerValue
            )
        }

        return (percent: nil, isCharging: false)
    }
}
