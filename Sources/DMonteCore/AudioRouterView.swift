import AppKit
import CoreAudio
import SwiftUI

/// A `Sendable` box owning the CoreAudio device-list listener registration, so it
/// can be torn down from the controller's nonisolated `deinit` without touching
/// actor-isolated state. (Mirrors the equivalent helper in `AudioSwitcherView`;
/// each tool keeps its own private copy — there is no shared symbol.)
private final class RouterDevicesListenerRegistration: @unchecked Sendable {
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init?(onChange: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        guard status == noErr else { return nil }
        self.block = block
        self.installed = true
    }

    func remove() {
        guard installed else { return }
        installed = false
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }
}

/// Drives the Audio Router popover: enumerates the tool's own virtual devices and
/// the hardware available to bundle, builds new aggregate / multi-output devices,
/// and persists routing presets. Refreshes live when audio hardware changes.
@MainActor
public final class AudioRouterController: ObservableObject {
    @Published public private(set) var routerDevices: [AudioDevice] = []
    @Published public private(set) var availableSubDevices: [AudioDevice] = []
    @Published public private(set) var presets: [RouterPreset] = []
    /// One bundled virtual cable plus its current installed/busy state.
    public struct CableRow: Identifiable, Sendable, Equatable {
        public let cable: LoopbackDriverInstaller.LoopbackCable
        public var isInstalled: Bool
        public var isBusy: Bool
        public var id: String { cable.id }
    }

    @Published public private(set) var cables: [CableRow] = []
    /// Whether this build bundles any cables to install.
    @Published public private(set) var canManageCables: Bool = false
    private var busyCableIDs: Set<String> = []

    /// Builder state.
    @Published public var mode: AudioRouterKit.RouterMode = .multiOutput {
        didSet { refreshSubDevices() }
    }
    @Published public var newDeviceName: String = ""
    @Published public var selectedSubUIDs: Set<String> = []

