//
//  ObjectLabelsOverlay.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 16/10/26.
//


import SwiftUI

/// Draws a thin outline and a name chip for each detected object (car,
/// table…) over the camera preview.
///
/// Boxes are in NORMALISED view space (0...1, top-left origin), the same space
/// as `SubjectBoxOverlay`, so both overlays line up with each other.
struct ObjectLabelsOverlay: View {

    let objects: [DetectedObject]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ForEach(objects) { object in
                let frame = CGRect(
                    x: object.boundingBox.minX * size.width,
                    y: object.boundingBox.minY * size.height,
                    width: object.boundingBox.width * size.width,
                    height: object.boundingBox.height * size.height
                )

                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .overlay(alignment: .topLeading) {
                        // Name chip just inside the box's top-left corner.
                        Text(object.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .fixedSize()
                            .padding(4)
                    }
                    .position(x: frame.midX, y: frame.midY)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Detected \(object.displayName)")
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: objects.map(\.boundingBox))
    }
}
