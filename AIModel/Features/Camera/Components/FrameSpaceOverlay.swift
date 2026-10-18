import SwiftUI

/// Places overlays that are expressed in camera-FRAME space onto the aspect-filled preview.
///
/// The preview scales the whole frame uniformly until it covers the viewfinder and crops the
/// overflow. Every overlay (subject box, guide, object labels, focus square) multiplies a
/// frame-normalised value by the size it is given, so giving them the SIZE OF THE SCALED FRAME,
/// centred on the viewfinder, makes them all line up with the picture. This is the one place
/// that conversion happens; the overlays themselves are unchanged.
///
/// The container extends beyond the viewfinder along the cropped axis; the viewfinder clips it.
/// With an unknown frame size it fills the viewfinder, which is the previous behaviour.
struct FrameSpaceOverlay<Content: View>: View {

    let frameSize: CGSize?
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            let fill = PreviewGeometry.aspectFillRect(frameSize: frameSize, in: geo.size)
            ZStack { content }
                .frame(width: fill.width, height: fill.height)
                .position(x: fill.midX, y: fill.midY)
        }
        .allowsHitTesting(false)
    }
}
