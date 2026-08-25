import SwiftUI

/// How a sparkline's vertical axis is derived from the series it is drawing.
public enum SparklineScale: Equatable, Sendable {
    /// Stretch the series' own minimum and maximum across the full height. Right for network
    /// rates, where the interesting thing is the shape of the burst and there is no meaningful
    /// ceiling to plot against.
    case fitToSeries

    /// Pin the axis to a known domain. Right for CPU and memory, which are already fractions of
    /// one: auto-scaling them would turn a flat 3% idle trace into a dramatic-looking mountain.
    case fixed(lower: Double, upper: Double)

    /// The 0...1 domain shared by the CPU and memory series.
    public static let unitInterval = SparklineScale.fixed(lower: 0, upper: 1)
}

/// The series-to-points mapping behind `SparklineShape`.
///
/// Split out from the `Shape` and kept `nonisolated` and pure so the awkward cases — an empty
/// history at launch, a single sample one tick later, a perfectly flat series whose range is
/// zero — are testable without a view hierarchy.
public enum Sparkline {

    /// Evenly spaced points across `rect`, oldest sample at the leading edge.
    ///
    /// Returns an empty array for an empty series, and exactly one point for one sample: a single
    /// reading has no horizontal extent to spread over, so it is placed at the centre and the
    /// `Shape` decides how to draw it.
    public nonisolated static func points(
        for series: [Double],
        in rect: CGRect,
        scale: SparklineScale = .fitToSeries
    ) -> [CGPoint] {
        guard !series.isEmpty, rect.width.isFinite, rect.height.isFinite else {
            return []
        }

        let normalized = normalizedValues(series, scale: scale)

        guard series.count > 1 else {
            return [CGPoint(x: rect.midX, y: yPosition(forNormalized: normalized[0], in: rect))]
        }

        let step = rect.width / CGFloat(series.count - 1)

        return normalized.enumerated().map { index, value in
            CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: yPosition(forNormalized: value, in: rect)
            )
        }
    }

    /// Each sample mapped onto 0...1, where 0 is the bottom of the plot and 1 the top.
    ///
    /// The flat-series case is the one that matters: an idle machine reports the same CPU figure
    /// for a minute straight, and dividing by that zero range would put a NaN into the `Path`,
    /// which CoreGraphics answers by dropping the whole shape rather than by drawing something
    /// wrong. A range that is zero, negative or not finite therefore falls back to a line drawn
    /// down the middle.
    nonisolated static func normalizedValues(_ series: [Double], scale: SparklineScale) -> [Double] {
        // A metric that arrived as a NaN or an infinity would poison the min/max for every other
        // sample too, so it is neutralised here rather than at the point of use.
        let sanitized = series.map { $0.isFinite ? $0 : 0 }

        let lower: Double
        let upper: Double

        switch scale {
        case .fitToSeries:
            lower = sanitized.min() ?? 0
            upper = sanitized.max() ?? 0
        case let .fixed(fixedLower, fixedUpper):
            lower = fixedLower
            upper = fixedUpper
        }

        let range = upper - lower

        guard range.isFinite, range > .ulpOfOne else {
            return Array(repeating: 0.5, count: sanitized.count)
        }

        return sanitized.map { min(max(($0 - lower) / range, 0), 1) }
    }

    private nonisolated static func yPosition(forNormalized value: Double, in rect: CGRect) -> CGFloat {
        // View coordinates grow downwards, so the largest sample belongs at the smallest y.
        rect.maxY - CGFloat(value) * rect.height
    }
}

/// The sparkline itself: a polyline across the series, optionally closed down to the baseline so
/// it can be filled as well as stroked.
public struct SparklineShape: Shape {
    public var series: [Double]
    public var scale: SparklineScale
    /// When true the path runs on to the bottom corners and closes, turning the line into an area
    /// the caller can fill. The stroked and filled variants are drawn as two shapes so the fill
    /// never picks up the baseline as a visible edge.
    public var isFilled: Bool

    public init(series: [Double], scale: SparklineScale = .fitToSeries, isFilled: Bool = false) {
        self.series = series
        self.scale = scale
        self.isFilled = isFilled
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = Sparkline.points(for: series, in: rect, scale: scale)

        guard let first = points.first else {
            return path
        }

        if points.count == 1 {
            // One sample is not a line, but leaving the card blank for the first second after
            // launch reads as a broken chart. Draw the reading as a flat trace instead.
            path.move(to: CGPoint(x: rect.minX, y: first.y))
            path.addLine(to: CGPoint(x: rect.maxX, y: first.y))
        } else {
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }

        guard isFilled else {
            return path
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()

        return path
    }
}
