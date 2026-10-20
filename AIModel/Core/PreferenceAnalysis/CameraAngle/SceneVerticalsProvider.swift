import Foundation
import CoreGraphics

/// Result of fitting how vertical edges lean as a function of where they are.
nonisolated struct ConvergenceFit: Sendable, Equatable {
    /// Lean (dx/dy) per unit of lateral position, image-height units.
    /// > 0: edges right of centre lean toward the centre going up, i.e. they
    /// converge upward (camera tilted UP). < 0: converge downward.
    let k: Double
    /// Lean of the edge at the centre column; a roll of the camera shows up here.
    let intercept: Double
    let standardError: Double
    let residualRMS: Double
    let inliers: [ImageLineSegment]
    /// Spread of the inliers' lateral positions. Convergence cannot be measured
    /// from edges that all sit at the same place.
    let lateralSpread: Double
    let totalLength: Double
}

/// Provider: convergence of vertical scene structure. DECISIVE when valid.
///
/// PHYSICS. Vertical lines in the world (walls, door frames, building corners,
/// lamp posts) are parallel. If the camera is level they stay parallel in the
/// photo; if it tilts up they converge toward a point above the frame, and if
/// it tilts down, toward a point below. The rate of convergence gives the tilt:
///
///      tan(tilt up) = f * k          (f = focal length, k = fitted convergence)
///
/// Tilt alone is not the camera angle. The camera angle relative to the
/// subject is the tilt plus how far the subject's eyes sit from the optical axis:
///
///      elevation (camera above eyes) = - tilt up + atan((eyeY - 0.5) / f)
///
/// This is the same geometry a horizon would give, obtained from building
/// structure instead. It is valid only where those lines exist and are
/// reliable; otherwise this provider reports why it could not observe.
///
/// VALIDITY CONDITIONS
///  - at least 6 vertical edges on man-made structure (segmentation filters out
///    trees, people, animals and natural surfaces),
///  - together at least one image-height long, spread over at least 10% of the
///    image width, consistent with one convergence model,
///  - the camera is not strongly rolled (verticals within ~7° of upright).
///
/// UNCERTAINTY POLICY
///  - The focal length is unknown, so the result is an interval over lenses.
///  - Error bars on the fitted convergence widen it further.
///  - The eye's position relative to the image centre is only trustworthy if
///    the photo was not cropped. A crop is undetectable, so the eye offset
///    carries a CROP ALLOWANCE (`LensModel.verticalCropAllowance`) that widens
///    the interval. The tilt measurement itself is unaffected by cropping.
///  - Quality is capped at MODERATE: perspective-correction edits (also
///    undetectable) would invalidate the convergence measurement.
nonisolated enum SceneVerticalsProvider {

    static let minimumSegments = 6
    static let minimumTotalLength = 1.0
    static let minimumLateralSpread = 0.10
    static let maximumRollLean = 0.12
    static let maximumResidualRMS = 0.012
    static let inlierTolerance = 0.015
    static let refineTolerance = 0.012
    /// Floor on the orientation noise of a fitted edge (about 0.35°).
    static let orientationNoiseFloor = 0.006
    static let levelToleranceDegrees = 3.0

    private static let structuralPrefixes = [
        "wall", "window", "door", "building", "house", "roof", "bridge", "ceiling", "cabinet",
        "shelf", "stairs", "fence", "tent", "banner", "platform", "curtain"
    ]
    private static let rejectedPrefixes = [
        "person", "tree", "grass", "flower", "fruit", "mountain", "rock", "sea", "water", "river",
        "sand", "snow", "dirt", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra",
        "giraffe", "bird", "potted"
    ]

    // MARK: Observation

    static func observe(lines: EvidenceOutcome<[ImageLineSegment]>,
                        segmentation: SegmentationGrid?,
                        segmentationProblem: String?,
                        anchor: SubjectAnchor?,
                        aspect: Double,
                        cropAllowance: Double,
                        lens: LensAssumption = .unknown) -> (observation: CameraAngleObservation, inliers: [ImageLineSegment]) {

        func none(_ validity: ProviderValidity, _ summary: String) -> (CameraAngleObservation, [ImageLineSegment]) {
            (.unavailable(.sceneVerticals, .decisive, validity, summary: summary), [])
        }

        let segments: [ImageLineSegment]
        switch lines {
        case .produced(let s): segments = s
        case .nothingDetected:
            return none(.notApplicable("No long vertical edges were found."),
                        "The photo has no long vertical structure to judge camera tilt from.")
        case .failed(let m), .skipped(let m):
            return none(.invalid("Edge analysis did not run: \(m)"), "Vertical structure could not be analysed.")
        }
        guard let segmentation else {
            return none(.invalid("Segmentation is needed to tell building edges from trees and people" +
                                 (segmentationProblem.map { " (\($0))" } ?? ".")),
                        "Vertical edges could not be checked against the scene, so they were not used.")
        }

        let structural = structuralSegments(segments, segmentation)
        guard structural.count >= minimumSegments else {
            return none(.notApplicable("Only \(structural.count) of \(segments.count) vertical edges lie on man-made structure (at least \(minimumSegments) are needed)."),
                        "There is too little vertical building structure in this photo to judge camera tilt.")
        }
        guard let fit = fit(structural, aspect: aspect) else {
            return none(.invalid("The vertical edges are too few, too clustered or too inconsistent to fit one convergence model."),
                        "Vertical structure was present but did not give a consistent tilt measurement.")
        }
        if fit.inliers.count < minimumSegments || fit.totalLength < minimumTotalLength {
            return none(.invalid("Only \(fit.inliers.count) consistent edges (\(String(format: "%.1f", fit.totalLength)) image heights) support the fit."),
                        "Too few consistent vertical edges to measure camera tilt.")
        }
        if fit.lateralSpread < minimumLateralSpread {
            return none(.invalid("The vertical edges sit in too narrow a part of the frame to measure how they converge."),
                        "The vertical edges are too close together to measure camera tilt.")
        }
        if abs(fit.intercept) > maximumRollLean {
            return none(.invalid(String(format: "The camera appears rolled by about %.0f°, beyond what this method handles.", CameraGeometry.degrees(atan(abs(fit.intercept))))),
                        "The camera is rolled too far for vertical lines to indicate tilt.")
        }
        if fit.residualRMS > maximumResidualRMS {
            return none(.invalid("The edges do not agree on a single convergence (residual \(String(format: "%.3f", fit.residualRMS)))."),
                        "The vertical edges disagree, so camera tilt was not measured.")
        }
        guard let anchor else {
            return none(.invalid("The subject's eye line could not be located."),
                        "Camera tilt was measured, but there is no eye line to compare it with.")
        }

        let eyeY = Double(anchor.eyePoint.y)
        let spread = [fit.k, fit.k - 2 * fit.standardError, fit.k + 2 * fit.standardError]

        let pitchDown = LensModel.interval(aspect: aspect, lens: lens) { f in
            spread.map { -CameraGeometry.degrees(atan(f * $0)) }
        }
        guard abs(pitchDown.nominal) <= 35 else {
            return none(.invalid("The implied camera tilt is outside the range where the approximation holds."),
                        "The vertical lines imply an extreme tilt, so they were not used.")
        }
        // Variants: tilt error bars x the eye offset shifted by a possible crop.
        let shifts = [0.0, -cropAllowance, cropAllowance]
        let elevation = LensModel.interval(aspect: aspect, lens: lens) { f in
            var values: [Double] = []
            for kk in spread {
                for shift in shifts {
                    values.append(CameraGeometry.elevation(pitchDownDegrees: -CameraGeometry.degrees(atan(f * kk)),
                                                           eyeY: eyeY + shift, f: f))
                }
            }
            return values
        }

        // Quality: capped at moderate, then lowered by explicit weaknesses.
        var quality: EvidenceQuality = .moderate
        var limitations = [
            lens.knownMM.map { "Assumes the photo was not perspective-corrected. The lens (\(Int($0.rounded())) mm equivalent) comes from the photo's metadata. A possible crop of up to \(Int(cropAllowance * 100))% of the frame height is allowed for." }
                ?? "Assumes the photo was not perspective-corrected and was taken with a phone-like lens (about 24-35 mm equivalent). A possible crop of up to \(Int(cropAllowance * 100))% of the frame height is allowed for."
        ]
        if fit.inliers.count < 10 {
            quality = quality.lowered()
            limitations.append("Only \(fit.inliers.count) vertical edges support the tilt measurement.")
        }
        if fit.lateralSpread < 0.20 {
            quality = quality.lowered()
            limitations.append("The vertical edges cover a narrow part of the frame.")
        }
        if anchor.isEstimated {
            quality = quality.lowered()
            limitations.append("The eye line was estimated from the face rectangle.")
        }
        if elevation.likelyHigh - elevation.likelyLow > 14 {
            quality = quality.lowered()
            limitations.append("The result is sensitive to the lens and to the tilt measurement.")
        }

        // Plain-language OBSERVATION. The verdict is the fusion's job: a provider's nominal
        // value can fall in a different category than the fused result when its
        // interval spans a boundary, so no conclusion is stated here.
        let tiltUp = CameraGeometry.degrees(atan(LensModel.focalLength(equivalentMM: lens.nominalMM, aspect: aspect) * fit.k))
        let tilt: CameraTilt = tiltUp > levelToleranceDegrees ? .up : (tiltUp < -levelToleranceDegrees ? .down : .level)
        let linesClause: String
        switch tilt {
        case .up: linesClause = "Vertical lines in the background converge upward (camera tilted up)"
        case .down: linesClause = "Vertical lines in the background converge downward (camera tilted down)"
        case .level: linesClause = "Vertical lines in the background stay nearly parallel (camera close to level)"
        }
        let offset = eyeY - 0.5
        let eyesClause = offset < -0.04 ? "the subject's eyes sit above the image center"
            : (offset > 0.04 ? "the subject's eyes sit below the image center" : "the subject's eyes sit near the image center")
        let summary = "\(linesClause), and \(eyesClause)."

        let measurements = [
            ObservationMeasurement(label: "Vertical edges used", value: structural.count == segments.count
                ? "\(fit.inliers.count) of \(segments.count) found"
                : "\(fit.inliers.count) of \(structural.count) on structure (\(segments.count) found)"),
            ObservationMeasurement(label: "Vertical lines", value: tilt == .up ? "converge upward" : (tilt == .down ? "converge downward" : "nearly parallel")),
            ObservationMeasurement(label: "Edge lean at center column", value: String(format: "%.1f°", CameraGeometry.degrees(atan(fit.intercept)))),
            ObservationMeasurement(label: "Eyes vs image center", value: String(format: "%+.0f%% of image height", offset * 100)),
            ObservationMeasurement(label: "Convergence rate", value: String(format: "%.4f ± %.4f per image height", fit.k, fit.standardError)),
            ObservationMeasurement(label: "Eye line (y)", value: String(format: "%.4f", eyeY)),
            ObservationMeasurement(label: "Fit", value: String(format: "residual %.4f, spread %.2f", fit.residualRMS, fit.lateralSpread))
        ]

        return (CameraAngleObservation(
            provider: .sceneVerticals, role: .decisive, validity: .valid, elevation: elevation, pitchDown: pitchDown,
            tiltHint: tilt, quality: quality, summary: summary, measurements: measurements, limitations: limitations),
                fit.inliers)
    }

    // MARK: Structure filter

    /// Keeps segments whose flanks are man-made structure and not people,
    /// vegetation, animals or natural surfaces.
    static func structuralSegments(_ segments: [ImageLineSegment], _ grid: SegmentationGrid) -> [ImageLineSegment] {
        func indices(_ prefixes: [String]) -> Set<Int> {
            Set(grid.labels.enumerated().filter { _, label in
                let l = label.lowercased()
                return prefixes.contains { l.hasPrefix($0) }
            }.map(\.offset))
        }
        let structure = indices(structuralPrefixes), rejected = indices(rejectedPrefixes)
        guard !structure.isEmpty else { return [] }

        let flank = 0.012
        return segments.filter { s in
            var passes = 0
            for step in 0..<7 {
                let t = 0.1 + 0.8 * Double(step) / 6
                let x = Double(s.start.x) + t * Double(s.end.x - s.start.x)
                let y = Double(s.start.y) + t * Double(s.end.y - s.start.y)
                let l = grid.classIndex(atNormalized: CGPoint(x: x - flank, y: y))
                let r = grid.classIndex(atNormalized: CGPoint(x: x + flank, y: y))
                if (structure.contains(l) || structure.contains(r)) && !rejected.contains(l) && !rejected.contains(r) {
                    passes += 1
                }
            }
            return passes >= 5
        }
    }

    // MARK: Convergence fit

    private struct Sample {
        let x: Double       // lateral position of the edge, from the image centre
        let m: Double       // lean dx/dy
        let w: Double       // length weight
        let segment: ImageLineSegment
    }

    /// Fits lean = intercept + k * x with an exhaustive, deterministic consensus
    /// search over pairs of the longest edges, then a weighted least-squares refinement.
    static func fit(_ segments: [ImageLineSegment], aspect: Double) -> ConvergenceFit? {
        let all: [Sample] = segments.compactMap { s in
            let dX = Double(s.end.x - s.start.x) * aspect, dY = Double(s.end.y - s.start.y)
            guard dY > 0.02 else { return nil }
            return Sample(x: (Double(s.start.x + s.end.x) / 2 - 0.5) * aspect, m: dX / dY, w: s.length, segment: s)
        }
        guard all.count >= minimumSegments else { return nil }

        let top = Array(all.sorted { $0.w != $1.w ? $0.w > $1.w : $0.x < $1.x }.prefix(40))
        var best: (score: Double, k: Double, c: Double)?
        for i in 0..<top.count {
            for j in (i + 1)..<top.count {
                let dx = top[j].x - top[i].x
                guard abs(dx) >= 0.04 else { continue }
                let k = (top[j].m - top[i].m) / dx
                guard abs(k) <= 1.5 else { continue }
                let c = top[i].m - k * top[i].x
                var score = 0.0
                for s in all where abs(s.m - (c + k * s.x)) <= inlierTolerance { score += s.w }
                if best == nil || score > best!.score + 1e-12 { best = (score, k, c) }
            }
        }
        guard var model = best.map({ (k: $0.k, c: $0.c) }) else { return nil }

        var inliers: [Sample] = []
        for _ in 0..<3 {
            inliers = all.filter { abs($0.m - (model.c + model.k * $0.x)) <= refineTolerance }
            guard inliers.count >= 3, let refined = weightedLeastSquares(inliers.map { ($0.x, $0.m, $0.w) }) else { return nil }
            model = refined
        }

        let sw = inliers.reduce(0) { $0 + $1.w }
        let residual = (inliers.reduce(0) { $0 + $1.w * pow($1.m - (model.c + model.k * $1.x), 2) } / sw).squareRoot()
        let meanX = inliers.reduce(0) { $0 + $1.w * $1.x } / sw
        let spread = (inliers.reduce(0) { $0 + $1.w * pow($1.x - meanX, 2) } / sw).squareRoot()
        let plainMean = inliers.reduce(0) { $0 + $1.x } / Double(inliers.count)
        let sxx = inliers.reduce(0) { $0 + pow($1.x - plainMean, 2) }
        guard sxx > 1e-9 else { return nil }
        let se = max(residual, orientationNoiseFloor) / sxx.squareRoot()

        return ConvergenceFit(k: model.k, intercept: model.c, standardError: se, residualRMS: residual,
                              inliers: inliers.map(\.segment), lateralSpread: spread,
                              totalLength: inliers.reduce(0) { $0 + $1.w })
    }

    private static func weightedLeastSquares(_ points: [(x: Double, y: Double, w: Double)]) -> (k: Double, c: Double)? {
        let sw = points.reduce(0) { $0 + $1.w }
        let sx = points.reduce(0) { $0 + $1.w * $1.x }, sy = points.reduce(0) { $0 + $1.w * $1.y }
        let sxx = points.reduce(0) { $0 + $1.w * $1.x * $1.x }, sxy = points.reduce(0) { $0 + $1.w * $1.x * $1.y }
        let denominator = sw * sxx - sx * sx
        guard abs(denominator) > 1e-12 else { return nil }
        let k = (sw * sxy - sx * sy) / denominator
        return (k, (sy - k * sx) / sw)
    }
}
