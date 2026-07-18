import XCTest
import CoreAudio
@testable import DMonteCore

/// Tests for the input-monitor support types. The real-time engine itself needs
/// audio hardware, so these cover the pure pieces: gain clamping, error
/// messages, and the shared sample-rate helper the monitor relies on.
final class AudioMonitorKitTests: XCTestCase {

    func testClampGainBounds() {
        XCTAssertEqual(AudioMonitorEngine.clampGain(-1), 0)
        XCTAssertEqual(AudioMonitorEngine.clampGain(0.5), 0.5)
        XCTAssertEqual(AudioMonitorEngine.clampGain(2), 1)
    }

    func testMonitorErrorMessagesAreNonEmpty() {
        XCTAssertFalse(AudioMonitorError.deviceUnavailable.message.isEmpty)
        XCTAssertFalse(AudioMonitorError.incompatibleSampleRate.message.isEmpty)
        XCTAssertFalse(AudioMonitorError.coreAudio(-10875).message.isEmpty)
    }

    func testFreshEngineIsNotRunning() {
        XCTAssertFalse(AudioMonitorEngine().isRunning)
    }

    // MARK: - Shared sample-rate helper (used by the monitor + the mixer)

    func testSharedChooserPrefersCommonRate() {
        // Mic at 44.1, output (e.g. HDMI) only 48 → must converge on 48.
        XCTAssertEqual(
            CoreAudioSampleRate.chooseCommonSampleRate(
                preferred: 44100,
                deviceSupportedRates: [[44100, 48000], [48000]]
            ),
            48000
        )
    }

    func testSharedChooserReturnsNilWhenDisjoint() {
        XCTAssertNil(
            CoreAudioSampleRate.chooseCommonSampleRate(
                preferred: nil,
                deviceSupportedRates: [[44100], [48000]]
            )
        )
    }

    func testSharedRatesFromRangesExpandsContinuousSpan() {
        let rates = CoreAudioSampleRate.ratesFromRanges(
            [AudioValueRange(mMinimum: 44100, mMaximum: 48000)]
        )
        XCTAssertEqual(rates, [44100, 48000])
    }

    func testSharedUniquedPreservesOrder() {
        XCTAssertEqual(CoreAudioSampleRate.uniqued([5, 1, 5, 9, 1]), [5, 1, 9])
    }

    /// A pinned device collapses to a single supported rate in `start()`, which is
    /// how a second monitor is made to converge on the rate the first one needs.
    func testPinnedRateWinsOverThePreferredRate() {
        XCTAssertEqual(
            CoreAudioSampleRate.chooseCommonSampleRate(
                preferred: 44100,
                deviceSupportedRates: [[48000], [44100, 48000]]
            ),
            48000
        )
    }

    // MARK: - Sample-rate registry (shared by simultaneous monitors)

    /// Ids no real CoreAudio device can hold, so the registry's rate reads/writes
    /// are guaranteed no-ops and the refcount bookkeeping is what's under test.
    private var deviceA: AudioObjectID { .max }
    private var deviceB: AudioObjectID { .max - 1 }

    func testRegistryPinsAcquiredDevices() {
        let registry = MonitorSampleRateRegistry()
        XCTAssertNil(registry.pinnedRate(for: deviceA))
        registry.acquire(deviceIDs: [deviceA, deviceB], rate: 48000)
        XCTAssertEqual(registry.pinnedRate(for: deviceA), 48000)
        XCTAssertEqual(registry.pinnedRate(for: deviceB), 48000)
    }

    func testRegistryKeepsDevicePinnedUntilTheLastMonitorReleasesIt() {
        // Two monitors share a device: the first to stop must not unpin it, or it
        // would retune the device under the one still running.
        let registry = MonitorSampleRateRegistry()
        registry.acquire(deviceIDs: [deviceA], rate: 48000)
        registry.acquire(deviceIDs: [deviceA], rate: 48000)
        registry.release(deviceIDs: [deviceA])
        XCTAssertEqual(registry.pinnedRate(for: deviceA), 48000)
        registry.release(deviceIDs: [deviceA])
        XCTAssertNil(registry.pinnedRate(for: deviceA))
    }

