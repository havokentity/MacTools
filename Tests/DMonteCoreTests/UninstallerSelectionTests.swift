import XCTest
@testable import DMonteCore

final class UninstallerSelectionTests: XCTestCase {
    private let alpha = InstalledApplication(
        id: "/Applications/Alpha.app",
        name: "Alpha",
        path: "/Applications/Alpha.app",
        size: nil,
        bundleIdentifier: "com.example.alpha"
    )
    private let beta = InstalledApplication(
        id: "/Applications/Beta.app",
        name: "Beta",
        path: "/Applications/Beta.app",
        size: nil,
        bundleIdentifier: "com.example.beta"
    )

    private let gamma = InstalledApplication(
        id: "/Applications/Gamma.app",
        name: "Gamma",
        path: "/Applications/Gamma.app",
        size: nil,
        bundleIdentifier: "com.example.gamma"
    )

    func testSelectedAppFallsBackWithinFilteredResultsOnly() {
        let filtered = UninstallerSelection.filteredApps([alpha, beta], query: "Beta")
        let selected = UninstallerSelection.selectedApp(in: filtered, selectedID: alpha.id)

        XCTAssertEqual(selected, beta)
    }

    func testSelectedAppKeepsVisibleSelection() {
        let filtered = UninstallerSelection.filteredApps([alpha, beta], query: "Beta")
        let selected = UninstallerSelection.selectedApp(in: filtered, selectedID: beta.id)

        XCTAssertEqual(selected, beta)
    }

    func testSelectedAppIsNilWhenFilterMatchesNothing() {
        let filtered = UninstallerSelection.filteredApps([alpha, beta], query: "Gamma")
        let selected = UninstallerSelection.selectedApp(in: filtered, selectedID: alpha.id)

        XCTAssertNil(selected)
    }

    // MARK: - The details pane

    /// The regression this file exists for. Uninstalling the last app that matches the current
    /// search is the *common* case — users search to find the app they want gone — and it is also
    /// the case where the leftover sweep has most likely been half-refused, because the tool is
    /// not privileged and cannot touch `/Library`. Rendering the report inside the selected-app
    /// branch threw it away exactly then, and the user walked away believing the machine was clean.
    func testDetailsPaneStillReportsTheSweepWhenTheUninstallEmptiedTheList() {
        var apps = [alpha, beta]
        let searchText = "Alpha"

        // What `performUninstall` does after macOS accepts the bundle.
        apps.removeAll { $0.id == alpha.id }
        let filtered = UninstallerSelection.filteredApps(apps, query: searchText)
        let selectedID = filtered.first?.id
        let feedback = UninstallerFeedback.sweepFinished(
            appName: alpha.name,
            result: LeftoverRemovalResult(
                trashedCount: 3,
                trashedBytes: 412_000_000,
                failures: [
                    LeftoverRemovalFailure(path: "/Library/Caches/com.example.alpha", reason: "Permission denied")
                ]
            )
        )

        XCTAssertTrue(filtered.isEmpty)
        XCTAssertNil(selectedID)

        let pane = UninstallerDetailsPane.resolve(
            filteredApps: filtered,
            selectedID: selectedID,
            feedback: feedback
        )

        XCTAssertNil(pane.app)
        XCTAssertEqual(pane.placeholder, "No apps found")
        XCTAssertTrue(pane.showsFeedback)
        XCTAssertEqual(pane.feedback, feedback)
    }

    func testDetailsPaneCarriesTheFeedbackAlongsideASelectedApp() {
        let filtered = UninstallerSelection.filteredApps([alpha, beta], query: "")
        let feedback = UninstallerFeedback.bundleTrashed(appName: "Gamma")

        let pane = UninstallerDetailsPane.resolve(
            filteredApps: filtered,
            selectedID: beta.id,
            feedback: feedback
        )

        XCTAssertEqual(pane.app, beta)
        XCTAssertNil(pane.placeholder)
        XCTAssertEqual(pane.feedback, feedback)
    }

    func testDetailsPaneShowsNoFeedbackWhenNothingHasHappenedYet() {
        let pane = UninstallerDetailsPane.resolve(
            filteredApps: [],
            selectedID: nil,
            feedback: .empty
        )

        XCTAssertNil(pane.app)
        XCTAssertFalse(pane.showsFeedback)
    }

    // MARK: - The sidebar is frozen while an uninstall is in flight

    func testSelectionOnlyMovesWhileNoUninstallIsInFlight() {
        XCTAssertTrue(UninstallerSelection.canChangeSelection(isPreparingRemoval: false, isRemoving: false))
        XCTAssertFalse(UninstallerSelection.canChangeSelection(isPreparingRemoval: true, isRemoving: false))
        XCTAssertFalse(UninstallerSelection.canChangeSelection(isPreparingRemoval: false, isRemoving: true))
        XCTAssertFalse(UninstallerSelection.canChangeSelection(isPreparingRemoval: true, isRemoving: true))
    }

