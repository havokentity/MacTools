import SwiftUI
import XCTest
@testable import DMonteCore

/// The series-to-points mapping is pure and off the main actor precisely so these cases can be
/// asserted without a view hierarchy. The one that bites in practice is the flat series: an idle
/// Mac reports the same CPU figure for a minute at a time, and normalising against a zero range
/// puts a NaN in the `Path`, which CoreGraphics answers by dropping the whole shape — so the
/// sparkline vanishes exactly when the machine is calm.
final class SparklineTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 100, height: 20)

    // MARK: - Empty and single-sample series

    func testEmptySeriesProducesNoPoints() {
        XCTAssertEqual(Sparkline.points(for: [], in: rect), [])
    }

    func testSingleSampleProducesOneCentredPoint() {
        let points = Sparkline.points(for: [0.42], in: rect)

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].x, rect.midX, accuracy: 1e-9)
    }

    /// One sample has no range of its own, so fitting to the series has to fall back to the mid
    /// line rather than dividing by zero.
    func testSingleSampleFittedToItselfSitsOnTheMidLine() {
        let points = Sparkline.points(for: [7.0], in: rect, scale: .fitToSeries)

        XCTAssertEqual(points[0].y, rect.midY, accuracy: 1e-9)
        XCTAssertTrue(points[0].y.isFinite)
    }

    /// Against a fixed domain a single sample still has a meaningful height.
    func testSingleSampleAgainstAFixedDomainUsesItsRealHeight() {
        let points = Sparkline.points(for: [1.0], in: rect, scale: .unitInterval)

        XCTAssertEqual(points[0].y, rect.minY, accuracy: 1e-9)
    }

    // MARK: - Flat series

    func testAllEqualValuesFitToSeriesDrawADividedByZeroFreeMidLine() {
        let points = Sparkline.points(for: Array(repeating: 0.37, count: 6), in: rect, scale: .fitToSeries)

        XCTAssertEqual(points.count, 6)
        for point in points {
            XCTAssertTrue(point.x.isFinite)
            XCTAssertTrue(point.y.isFinite)
            XCTAssertEqual(point.y, rect.midY, accuracy: 1e-9)
        }
    }

    func testAllZeroValuesFitToSeriesStayFinite() {
        let points = Sparkline.points(for: Array(repeating: 0.0, count: 4), in: rect, scale: .fitToSeries)

        XCTAssertEqual(points.count, 4)
        XCTAssertFalse(points.contains { $0.y.isNaN })
    }

    /// A fixed domain with no width is the same division by zero arriving from the caller's side.
    func testCollapsedFixedDomainFallsBackToTheMidLine() {
        let points = Sparkline.points(for: [3.0, 9.0], in: rect, scale: .fixed(lower: 5, upper: 5))

        XCTAssertEqual(points.map(\.y), [rect.midY, rect.midY])
    }

    func testInvertedFixedDomainFallsBackToTheMidLine() {
        let points = Sparkline.points(for: [3.0, 9.0], in: rect, scale: .fixed(lower: 10, upper: 0))

        XCTAssertEqual(points.map(\.y), [rect.midY, rect.midY])
    }

    // MARK: - Real ranges

    func testExtremesLandOnTheTopAndBottomEdges() {
        let points = Sparkline.points(for: [0, 50, 100], in: rect, scale: .fitToSeries)

        XCTAssertEqual(points[0].y, rect.maxY, accuracy: 1e-9)
        XCTAssertEqual(points[1].y, rect.midY, accuracy: 1e-9)
        // View coordinates grow downwards, so the largest sample is at the smallest y.
        XCTAssertEqual(points[2].y, rect.minY, accuracy: 1e-9)
    }

    /// A network burst spans several orders of magnitude in one minute; the mapping must stay
    /// exact rather than losing the small samples into the floor.
    func testLargeValueRangeKeepsEveryPointInsideTheRect() {
        let series: [Double] = [0, 1, 1_000, 5_000_000, 12, 1_250_000_000]
        let points = Sparkline.points(for: series, in: rect, scale: .fitToSeries)

        XCTAssertEqual(points.count, series.count)
        for point in points {
            XCTAssertTrue(point.y.isFinite)
            XCTAssertGreaterThanOrEqual(point.y, rect.minY)
            XCTAssertLessThanOrEqual(point.y, rect.maxY)
        }

        XCTAssertEqual(points[0].y, rect.maxY, accuracy: 1e-9)
        XCTAssertEqual(points[5].y, rect.minY, accuracy: 1e-9)
    }

    func testPointsAreEvenlySpacedAcrossTheFullWidth() {
        let points = Sparkline.points(for: [1, 2, 3, 4, 5], in: rect, scale: .fitToSeries)

        XCTAssertEqual(points.first?.x, rect.minX)
        XCTAssertEqual(points.last?.x, rect.maxX)

        let gaps = zip(points, points.dropFirst()).map { $1.x - $0.x }
        for gap in gaps {
            XCTAssertEqual(gap, rect.width / 4, accuracy: 1e-9)
        }
    }

    func testMappingRespectsARectThatIsNotAtTheOrigin() {
        let offset = CGRect(x: 30, y: 12, width: 60, height: 40)
        let points = Sparkline.points(for: [0, 1], in: offset, scale: .unitInterval)

        XCTAssertEqual(points[0], CGPoint(x: offset.minX, y: offset.maxY))
        XCTAssertEqual(points[1], CGPoint(x: offset.maxX, y: offset.minY))
    }

    // MARK: - Out-of-domain and non-finite input

    func testValuesOutsideAFixedDomainAreClampedToTheEdges() {
        let points = Sparkline.points(for: [-4, 0.5, 9], in: rect, scale: .unitInterval)

        XCTAssertEqual(points[0].y, rect.maxY, accuracy: 1e-9)
        XCTAssertEqual(points[1].y, rect.midY, accuracy: 1e-9)
        XCTAssertEqual(points[2].y, rect.minY, accuracy: 1e-9)
    }

    /// One bad reading would otherwise poison the series' minimum and maximum and take every other
    /// point down with it.
    func testNonFiniteSamplesDoNotProduceNonFinitePoints() {
        let points = Sparkline.points(for: [0.2, .nan, 0.8, .infinity], in: rect, scale: .fitToSeries)

        XCTAssertEqual(points.count, 4)
        for point in points {
            XCTAssertTrue(point.x.isFinite)
            XCTAssertTrue(point.y.isFinite)
        }
    }

    func testAZeroHeightRectStillProducesFinitePoints() {
        let flat = CGRect(x: 0, y: 5, width: 40, height: 0)
        let points = Sparkline.points(for: [1, 9, 4], in: flat, scale: .fitToSeries)

        XCTAssertEqual(points.count, 3)
        for point in points {
            XCTAssertEqual(point.y, 5, accuracy: 1e-9)
        }
    }

    // MARK: - Shape

    @MainActor
    func testShapeDrawsNothingForAnEmptySeries() {
        let path = SparklineShape(series: []).path(in: rect)

        XCTAssertTrue(path.isEmpty)
    }

    /// A blank card for the first second after launch reads as broken, so one sample is drawn as a
    /// flat trace across the full width rather than as an invisible single point.
    @MainActor
    func testShapeDrawsAFullWidthTraceForOneSample() {
        let path = SparklineShape(series: [0.5], scale: .unitInterval).path(in: rect)

        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingRect.minX, rect.minX, accuracy: 1e-6)
        XCTAssertEqual(path.boundingRect.maxX, rect.maxX, accuracy: 1e-6)
    }

    @MainActor
    func testFilledShapeClosesDownToTheBaseline() {
        let stroked = SparklineShape(series: [0.9, 0.9, 0.9], scale: .unitInterval).path(in: rect)
        let filled = SparklineShape(series: [0.9, 0.9, 0.9], scale: .unitInterval, isFilled: true).path(in: rect)

        XCTAssertLessThan(stroked.boundingRect.maxY, rect.maxY)
        XCTAssertEqual(filled.boundingRect.maxY, rect.maxY, accuracy: 1e-6)
    }

    /// The whole point of the flat-series guard: an idle machine must still get a drawable path.
    @MainActor
    func testShapeStaysDrawableForAFlatSeries() {
        let path = SparklineShape(series: Array(repeating: 0.0, count: 60)).path(in: rect)

        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.boundingRect.origin.x.isFinite)
        XCTAssertTrue(path.boundingRect.origin.y.isFinite)
        XCTAssertTrue(path.boundingRect.width.isFinite)
        XCTAssertTrue(path.boundingRect.height.isFinite)
    }
}
