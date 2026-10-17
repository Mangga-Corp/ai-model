import SwiftUI

/// An overlay that explains a measurement.
enum EvidenceLayer: String, CaseIterable, Identifiable, Hashable {
    case subjectBox, center, thirdsGrid, poseLandmarks, horizon, sceneLines, personMask, depthMap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subjectBox: return "Subject box"
        case .center: return "Center"
        case .thirdsGrid: return "Thirds grid"
        case .poseLandmarks: return "Pose"
        case .horizon: return "Horizon"
        case .sceneLines: return "Vertical lines"
        case .personMask: return "Person mask"
        case .depthMap: return "Depth"
        }
    }

    var symbol: String {
        switch self {
        case .subjectBox: return "rectangle.dashed"
        case .center: return "plus.viewfinder"
        case .thirdsGrid: return "grid"
        case .poseLandmarks: return "figure.stand"
        case .horizon: return "water.waves"
        case .sceneLines: return "building.2"
        case .personMask: return "person.fill"
        case .depthMap: return "square.3.layers.3d.down.right"
        }
    }

    /// Layers backed by real data for this photo. A layer without evidence is
    /// never offered, so nothing is drawn that the pipeline did not produce.
    static func available(for photo: PhotoResult, artifacts: PhotoArtifacts?) -> [EvidenceLayer] {
        var layers: [EvidenceLayer] = []
        let positioning = photo.subjectPositioning
        if positioning.isMeasurementValid, positioning.subjectBox != nil {
            layers += [.subjectBox, .center, .thirdsGrid]
        }
        if let poses = photo.evidence?.pose.value, poses.contains(where: { !$0.reliableLandmarks().isEmpty }) {
            layers.append(.poseLandmarks)
        }
        if photo.cameraAngle.horizonCue != nil { layers.append(.horizon) }
        if !photo.cameraAngle.sceneLines.isEmpty { layers.append(.sceneLines) }
        if let seg = artifacts?.segmentation, seg.personClassIndex != nil,
           (photo.evidence?.segmentation.value?.personFraction ?? 0) > 0 {
            layers.append(.personMask)
        }
        if artifacts?.depth != nil { layers.append(.depthMap) }
        return layers
    }

    static func defaultSelection(from available: [EvidenceLayer]) -> Set<EvidenceLayer> {
        // Evidence that decided the camera angle is shown by default, so the result is explained.
        Set(available.filter { $0 == .subjectBox || $0 == .thirdsGrid || $0 == .horizon || $0 == .sceneLines })
    }
}

