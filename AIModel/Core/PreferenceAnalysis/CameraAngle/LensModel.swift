import Foundation
import CoreGraphics

/// The focal length of the lens is NOT known: photos arrive as images with no
/// metadata. Any conversion from "pixels from the image centre" to "degrees"
/// needs it, so the uncertainty is modelled explicitly instead of hidden.
///
/// All lengths are in image-HEIGHT units (y in 0...1 is 1.0 high). A focal length
/// `f` in those units gives the angle of a point `d` below the optical axis as
/// atan(d / f).
///
/// ASSUMPTIONS (documented, deliberately conservative):
///  - 35 mm-equivalent focal length between 24 and 35 mm is the "likely" range
///    (the main camera of nearly every phone, the source of most reference
///    photos). Categories are decided against this range.
///  - 20 to 70 mm is the "extended" range (adds slightly wider lenses, 2x and
///    3x phone cameras and short telephoto). A result that would change inside
///    it is flagged as lens-sensitive and loses one quality grade.
///  - Longer lenses (85 mm portraits and above) and ultra-wide cameras
///    (about 13 mm) are outside both ranges: long lenses compress angles and
///    ultra-wides exaggerate them, so the true angle can differ from the estimate.
///  - The principal point is the image centre, up to the CROP ALLOWANCE below.
nonisolated enum LensModel {

    /// Diagonal of a 35 mm frame, in mm.
    static let fullFrameDiagonal = 43.27
    static let nominalMM = 26.0
    static let likelyMM: [Double] = [24, 26, 28, 35]
    static let extendedMM: [Double] = [20, 24, 26, 28, 35, 50, 70]

    /// Width / height of the upright image; 3:4 portrait when unknown.
    static func aspect(of size: CGSize?) -> Double {
        guard let size, size.width > 0, size.height > 0 else { return 0.75 }
        return Double(size.width / size.height)
    }

    /// Focal length in image-height units for a 35 mm-equivalent focal length.
    static func focalLength(equivalentMM mm: Double, aspect: Double) -> Double {
        (mm / fullFrameDiagonal) * (1 + aspect * aspect).squareRoot()
    }

    /// Evaluates `value` over the lens ranges. `value(f)` returns the nominal-case
    /// quantity first, followed by any extra variants (for example pitch error bars).
    static func interval(aspect: Double, value: (_ f: Double) -> [Double]) -> AngleInterval {
        func span(_ mms: [Double]) -> (Double, Double) {
            let all = mms.flatMap { value(focalLength(equivalentMM: $0, aspect: aspect)) }
            return (all.min() ?? 0, all.max() ?? 0)
        }
        let nominal = value(focalLength(equivalentMM: nominalMM, aspect: aspect)).first ?? 0
        let likely = span(likelyMM), extended = span(extendedMM)
        return AngleInterval(nominal: nominal, likelyLow: likely.0, likelyHigh: likely.1,
                             extendedLow: extended.0, extendedHigh: extended.1)
    }

    /// A photo whose aspect ratio is not a native camera format was probably cropped.
    static func looksUncropped(aspect: Double) -> Bool {
        let r = max(aspect, 1 / aspect)
        return abs(r - 4.0 / 3.0) < 0.04 || abs(r - 1.5) < 0.04 || abs(r - 16.0 / 9.0) < 0.05
    }

    /// How far, in image heights, the true optical axis may sit from the image
    /// centre because the photo was cropped.
    ///
    /// A crop cannot be detected from the pixels, only made more or less
    /// plausible by the proportions. 4:3 is what phones record by default, so
    /// a crop is unlikely. 3:2 is a native DSLR format and a common phone
    /// option. 16:9 is native too, but is also the usual way people trim a 4:3
    /// photo, with an arbitrary vertical offset (up to ~0.17 of the frame), so
    /// it allows the most among native ratios. Any other ratio is a crop.
    /// Measured: a level, eye-height photo trimmed to 16:9 moved the eyes by
    /// 0.18 of the frame and flipped the result to "low angle" without this term.
    static func verticalCropAllowance(aspect: Double) -> Double {
        let r = max(aspect, 1 / aspect)
        if abs(r - 4.0 / 3.0) < 0.04 { return 0.05 }
        if abs(r - 1.5) < 0.04 { return 0.08 }
        if abs(r - 16.0 / 9.0) < 0.05 { return 0.15 }
        return 0.20
    }
}

/// Geometry shared by the decisive providers. Angles in degrees.
nonisolated enum CameraGeometry {

    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// The camera looks DOWN by this much when the horizon sits `0.5 - horizonY`
    /// above the image centre. Positive = pitched down.
    static func pitchDown(horizonY: Double, f: Double) -> Double {
        degrees(atan((0.5 - horizonY) / f))
    }

    /// Elevation of the camera relative to the eyes: the direction to the eyes
    /// is the camera's pitch plus the eyes' offset from the optical axis.
    /// Positive = camera ABOVE the eyes (looking down on the subject).
    static func elevation(pitchDownDegrees: Double, eyeY: Double, f: Double) -> Double {
        pitchDownDegrees + degrees(atan((eyeY - 0.5) / f))
    }
}
