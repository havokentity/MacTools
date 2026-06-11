import CoreAudio
import Foundation

/// Shared CoreAudio sample-rate utilities used wherever we route audio through an
/// aggregate device whose render loop is a raw byte copy (the Volume Mixer's
/// per-app reroute and the Audio Router's input monitor). Aligning every member
/// device to one nominal rate is what keeps fixed-rate outputs like an HDMI/TV
/// (or a 44.1 vs 48 kHz mismatch) from producing silence or artifacts.
public enum CoreAudioSampleRate {

    /// Order-preserving de-duplication of device ids.
    public static func uniqued(_ ids: [AudioObjectID]) -> [AudioObjectID] {
        var seen = Set<AudioObjectID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Standard PCM rates we probe a device's continuous ranges against.
    static let standardSampleRates: [Double] =
        [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000]

    /// The device's current nominal sample rate, or `nil` if unavailable.
    public static func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    /// Every nominal sample rate the device can run, expanding continuous ranges
    /// into the standard rates that fall inside them. Returns `[]` if unknown
    /// (treated by the chooser as "imposes no constraint").
    public static func availableNominalSampleRates(for deviceID: AudioObjectID) -> [Double] {
        guard deviceID != kAudioObjectUnknown else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return [] }
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        guard count > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &ranges) == noErr else {
            return []
        }
        return ratesFromRanges(ranges)
    }

    /// Pure expansion of `AudioValueRange`s into concrete candidate rates.
    public static func ratesFromRanges(_ ranges: [AudioValueRange]) -> [Double] {
        var result = Set<Int>()
        for range in ranges {
            let lo = range.mMinimum
            let hi = range.mMaximum
            result.insert(Int(lo.rounded()))
            result.insert(Int(hi.rounded()))
            for rate in standardSampleRates where rate >= lo && rate <= hi {
                result.insert(Int(rate.rounded()))
            }
        }
        return result.sorted().map(Double.init)
    }

    /// Sets a device's nominal sample rate. Returns `true` if it accepted the
    /// change. Best-effort; non-settable devices fail cleanly with `false`.
    @discardableResult
    public static func setNominalSampleRate(_ rate: Double, for deviceID: AudioObjectID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else { return false }
        var value = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    /// Chooses a sample rate every device can run. Prefers `preferred` (the
    /// source rate) when all devices support it, otherwise the highest rate
    /// common to all, biased toward the universal broadcast rates. An empty rate
    /// list for a device means "no constraint" (unknown) and is skipped. Returns
    /// `nil` only when the constraining devices genuinely share no rate.
    public static func chooseCommonSampleRate(
        preferred: Double?,
        deviceSupportedRates: [[Double]]
    ) -> Double? {
        func key(_ rate: Double) -> Int { Int(rate.rounded()) }
        let constraining = deviceSupportedRates.filter { !$0.isEmpty }
        guard let first = constraining.first else {
            return preferred
        }
        var common = Set(first.map(key))
        for rates in constraining.dropFirst() {
            common.formIntersection(rates.map(key))
        }
        guard !common.isEmpty else { return nil }
        if let preferred, common.contains(key(preferred)) {
            return preferred
        }
        for candidate in [48000, 44100, 96000, 88200, 192000, 176400, 32000] where common.contains(candidate) {
            return Double(candidate)
        }
        return common.max().map(Double.init)
    }
}