/// The upright photo with overlays drawn in normalised image space.
///
/// The container takes exactly the image's aspect-fitted size, so the overlay's
/// coordinate space IS the image: a normalised point maps to
/// (x * width, y * height) with no extra letterbox arithmetic. The same
/// convention is documented in `ImageSpace`.
struct EvidenceImageView: View {
    let image: UIImage
    let photo: PhotoResult
    let artifacts: PhotoArtifacts?
    let layers: Set<EvidenceLayer>

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        rasterLayers(size: geo.size)
                        Canvas { context, size in draw(into: &context, size: size) }
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reference photo with \(layers.count) analysis overlay\(layers.count == 1 ? "" : "s")")
    }

    // MARK: Raster overlays

    @ViewBuilder
    private func rasterLayers(size: CGSize) -> some View {
        if layers.contains(.depthMap), let depth = artifacts?.depth,
           let img = OverlayImageCache.image(key: "\(photo.id)-depth", make: { OverlayRasterizer.depthHeatmap(depth) }) {
            Image(uiImage: img).resizable().interpolation(.medium).frame(width: size.width, height: size.height)
        }
        if layers.contains(.personMask), let seg = artifacts?.segmentation,
           let img = OverlayImageCache.image(key: "\(photo.id)-mask", make: { OverlayRasterizer.personMask(seg) }) {
            Image(uiImage: img).resizable().interpolation(.none).frame(width: size.width, height: size.height)
        }
    }

    // MARK: Vector overlays

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
        }

        let positioning = photo.subjectPositioning

        if layers.contains(.thirdsGrid), positioning.isMeasurementValid {
            if let c = positioning.center {
                // Highlight the cell that holds the subject's centre.
                let col = min(2, Int(c.x * 3)), row = min(2, Int(c.y * 3))
                let cell = CGRect(x: CGFloat(col) / 3 * size.width, y: CGFloat(row) / 3 * size.height,
                                  width: size.width / 3, height: size.height / 3)
                context.fill(Path(cell), with: .color(.green.opacity(0.14)))
            }
            var grid = Path()
            for i in 1...2 {
                let f = CGFloat(i) / 3
                grid.move(to: CGPoint(x: f * size.width, y: 0)); grid.addLine(to: CGPoint(x: f * size.width, y: size.height))
                grid.move(to: CGPoint(x: 0, y: f * size.height)); grid.addLine(to: CGPoint(x: size.width, y: f * size.height))
            }
            context.stroke(grid, with: .color(.white.opacity(0.75)), lineWidth: 1)
        }

        if layers.contains(.horizon), let cue = photo.cameraAngle.horizonCue {
            let h = cue.horizon
            var line = Path()
            line.move(to: point(CGPoint(x: 0, y: h.y(atX: 0))))
            line.addLine(to: point(CGPoint(x: 1, y: h.y(atX: 1))))
            context.stroke(line, with: .color(.orange), lineWidth: 2.5)

            let eye = point(cue.eyePoint)
            let onHorizon = point(CGPoint(x: cue.eyePoint.x, y: h.y(atX: Double(cue.eyePoint.x))))
            var link = Path(); link.move(to: eye); link.addLine(to: onHorizon)
            context.stroke(link, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            context.fill(Path(ellipseIn: CGRect(x: eye.x - 5, y: eye.y - 5, width: 10, height: 10)), with: .color(.cyan))
        }

        if layers.contains(.sceneLines) {
            var lines = Path()
            for segment in photo.cameraAngle.sceneLines {
                lines.move(to: point(segment.start)); lines.addLine(to: point(segment.end))
            }
            context.stroke(lines, with: .color(.cyan), lineWidth: 2.5)
        }

        if layers.contains(.poseLandmarks), let poses = photo.evidence?.pose.value {
            let links: [(BodyJoint, BodyJoint)] = [
                (.neck, .nose), (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
                (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.leftShoulder, .leftHip),
                (.rightShoulder, .rightHip), (.leftHip, .rightHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
                (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
            ]
            for pose in poses {
                var bones = Path()
                for (a, b) in links {
                    if let la = pose.reliable(a), let lb = pose.reliable(b) {
                        bones.move(to: point(la.point)); bones.addLine(to: point(lb.point))
                    }
                }
                context.stroke(bones, with: .color(.pink.opacity(0.9)), lineWidth: 2)
                for landmark in pose.reliableLandmarks() {
                    let p = point(landmark.point)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.yellow))
                }
            }
        }

        if layers.contains(.subjectBox), let box = positioning.subjectBox {
            for other in positioning.secondarySubjects {
                context.stroke(Path(rect(other.box)), with: .color(.yellow),
                               style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            context.stroke(Path(roundedRect: rect(box), cornerRadius: 3), with: .color(.green), lineWidth: 3)
        }

        if layers.contains(.center), let c = positioning.center {
            let p = point(c)
            var cross = Path()
            cross.move(to: CGPoint(x: p.x - 12, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 12, y: p.y))
            cross.move(to: CGPoint(x: p.x, y: p.y - 12)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 12))
            context.stroke(cross, with: .color(.white), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.green))
        }
    }
}

/// Horizontally scrolling toggles for the available overlays.
struct EvidenceLayerPicker: View {
    let available: [EvidenceLayer]
    @Binding var selection: Set<EvidenceLayer>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(available) { layer in
                    let isOn = selection.contains(layer)
                    Button {
                        if isOn { selection.remove(layer) } else { selection.insert(layer) }
                    } label: {
                        Label(layer.title, systemImage: layer.symbol)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(isOn ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isOn ? "On" : "Off")
                    .accessibilityHint("Toggles the \(layer.title) overlay")
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
