//
//  FocusIndicatorOverlay.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 16/10/26.
//


import SwiftUI

/// Yellow focus square on the subject, like the stock Camera app's
/// tap-to-focus indicator.
///
/// Pulses (shrinks in) each time focus moves to a new point, then rests at a
/// dimmer opacity so it does not compete with the guidance boxes.
struct FocusIndicatorOverlay: View {

    /// Focus point in NORMALISED view space (0...1), origin top-left.
    /// Nil when focus is not on a subject; nothing is drawn.
    let point: CGPoint?

    /// Changes each time a new focus command is sent, to replay the pulse.
    let pulseID: Int

    private let side: CGFloat = 64

    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0.6

    var body: some View {
        GeometryReader { geo in
            if let point {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: side, height: side)
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .position(x: point.x * geo.size.width,
                              y: point.y * geo.size.height)
                    .animation(.easeOut(duration: 0.25), value: point)
                    .onAppear(perform: pulse)
                    .onChange(of: pulseID) { pulse() }
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }

    private func pulse() {
        scale = 1.35
        opacity = 1
        withAnimation(.easeOut(duration: 0.3)) { scale = 1 }
        withAnimation(.easeOut(duration: 0.8).delay(0.6)) { opacity = 0.6 }
    }
}

#Preview {
    ZStack {
        Color.black
        FocusIndicatorOverlay(point: CGPoint(x: 0.5, y: 0.4), pulseID: 0)
    }
}
