import Foundation
import CoreGraphics

/// Resolves a photographer's measured composition habit into a guide position.
///
/// The input is the HALF-BODY position distribution — where the upper-body
/// (torso/head) box centre sits across analysed photos — because the guide box
/// targets a half-body framing, not the full-body centre.
///
/// The profile is measured from analysed PHOTOS, where position is recorded with
/// a bottom-left, y-up origin (UIKit image coordinates). The camera overlay
/// draws top-left, y-down. Mixing those two spaces is the single easiest way to
/// place a guide upside-down, so the conversion happens in one named place.
struct SubjectGuideResolver {

    struct Guide: Equatable {
        /// Center in NORMALISED overlay space: origin top-left, y down, 0...1.
        let center: CGPoint
        /// Spread of the user's placement, 0...1.
        let spread: CGFloat
        /// True when the sample supports using this as a target.
        let isConfident: Bool

        /// Why no guide was offered, when `center` is nil.
        var unavailableReason: String?
    }

    /// Resolves the guide from measured distributions.
    ///
    /// Always returns a Guide — check `isConfident` and `unavailableReason` to
    /// tell whether it is usable. Returning nil instead would discard the
    /// reason, leaving nothing to explain why no guide was shown.
    static func resolve(
        position: PositionDistribution?,
        photoCount: Int
    ) -> Guide {
        guard let position else {
            return Guide(
                center: .zero,
                spread: 0,
                isConfident: false,
                unavailableReason: "No placement measurements yet."
            )
        }

        // A single photo is a data point, not a habit.
        guard photoCount >= 2 else {
            return Guide(
                center: .zero,
                spread: 0,
                isConfident: false,
                unavailableReason: "Analyse at least 2 photos to learn your placement."
            )
        }

        let spread = max(
            CGFloat(position.stdDevX),
            CGFloat(position.stdDevY)
        )

        // Spread beyond this means the subject lands all over the frame — there
        // is no stable zone to point at.
        guard spread <= 0.28, position.isConsistent else {
            return Guide(
                center: .zero,
                spread: spread,
                isConfident: false,
                unavailableReason: "Your placement varies too much across photos to suggest a position."
            )
        }

        // NO y-flip here. The profile's position values are ALREADY stored in
        // UIKit space (y-down, top-left origin) — `VisionAnalysisService` flips
        // Vision's y-up coordinates at storage time. Flipping again here would
        // mirror the guide vertically: a subject placed low in the photo would
        // get a guide in the upper frame. The overlay draws in the same y-down
        // space the profile is stored in, so x and y pass through unchanged.
        let center = CGPoint(
            x: position.meanX,
            y: position.meanY
        )

        return Guide(
            center: center,
            spread: spread,
            isConfident: photoCount >= 3
        )
    }
}
