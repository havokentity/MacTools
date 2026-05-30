import AppKit
import SwiftUI

/// The tools surfaced in the left sidebar. Each maps to a single input -> output pane.
private enum DevTool: String, CaseIterable, Identifiable {
    case json
    case base64
    case url
    case hash
    case uuid
    case timestamp
    case caseConvert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .json: "JSON"
        case .base64: "Base64"
        case .url: "URL"
        case .hash: "Hash"
        case .uuid: "UUID"
        case .timestamp: "Timestamp"
        case .caseConvert: "Case"
        }
    }

    var symbol: String {
        switch self {
        case .json: "curlybraces"
        case .base64: "arrow.left.arrow.right.square"
        case .url: "link"
        case .hash: "number"
        case .uuid: "wand.and.stars"
        case .timestamp: "clock"
        case .caseConvert: "textformat"
        }
    }
}

public struct DevToolsWindowView: View {
    var onQuit: () -> Void

    @State private var selectedTool: DevTool = .json
    private let layout = DevToolsLayout.current

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.4)

            HStack(spacing: 0) {
                sidebar

                Divider()
                    .opacity(0.4)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
        .frostedPanel(cornerRadius: 18)
    }

    private var header: some View {
        HStack {
            Button(action: onQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: layout.closeIconSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
            }
            .buttonStyle(.plain)
            .help("Quit Dev Tools")

            Spacer()

            Text("Dev Tools")
                .font(.system(size: layout.titleFontSize, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.82))

            Spacer()

            // Spacer mirror so the title stays centered against the close button.
            Color.clear
                .frame(width: layout.headerButtonSize, height: layout.headerButtonSize)
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.top, layout.headerTopPadding)
        .padding(.bottom, layout.headerBottomPadding)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: layout.sidebarRowSpacing) {
            ForEach(DevTool.allCases) { tool in
                Button {
                    selectedTool = tool
                } label: {
                    HStack(spacing: layout.sidebarIconSpacing) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: layout.sidebarIconSize, weight: .semibold))
                            .frame(width: layout.sidebarIconWidth)
                            .foregroundStyle(selectedTool == tool ? Color.white : .secondary)

                        Text(tool.title)
                            .font(.system(size: layout.sidebarFontSize, weight: .semibold))
                            .foregroundStyle(selectedTool == tool ? Color.white : .primary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, layout.sidebarRowHorizontalPadding)
                    .frame(height: layout.sidebarRowHeight)
                    .background(
                        RoundedRectangle(cornerRadius: layout.sidebarRowCornerRadius, style: .continuous)
                            .fill(selectedTool == tool ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, layout.sidebarHorizontalPadding)
        .padding(.vertical, layout.sidebarVerticalPadding)
        .frame(width: layout.sidebarWidth)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedTool {
        case .json:
            TransformPane(
                title: "JSON",
                layout: layout,
                modes: ["Pretty", "Minify"],
                transform: { input, mode in
                    Self.result(DevToolsKit.formatJSON(input, pretty: mode == 0))
                }
            )
            .id(DevTool.json)
        case .base64:
            TransformPane(
                title: "Base64",
                layout: layout,
                modes: ["Encode", "Decode"],
                transform: { input, mode in
                    mode == 0
                        ? .success(DevToolsKit.base64Encode(input))
                        : Self.result(DevToolsKit.base64Decode(input))
                }
            )
            .id(DevTool.base64)
        case .url:
            TransformPane(
                title: "URL",
                layout: layout,
                modes: ["Encode", "Decode"],
                transform: { input, mode in
                    mode == 0
                        ? .success(DevToolsKit.urlEncode(input))
                        : Self.result(DevToolsKit.urlDecode(input))
                }
            )
            .id(DevTool.url)
        case .hash:
            HashPane(layout: layout)
                .id(DevTool.hash)
        case .uuid:
            UUIDPane(layout: layout)
                .id(DevTool.uuid)
        case .timestamp:
            TimestampPane(layout: layout)
                .id(DevTool.timestamp)
        case .caseConvert:
            CasePane(layout: layout)
                .id(DevTool.caseConvert)
        }
    }

    /// Bridges a `DevToolsKit.Result` into a string-or-message pair the panes can render.
    fileprivate static func result(_ value: Result<String, DevToolsKit.DevToolsError>) -> PaneOutput {
        switch value {
        case let .success(string):
            return .success(string)
        case let .failure(error):
            return .failure(message(for: error))
        }
    }

    fileprivate static func message(for error: DevToolsKit.DevToolsError) -> String {
        switch error {
        case let .invalidJSON(detail): "Invalid JSON: \(detail)"
        case .invalidBase64: "Invalid Base64 input."
        case .invalidURLEncoding: "Invalid percent-encoding."
        case .invalidEpoch: "Invalid timestamp."
        case .emptyInput: "Enter some text to begin."
        }
    }
}

