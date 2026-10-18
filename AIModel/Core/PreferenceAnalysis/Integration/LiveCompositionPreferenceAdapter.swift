import Foundation
import CoreGraphics

/// Translates the analysed reference photos into the preferences the live camera can use.
///
/// Runs once, when the camera profile is built. It adds no analysis: every input is
/// something the offline pipeline already measured (`SubjectPositioningResult`), and every
/// rule about WHAT COUNTS AS A PATTERN comes from the profile itself:
///
///   - Horizontal habit: `ProfileAggregator.finding` (the same recurrence, majority and
///     "one photo is not a habit" rules the profile screen uses), applied to the thirds
///     zone of each photo's UPPER-BODY centre.
///   - Spread: the profile's own tolerances (`centerTolerance`, `areaCoefficientOfVariation`).
///   - Evidence: only photos the profile's coverage lists as determined for subject
///     positioning, graded at least `minimumQuality`.
///
/// WHY UPPER BODY. The live camera detects the upper body only, so only the upper-body box
/// is comparable with it. `PreferenceProfile.positioning` is built from the full-person box
/// and is deliberately not used for targets.
///
/// WHAT IS LEFT OUT (counted in `ReferenceAccounting`, never counted against anything):
///   - photos whose subject position was not determined (profile coverage is authoritative),
///   - photos with no upper-body box,
///   - photos graded below `minimumQuality` (low detection confidence, a tiny subject, or an
///     ambiguous choice of main subject),
///   - photos whose upper-body box touches the frame edge (centre and area describe only
///     part of the person, and the live camera treats a touching box the same way),
///   - photos whose orientation cannot be established.
///
/// ORIENTATION. Preferences are computed separately for portrait and landscape reference
/// photos. A live frame is only ever compared with preferences from its own orientation.
nonisolated enum LiveCompositionPreferenceAdapter {

    /// Reference photos graded below this are not used as live targets.
    static let minimumQuality: EvidenceQuality = .moderate

    /// Weakest recurrence accepted. `.limited` is the profile's own label for two agreeing
    /// photos, which is the least it ever calls a pattern.
    static let minimumStrength: PatternStrength = .limited

    /// A reference box within this distance of an edge counts as clipped. Must equal the live
    /// evaluator's `CompositionEvaluator.clipMargin`, so that a target is never learned from a
    /// framing the live camera would flag as cut off. Pinned by a test.
    static let clipMargin: CGFloat = 0.01

    private struct Sample {
        let result: PhotoResult
        let upper: CGRect
    }

    static func make(profile: PreferenceProfile, results: [PhotoResult]) -> LiveCompositionPreferences {
        var accounting = ReferenceAccounting()
        accounting.totalPhotos = results.count

        func unavailable(_ reason: PreferenceUnavailableReason) -> LiveCompositionPreferences {
            LiveCompositionPreferences(portrait: .unavailable(reason), landscape: .unavailable(reason),
                                       accounting: accounting)
        }

        // The profile and the results must describe the same photos, or the profile's
        // coverage says nothing about these results. Treat a mismatch as unusable.
        let ids = Set(results.map(\.id))
        guard let coverage = profile.coverage[.subjectPositioning],
              ids.count == results.count,
              coverage.totalPhotos == results.count,
              profile.totalPhotoCount == results.count,
              Set(coverage.determinedPhotoIDs).isSubset(of: ids)
        else { return unavailable(.profileInconsistent) }

        let determined = Set(coverage.determinedPhotoIDs)
        var portrait: [Sample] = []
        var landscape: [Sample] = []

        for result in results.sorted(by: { $0.selectionOrder < $1.selectionOrder }) {
            let positioning = result.subjectPositioning
            guard determined.contains(result.id), positioning.assessment.isDetermined, positioning.isMeasurementValid else {
                accounting.undeterminedPositioning += 1
                continue
            }
            guard let upper = positioning.upperBodyBox, ImageSpace.area(upper) > 0 else {
                accounting.noUpperBodyBox += 1
                continue
            }
            guard positioning.assessment.quality >= minimumQuality else {
                accounting.lowQuality += 1
                continue
            }
            guard ImageSpace.touchedEdges(of: upper, margin: clipMargin).isEmpty else {
                accounting.clippedUpperBody += 1
                continue
            }
            guard let prepared = result.preparation,
                  let orientation = FrameOrientation(width: Double(prepared.uprightWidth),
                                                     height: Double(prepared.uprightHeight)) else {
                accounting.unknownOrientation += 1
                continue
            }
            switch orientation {
            case .portrait: portrait.append(Sample(result: result, upper: upper))
            case .landscape: landscape.append(Sample(result: result, upper: upper))
            }
        }

        accounting.usablePortrait = portrait.count
        accounting.usableLandscape = landscape.count
        return LiveCompositionPreferences(portrait: slice(portrait), landscape: slice(landscape),
                                          accounting: accounting)
    }

    // MARK: Per-orientation slice

    private static func slice(_ samples: [Sample]) -> OrientationPreferences {
        switch samples.count {
        case 0: return .unavailable(.noUsableObservations)
        case 1: return .unavailable(.singleObservation, usable: 1)
        default:
            return OrientationPreferences(usableObservationCount: samples.count,
                                          horizontal: horizontal(samples), scale: scale(samples))
        }
    }

    private static func zone(of sample: Sample) -> HorizontalZone {
        SubjectPositioningMeasurer.horizontalZone(forCenterX: Double(sample.upper.midX))
    }

    private static func horizontal(_ samples: [Sample]) -> PreferenceSupport<HorizontalPreference> {
        let boxes = Dictionary(uniqueKeysWithValues: samples.map { ($0.result.id, $0) })
        let finding: CategoryFinding<HorizontalZone> = ProfileAggregator.finding(
            kind: nil, all: samples.map(\.result), possible: HorizontalZone.allCases.count,
            name: { (z: HorizontalZone) -> String in z.rawValue },
            observe: { (r: PhotoResult) -> (HorizontalZone, EvidenceQuality)? in
                guard let sample = boxes[r.id] else { return nil }
                return (zone(of: sample), r.subjectPositioning.assessment.quality)
            })

        switch finding.pattern {
        case .noEvidence: return .unavailable(.noUsableObservations)
        case .singleObservation: return .unavailable(.singleObservation)
        case .mixed: return .unavailable(.noRecurringPattern)
        case .recurring: break
        }
        guard let dominant = finding.dominant, finding.strength >= minimumStrength else {
            return .unavailable(.noRecurringPattern)
        }

        // One target for the recurring zone: the median of the photos in it.
        let xs = samples.filter { zone(of: $0) == dominant }.map { Double($0.upper.midX) }
        guard let summary = NumericSummary.make(xs), summary.count >= 2,
              summary.consistency(tolerance: ProfileAggregator.centerTolerance) == .tight else {
            return .unavailable(.tooVariable)
        }
        return .supported(HorizontalPreference(
            zone: dominant, targetX: summary.median, spread: summary.standardDeviation,
            agreeingCount: summary.count, observationCount: samples.count, strength: finding.strength))
    }

    private static func scale(_ samples: [Sample]) -> PreferenceSupport<ScalePreference> {
        let areas = samples.map { ImageSpace.area($0.upper) }
        guard let summary = NumericSummary.make(areas), summary.count >= 2, summary.mean > 0 else {
            return .unavailable(.noUsableObservations)
        }
        let ratio = summary.standardDeviation / summary.mean
        guard ratio <= ProfileAggregator.areaCoefficientOfVariation else { return .unavailable(.tooVariable) }
        return .supported(ScalePreference(targetArea: summary.median, spreadRatio: ratio,
                                          observationCount: summary.count))
    }
}
