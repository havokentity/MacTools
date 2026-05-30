import SwiftUI

/// Controller that owns the mutable state of the Maintenance popover: the live
/// value of each toggle, which action is currently running, and the transient
/// status line shown after an operation completes.
///
/// All published state lives on the main actor. Shell/admin work runs in
/// `Task.detached` and hops back here to publish results.
@MainActor
public final class MaintenanceController: ObservableObject {

    /// Current on/off state for each toggle, keyed by toggle id.
    @Published public private(set) var toggleStates: [String: Bool] = [:]

    /// Id of the action/toggle currently running (nil = idle).
    @Published public private(set) var runningID: String?

    /// Transient result line shown beneath the title.
    @Published public private(set) var statusMessage: String = "Ready"

    /// Whether the most recent operation failed (drives the status colour).
    @Published public private(set) var statusIsError: Bool = false

    public init() {}

    /// Reads the live state of every toggle from `defaults`. Called on appear.
    public func refreshToggles() {
        Task.detached {
            var states: [String: Bool] = [:]
            for section in MaintenanceKit.sections {
                for toggle in section.toggles {
                    let value = MaintenanceKit.readDefaultsBool(domain: toggle.domain, key: toggle.key)
                    states[toggle.id] = value
                }
            }
            let resolved = states
            await MainActor.run {
                self.toggleStates = resolved
            }
        }
    }

    public func isOn(_ toggle: MaintenanceKit.MaintenanceToggle) -> Bool {
        toggleStates[toggle.id] ?? false
    }

    /// Flips a toggle: optimistically updates the UI, writes the new value, and
    /// restarts the associated process if needed.
    public func setToggle(_ toggle: MaintenanceKit.MaintenanceToggle, to newValue: Bool) {
        guard runningID == nil else { return }
        toggleStates[toggle.id] = newValue          // optimistic
        runningID = toggle.id
        setStatus("Updating \u{201C}\(toggle.title)\u{201D}\u{2026}", isError: false)

        Task.detached {
            let wrote = MaintenanceKit.writeDefaultsBool(domain: toggle.domain, key: toggle.key, value: newValue)
            if wrote, let process = toggle.restartProcess {
                _ = MaintenanceKit.killall(process)
            }

            await MainActor.run {
                self.runningID = nil
                if wrote {
                    self.setStatus("\(toggle.title): \(newValue ? "On" : "Off")", isError: false)
                } else {
                    // Revert optimistic change on failure.
                    self.toggleStates[toggle.id] = !newValue
                    self.setStatus("Could not update \(toggle.title).", isError: true)
                }
            }
        }
    }

    /// Performs a one-shot action.
    public func run(_ action: MaintenanceKit.MaintenanceAction) {
        guard runningID == nil else { return }
        runningID = action.id
        setStatus(action.isSlow ? "\(action.title)\u{2026} this can take a moment" : "\(action.title)\u{2026}",
                  isError: false)

        Task.detached {
            let result = Self.perform(action)
            await MainActor.run {
                self.runningID = nil
                self.setStatus(result.message, isError: !result.success)
            }
        }
    }