    func testRegistryIgnoresReleaseOfAnUnclaimedDevice() {
        let registry = MonitorSampleRateRegistry()
        registry.release(deviceIDs: [deviceA])
        XCTAssertNil(registry.pinnedRate(for: deviceA))
    }

    // MARK: - Render input-buffer selection

    /// An interleaved-float `AudioBufferList` with one buffer per entry, mirroring
    /// how the aggregate hands the IO proc one buffer per sub-device stream. No
    /// audio hardware is touched — the buffers are built by hand.
    private final class BufferList {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float32>] = []
        private let counts: [Int]

        init(buffers: [(channels: Int, samples: [Float32])]) {
            counts = buffers.map { $0.samples.count }
            list = AudioBufferList.allocate(maximumBuffers: buffers.count)
            for (index, buffer) in buffers.enumerated() {
                let data = UnsafeMutablePointer<Float32>.allocate(capacity: max(buffer.samples.count, 1))
                for (sampleIndex, sample) in buffer.samples.enumerated() {
                    data[sampleIndex] = sample
                }
                storage.append(data)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(buffer.channels),
                    mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float32>.size),
                    mData: UnsafeMutableRawPointer(data)
                )
            }
        }

        func samples(at index: Int) -> [Float32] {
            (0..<counts[index]).map { storage[index][$0] }
        }

        deinit {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    private func render(input: BufferList, output: BufferList, inputBufferIndex: Int, gain: Float) {
        AudioMonitorEngine.render(
            inputData: UnsafePointer(input.list.unsafeMutablePointer),
            outputData: output.list.unsafeMutablePointer,
            inputBufferIndex: inputBufferIndex,
            gain: gain
        )
    }

    func testRenderPlaysTheSelectedInputBufferNotTheFirst() {
        // The listening output device is the aggregate's first sub-device, so when
        // it has input streams of its own (AirPods/USB headset mic) they occupy the
        // leading input buffers. Taking `inputs.first` would monitor that mic
        // instead of the device the user picked.
        let input = BufferList(buffers: [
            (channels: 2, samples: [0.9, 0.9, 0.9, 0.9]),
            (channels: 2, samples: [0.1, -0.2, 0.3, -0.4])
        ])
        let output = BufferList(buffers: [(channels: 2, samples: [9, 9, 9, 9])])
        render(input: input, output: output, inputBufferIndex: 1, gain: 1)
        XCTAssertEqual(output.samples(at: 0), [0.1, -0.2, 0.3, -0.4])
    }

    func testRenderPlaysBufferZeroWhenTheOutputHasNoInputStreams() {
        let input = BufferList(buffers: [(channels: 2, samples: [0.1, -0.2])])
        let output = BufferList(buffers: [(channels: 2, samples: [9, 9])])
        render(input: input, output: output, inputBufferIndex: 0, gain: 1)
        XCTAssertEqual(output.samples(at: 0), [0.1, -0.2])
    }

    func testRenderAppliesGainToTheSelectedInputBuffer() {
        let input = BufferList(buffers: [
            (channels: 2, samples: [0.9, 0.9]),
            (channels: 2, samples: [0.5, -0.5])
        ])
        let output = BufferList(buffers: [(channels: 2, samples: [9, 9])])
        render(input: input, output: output, inputBufferIndex: 1, gain: 0.5)
        XCTAssertEqual(output.samples(at: 0), [0.25, -0.25])
    }

    func testRenderSilencesOutputWhenInputIndexIsOutOfRange() {
        let input = BufferList(buffers: [(channels: 2, samples: [0.5, 0.5])])
        let output = BufferList(buffers: [(channels: 2, samples: [9, 9])])
        render(input: input, output: output, inputBufferIndex: 1, gain: 1)
        XCTAssertEqual(output.samples(at: 0), [0, 0])
    }

    func testRenderMonoInputFansOutToEveryOutputChannel() {
        let input = BufferList(buffers: [
            (channels: 2, samples: [0.9, 0.9]),
            (channels: 1, samples: [0.5, -0.25])
        ])
        let output = BufferList(buffers: [(channels: 2, samples: [9, 9, 9, 9])])
        render(input: input, output: output, inputBufferIndex: 1, gain: 1)
        XCTAssertEqual(output.samples(at: 0), [0.5, 0.5, -0.25, -0.25])
    }
}
