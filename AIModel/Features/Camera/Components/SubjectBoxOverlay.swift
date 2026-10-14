import SwiftUI

/// Draws the detected subject's bounding box over the live camera feed.
///
/// The same visual language as the analysis page's subject box, so a subject
/// looks the same whether it was detected live or in a stored photo.
///
/// Subject only — no face box. Face detection needs the subject facing the
/// camera and adds a second Vision pass per frame, and the composition
/// guidance this supports does not depend on where the face is.
struct SubjectBoxOverlay: View {

    /// Box in NORMALISED view space (0...1), origin top-left, y down.
    /// Nil when no person is detected.
    let box: CGRect?

    var body: some View {
        GeometryReader { geo in
            if let box {
                let frame = CGRect(
                    x: box.origin.x * geo.size.width,
                    y: box.origin.y * geo.size.height,
                    width: box.width * geo.size.width,
                    height: box.height * geo.size.height
                )

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.green, lineWidth: 2)

                    Text("Subject")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .offset(y: -14)
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ZStack {
        Color.black
        SubjectBoxOverlay(box: CGRect(x: 0.25, y: 0.30, width: 0.5, height: 0.4))
    }
}
