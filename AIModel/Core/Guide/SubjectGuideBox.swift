import SwiftUI

/// A dashed guide rectangle showing where the subject should be placed.
///
/// Derived from the user's own photography: the box is centred on the measured
/// mean subject position across their analysed photos, so framing the live
/// subject inside it reproduces their habitual composition.
///
/// Distinct from the thirds GRID — a grid is a fixed reference, this is a target
/// position, so it is deliberately not snapped to the thirds lines. When the
/// photographer's habit is the centre, the guide sits at the centre.
///
/// Drawn as a DASHED stroke: a solid guide would read as a captured edge
/// (indistinguishable from the detection box) and a real capture would overlap
/// it. A dash pattern reads as a construction line.
struct SubjectGuideBox: View {

    /// Measured mean subject position in NORMALISED coordinates (0...1),
    /// origin TOP-LEFT, y down — the same space the camera overlay draws in.
    let center: CGPoint

    /// Guide box size as a fraction of the frame.
    ///
    /// 0.707 is √0.5 inverted — it makes the box roughly TWICE THE AREA of the
    /// previous 0.5 box, so it reads as a generous placement region rather than
    /// a precise target.
    ///
    /// Kept below 1.0 deliberately: at 1.0 the box is the whole frame and the
    /// clamping below collapses every position to dead-centre, so the guide
    /// would stop reflecting WHERE the subject belongs (left / centre / right)
    /// and just become a full-frame rectangle. 0.707 keeps that position signal
    /// while being substantially larger.
    var sizeFraction: CGFloat = 0.500

    /// Spread of the user's subject placement, 0...1. Wider spread means less
    /// consistency, so the dash pattern opens up to suggest a looser fit.
    var spread: CGFloat = 0.10

    /// True when the sample was large and consistent enough to trust as a
    /// target. False renders a muted guide, since a habit measured from one or
    /// two photos is not a preference.
    var isConfident: Bool

    var body: some View {
        GeometryReader { geo in
            // Keep the WHOLE box on screen.
            //
            // A guide centred on the left third sits at x≈0.17, so a 0.34-wide
            // box would extend to x=0 — half of it drawn off-frame. A half-box
            // reads as "no guide", which is exactly what a left-side placement
            // looked like. The center is pulled toward the middle by the
            // smallest amount that keeps every edge visible; the position is
            // still recognisably left-of-centre, just fully drawn.
            let half = sizeFraction / 2
            let clampedX = min(max(center.x, half), 1 - half)
            let clampedY = min(max(center.y, half), 1 - half)

            let box = CGRect(
                x: (clampedX - half) * geo.size.width,
                y: (clampedY - half) * geo.size.height,
                width: sizeFraction * geo.size.width,
                height: sizeFraction * geo.size.height
            )

            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isConfident ? Color.green : Color.green.opacity(0.45),
                    style: StrokeStyle(
                        lineWidth: 2,
                        // Inconsistent placement opens the dashes — a tighter
                        // pattern reads as a precise target, which would
                        // overstate what the measurements support.
                        dash: spread > 0.16 ? [8, 6] : [5, 4]
                    )
                )
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
        }
        .allowsHitTesting(false)
    }
}
