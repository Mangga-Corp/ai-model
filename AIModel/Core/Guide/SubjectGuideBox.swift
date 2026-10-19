import SwiftUI

/// A dashed guide rectangle showing where the subject should be placed.
///
/// Derived from the user's own photography and drawn from the SAME target the composition
/// evaluator enforces (`LiveGuideTarget`): framing the live subject inside it reproduces the
/// user's habitual composition, and when the subject is inside it the evaluator agrees.
///
/// Distinct from the thirds GRID — a grid is a fixed reference, this is a target
/// position, so it is deliberately not snapped to the thirds lines. When the
/// photographer's habit is the centre, the guide sits at the centre.
///
/// Drawn as a DASHED stroke: a solid guide would read as a captured edge
/// (indistinguishable from the detection box) and a real capture would overlap
/// it. A dash pattern reads as a construction line.
///
/// COORDINATES. The view draws in FRAME space (normalised over the whole camera frame). It is
/// meant to be placed inside `FrameSpaceOverlay`, which maps frame space onto the aspect-filled
/// preview; used on its own it assumes frame and view have the same shape.
struct SubjectGuideBox: View {

    let target: LiveGuideTarget

    /// Size used when the target carries none (profiles without a scale preference).
    ///
    /// Deliberately a generous placement region rather than a precise target: it says WHERE the
    /// subject belongs (left / centre / right), not how large it should be. Kept below 1.0 so
    /// the box-clamping below does not collapse every position to dead-centre.
    var defaultSizeFraction: CGFloat = 0.500

    var body: some View {
        GeometryReader { geo in
            let box = Self.frame(for: target, defaultSize: defaultSizeFraction)

            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    target.isConfident ? Color.green : Color.green.opacity(0.45),
                    style: StrokeStyle(
                        lineWidth: 2,
                        // Inconsistent placement opens the dashes — a tighter
                        // pattern reads as a precise target, which would
                        // overstate what the measurements support.
                        dash: target.spread > 0.16 ? [8, 6] : [5, 4]
                    )
                )
                .frame(width: box.width * geo.size.width, height: box.height * geo.size.height)
                .position(x: box.midX * geo.size.width, y: box.midY * geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The guide rectangle in frame space. Pure, so it can be tested.
    ///
    /// The WHOLE box is kept inside the frame: a guide centred on the left third would
    /// otherwise extend past the edge and be drawn half off-frame, which reads as "no guide".
    /// The centre moves toward the middle by the smallest amount that keeps every edge in.
    /// With no vertical target the guide is a full-height band, so no height is implied.
    static func frame(for target: LiveGuideTarget, defaultSize: CGFloat = 0.5) -> CGRect {
        let width = CGFloat(target.width ?? Double(defaultSize))
        let halfWidth = width / 2
        let x = min(max(CGFloat(target.centerX), halfWidth), 1 - halfWidth)

        guard let centerY = target.centerY else {
            return CGRect(x: x - halfWidth, y: 0, width: width, height: 1)
        }
        let height = CGFloat(target.height ?? Double(defaultSize))
        let halfHeight = height / 2
        let y = min(max(CGFloat(centerY), halfHeight), 1 - halfHeight)
        return CGRect(x: x - halfWidth, y: y - halfHeight, width: width, height: height)
    }
}
