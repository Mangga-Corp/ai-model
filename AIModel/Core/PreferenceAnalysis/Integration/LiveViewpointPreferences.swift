//
//  LiveViewpointPreferences.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//


import Foundation

/// The user's viewpoint habits, shaped for the live camera's "match my photos"
/// targets. Derived once from the `PreferenceProfile` when the camera profile is
/// built (`CameraProfileBridge`), with the profile's own recurrence rules: a
/// habit needs at least two agreeing photos and a clear majority. Anything less
/// is unavailable with its reason, never defaulted.
nonisolated struct LiveViewpointPreferences: Hashable, Sendable {
    let angle: PreferenceSupport<CameraAngleCategory>
    let heightLevel: PreferenceSupport<CameraHeightLevel>
    /// Range of camera pitch, degrees, positive = tilted UP (the live convention).
    let pitchUp: PreferenceSupport<ClosedRange<Double>>
    let dutchAngle: PreferenceSupport<DutchAngleCategory>

    static let noData = LiveViewpointPreferences(
        angle: .unavailable(.noPreferenceData), heightLevel: .unavailable(.noPreferenceData),
        pitchUp: .unavailable(.noPreferenceData), dutchAngle: .unavailable(.noPreferenceData))

    /// Pitch habits wider than this standard deviation are not one target.
    static let pitchSpreadLimit = 8.0
    /// Narrowest pitch window offered as a target, either side of the median.
    static let minimumPitchHalfWidth = 5.0

    static func make(profile: PreferenceProfile) -> LiveViewpointPreferences {
        let viewpoint = profile.viewpoint
        return LiveViewpointPreferences(
            angle: support(profile.cameraAngle),
            heightLevel: viewpoint.map { support($0.heightLevel) } ?? .unavailable(.noPreferenceData),
            pitchUp: pitch(viewpoint?.pitchDown),
            dutchAngle: viewpoint.map { support($0.dutchAngle) } ?? .unavailable(.noPreferenceData))
    }

    static func support<C: Hashable & Sendable>(_ finding: CategoryFinding<C>) -> PreferenceSupport<C> {
        switch finding.pattern {
        case .noEvidence: return .unavailable(.noUsableObservations)
        case .singleObservation: return .unavailable(.singleObservation)
        case .mixed: return .unavailable(.noRecurringPattern)
        case .recurring:
            guard let dominant = finding.dominant else { return .unavailable(.noRecurringPattern) }
            return .supported(dominant)
        }
    }

    static func pitch(_ pitchDown: NumericSummary?) -> PreferenceSupport<ClosedRange<Double>> {
        guard let s = pitchDown, s.count > 0 else { return .unavailable(.noUsableObservations) }
        guard s.count >= 2 else { return .unavailable(.singleObservation) }
        guard s.standardDeviation <= pitchSpreadLimit else { return .unavailable(.tooVariable) }
        let center = -s.median
        let half = max(minimumPitchHalfWidth, s.standardDeviation)
        return .supported((center - half)...(center + half))
    }
}
