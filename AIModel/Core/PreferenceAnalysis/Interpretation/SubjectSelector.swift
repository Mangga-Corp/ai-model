import Foundation
import CoreGraphics

/// The outcome of choosing the primary human subject.
nonisolated struct SubjectSelection: Sendable, Equatable {
    let primary: HumanCandidate?
    /// Other eligible people, most prominent first.
    let secondaries: [HumanCandidate]
    /// Every detection except the primary, eligible or not. Used to judge
    /// whether other people could contaminate a person mask.
    let otherDetections: [HumanCandidate]
    let info: SubjectSelectionInfo
}

/// Deterministic primary-subject policy (documented in `SubjectSelectionInfo.policy`).
///
/// The same detections always produce the same choice, independent of the
/// order Vision happened to return them in. Other people are preserved as
/// secondary subjects rather than discarded.
nonisolated enum SubjectSelector {

    static let minimumConfidence = 0.30
    static let minimumArea = 0.005
    /// A runner-up this large (relative to the primary) makes the choice ambiguous.
    static let ambiguityRatio = 0.6
    /// Areas within this relative gap are treated as tied.
    static let tieTolerance = 0.02

    static func select(from candidates: [HumanCandidate]) -> SubjectSelection {
        let eligible = candidates.filter { $0.confidence >= minimumConfidence && $0.area >= minimumArea }

        guard let maxArea = eligible.map(\.area).max() else {
            return SubjectSelection(
                primary: nil, secondaries: [], otherDetections: candidates,
                info: SubjectSelectionInfo(detectedCount: candidates.count, eligibleCount: 0,
                                           primaryCandidateID: nil, isAmbiguous: false))
        }

        // Candidates within the tie tolerance of the largest compete on
        // confidence, then centrality, then leftmost position, then index.
        let contenders = eligible.filter { $0.area >= maxArea * (1 - tieTolerance) }
        let primary = contenders.sorted { a, b in
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            let da = distanceFromCentre(a.box), db = distanceFromCentre(b.box)
            if da != db { return da < db }
            if a.box.minX != b.box.minX { return a.box.minX < b.box.minX }
            return a.id < b.id
        }[0]

        let secondaries = eligible
            .filter { $0.id != primary.id }
            .sorted { $0.area != $1.area ? $0.area > $1.area : $0.id < $1.id }

        let ambiguous = secondaries.first.map { $0.area >= primary.area * ambiguityRatio } ?? false
        return SubjectSelection(
            primary: primary, secondaries: secondaries,
            otherDetections: candidates.filter { $0.id != primary.id },
            info: SubjectSelectionInfo(detectedCount: candidates.count, eligibleCount: eligible.count,
                                       primaryCandidateID: primary.id, isAmbiguous: ambiguous))
    }

    private static func distanceFromCentre(_ box: CGRect) -> Double {
        let dx = Double(box.midX) - 0.5, dy = Double(box.midY) - 0.5
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Association helpers

/// Ties pose and face observations to the primary subject by geometry, since
/// Vision returns them as independent lists.
nonisolated enum SubjectAssociation {

    /// The pose whose reliable landmarks mostly fall inside the subject's box.
    static func pose(for box: CGRect, among poses: [PoseCandidate]) -> PoseCandidate? {
        let region = ImageSpace.expanded(box, by: 0.08)
        var best: (pose: PoseCandidate, score: Double)?
        for pose in poses {
            let reliable = pose.reliableLandmarks()
            guard reliable.count >= 3 else { continue }
            let inside = reliable.filter { region.contains($0.point) }.count
            let insideFraction = Double(inside) / Double(reliable.count)
            guard insideFraction >= 0.6 else { continue }
            let score = reliable.reduce(0) { $0 + $1.confidence } * insideFraction
            if score > (best?.score ?? 0) { best = (pose, score) }
        }
        return best?.pose
    }

    /// The largest face whose centre lies inside the subject's box.
    static func face(for box: CGRect, among faces: [FaceCandidate]) -> FaceCandidate? {
        let region = ImageSpace.expanded(box, by: 0.02)
        return faces
            .filter { region.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
            .max { ImageSpace.area($0.box) < ImageSpace.area($1.box) }
    }
}
