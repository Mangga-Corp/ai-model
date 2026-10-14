import SwiftUI
import CoreGraphics

/// Renders the detected characteristics of a single photo as visual overlays.
///
/// Every overlay corresponds to an actual measurement in `PhotoAnalysis` —
/// nothing here is decorative. Vision reports coordinates with the origin at
/// the BOTTOM-LEFT and y increasing upward; SwiftUI's coordinate space is
/// TOP-LEFT with y increasing downward. `VisionGeometry` handles that flip.
///
/// Which overlays appear depends on what the model actually detected:
/// a photo with no horizon draws no horizon line, rather than a guessed one.
/// (PRD Rule 4: missing data is not absent data.)
struct AnalysisOverlayView: View {

    let analysis: PhotoAnalysis

    /// Which overlay layers to draw.
    var showRuleOfThirds = true
    var showSubjectBox = true
    var showFaceBox = true
    var showHorizon = true
    var showLeadingLines = true
    var showLightDirection = true

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                // Rule of thirds grid — a reference frame, not a detection.
                if showRuleOfThirds {
                    RuleOfThirdsGrid(size: size)
                }

                // Subject bounding box (DetectHumanRectanglesRequest)
                if showSubjectBox, let box = analysis.subjectBoxViewSpace {
                    VisionBox(box: box, size: size, color: .green, label: "Subject")
                }

                // Face bounding box (DetectFaceRectanglesRequest)
                if showFaceBox, let box = analysis.faceBoxViewSpace {
                    VisionBox(box: box, size: size, color: .yellow, label: "Face")
                }

                // Horizon line (DetectHorizonRequest)
                if showHorizon, let position = analysis.horizonVerticalPosition {
                    HorizonLine(position: position, size: size, angle: analysis.horizonAngle ?? 0)
                }

                // Leading lines (DetectContoursRequest)
                if showLeadingLines, let lines = analysis.leadingLines, lines.isAvailable {
                    ForEach(Array(lines.lines.enumerated()), id: \.offset) { _, line in
                        LineSegment(line: line, size: size)
                    }
                }

                // Light direction arrow (Sobel gradient estimate)
                if showLightDirection,
                   let direction = analysis.lightDirection,
                   analysis.hasLightDirection {
                    LightArrow(direction: direction, confidence: analysis.lightDirectionConfidence ?? 0, size: size)
                }
            }
        }
    }
}

// MARK: - Rule of Thirds Grid

/// A 3×3 reference grid. This is a compositional reference, not a detection —
/// it is drawn the same way for every photo.
private struct RuleOfThirdsGrid: View {
    let size: CGSize

    var body: some View {
        Path { path in
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3.0
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))

                let y = size.height * CGFloat(i) / 3.0
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}

// MARK: - Vision Bounding Box

/// Draws a bounding box in normalized view space with a label.
///
/// The rect arrives already flipped into top-left coordinates by the model's
/// `subjectBoxViewSpace` / `faceBoxViewSpace` accessors, so this only scales it
/// into pixel space.
private struct VisionBox: View {
    let box: CGRect
    let size: CGSize
    let color: Color
    let label: String

    var body: some View {
        let origin = CGPoint(x: box.origin.x * size.width, y: box.origin.y * size.height)
        let boxSize = CGSize(width: box.width * size.width, height: box.height * size.height)

        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(color, lineWidth: 2)

            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(color)
                .foregroundStyle(.black)
                .offset(y: -18)
        }
        .frame(width: boxSize.width, height: boxSize.height)
        .position(x: origin.x + boxSize.width / 2, y: origin.y + boxSize.height / 2)
    }
}

// MARK: - Horizon Line

/// Draws the detected horizon, tilted by its measured angle.
private struct HorizonLine: View {
    let position: Double   // 0 (top) to 1 (bottom)
    let size: CGSize
    let angle: Double      // degrees

    var body: some View {
        // `position` is normalized top-down already (VisionAnalysisService flips it).
        let y = position * size.height
        let radians = angle * .pi / 180

        // Half-length so a tilted line still spans the frame.
        let halfLength = size.width / 2

        Path { path in
            path.move(to: CGPoint(x: size.width / 2 - halfLength, y: y + halfLength * tan(radians)))
            path.addLine(to: CGPoint(x: size.width / 2 + halfLength, y: y - halfLength * tan(radians)))
        }
        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
    }
}

// MARK: - Leading Line Segment

/// Draws one detected structural line segment.
private struct LineSegment: View {
    let line: DetectedLine
    let size: CGSize

    var body: some View {
        // DetectedLine is already stored in UIKit (top-down) coordinates.
        Path { path in
            path.move(to: CGPoint(x: line.start.x * size.width, y: line.start.y * size.height))
            path.addLine(to: CGPoint(x: line.end.x * size.width, y: line.end.y * size.height))
        }
        .stroke(Color.orange.opacity(0.9), lineWidth: 2)
    }
}

// MARK: - Light Direction Arrow

/// Draws an arrow from the frame center toward the estimated light source.
/// The label states the direction and that it is an estimate.
private struct LightArrow: View {
    let direction: LightDirection
    let confidence: Double
    let size: CGSize

    /// Unit vector toward the light, in SwiftUI space (y down).
    private var vector: CGVector {
        switch direction {
        case .topLeft:     return CGVector(dx: -0.7, dy: -0.7)
        case .top:         return CGVector(dx: 0, dy: -1)
        case .topRight:    return CGVector(dx: 0.7, dy: -0.7)
        case .left:        return CGVector(dx: -1, dy: 0)
        case .center:      return CGVector(dx: 0, dy: 0)
        case .right:       return CGVector(dx: 1, dy: 0)
        case .bottomLeft:  return CGVector(dx: -0.7, dy: 0.7)
        case .bottom:      return CGVector(dx: 0, dy: 1)
        case .bottomRight: return CGVector(dx: 0.7, dy: 0.7)
        }
    }

    var body: some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let length = min(size.width, size.height) * 0.3
        let v = vector

        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x + v.dx * length, y: center.y + v.dy * length))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            // Arrowhead
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .position(x: center.x + v.dx * length, y: center.y + v.dy * length)

            Text("☀ \(direction.rawValue)")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .offset(y: 6)
        }
        .opacity(0.5 + confidence * 0.5)  // fainter when less confident
    }
}
