import AppKit
import SwiftUI

/// The floating Drive Ejector popover: a live list of external volumes with capacity and free
/// space, a per-volume eject button, an Eject All action, and an inline status line that reports
/// refusals verbatim. Content is scaled to match the menu-bar/display scale so it fits the scaled
/// panel (same approach as the other tools).
public struct DriveEjectorPopoverView: View {
    @ObservedObject var controller: DriveEjectorController
    var onQuit: () -> Void

    @State private var isShowingSettings = false
    private let scale = DriveEjectorSizing.currentScale

    public init(controller: DriveEjectorController, onQuit: @escaping () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    private var accent: Color { .teal }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)

                if controller.volumes.isEmpty {
                    emptyState
                } else {
                    volumeList
                }

                Spacer(minLength: 0)

                if let status = controller.statusMessage {
                    statusLine(status)
                }

                ejectAllRow
                footer
            }

            if isShowingSettings {
                PreferencesOverlay(cornerRadius: 18) {
                    DriveEjectorSettingsView(
                        controller: controller,
                        onQuit: onQuit,
                        onClose: { isShowingSettings = false }
                    )
                }
            }
        }
        .frame(width: DriveEjectorSizing.preferredSize().width, height: DriveEjectorSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: "eject.fill")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(controller.volumes.isEmpty ? Color.secondary : accent)

            Text("Drive Ejector")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(.primary.opacity(0.9))

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: s(14), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(14))
        .padding(.bottom, s(10))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: s(10)) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: s(34), weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            Text("No ejectable volumes")
                .font(.system(size: s(14), weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Only external, removable disks appear here. Your startup disk and internal drives are never listed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, s(24))
        .padding(.vertical, s(34))
    }

    // MARK: - Volume list

    private var volumeList: some View {
        ScrollView {
            VStack(spacing: s(8)) {
                ForEach(controller.volumes) { volume in
                    volumeRow(volume)
                }
            }
            .padding(.horizontal, s(16))
            .padding(.vertical, s(12))
        }
    }

    private func volumeRow(_ volume: VolumeDescriptor) -> some View {
        let isBusy = controller.busyVolumeIDs.contains(volume.id)

        return HStack(spacing: s(10)) {
            VolumeIcon(url: volume.url, size: s(30))

            VStack(alignment: .leading, spacing: s(2)) {
                Text(volume.name)
                    .font(.system(size: s(13), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(capacityLine(volume))
                    .font(.system(size: s(11), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: s(6))

            Button {
                controller.eject(volume)
            } label: {
                Image(systemName: "eject.fill")
                    .font(.system(size: s(13), weight: .semibold))
                    .foregroundStyle(isBusy ? Color.secondary : accent)
                    .frame(width: s(30), height: s(26))
                    .background(
                        RoundedRectangle(cornerRadius: s(7), style: .continuous)
                            .fill((isBusy ? Color.secondary : accent).opacity(0.16))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: s(7), style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help(isBusy ? "Ejecting…" : "Eject “\(volume.name)”")
        }
        .padding(.horizontal, s(10))
        .padding(.vertical, s(8))
        .background(
            RoundedRectangle(cornerRadius: s(10), style: .continuous)
                .fill(Color.secondary.opacity(isBusy ? 0.06 : 0.12))
        )
        .opacity(isBusy ? 0.6 : 1)
    }

    /// "128GB free of 500GB" — or just the total when the volume declines to report capacity,
    /// which beats printing a confident "0B free".
    private func capacityLine(_ volume: VolumeDescriptor) -> String {
        guard volume.totalBytes > 0 else {
            return "Capacity unavailable"
        }
        return "\(volume.freeBytes.compactBytesString) free of \(volume.totalBytes.compactBytesString)"
    }

    // MARK: - Status

    private func statusLine(_ status: String) -> some View {
        Text(status)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, s(16))
            .padding(.bottom, s(8))
    }

    // MARK: - Eject All

    @ViewBuilder
    private var ejectAllRow: some View {
        if controller.isConfirmingEjectAll {
            HStack(spacing: s(8)) {
                Button {
                    controller.confirmEjectAll()
                } label: {
                    Text("Eject \(controller.volumes.count) Volume\(controller.volumes.count == 1 ? "" : "s")")
                        .font(.system(size: s(12), weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: s(32))
                        .background(
                            RoundedRectangle(cornerRadius: s(8), style: .continuous)
                                .fill(accent)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    controller.cancelEjectAll()
                } label: {
                    Text("Cancel")
                        .font(.system(size: s(12), weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: s(80))
                        .frame(height: s(32))
                        .background(
                            RoundedRectangle(cornerRadius: s(8), style: .continuous)
                                .fill(Color.secondary.opacity(0.14))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, s(16))
            .padding(.bottom, s(8))
        } else if !controller.volumes.isEmpty {
            Button {
                controller.requestEjectAll()
            } label: {
                HStack(spacing: s(8)) {
                    Image(systemName: "eject.circle.fill")
                        .font(.system(size: s(13), weight: .semibold))
                    Text("Eject All")
                        .font(.system(size: s(13), weight: .semibold))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: s(34))
                .background(
                    RoundedRectangle(cornerRadius: s(8), style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )
                .contentShape(RoundedRectangle(cornerRadius: s(8), style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, s(16))
            .padding(.bottom, s(8))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                controller.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: s(12), weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                onQuit()
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: s(12), weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(4))
        .padding(.bottom, s(14))
    }
}

/// The Finder icon for a mount point, which is what users actually recognise a disk by — a
/// branded external SSD, a camera card, a mounted disk image all look different here.
private struct VolumeIcon: View {
    var url: URL
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}

// MARK: - Settings

private struct DriveEjectorSettingsView: View {
    @ObservedObject var controller: DriveEjectorController
    var onQuit: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Drive Ejector Settings")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            settingRow(title: "Confirm before Eject All") {
                GreenSwitch(isOn: Binding(
                    get: { controller.confirmsEjectAll },
                    set: { controller.setConfirmsEjectAll($0) }
                ))
            }

            Text("When on, Eject All asks for a second press before unmounting every listed volume.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Only external, removable volumes are ever listed. Your startup disk and internal drives are excluded, and every volume is re-checked the moment before it is ejected. Nothing here force-unmounts: if a file is open or Spotlight is still indexing, the disk stays mounted and the reason is shown.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(role: .destructive) {
                onClose()
                onQuit()
            } label: {
                Label("Quit Drive Ejector", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: DriveEjectorSizing.settingsSize().width, height: DriveEjectorSizing.settingsSize().height)
    }

    private func settingRow<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            trailing()
        }
    }
}