    /// Executes an action off the main actor. Pure dispatch over the action kind.
    nonisolated private static func perform(_ action: MaintenanceKit.MaintenanceAction) -> (success: Bool, message: String) {
        switch action.kind {
        case .killall(let process):
            _ = MaintenanceKit.killall(process)
            // killall returns non-zero when the process wasn't running; treat
            // that as success since the end state ("not running / relaunched")
            // is what the user asked for.
            return (true, "\(action.title.replacingOccurrences(of: "Restart ", with: "")) restarted.")

        case .admin(let command):
            let res = MaintenanceKit.runAdminScript(command)
            if res.success {
                return (true, "DNS cache flushed.")
            } else if res.message == "Cancelled." {
                return (false, "Cancelled.")
            } else {
                return (false, res.message)
            }

        case .lsregister:
            guard let path = MaintenanceKit.lsregisterPath() else {
                return (false, "Could not find lsregister on this system.")
            }
            let res = MaintenanceKit.runShell(path,
                ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
            if res.status == 0 {
                return (true, "Launch Services rebuilt. \u{201C}Open With\u{201D} reset.")
            } else {
                let detail = res.output.isEmpty ? "exit code \(res.status)" : res.output
                return (false, "Rebuild failed: \(detail)")
            }

        case .openPath(let path):
            let res = MaintenanceKit.runShell("/usr/bin/open", [path])
            if res.status == 0 {
                return (true, "Opened in Finder.")
            } else {
                return (false, "Could not open \(path).")
            }
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}

// MARK: - View

/// The Maintenance popover. Data-driven from `MaintenanceKit.sections`.
public struct MaintenancePopoverView: View {

    @StateObject private var controller = MaintenanceController()
    private let onQuit: () -> Void

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MaintenanceSizing.sectionSpacing) {
            header

            ForEach(MaintenanceKit.sections) { section in
                sectionView(section)
            }

            footer
        }
        .padding(.horizontal, MaintenanceSizing.horizontalPadding)
        .padding(.vertical, MaintenanceSizing.verticalPadding)
        .frame(width: MaintenanceSizing.popoverWidth)
        .frostedPanel(cornerRadius: MaintenanceSizing.s(18))
        .onAppear { controller.refreshToggles() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: MaintenanceSizing.s(10)) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: MaintenanceSizing.s(18), weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: MaintenanceSizing.s(2)) {
                Text("Maintenance")
                    .font(.system(size: MaintenanceSizing.s(15), weight: .semibold))
                statusLine
            }
            Spacer()
            if controller.runningID != nil {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(MaintenanceSizing.currentScale)
            }
        }
    }

    private var statusLine: some View {
        Text(controller.statusMessage)
            .font(.system(size: MaintenanceSizing.s(11)))
            .foregroundStyle(controller.statusIsError ? Color.red : Color.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeInOut(duration: 0.15), value: controller.statusMessage)
    }

    private func sectionView(_ section: MaintenanceKit.MaintenanceSection) -> some View {
        VStack(alignment: .leading, spacing: MaintenanceSizing.rowSpacing) {
            Text(section.title.uppercased())
                .font(.system(size: MaintenanceSizing.s(10), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)

            VStack(spacing: 0) {
                ForEach(Array(section.toggles.enumerated()), id: \.element.id) { index, toggle in
                    if index > 0 { rowDivider }
                    toggleRow(toggle)
                }
                if !section.toggles.isEmpty && !section.actions.isEmpty {
                    rowDivider
                }
                ForEach(Array(section.actions.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { rowDivider }
                    actionRow(action)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: MaintenanceSizing.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MaintenanceSizing.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var rowDivider: some View {
        Divider().opacity(0.4)
            .padding(.leading, MaintenanceSizing.s(12))
    }

    // MARK: Rows

    private func toggleRow(_ toggle: MaintenanceKit.MaintenanceToggle) -> some View {
        let binding = Binding<Bool>(
            get: { controller.isOn(toggle) },
            set: { controller.setToggle(toggle, to: $0) }
        )
        return HStack(spacing: MaintenanceSizing.s(10)) {
            rowText(title: toggle.title, subtitle: toggle.subtitle)
            Spacer(minLength: MaintenanceSizing.s(8))
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.green)
                .disabled(controller.runningID != nil)
        }
        .padding(.horizontal, MaintenanceSizing.s(12))
        .padding(.vertical, MaintenanceSizing.s(9))
    }

    private func actionRow(_ action: MaintenanceKit.MaintenanceAction) -> some View {
        let isRunning = controller.runningID == action.id
        return HStack(spacing: MaintenanceSizing.s(10)) {
            rowText(title: action.title, subtitle: action.subtitle)
            Spacer(minLength: MaintenanceSizing.s(8))
            Button {
                controller.run(action)
            } label: {
                HStack(spacing: MaintenanceSizing.s(5)) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isRunning ? "Working\u{2026}" : action.buttonLabel)
                        .font(.system(size: MaintenanceSizing.s(12), weight: .medium))
                }
                .frame(minWidth: MaintenanceSizing.s(64))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.runningID != nil)
        }
        .padding(.horizontal, MaintenanceSizing.s(12))
        .padding(.vertical, MaintenanceSizing.s(9))
    }

    private func rowText(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: MaintenanceSizing.s(1)) {
            Text(title)
                .font(.system(size: MaintenanceSizing.s(13), weight: .medium))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: MaintenanceSizing.s(10.5)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit", action: onQuit)
                .buttonStyle(.borderless)
                .font(.system(size: MaintenanceSizing.s(11)))
                .foregroundStyle(.secondary)
        }
    }
}
