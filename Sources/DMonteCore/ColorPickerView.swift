import AppKit
import SwiftUI

/// The floating Color Picker popover: a system eyedropper, a large swatch, copyable
/// value rows (HEX, HEX+alpha, RGB, HSL, SwiftUI literal), a hex input field, and an
/// in-memory strip of recently picked colours. Content is scaled to match the
/// menu-bar/display scale so it fits the scaled panel (same approach as the other tools).
public struct ColorPickerPopoverView: View {
    var onQuit: () -> Void

    @State private var color: NSColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    @State private var hexInput: String = "#FF0000"
    @State private var recents: [NSColor] = []
    @State private var copiedRow: String?

    private let scale = ColorPickerSizing.currentScale

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    public var body: some View {
        VStack(spacing: 0) {
            header
            swatch
            valueRows
            hexField
            recentsStrip
            Spacer(minLength: 0)
            footer
        }
        .frame(width: ColorPickerSizing.preferredSize().width, height: ColorPickerSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: "eyedropper.halffull")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text("Color Picker")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.9))

            Spacer()

            Button(action: pickColor) {
                HStack(spacing: s(5)) {
                    Image(systemName: "eyedropper")
                        .font(.system(size: s(11), weight: .bold))
                    Text("Pick")
                        .font(.system(size: s(12), weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, s(10))
                .padding(.vertical, s(5))
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .help("Pick a colour from anywhere on screen")
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(14))
        .padding(.bottom, s(10))
    }

    // MARK: - Swatch

    private var swatch: some View {
        RoundedRectangle(cornerRadius: s(12), style: .continuous)
            .fill(Color(nsColor: color))
            .frame(height: s(96))
            .overlay {
                RoundedRectangle(cornerRadius: s(12), style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .padding(.horizontal, s(16))
            .padding(.bottom, s(12))
    }

    // MARK: - Value rows

    private var valueRows: some View {
        VStack(spacing: s(6)) {
            valueRow(label: "HEX", value: ColorKit.hexString(color, includeAlpha: false))
            valueRow(label: "HEXA", value: ColorKit.hexString(color, includeAlpha: true))
            valueRow(label: "RGB", value: ColorKit.rgbString(color))
            valueRow(label: "HSL", value: ColorKit.hslString(color))
            valueRow(label: "Swift", value: ColorKit.swiftUILiteral(color))
        }
        .padding(.horizontal, s(16))
        .padding(.bottom, s(12))
    }

    private func valueRow(label: String, value: String) -> some View {
        HStack(spacing: s(8)) {
            Text(label)
                .font(.system(size: s(9), weight: .bold))
                .foregroundStyle(Color.secondary)
                .frame(width: s(40), alignment: .leading)

            Text(value)
                .font(.system(size: s(11.5), design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Button {
                copy(value, rowID: label)
            } label: {
                Image(systemName: copiedRow == label ? "checkmark" : "doc.on.doc")
                    .font(.system(size: s(11), weight: .semibold))
                    .foregroundStyle(copiedRow == label ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy \(label)")
        }
        .padding(.horizontal, s(10))
        .frame(height: s(28))
        .background(
            RoundedRectangle(cornerRadius: s(7), style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    // MARK: - Hex field

    private var hexField: some View {
        HStack(spacing: s(7)) {
            Image(systemName: "number")
                .font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(Color.secondary)

            TextField("Enter hex (e.g. #1E90FF)", text: $hexInput)
                .textFieldStyle(.plain)
                .font(.system(size: s(13), design: .monospaced))
                .onSubmit { applyHexInput() }
                .onChange(of: hexInput) { _, newValue in
                    applyHex(newValue)
                }

            if let parsed = ColorKit.color(fromHex: hexInput) {
                Circle()
                    .fill(Color(nsColor: parsed))
                    .frame(width: s(16), height: s(16))
                    .overlay {
                        Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    }
            } else if !hexInput.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: s(11)))
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(.horizontal, s(10))
        .frame(height: s(32))
        .background(
            RoundedRectangle(cornerRadius: s(8), style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .padding(.horizontal, s(16))
        .padding(.bottom, s(12))
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentsStrip: some View {
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: s(6)) {
                Text("RECENT")
                    .font(.system(size: s(9), weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, s(16))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: s(6)) {
                        ForEach(Array(recents.enumerated()), id: \.offset) { _, recent in
                            Button {
                                select(recent)
                            } label: {
                                RoundedRectangle(cornerRadius: s(6), style: .continuous)
                                    .fill(Color(nsColor: recent))
                                    .frame(width: s(26), height: s(26))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: s(6), style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(ColorKit.hexString(recent, includeAlpha: false))
                        }
                    }
                    .padding(.horizontal, s(16))
                }
            }
            .padding(.bottom, s(10))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onQuit) {
                Label("Quit", systemImage: "power")
                    .font(.system(size: s(11), weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Color Picker")
        }
        .padding(.horizontal, s(16))
        .padding(.bottom, s(12))
    }

    // MARK: - Actions

    private func pickColor() {
        NSColorSampler().show { picked in
            guard let picked else { return }
            let srgb = picked.usingColorSpace(.sRGB) ?? picked
            Task { @MainActor in
                select(srgb, remember: true)
            }
        }
    }

    private func select(_ newColor: NSColor, remember: Bool = true) {
        let srgb = newColor.usingColorSpace(.sRGB) ?? newColor
        color = srgb
        hexInput = ColorKit.hexString(srgb, includeAlpha: false)
        copiedRow = nil
        if remember {
            addRecent(srgb)
        }
    }

    private func addRecent(_ newColor: NSColor) {
        let newHex = ColorKit.hexString(newColor, includeAlpha: true)
        recents.removeAll { ColorKit.hexString($0, includeAlpha: true) == newHex }
        recents.insert(newColor, at: 0)
        if recents.count > 10 {
            recents = Array(recents.prefix(10))
        }
    }

    private func applyHexInput() {
        applyHex(hexInput)
    }

    private func applyHex(_ raw: String) {
        guard let parsed = ColorKit.color(fromHex: raw) else { return }
        color = parsed
        copiedRow = nil
    }

    private func copy(_ value: String, rowID: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedRow = rowID
    }
}
