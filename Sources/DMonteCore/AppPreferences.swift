import Foundation

/// Reads the running bundle's version metadata so the UI can show it without hard-coding.
public enum AppInfo {
    /// Marketing version, e.g. "0.6.0" (CFBundleShortVersionString). Falls back to the VERSION
    /// file when running unbundled (e.g. `swift run` during development).
    public static var shortVersion: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !value.isEmpty {
            return value
        }
        return developmentVersion
    }

    /// Build number, e.g. "42" (CFBundleVersion). Empty when unavailable.
    public static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
    }

    /// "Version 0.6.0 (42)" — or "Version 0.6.0" when there's no distinct build number.
    public static var displayVersion: String {
        let build = buildNumber
        if build.isEmpty || build == shortVersion {
            return "Version \(shortVersion)"
        }
        return "Version \(shortVersion) (\(build))"
    }

    /// Best-effort read of the repo VERSION file for unbundled dev runs; "dev" if not found.
    private static var developmentVersion: String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("VERSION")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return "dev"
    }
}

public enum DefaultsKey {
    public static let videoDownloaderPreferredQuality = "tool.videoDownloader.preferredQuality"
    public static let videoDownloaderDownloadMode = "tool.videoDownloader.downloadMode"
    public static let videoDownloaderAudioFormat = "tool.videoDownloader.audioFormat"
    public static let videoDownloaderNonMP4Handling = "tool.videoDownloader.nonMP4Handling"
    public static let videoDownloaderDownloadsSubtitles = "tool.videoDownloader.downloadsSubtitles"
    public static let videoDownloaderSubtitleMode = "tool.videoDownloader.subtitleMode"
    public static let videoDownloaderSaveDirectory = "tool.videoDownloader.saveDirectory"
    public static let videoDownloaderCookieSource = "tool.videoDownloader.cookieSource"
    public static let systemMonitorTemperatureUnit = "tool.systemMonitor.temperatureUnit"
    public static let systemMonitorOpenAtLogin = "tool.systemMonitor.openAtLogin"
    public static let systemMonitorShowsTrayIcon = "tool.systemMonitor.showsTrayIcon"
    /// Which column the popover's top-process list is ranked by. Persisted because whichever of
    /// the two a user cares about, they care about it every time they open the panel.
    public static let systemMonitorProcessSortKey = "tool.systemMonitor.processSortKey"
    public static let clipboardOpenAtLogin = "tool.clipboard.openAtLogin"
    public static let clipboardMaxHistory = "tool.clipboard.maxHistory"
    public static let grabTextCopyAutomatically = "tool.grabText.copyAutomatically"
    public static let volumeMixerAppVolumeGains = "tool.volumeMixer.appVolumeGains"
    public static let volumeMixerPinnedApps = "tool.volumeMixer.pinnedApps"
    public static let volumeMixerIgnoredApps = "tool.volumeMixer.ignoredApps"
    public static let volumeMixerHideIgnoredApps = "tool.volumeMixer.hideIgnoredApps"
    public static let volumeMixerSmartFilter = "tool.volumeMixer.smartFilter"
    public static let volumeMixerIncludedDefaultIgnoredApps = "tool.volumeMixer.includedDefaultIgnoredApps"
    public static let volumeMixerOutputRoutes = "tool.volumeMixer.outputRoutes"
    /// Stable keys of apps the user pressed "stop processing" on. Persisted so the stop survives a
    /// relaunch instead of the automatic policy re-tapping an app whose gain is still below unity.
    public static let volumeMixerStoppedApps = "tool.volumeMixer.stoppedApps"
    public static let windowManagerShortcuts = "tool.windowManager.shortcuts"
    public static let audioRouterPresets = "tool.audioRouter.presets"
    public static let qrTemplate = "tool.qr.template"

    /// Calendars the user has hidden. Excluded rather than included, so a calendar added later shows
    /// up by default instead of silently vanishing.
    public static let calendarExcludedCalendarIDs = "tool.calendar.excludedCalendarIDs"
    public static let toolboxRecentToolIDs = "toolbox.recentToolIDs"

    static let obsoleteKeys = [
        "tool.systemMonitor.enabled",
        "tool.uninstaller.enabled",
        "tool.uninstaller.tray.enabled",
        "tool.cleanDrive.enabled",
        "tool.cleanDrive.tray.enabled",
        "tool.videoDownloader.enabled",
        "tool.videoDownloader.tray.enabled"
    ]
}

@MainActor
public enum AppDefaults {
    public static let shared = UserDefaults(suiteName: "com.havokentity.mactools.shared") ?? .standard

    public static func registerDefaults() {
        DefaultsKey.obsoleteKeys.forEach { shared.removeObject(forKey: $0) }

        // Migrate the legacy on/off subtitle boolean to the new language mode. Done
        // before register() so the new key still reads as unset (nil) here. Only an
        // explicit "off" needs preserving; everyone else gets the new default.
        if shared.object(forKey: DefaultsKey.videoDownloaderSubtitleMode) == nil,
           shared.object(forKey: DefaultsKey.videoDownloaderDownloadsSubtitles) != nil,
           !shared.bool(forKey: DefaultsKey.videoDownloaderDownloadsSubtitles) {
            shared.set(VideoSubtitleMode.off.rawValue, forKey: DefaultsKey.videoDownloaderSubtitleMode)
        }

        shared.register(defaults: [
            DefaultsKey.videoDownloaderPreferredQuality: VideoQuality.maximum.rawValue,
            DefaultsKey.videoDownloaderDownloadMode: VideoDownloadMode.video.rawValue,
            DefaultsKey.videoDownloaderAudioFormat: VideoAudioFormat.m4a.rawValue,
            DefaultsKey.videoDownloaderNonMP4Handling: VideoNonMP4Handling.downloadWithoutConversion.rawValue,
            DefaultsKey.videoDownloaderSubtitleMode: VideoSubtitleMode.englishAndSystem.rawValue,
            DefaultsKey.videoDownloaderSaveDirectory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path,
            DefaultsKey.videoDownloaderCookieSource: VideoCookieSource.automatic.rawValue,
            DefaultsKey.systemMonitorTemperatureUnit: TemperatureUnitPreference.celsius.rawValue,
            DefaultsKey.systemMonitorOpenAtLogin: false,
            DefaultsKey.systemMonitorShowsTrayIcon: true,
            DefaultsKey.systemMonitorProcessSortKey: TopProcessSortKey.cpu.rawValue,
            DefaultsKey.clipboardOpenAtLogin: false,
            DefaultsKey.clipboardMaxHistory: 200,
            DefaultsKey.grabTextCopyAutomatically: true,
            DefaultsKey.volumeMixerHideIgnoredApps: true,
            DefaultsKey.volumeMixerSmartFilter: true,
            DefaultsKey.volumeMixerIncludedDefaultIgnoredApps: [],
            DefaultsKey.volumeMixerOutputRoutes: [:],
            DefaultsKey.windowManagerShortcuts: [:],
            DefaultsKey.toolboxRecentToolIDs: [],
            DefaultsKey.calendarExcludedCalendarIDs: [],
            DefaultsKey.focusTimerFocusMinutes: 25,
            DefaultsKey.focusTimerShortBreakMinutes: 5,
            DefaultsKey.focusTimerLongBreakMinutes: 15,
            DefaultsKey.focusTimerLongBreakInterval: 4,
            DefaultsKey.driveEjectorConfirmsEjectAll: true,
            DefaultsKey.scratchpadFontSize: 13,
            DefaultsKey.networkInfoFetchesPublicIPAutomatically: false
        ])
    }
}