    /// The ordering hole this guard closes. Selecting an app clears the last report on purpose,
    /// but the sweep's report is written by a background task that lands *after* the click — so
    /// without the freeze a mid-sweep click cleared the report only for the sweep to re-file it
    /// under whichever app the user had wandered onto in the meantime.
    func testAMidSweepClickCannotRefileTheReportUnderAnotherApp() {
        // Where `performUninstall` leaves things once macOS has accepted Alpha's bundle: Alpha is
        // gone from the list, Beta is selected, and the leftover sweep is still running.
        var apps = [alpha, beta, gamma]
        apps.removeAll { $0.id == alpha.id }
        let filtered = UninstallerSelection.filteredApps(apps, query: "")
        var selectedID = filtered.first?.id
        var feedback = UninstallerFeedback.empty

        // What `select(_:)` does with a click.
        func select(_ app: InstalledApplication, isRemoving: Bool) {
            guard UninstallerSelection.canChangeSelection(isPreparingRemoval: false, isRemoving: isRemoving) else {
                return
            }

            selectedID = app.id
            feedback = .empty
        }

        select(gamma, isRemoving: true)
        XCTAssertEqual(selectedID, beta.id, "the sidebar must not answer clicks mid-sweep")

        // The background task lands.
        feedback = .sweepFinished(
            appName: alpha.name,
            result: LeftoverRemovalResult(trashedCount: 2, trashedBytes: 2_048)
        )

        let pane = UninstallerDetailsPane.resolve(
            filteredApps: filtered,
            selectedID: selectedID,
            feedback: feedback
        )

        XCTAssertEqual(pane.app, beta)
        XCTAssertTrue(pane.showsFeedback)

        // And the sidebar answers again the moment the sweep is done.
        select(gamma, isRemoving: false)
        XCTAssertEqual(selectedID, gamma.id)
        XCTAssertTrue(feedback.isEmpty)
    }

    // MARK: - Uninstall feedback

    /// A partial sweep has to say both halves. Reporting only the failure sends the user hunting
    /// in `~/Library` for files that are already in the Trash, or re-running the sweep.
    func testSweepFeedbackReportsWhatMovedAndWhatDidNot() {
        let feedback = UninstallerFeedback.sweepFinished(
            appName: "Alpha",
            result: LeftoverRemovalResult(
                trashedCount: 3,
                trashedBytes: 412_000_000,
                failures: [
                    LeftoverRemovalFailure(path: "/Library/Caches/com.example.alpha", reason: "Permission denied"),
                    LeftoverRemovalFailure(path: "/Library/Logs/com.example.alpha", reason: "Permission denied")
                ]
            )
        )

        XCTAssertNotNil(feedback.status)
        XCTAssertTrue(feedback.status?.contains("Alpha") == true)
        XCTAssertTrue(feedback.status?.contains("3 support items") == true)

        XCTAssertTrue(feedback.failure?.contains("2 support items") == true)
        XCTAssertTrue(feedback.failure?.contains("/Library/Caches/com.example.alpha") == true)
    }

    func testSweepFeedbackNamesTheOnlyFailureOutright() {
        let feedback = UninstallerFeedback.sweepFinished(
            appName: "Alpha",
            result: LeftoverRemovalResult(
                trashedCount: 1,
                trashedBytes: 1024,
                failures: [LeftoverRemovalFailure(path: "/Library/Caches/com.example.alpha", reason: "Permission denied")]
            )
        )

        XCTAssertTrue(feedback.status?.contains("1 support item ") == true)
        XCTAssertEqual(feedback.failure, "Could not remove /Library/Caches/com.example.alpha: Permission denied")
    }

    func testSweepFeedbackDropsTheItemCountWhenEverySweepFailed() {
        let feedback = UninstallerFeedback.sweepFinished(
            appName: "Alpha",
            result: LeftoverRemovalResult(
                trashedCount: 0,
                trashedBytes: 0,
                failures: [LeftoverRemovalFailure(path: "/Library/Caches/com.example.alpha", reason: "Permission denied")]
            )
        )

        XCTAssertEqual(feedback.status, "Moved Alpha to Trash.")
        XCTAssertNotNil(feedback.failure)
    }

    func testSweepFeedbackWithNoFailuresHasNothingRedToSay() {
        let feedback = UninstallerFeedback.sweepFinished(
            appName: "Alpha",
            result: LeftoverRemovalResult(trashedCount: 2, trashedBytes: 2048)
        )

        XCTAssertNotNil(feedback.status)
        XCTAssertNil(feedback.failure)
    }

    func testRefusedBundleReportsOnlyTheFailure() {
        let feedback = UninstallerFeedback.bundleRefused(reason: "Operation not permitted")

        XCTAssertNil(feedback.status)
        XCTAssertEqual(feedback.failure, "Operation not permitted")
        XCTAssertFalse(feedback.isEmpty)
    }

    func testEmptyFeedbackIsEmpty() {
        XCTAssertTrue(UninstallerFeedback.empty.isEmpty)
        XCTAssertFalse(UninstallerFeedback.bundleTrashed(appName: "Alpha").isEmpty)
    }
}
