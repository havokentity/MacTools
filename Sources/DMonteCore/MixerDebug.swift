import Foundation

/// Lightweight, opt-in diagnostics for the Volume Mixer's per-app routing path.
///
/// Enable by launching with `DMONTE_MIXER_DEBUG=1` (e.g.
/// `DMONTE_MIXER_DEBUG=1 swift run DMonteVolumeMixer`). Messages go to stderr so
/// they show up directly in the terminal. Off by default — zero overhead in
/// normal use.
enum MixerDebug {
    static let enabled: Bool = ProcessInfo.processInfo.environment["DMONTE_MIXER_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("‹mixer› " + message() + "\n").utf8))
    }

    /// Scans up to `maxSamples` float samples for any non-zero value, so the
    /// render log can report whether the tap is actually delivering signal.
    static func hasSignal(_ data: UnsafeRawPointer, byteCount: Int, maxSamples: Int = 256) -> Bool {
        let count = min(byteCount / MemoryLayout<Float32>.size, maxSamples)
        let samples = data.assumingMemoryBound(to: Float32.self)
        for index in 0..<count where samples[index] != 0 {
            return true
        }
        return false
    }

    /// Peak absolute sample value over the (whole) float buffer — lets the render
    /// log report how hot the captured signal is (1.0 == full scale / 0 dBFS).
    static func peak(_ data: UnsafeRawPointer, byteCount: Int) -> Float {
        let count = byteCount / MemoryLayout<Float32>.size
        guard count > 0 else { return 0 }
        let samples = data.assumingMemoryBound(to: Float32.self)
        var maxValue: Float = 0
        for index in 0..<count {
            let magnitude = abs(samples[index])
            if magnitude > maxValue { maxValue = magnitude }
        }
        return maxValue
    }
}
