import CoreAudio

/// A `Sendable` box that owns one CoreAudio property-listener registration and
/// knows how to tear it down. Kept separate from the `@MainActor` controllers that
/// use it so it can be released from a nonisolated `deinit` without touching
/// actor-isolated, non-`Sendable` state.
final class AudioPropertyListenerRegistration: @unchecked Sendable {
    private let objectID: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init?(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        onChange: @escaping @Sendable () -> Void
    ) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // CoreAudio invokes this on the dispatch queue we supply (main).
            onChange()
        }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
        guard status == noErr else { return nil }
        self.objectID = objectID
        self.address = address
        self.block = block
        self.installed = true
    }

    func remove() {
        guard installed else { return }
        installed = false
        var address = self.address
        AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
    }
}

/// Owns the volume/mute listeners for whichever device is currently the default
/// for one direction, re-pointing them when that default changes. Volume and mute
/// are per-device properties, so they cannot be observed once and for all — and the
/// element is a wildcard because a device may expose volume on its main element
/// or only per-channel (mirroring `AudioDeviceKit.volume(for:scope:)`).
///
/// The `scope` is supplied by the caller: Audio Switcher watches the default
/// output, Mic Control watches the default input, and the two scopes are entirely
/// separate CoreAudio properties even on a device that has both directions.
final class DefaultDeviceStateListener: @unchecked Sendable {
    private let scope: AudioObjectPropertyScope
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var observedDeviceID: AudioDeviceID?
    private var registrations: [AudioPropertyListenerRegistration] = []

    init(scope: AudioObjectPropertyScope, onChange: @escaping @Sendable () -> Void) {
        self.scope = scope
        self.onChange = onChange
    }

    /// Points the listeners at `deviceID`; a no-op when it is already observed.
    func observe(deviceID: AudioDeviceID?) {
        lock.lock()
        guard deviceID != observedDeviceID else {
            lock.unlock()
            return
        }
        observedDeviceID = deviceID
        let previous = registrations
        let scope = self.scope
        registrations = (deviceID.map { id in
            [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].compactMap { selector in
                AudioPropertyListenerRegistration(
                    objectID: id,
                    selector: selector,
                    scope: scope,
                    element: kAudioObjectPropertyElementWildcard,
                    onChange: onChange
                )
            }
        }) ?? []
        lock.unlock()
        previous.forEach { $0.remove() }
    }

    func remove() { observe(deviceID: nil) }
}
