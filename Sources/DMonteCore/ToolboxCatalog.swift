import SwiftUI

/// A single tool in the toolbox. One value drives both the dashboard UI (title/icon/tint) and
/// the launcher (bundle id / app name / executable / launch args), so adding a tool is a single
/// catalog entry plus its self-contained helper target — no scattered switch statements.
public struct ToolboxTool: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let iconName: String
    public let tint: Color
    public let bundleID: String
    public let appName: String
    public let executableName: String
    public let arguments: [String]

    /// The distributed-notification a helper observes to reveal its window. By convention this
    /// is `<bundleID>.showWindow`, matching every helper's own observer registration.
    public var showNotification: Notification.Name {
        Notification.Name(bundleID + ".showWindow")
    }

    public init(
        id: String,
        title: String,
        iconName: String,
        tint: Color,
        bundleID: String,
        appName: String,
        executableName: String,
        arguments: [String]
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.tint = tint
        self.bundleID = bundleID
        self.appName = appName
        self.executableName = executableName
        self.arguments = arguments
    }
}

public enum ToolboxCatalog {
    private static let prefix = "com.havokentity.mactools."

    public static let all: [ToolboxTool] = [
        ToolboxTool(id: "systemMonitor", title: "System Monitor", iconName: "waveform.path.ecg.rectangle", tint: .green, bundleID: prefix + "systemmonitor", appName: "DMonte System Monitor.app", executableName: "DMonteSystemMonitor", arguments: []),
        ToolboxTool(id: "downloadVideo", title: "Download Video", iconName: "play.rectangle.fill", tint: .purple, bundleID: prefix + "videodownloader", appName: "DMonte Video Downloader.app", executableName: "DMonteVideoDownloader", arguments: ["--open"]),
        ToolboxTool(id: "uninstaller", title: "Uninstall Apps", iconName: "trash", tint: .red, bundleID: prefix + "uninstaller", appName: "DMonte Uninstaller.app", executableName: "DMonteUninstaller", arguments: ["--open"]),
        ToolboxTool(id: "cleanDrive", title: "Clean Drive", iconName: "paintbrush.pointed", tint: .yellow, bundleID: prefix + "cleandrive", appName: "DMonte Clean Drive.app", executableName: "DMonteCleanDrive", arguments: ["--open"]),
        ToolboxTool(id: "diskAnalyzer", title: "Disk Usage Analyzer", iconName: "chart.pie.fill", tint: .blue, bundleID: prefix + "diskanalyzer", appName: "DMonte Disk Analyzer.app", executableName: "DMonteDiskAnalyzer", arguments: ["--open"]),
        ToolboxTool(id: "clipboard", title: "Clipboard History", iconName: "doc.on.clipboard", tint: .orange, bundleID: prefix + "clipboard", appName: "DMonte Clipboard.app", executableName: "DMonteClipboard", arguments: ["--open"]),
        ToolboxTool(id: "devTools", title: "Dev Tools", iconName: "curlybraces", tint: .cyan, bundleID: prefix + "devtools", appName: "DMonte Dev Tools.app", executableName: "DMonteDevTools", arguments: ["--open"]),
        ToolboxTool(id: "qr", title: "QR Studio", iconName: "qrcode", tint: .indigo, bundleID: prefix + "qr", appName: "DMonte QR.app", executableName: "DMonteQR", arguments: ["--open"]),
        ToolboxTool(id: "keepAwake", title: "Keep Awake", iconName: "cup.and.saucer.fill", tint: .brown, bundleID: prefix + "keepawake", appName: "DMonte Keep Awake.app", executableName: "DMonteKeepAwake", arguments: ["--open"]),
        ToolboxTool(id: "imageConverter", title: "Image Converter", iconName: "photo.on.rectangle.angled", tint: .teal, bundleID: prefix + "imageconverter", appName: "DMonte Image Converter.app", executableName: "DMonteImageConverter", arguments: ["--open"]),
        ToolboxTool(id: "maintenance", title: "Maintenance", iconName: "wrench.and.screwdriver.fill", tint: .pink, bundleID: prefix + "maintenance", appName: "DMonte Maintenance.app", executableName: "DMonteMaintenance", arguments: ["--open"]),
        ToolboxTool(id: "duplicateFinder", title: "Duplicate Finder", iconName: "doc.on.doc", tint: .mint, bundleID: prefix + "duplicatefinder", appName: "DMonte Duplicate Finder.app", executableName: "DMonteDuplicateFinder", arguments: ["--open"]),
        ToolboxTool(id: "audioSwitcher", title: "Audio Switcher", iconName: "speaker.wave.2.fill", tint: .purple, bundleID: prefix + "audioswitcher", appName: "DMonte Audio Switcher.app", executableName: "DMonteAudioSwitcher", arguments: ["--open"]),
        ToolboxTool(id: "calendar", title: "Calendar", iconName: "calendar", tint: .red, bundleID: prefix + "calendar", appName: "DMonte Calendar.app", executableName: "DMonteCalendar", arguments: ["--open"])
    ]
}
