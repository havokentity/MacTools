// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "DMonte",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DMonteCore",
            targets: ["DMonteCore"]
        ),
        .executable(
            name: "DMonte",
            targets: ["DMonte"]
        ),
        .executable(
            name: "DMonteSystemMonitor",
            targets: ["DMonteSystemMonitor"]
        ),
        .executable(
            name: "DMonteUninstaller",
            targets: ["DMonteUninstaller"]
        ),
        .executable(
            name: "DMonteCleanDrive",
            targets: ["DMonteCleanDrive"]
        ),
        .executable(
            name: "DMonteVideoDownloader",
            targets: ["DMonteVideoDownloader"]
        ),
        .executable(
            name: "DMonteDiskAnalyzer",
            targets: ["DMonteDiskAnalyzer"]
        ),
        .executable(
            name: "DMonteClipboard",
            targets: ["DMonteClipboard"]
        ),
        .executable(
            name: "DMonteDevTools",
            targets: ["DMonteDevTools"]
        ),
        .executable(
            name: "DMonteQR",
            targets: ["DMonteQR"]
        ),
        .executable(
            name: "DMonteKeepAwake",
            targets: ["DMonteKeepAwake"]
        ),
        .executable(
            name: "DMonteImageConverter",
            targets: ["DMonteImageConverter"]
        ),
        .executable(
            name: "DMonteMaintenance",
            targets: ["DMonteMaintenance"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
    ],
    targets: [
        .target(
            name: "DMonteCore",
            path: "Sources/DMonteCore"
        ),
        .executableTarget(
            name: "DMonte",
            dependencies: [
                "DMonteCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/DMonteApp"
        ),
        .executableTarget(
            name: "DMonteSystemMonitor",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteSystemMonitorApp"
        ),
        .executableTarget(
            name: "DMonteUninstaller",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteUninstallerApp"
        ),
        .executableTarget(
            name: "DMonteCleanDrive",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteCleanDriveApp"
        ),
        .executableTarget(
            name: "DMonteVideoDownloader",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteVideoDownloaderApp"
        ),
        .executableTarget(
            name: "DMonteDiskAnalyzer",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteDiskAnalyzerApp"
        ),
        .executableTarget(
            name: "DMonteClipboard",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteClipboardApp"
        ),
        .executableTarget(
            name: "DMonteDevTools",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteDevToolsApp"
        ),
        .executableTarget(
            name: "DMonteQR",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteQRApp"
        ),
        .executableTarget(
            name: "DMonteKeepAwake",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteKeepAwakeApp"
        ),
        .executableTarget(
            name: "DMonteImageConverter",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteImageConverterApp"
        ),
        .executableTarget(
            name: "DMonteMaintenance",
            dependencies: [
                "DMonteCore"
            ],
            path: "Sources/DMonteMaintenanceApp"
        ),
        .testTarget(
            name: "DMonteCoreTests",
            dependencies: ["DMonteCore"],
            path: "Tests/DMonteCoreTests"
        )
    ]
)
