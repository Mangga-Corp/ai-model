//
//  ObjectRulebook.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 16/10/26.
//


import Foundation
import CoreGraphics

/// Best-practice rules about individual OBJECTS in the frame (cars, chairs,
/// other people…). Pure: same inputs, same output. Complements
/// `SceneRulebook`, which reasons about the place as a whole.
nonisolated struct ObjectRulebook: Sendable {

    // MARK: - Tunables

    /// Share of the area around the head an object must cover to count as
    /// "growing out of the head".
    var behindHeadCoverage = 0.10
    /// Share of the subject's usual spot an object must fill.
    var targetSpotCoverage = 0.35
    /// Half-size of the usual subject spot around the profile's guide centre.
    var targetSpotHalfSize: CGFloat = 0.15
    /// A bystander must cover at least this share of the frame to matter.
    var minimumBystanderArea = 0.01
    /// Objects at least this large count towards "busy background".
    var busyObjectMinimumArea = 0.005
    var busyObjectCount = 6
    var maximumSnapshotAge: TimeInterval = 3

    // Subject occlusion. UNVALIDATED starting values, chosen to be conservative: a warning needs
    // BOTH a large object share of the subject's core AND little visible person there.
    /// Share of the subject's core that one object must cover.
    var occlusionObjectCoverage = 0.40
    /// The person's own pixels must cover at most this share of the same core.
    var occlusionMaxPersonCoverage = 0.50
    /// The snapshot's person must contain this much of the live subject box, which shows the
    /// snapshot still describes the person being guided.
    var occlusionMinimumPersonMatch = 0.60
    /// The scene snapshot is refreshed about once a second and the subject moves, so this rule
    /// accepts only a fresher one than the others do.
    var occlusionMaximumSnapshotAge: TimeInterval = 1.5

    /// - Parameters:
    ///   - subjectBox: Live upper-body box (normalised, top-left), or nil.
    ///   - targetCenter: Where the user usually places the subject (the dashed
    ///     guide's centre), or nil when the profile has no confident habit.
    func recommendations(scene: SceneSnapshot?,
                         subjectBox: CGRect?,
                         targetCenter: CGPoint?,
                         now: Date = Date()) -> [Recommendation] {
        guard let scene, now.timeIntervalSince(scene.capturedAt) <= maximumSnapshotAge,
              !scene.objects.isEmpty else { return [] }

        let things = scene.objects.filter { !$0.isPerson }
        var result: [Recommendation] = []

        if let box = subjectBox {
            // An occluding object near the head would also trip "behind the head": say it once.
            if let rec = subjectOccluded(scene, subjectBox: box, now: now) {
                result.append(rec)
            } else if let rec = objectBehindHead(things, subjectBox: box) {
                result.append(rec)
            }
            if let rec = bystander(scene.objects, subjectBox: box) { result.append(rec) }

            let busy = things.filter { $0.areaFraction >= busyObjectMinimumArea }.count
            if busy >= busyObjectCount {
                result.append(.init(kind: .busyBackground, priority: .enhancement,
                                    message: "The background is busy (\(busy) objects). Move closer or pick a simpler angle."))
            }
        } else if let target = targetCenter,
                  let rec = objectInTargetSpot(things, targetCenter: target) {
            result.append(rec)
        }
        return result
    }

    // MARK: - Rules

    /// A pole, car or plant right behind the head is a classic distraction.
    /// The fix uses parallax: stepping TOWARD the object's side moves the
    /// background away from the subject in the frame.
    private func objectBehindHead(_ things: [DetectedObject], subjectBox box: CGRect) -> Recommendation? {
        let headZone = CGRect(x: box.midX - box.width * 0.4,
                              y: box.minY - box.height * 0.15,
                              width: box.width * 0.8,
                              height: box.height * 0.55)

        let worst = things
            .map { (object: $0, coverage: $0.mask.coverage(of: headZone)) }
            .filter { $0.coverage >= behindHeadCoverage }
            .max { $0.coverage < $1.coverage }
        guard let worst else { return nil }

        let side = worst.object.centroid.x < box.midX ? "left" : "right"
        return .init(kind: .objectBehindHead, priority: .notable,
                     message: "\(article(worst.object.displayName)) is right behind the head. Take a small step to your \(side).")
    }

    /// Another person who is not the subject.
    /// An object covers a large part of the subject's visible core.
    ///
    /// Not "an object is near or inside the box": it needs the object's own pixels over the
    /// torso/face core while the person's pixels are largely missing there. Fails safe (nil) when
    /// the snapshot is old, no person in it matches the live subject, the object is a carried or
    /// worn item, or the label is implausibly large (a mislabelled surface, see
    /// `RegionReliabilityAssessor`). The object is not named: a misread label would overstate it.
    func subjectOccluded(_ scene: SceneSnapshot, subjectBox box: CGRect, now: Date) -> Recommendation? {
        guard now.timeIntervalSince(scene.capturedAt) <= occlusionMaximumSnapshotAge, box.width > 0, box.height > 0 else { return nil }

        // The snapshot's person pixels around the live box. An occluder can split one person into
        // several components, so all that touch the box are used together.
        let boxArea = box.width * box.height
        let people = scene.objects.filter { $0.isPerson && !$0.boundingBox.intersection(box).isNull }
        guard let first = people.first else { return nil }
        let extent = people.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
        let match = extent.intersection(box)
        guard !match.isNull, Double(match.width * match.height / boxArea) >= occlusionMinimumPersonMatch else { return nil }

        // Torso/face core: away from the box edges, where background and arms-length items sit.
        let core = box.insetBy(dx: box.width * 0.2, dy: box.height * 0.15)
        guard people.reduce(0, { $0 + $1.mask.coverage(of: core) }) <= occlusionMaxPersonCoverage else { return nil }

        let occluded = scene.objects.contains { object in
            guard !object.isPerson, object.areaFraction < RegionReliabilityAssessor.implausibleObjectArea,
                  SegmentationTaxonomy.family(forLabel: object.label)?.group != .carriedItem else { return false }
            return object.mask.coverage(of: core) >= occlusionObjectCoverage
        }
        guard occluded else { return nil }
        return .init(kind: .subjectOccluded, priority: .notable,
                     message: "An object is blocking too much of your subject. Move it away from them.")
    }

    private func bystander(_ objects: [DetectedObject], subjectBox box: CGRect) -> Recommendation? {
        let others = objects.filter { object in
            guard object.isPerson, object.areaFraction >= minimumBystanderArea else { return false }
            let overlap = object.boundingBox.intersection(box)
            let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
            let ownArea = object.boundingBox.width * object.boundingBox.height
            return ownArea > 0 && overlapArea / ownArea < 0.3
        }
        guard !others.isEmpty else { return nil }
        return .init(kind: .personInBackground, priority: .enhancement,
                     message: "Someone else is in the background. Wait for them to move or change your angle.")
    }

    /// No subject yet, but something already fills the user's usual subject spot.
    private func objectInTargetSpot(_ things: [DetectedObject], targetCenter: CGPoint) -> Recommendation? {
        let spot = CGRect(x: targetCenter.x - targetSpotHalfSize,
                          y: targetCenter.y - targetSpotHalfSize,
                          width: targetSpotHalfSize * 2,
                          height: targetSpotHalfSize * 2)

        let worst = things
            .map { (object: $0, coverage: $0.mask.coverage(of: spot)) }
            .filter { $0.coverage >= targetSpotCoverage }
            .max { $0.coverage < $1.coverage }
        guard let worst else { return nil }

        return .init(kind: .objectInTargetSpot, priority: .notable,
                     message: "\(article(worst.object.displayName)) fills your usual subject spot. Place your subject in front of it or reframe.")
    }

    /// "Car" → "A car", "Umbrella" → "An umbrella", "TV" → "A TV".
    private func article(_ name: String) -> String {
        let lowered = name == name.uppercased() ? name : name.lowercased()
        let vowel = "aeiou".contains(lowered.prefix(1).lowercased())
        return (vowel ? "An " : "A ") + lowered
    }
}