// MARK: - Output value

fileprivate enum PaneOutput {
    case success(String)
    case failure(String)

    var text: String {
        switch self {
        case let .success(value): value
        case let .failure(message): message
        }
    }

    var isError: Bool {
        if case .failure = self { return true }
        return false
    }

    /// The string worth copying — only successful output, never an error banner.
    var copyableText: String? {
        switch self {
        case let .success(value): value
        case .failure: nil
        }
    }
}

// MARK: - Shared building blocks

/// A labeled, monospaced text editor used for both input and read-only output.
fileprivate struct EditorBox: View {
    var layout: DevToolsLayout
    var text: Binding<String>
    var placeholder: String
    var isEditable: Bool
    var isError: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: layout.editorCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: layout.editorCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                }

            if isEditable {
                TextEditor(text: text)
                    .font(.system(size: layout.editorFontSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(.primary)
                    .scrollContentBackground(.hidden)
                    .padding(layout.editorTextPadding)
            } else {
                ScrollView {
                    Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue)
                        .font(.system(size: layout.editorFontSize, weight: .regular, design: .monospaced))
                        .foregroundStyle(outputColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(layout.editorTextPadding)
                }
            }

            if isEditable, text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: layout.editorFontSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .padding(layout.editorTextPadding)
                    .padding(.top, 2)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
    }

    private var outputColor: Color {
        if text.wrappedValue.isEmpty {
            return .secondary.opacity(0.55)
        }
        return isError ? Color.red.opacity(0.9) : .primary
    }
}

fileprivate struct SectionLabel: View {
    var layout: DevToolsLayout
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: layout.sectionLabelFontSize, weight: .heavy))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }
}

fileprivate struct CopyButton: View {
    var layout: DevToolsLayout
    var value: String?
    @State private var didCopy = false

    var body: some View {
        Button {
            guard let value, !value.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            didCopy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: layout.controlFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, layout.copyButtonHorizontalPadding)
                .frame(height: layout.controlHeight)
                .background(Color.accentColor.opacity(value?.isEmpty == false ? 1 : 0.4))
                .clipShape(RoundedRectangle(cornerRadius: layout.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(value?.isEmpty != false)
    }
}

fileprivate struct ModePicker: View {
    var layout: DevToolsLayout
    var labels: [String]
    @Binding var selection: Int

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Text(label).tag(index)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: layout.modePickerMaxWidth)
    }
}

// MARK: - Generic input -> output pane

/// A pane with an editable input, an optional mode segmented control, and a derived output.
/// Used by JSON, Base64 and URL which all share the same shape.
fileprivate struct TransformPane: View {
    var title: String
    var layout: DevToolsLayout
    var modes: [String]
    var transform: (String, Int) -> PaneOutput

    @State private var input = ""
    @State private var mode = 0

    var body: some View {
        VStack(alignment: .leading, spacing: layout.paneSpacing) {
            HStack {
                SectionLabel(layout: layout, text: "Input")
                Spacer()
                ModePicker(layout: layout, labels: modes, selection: $mode)
            }

            EditorBox(
                layout: layout,
                text: $input,
                placeholder: "Paste \(title) here…",
                isEditable: true,
                isError: false
            )
            .frame(maxHeight: .infinity)

            HStack {
                SectionLabel(layout: layout, text: "Output")
                Spacer()
                CopyButton(layout: layout, value: output.copyableText)
            }

            EditorBox(
                layout: layout,
                text: .constant(input.isEmpty ? "" : output.text),
                placeholder: "Result appears here",
                isEditable: false,
                isError: output.isError
            )
            .frame(maxHeight: .infinity)
        }
        .padding(layout.detailPadding)
    }

    private var output: PaneOutput {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success("")
        }
        return transform(input, mode)
    }
}

// MARK: - Hash pane