    /// One live input→output monitor ("listen to this device").
    public struct ActiveMonitor: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let inputUID: String
        public let inputName: String
        public let outputUID: String
        public let outputName: String
        public var gain: Float
    }

    @Published public private(set) var activeMonitors: [ActiveMonitor] = []
    /// Input-capable devices to monitor (mics, line-in, loopback cables).
    @Published public private(set) var monitorInputs: [AudioDevice] = []
    /// Output-capable devices to listen through.
    @Published public private(set) var monitorOutputs: [AudioDevice] = []
    /// Monitor builder selection.
    @Published public var selectedMonitorInputUID: String?
    @Published public var selectedMonitorOutputUID: String?
    @Published public var newMonitorGain: Float = 1
    private var monitorEngines: [UUID: AudioMonitorEngine] = [:]

    /// Transient status line shown under the builder (success or failure).
    @Published public var statusMessage: String?

    private let defaults: UserDefaults
    private let listener: RouterDevicesListenerRegistration?

    public init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
        listener = RouterDevicesListenerRegistration {
            Task { @MainActor in AudioRouterController.activeController?.refresh() }
        }
        AudioRouterController.activeController = self
        refresh()
    }

    deinit {
        listener?.remove()
    }

    @MainActor private static weak var activeController: AudioRouterController?

    /// Whether the current builder state can produce a device.
    public var canCreate: Bool {
        !newDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedSubUIDs.isEmpty
    }

    public func refresh() {
        routerDevices = AudioRouterKit.routerDevices()
        let bundled = LoopbackDriverInstaller.bundledCables()
        canManageCables = !bundled.isEmpty
        cables = bundled.map { cable in
            CableRow(
                cable: cable,
                isInstalled: LoopbackDriverInstaller.isInstalled(cable),
                isBusy: busyCableIDs.contains(cable.id)
            )
        }
        presets = RouterPresetStore.load(defaults: defaults)
        refreshSubDevices()
        refreshMonitorDevices()
    }

    private func refreshMonitorDevices() {
        let devices = AudioSwitcherKit.devices().filter { !$0.uid.isEmpty }
        monitorInputs = devices.filter(\.hasInput)
        monitorOutputs = devices.filter(\.hasOutput)
        // Drop selections that vanished.
        if let input = selectedMonitorInputUID, !monitorInputs.contains(where: { $0.uid == input }) {
            selectedMonitorInputUID = nil
        }
        if let output = selectedMonitorOutputUID, !monitorOutputs.contains(where: { $0.uid == output }) {
            selectedMonitorOutputUID = nil
        }
        // Reflect any engines that stopped themselves (e.g. device unplugged).
        activeMonitors = activeMonitors.filter { monitorEngines[$0.id]?.isRunning == true }
    }

    /// Installs or removes a virtual cable (admin prompt). Runs the privileged,
    /// blocking work off the main actor and refreshes when done.
    public func setCable(_ cable: LoopbackDriverInstaller.LoopbackCable, installed: Bool) {
        guard !busyCableIDs.contains(cable.id) else { return }
        busyCableIDs.insert(cable.id)
        statusMessage = "\(installed ? "Installing" : "Removing") \(cable.displayName)…"
        refresh()
        Task { [weak self] in
            let outcome: Result<Void, Error> = await Task.detached {
                do {
                    if installed {
                        try LoopbackDriverInstaller.install(cable)
                    } else {
                        try LoopbackDriverInstaller.uninstall(cable)
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                guard let self else { return }
                self.busyCableIDs.remove(cable.id)
                switch outcome {
                case .success:
                    self.statusMessage = "\(cable.displayName) \(installed ? "installed" : "removed")"
                case .failure(let error):
                    self.statusMessage = (error as? LoopbackDriverInstaller.InstallError)?.message
                        ?? error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    // MARK: - Input monitors ("listen to this device")

    /// Whether the current monitor selection can be started.
    public var canAddMonitor: Bool {
        guard let input = selectedMonitorInputUID, let output = selectedMonitorOutputUID else {
            return false
        }
        // Don't allow a pointless input==output loop.
        return input != output
    }

    /// Starts a new input→output monitor. Requests microphone permission first
    /// (capturing an input device requires it).
    public func addMonitor() {
        guard canAddMonitor,
              let inputUID = selectedMonitorInputUID,
              let outputUID = selectedMonitorOutputUID,
              let input = monitorInputs.first(where: { $0.uid == inputUID }),
              let output = monitorOutputs.first(where: { $0.uid == outputUID }) else {
            return
        }
        let gain = newMonitorGain
        Task { [weak self] in
            let granted = await AudioMonitorPermission.ensureMicrophoneAccess()
            guard let self else { return }
            guard granted else {
                self.statusMessage = "Microphone access is needed to listen to an input"
                return
            }
            let engine = AudioMonitorEngine()
            do {
                try engine.start(inputUID: inputUID, outputUID: outputUID, gain: gain)
                let monitor = ActiveMonitor(
                    id: UUID(),
                    inputUID: inputUID,
                    inputName: input.name,
                    outputUID: outputUID,
                    outputName: output.name,
                    gain: gain
                )
                self.monitorEngines[monitor.id] = engine
                self.activeMonitors.append(monitor)
                self.statusMessage = "Listening: \(input.name) → \(output.name)"
            } catch {
                self.statusMessage = (error as? AudioMonitorError)?.message ?? error.localizedDescription
            }
        }
    }

    public func removeMonitor(_ monitor: ActiveMonitor) {
        monitorEngines[monitor.id]?.stop()
        monitorEngines.removeValue(forKey: monitor.id)
        activeMonitors.removeAll { $0.id == monitor.id }
    }

    public func setMonitorGain(_ gain: Float, for monitor: ActiveMonitor) {
        monitorEngines[monitor.id]?.setGain(gain)
        if let index = activeMonitors.firstIndex(where: { $0.id == monitor.id }) {
            activeMonitors[index].gain = gain
        }
    }

    /// Stops every running monitor (call on teardown).
    public func stopAllMonitors() {
        for engine in monitorEngines.values { engine.stop() }
        monitorEngines.removeAll()
        activeMonitors.removeAll()
    }

    private func refreshSubDevices() {
        let available = AudioRouterKit.availableSubDevices(matching: mode)
        availableSubDevices = available
        // Drop any selections that are no longer valid for the current mode.
        let validUIDs = Set(available.map(\.uid))
        selectedSubUIDs.formIntersection(validUIDs)
    }

    public func toggleSubDevice(_ uid: String) {
        if selectedSubUIDs.contains(uid) {
            selectedSubUIDs.remove(uid)
        } else {
            selectedSubUIDs.insert(uid)
        }
    }

    public func isSelected(_ uid: String) -> Bool {
        selectedSubUIDs.contains(uid)
    }

    /// Builds a device from the current builder state.
    public func createDevice() {
        // Preserve the on-screen order of sub-devices rather than the set's order.
        let orderedUIDs = availableSubDevices.map(\.uid).filter { selectedSubUIDs.contains($0) }
        let spec = AudioRouterKit.RouterDeviceSpec(
            name: newDeviceName.trimmingCharacters(in: .whitespacesAndNewlines),
            uid: AudioRouterKit.makeUID(),
            mode: mode,
            subDeviceUIDs: orderedUIDs
        )
        switch AudioRouterKit.createDevice(spec) {
        case .success:
            statusMessage = "Created “\(spec.name)”"
            newDeviceName = ""
            selectedSubUIDs.removeAll()
            refresh()
        case .failure(let error):
            statusMessage = message(for: error)
        }
    }

    public func destroy(_ device: AudioDevice) {
        if AudioRouterKit.destroyDevice(uid: device.uid) {
            statusMessage = "Removed “\(device.name)”"
        } else {
            statusMessage = "Couldn’t remove “\(device.name)”"
        }
        refresh()
    }

    /// Saves the current builder state as a reusable preset.
    public func saveCurrentAsPreset() {
        guard canCreate else { return }
        let orderedUIDs = availableSubDevices.map(\.uid).filter { selectedSubUIDs.contains($0) }
        let preset = RouterPreset(
            name: newDeviceName.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            subDeviceUIDs: orderedUIDs
        )
        RouterPresetStore.upsert(preset, defaults: defaults)
        statusMessage = "Saved preset “\(preset.name)”"
        refresh()
    }

    /// Creates a device from a saved preset.
    public func applyPreset(_ preset: RouterPreset) {
        switch AudioRouterKit.createDevice(preset.makeSpec()) {
        case .success:
            statusMessage = "Created “\(preset.name)”"
            refresh()
        case .failure(let error):
            statusMessage = message(for: error)
        }
    }

    public func deletePreset(_ preset: RouterPreset) {
        RouterPresetStore.remove(id: preset.id, defaults: defaults)
        refresh()
    }

    private func message(for error: AudioRouterKit.RouterError) -> String {
        switch error {
        case .emptyName: return "Give the device a name first"
        case .noSubDevices: return "Pick at least one device to route"
        case .coreAudio(let status): return "CoreAudio error \(status)"
        }
    }
}

public struct AudioRouterPopoverView: View {
    @ObservedObject private var controller: AudioRouterController
    private let onQuit: () -> Void

    public init(controller: AudioRouterController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AudioRouterSizing.sectionSpacing) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AudioRouterSizing.sectionSpacing) {
                    cablesSection
                    builderSection
                    monitorSection
                    routerDevicesSection
                    presetsSection
                }
            }
            .frame(maxHeight: AudioRouterSizing.scrollMaxHeight)
            Divider()
            footer
        }
        .padding(AudioRouterSizing.outerPadding)
        .frame(width: AudioRouterSizing.panelWidth, height: AudioRouterSizing.panelHeight)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: AudioRouterSizing.titleSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Audio Router")
                .font(.system(size: AudioRouterSizing.titleSize, weight: .semibold))
                .foregroundStyle(Color.primary)
            Spacer()
            Button(action: { controller.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AudioRouterSizing.bodySize, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh devices")
        }
    }

    // MARK: - Virtual cables

    private var cablesSection: some View {
        VStack(alignment: .leading, spacing: AudioRouterSizing.rowSpacing) {
            sectionHeader("VIRTUAL CABLES")
            Text("Independent cables to route one app's audio into another (e.g. Audacity → Discord). Install a separate cable per app pair so they stay isolated.")
                .font(.system(size: AudioRouterSizing.captionSize))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !controller.canManageCables {
                Text("This build has no bundled cables — install BlackHole manually to route between apps.")
                    .font(.system(size: AudioRouterSizing.captionSize))
                    .foregroundStyle(Color.secondary)
                    .padding(.top, 2)
            } else {
                ForEach(controller.cables) { row in
                    cableRow(row)
                }
            }
        }
    }

    private func cableRow(_ row: AudioRouterController.CableRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cable.connector.horizontal")
                .foregroundStyle(row.isInstalled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.cable.displayName)
                    .font(.system(size: AudioRouterSizing.bodySize, weight: row.isInstalled ? .semibold : .regular))
                    .lineLimit(1)
                Text(row.isInstalled ? "Installed · appears as “\(row.cable.deviceName)”" : "Not installed")
                    .font(.system(size: AudioRouterSizing.captionSize))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if row.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: { controller.setCable(row.cable, installed: !row.isInstalled) }) {
                    Text(row.isInstalled ? "Remove" : "Install")
                        .font(.system(size: AudioRouterSizing.bodySize, weight: .medium))
                        .foregroundStyle(row.isInstalled ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(row.isInstalled
                    ? "Remove this cable from /Library/Audio/Plug-Ins/HAL (requires admin)"
                    : "Install this cable to /Library/Audio/Plug-Ins/HAL (requires admin)")
            }
        }
        .padding(.vertical, AudioRouterSizing.rowVerticalPadding)
        .padding(.horizontal, AudioRouterSizing.rowHorizontalPadding)
        .frame(minHeight: AudioRouterSizing.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isSelected: row.isInstalled))
    }

    // MARK: - Builder

    private var builderSection: some View {
        VStack(alignment: .leading, spacing: AudioRouterSizing.rowSpacing) {
            sectionHeader("NEW ROUTING DEVICE")

            Picker("", selection: $controller.mode) {
                Text("Mirror output").tag(AudioRouterKit.RouterMode.multiOutput)
                Text("Combine inputs").tag(AudioRouterKit.RouterMode.aggregate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Device name", text: $controller.newDeviceName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AudioRouterSizing.bodySize))

            if controller.availableSubDevices.isEmpty {
                emptyRow("No devices available")
            } else {
                ForEach(controller.availableSubDevices) { device in
                    subDeviceRow(device)
                }
            }

            HStack(spacing: 8) {
                Button(action: { controller.createDevice() }) {
                    Text("Create")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canCreate)

                Button(action: { controller.saveCurrentAsPreset() }) {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.bordered)
                .disabled(!controller.canCreate)
                .help("Save as preset")
            }
            .font(.system(size: AudioRouterSizing.bodySize, weight: .medium))

            if let status = controller.statusMessage {
                Text(status)
                    .font(.system(size: AudioRouterSizing.captionSize))
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private func subDeviceRow(_ device: AudioDevice) -> some View {
        let selected = controller.isSelected(device.uid)
        return Button(action: { controller.toggleSubDevice(device.uid) }) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: AudioRouterSizing.checkmarkSize, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(device.name)
                    .font(.system(size: AudioRouterSizing.bodySize, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if device.name.localizedCaseInsensitiveContains(AudioRouterKit.loopbackDriverName) {
                    Text("loopback")
                        .font(.system(size: AudioRouterSizing.captionSize, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, AudioRouterSizing.rowVerticalPadding)
            .padding(.horizontal, AudioRouterSizing.rowHorizontalPadding)
            .frame(minHeight: AudioRouterSizing.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isSelected: selected))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input monitors

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: AudioRouterSizing.rowSpacing) {
            sectionHeader("LISTEN TO AN INPUT")
            Text("Play an input device (mic, line-in, or a cable) through an output so you can hear it — like Windows' “Listen to this device”.")
                .font(.system(size: AudioRouterSizing.captionSize))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if monitorInputs.isEmpty || monitorOutputs.isEmpty {
                emptyRow("Need at least one input and one output device")
            } else {
                monitorBuilder
            }

            ForEach(controller.activeMonitors) { monitor in
                monitorRow(monitor)
            }
        }
    }

    private var monitorInputs: [AudioDevice] { controller.monitorInputs }
    private var monitorOutputs: [AudioDevice] { controller.monitorOutputs }

    private var monitorBuilder: some View {
        VStack(alignment: .leading, spacing: AudioRouterSizing.rowSpacing) {
            HStack(spacing: 8) {
                Picker("", selection: $controller.selectedMonitorInputUID) {
                    Text("Input…").tag(String?.none)
                    ForEach(monitorInputs) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
                Image(systemName: "arrow.right")
                    .font(.system(size: AudioRouterSizing.captionSize))
                    .foregroundStyle(Color.secondary)
                Picker("", selection: $controller.selectedMonitorOutputUID) {
                    Text("Output…").tag(String?.none)
                    ForEach(monitorOutputs) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
            }
            .font(.system(size: AudioRouterSizing.bodySize))

            Button(action: { controller.addMonitor() }) {
                Text("Listen")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!controller.canAddMonitor)
        }
    }

    private func monitorRow(_ monitor: AudioRouterController.ActiveMonitor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "ear")
                    .foregroundStyle(Color.accentColor)
                Text("\(monitor.inputName) → \(monitor.outputName)")
                    .font(.system(size: AudioRouterSizing.bodySize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: { controller.removeMonitor(monitor) }) {
                    Image(systemName: "stop.circle")
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
                .help("Stop listening")
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: AudioRouterSizing.captionSize))
                    .foregroundStyle(Color.secondary)
                Slider(
                    value: Binding(
                        get: { monitor.gain },
                        set: { controller.setMonitorGain($0, for: monitor) }
                    ),
                    in: 0...1
                )
                Text("\(Int((monitor.gain * 100).rounded()))%")
                    .font(.system(size: AudioRouterSizing.captionSize).monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(.vertical, AudioRouterSizing.rowVerticalPadding)
        .padding(.horizontal, AudioRouterSizing.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isSelected: true))
    }

    // MARK: - Router devices

    private var routerDevicesSection: some View {
        VStack(alignment: .leading, spacing: AudioRouterSizing.rowSpacing) {
            sectionHeader("YOUR ROUTING DEVICES")
            if controller.routerDevices.isEmpty {
                emptyRow("None yet — create one above")
            } else {
                ForEach(controller.routerDevices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(Color.secondary)
                        Text(device.name)
                            .font(.system(size: AudioRouterSizing.bodySize))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button(action: { controller.destroy(device) }) {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.red)
                        }
                        .buttonStyle(.plain)
                        .help("Remove device")
                    }
                    .padding(.vertical, AudioRouterSizing.rowVerticalPadding)
                    .padding(.horizontal, AudioRouterSizing.rowHorizontalPadding)
                    .frame(minHeight: AudioRouterSizing.rowMinHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(rowBackground(isSelected: false))
                }
            }
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: AudioRouterSizing.rowSpacing) {
            sectionHeader("PRESETS")
            if controller.presets.isEmpty {
                emptyRow("Save a configuration to reuse it")
            } else {
                ForEach(controller.presets) { preset in
                    HStack(spacing: 8) {
                        Image(systemName: preset.mode == .multiOutput ? "speaker.wave.2" : "mic")
                            .foregroundStyle(Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                                .font(.system(size: AudioRouterSizing.bodySize))
                                .lineLimit(1)
                            Text("\(preset.subDeviceUIDs.count) device\(preset.subDeviceUIDs.count == 1 ? "" : "s")")
                                .font(.system(size: AudioRouterSizing.captionSize))
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(action: { controller.applyPreset(preset) }) {
                            Image(systemName: "play.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Create device from preset")
                        Button(action: { controller.deletePreset(preset) }) {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete preset")
                    }
                    .padding(.vertical, AudioRouterSizing.rowVerticalPadding)
                    .padding(.horizontal, AudioRouterSizing.rowHorizontalPadding)
                    .frame(minHeight: AudioRouterSizing.rowMinHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(rowBackground(isSelected: false))
                }
            }
        }
    }

    // MARK: - Shared builders

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AudioRouterSizing.sectionHeaderSize, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .kerning(0.5)
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: AudioRouterSizing.bodySize))
            .foregroundStyle(Color.secondary)
            .padding(.vertical, AudioRouterSizing.rowVerticalPadding)
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: AudioRouterSizing.rowCornerRadius, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Text("\(controller.routerDevices.count) device\(controller.routerDevices.count == 1 ? "" : "s")")
                .font(.system(size: AudioRouterSizing.captionSize))
                .foregroundStyle(Color.secondary)
            Spacer()
            Button(action: onQuit) {
                Text("Quit")
                    .font(.system(size: AudioRouterSizing.bodySize, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Audio Router")
        }
    }
}