fileprivate struct HashPane: View {
    var layout: DevToolsLayout
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: layout.paneSpacing) {
            SectionLabel(layout: layout, text: "Input")

            EditorBox(
                layout: layout,
                text: $input,
                placeholder: "Type or paste text to hash…",
                isEditable: true,
                isError: false
            )
            .frame(maxHeight: .infinity)

            SectionLabel(layout: layout, text: "Digests")

            VStack(spacing: layout.hashRowSpacing) {
                HashRow(layout: layout, name: "MD5", value: input.isEmpty ? "" : DevToolsKit.md5(input))
                HashRow(layout: layout, name: "SHA-1", value: input.isEmpty ? "" : DevToolsKit.sha1(input))
                HashRow(layout: layout, name: "SHA-256", value: input.isEmpty ? "" : DevToolsKit.sha256(input))
                HashRow(layout: layout, name: "SHA-512", value: input.isEmpty ? "" : DevToolsKit.sha512(input))
            }
        }
        .padding(layout.detailPadding)
    }
}

fileprivate struct HashRow: View {
    var layout: DevToolsLayout
    var name: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: layout.hashRowInnerSpacing) {
            HStack {
                Text(name)
                    .font(.system(size: layout.sectionLabelFontSize, weight: .heavy))
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(layout: layout, value: value.isEmpty ? nil : value)
            }

            Text(value.isEmpty ? "—" : value)
                .font(.system(size: layout.hashValueFontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(value.isEmpty ? Color.secondary.opacity(0.55) : Color.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(layout.hashRowPadding)
        .background(
            RoundedRectangle(cornerRadius: layout.editorCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
    }
}

// MARK: - UUID pane

fileprivate struct UUIDPane: View {
    var layout: DevToolsLayout
    // Store the canonical (lowercase) UUID and derive the displayed casing, so toggling case
    // never needs an onChange side effect and always stays in sync with the toggle.
    @State private var canonical = DevToolsKit.uuid(uppercase: false)
    @State private var uppercase = false

    private var value: String {
        uppercase ? canonical.uppercased() : canonical
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.paneSpacing) {
            SectionLabel(layout: layout, text: "UUID")

            Text(value)
                .font(.system(size: layout.uuidFontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(layout.editorTextPadding)
                .background(
                    RoundedRectangle(cornerRadius: layout.editorCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )

            HStack(spacing: layout.controlSpacing) {
                Button {
                    canonical = DevToolsKit.uuid(uppercase: false)
                } label: {
                    Label("Generate", systemImage: "arrow.clockwise")
                        .font(.system(size: layout.controlFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, layout.copyButtonHorizontalPadding)
                        .frame(height: layout.controlHeight)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: layout.controlCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)

                CopyButton(layout: layout, value: value)

                Spacer()

                Toggle("Uppercase", isOn: $uppercase)
                    .toggleStyle(.switch)
                    .font(.system(size: layout.controlFontSize, weight: .semibold))
            }

            Spacer()
        }
        .padding(layout.detailPadding)
    }
}

// MARK: - Timestamp pane

fileprivate struct TimestampPane: View {
    var layout: DevToolsLayout
    @State private var epochInput = String(DevToolsKit.currentEpoch())
    @State private var dateInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: layout.paneSpacing) {
            HStack {
                SectionLabel(layout: layout, text: "Current epoch")
                Spacer()
                Button {
                    epochInput = String(DevToolsKit.currentEpoch())
                } label: {
                    Label("Now", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: layout.controlFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, layout.copyButtonHorizontalPadding)
                        .frame(height: layout.controlHeight)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: layout.controlCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            SectionLabel(layout: layout, text: "Epoch seconds → date")
            TextField("1700000000", text: $epochInput)
                .textFieldStyle(.plain)
                .font(.system(size: layout.editorFontSize, weight: .regular, design: .monospaced))
                .padding(layout.editorTextPadding)
                .background(
                    RoundedRectangle(cornerRadius: layout.editorCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )

            outputRow(label: "UTC date", output: epochOutput)

            Divider().opacity(0.3).padding(.vertical, layout.controlSpacing)

            SectionLabel(layout: layout, text: "ISO-8601 date → epoch")
            TextField("2023-11-14T22:13:20Z", text: $dateInput)
                .textFieldStyle(.plain)
                .font(.system(size: layout.editorFontSize, weight: .regular, design: .monospaced))
                .padding(layout.editorTextPadding)
                .background(
                    RoundedRectangle(cornerRadius: layout.editorCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )

            outputRow(label: "Epoch seconds", output: dateOutput)

            Spacer()
        }
        .padding(layout.detailPadding)
    }

    @ViewBuilder
    private func outputRow(label: String, output: PaneOutput) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: layout.hashRowInnerSpacing) {
                SectionLabel(layout: layout, text: label)
                Text(output.text.isEmpty ? "—" : output.text)
                    .font(.system(size: layout.editorFontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(output.isError ? Color.red.opacity(0.9) : .primary)
                    .textSelection(.enabled)
            }
            Spacer()
            CopyButton(layout: layout, value: output.copyableText)
        }
    }

    private var epochOutput: PaneOutput {
        let trimmed = epochInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success("") }
        switch DevToolsKit.parseEpoch(trimmed) {
        case let .success(seconds):
            return DevToolsWindowView.result(DevToolsKit.epochToDate(seconds))
        case let .failure(error):
            return .failure(DevToolsWindowView.message(for: error))
        }
    }

    private var dateOutput: PaneOutput {
        let trimmed = dateInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success("") }
        switch DevToolsKit.dateToEpoch(trimmed) {
        case let .success(seconds):
            return .success(String(Int(seconds)))
        case let .failure(error):
            return .failure(DevToolsWindowView.message(for: error))
        }
    }
}

// MARK: - Case pane

fileprivate struct CasePane: View {
    var layout: DevToolsLayout
    @State private var input = ""
    @State private var style: DevToolsKit.CaseStyle = .camel

    var body: some View {
        VStack(alignment: .leading, spacing: layout.paneSpacing) {
            HStack {
                SectionLabel(layout: layout, text: "Input")
                Spacer()
                Picker("", selection: $style) {
                    ForEach(DevToolsKit.CaseStyle.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: layout.casePickerMaxWidth)
            }

            EditorBox(
                layout: layout,
                text: $input,
                placeholder: "Type text to convert…",
                isEditable: true,
                isError: false
            )
            .frame(maxHeight: .infinity)

            HStack {
                SectionLabel(layout: layout, text: "Output")
                Spacer()
                CopyButton(layout: layout, value: output.isEmpty ? nil : output)
            }

            EditorBox(
                layout: layout,
                text: .constant(output),
                placeholder: "Result appears here",
                isEditable: false,
                isError: false
            )
            .frame(maxHeight: .infinity)
        }
        .padding(layout.detailPadding)
    }

    private var output: String {
        guard !input.isEmpty else { return "" }
        return DevToolsKit.convertCase(input, to: style)
    }
}

// MARK: - Layout

private struct DevToolsLayout {
    let scale: CGFloat

    static var current: DevToolsLayout {
        DevToolsLayout(scale: DevToolsSizing.currentScale)
    }

    var windowSize: NSSize { DevToolsSizing.preferredSize() }

    // Header
    var headerButtonSize: CGFloat { 30 * scale }
    var closeIconSize: CGFloat { 16 * scale }
    var titleFontSize: CGFloat { 18 * scale }
    var headerHorizontalPadding: CGFloat { 18 * scale }
    var headerTopPadding: CGFloat { 14 * scale }
    var headerBottomPadding: CGFloat { 10 * scale }

    // Sidebar
    var sidebarWidth: CGFloat { 132 * scale }
    var sidebarHorizontalPadding: CGFloat { 10 * scale }
    var sidebarVerticalPadding: CGFloat { 12 * scale }
    var sidebarRowSpacing: CGFloat { 4 * scale }
    var sidebarRowHeight: CGFloat { 32 * scale }
    var sidebarRowHorizontalPadding: CGFloat { 10 * scale }
    var sidebarRowCornerRadius: CGFloat { 8 * scale }
    var sidebarIconSpacing: CGFloat { 9 * scale }
    var sidebarIconSize: CGFloat { 13 * scale }
    var sidebarIconWidth: CGFloat { 16 * scale }
    var sidebarFontSize: CGFloat { 13 * scale }

    // Detail
    var detailPadding: CGFloat { 18 * scale }
    var paneSpacing: CGFloat { 9 * scale }
    var sectionLabelFontSize: CGFloat { 11 * scale }
    var editorCornerRadius: CGFloat { 9 * scale }
    var editorFontSize: CGFloat { 12 * scale }
    var editorTextPadding: CGFloat { 8 * scale }

    // Controls
    var controlHeight: CGFloat { 28 * scale }
    var controlFontSize: CGFloat { 12 * scale }
    var controlCornerRadius: CGFloat { 7 * scale }
    var controlSpacing: CGFloat { 10 * scale }
    var copyButtonHorizontalPadding: CGFloat { 12 * scale }
    var modePickerMaxWidth: CGFloat { 160 * scale }
    var casePickerMaxWidth: CGFloat { 150 * scale }

    // Hash
    var hashRowSpacing: CGFloat { 8 * scale }
    var hashRowInnerSpacing: CGFloat { 4 * scale }
    var hashRowPadding: CGFloat { 10 * scale }
    var hashValueFontSize: CGFloat { 11 * scale }

    // UUID
    var uuidFontSize: CGFloat { 15 * scale }
}
