import XCTest
import CoreGraphics
@testable import AIModel

/// Subject-occlusion warning: only a large object share of the subject's visible core, with the
/// person largely missing there, from a fresh snapshot, produces it.
final class SubjectOcclusionTests: XCTestCase {

    private let subject = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4)    // core: x 0.38...0.62, y 0.26...0.54

    /// A 100x100 map; `rect` filled.
    private func mask(_ rect: CGRect) -> ObjectMask {
        let n = 100
        var bits = [Bool](repeating: false, count: n * n)
        for y in 0..<n { for x in 0..<n where rect.contains(CGPoint(x: (Double(x) + 0.5) / 100, y: (Double(y) + 0.5) / 100)) { bits[y * n + x] = true } }
        return ObjectMask(mapWidth: n, mapHeight: n, originX: 0, originY: 0, width: n, height: n, bits: bits)
    }

    private func object(_ id: Int, _ label: String, _ rect: CGRect) -> DetectedObject {
        DetectedObject(id: id, label: label, displayName: label, boundingBox: rect,
                       areaFraction: Double(rect.width * rect.height), centroid: CGPoint(x: rect.midX, y: rect.midY), mask: mask(rect))
    }

    private func snapshot(_ objects: [DetectedObject], age: TimeInterval = 0.3) -> SceneSnapshot {
        SceneSnapshot(category: .indoor, confidence: 0.9,
                      segmentation: SegmentationStatistics(backgroundFractions: [:], skyline: nil, topEdgeCoverage: [:]),
                      depth: nil, hints: [], capturedAt: Date().addingTimeInterval(-age), objects: objects)
    }

    private func kinds(_ s: SceneSnapshot?) -> [Recommendation.Kind] {
        ObjectRulebook().recommendations(scene: s, subjectBox: subject, targetCenter: nil).map(\.kind)
    }

    func testAnObjectCoveringTheSubjectsCoreWarnsOnce() {
        // The person is left and right of a laptop-sized object that sits over the torso.
        let s = snapshot([object(0, "person", CGRect(x: 0.3, y: 0.2, width: 0.08, height: 0.4)),
                          object(1, "person", CGRect(x: 0.62, y: 0.2, width: 0.08, height: 0.4)),
                          object(2, "laptop", CGRect(x: 0.36, y: 0.24, width: 0.28, height: 0.34))])
        let rec = ObjectRulebook().recommendations(scene: s, subjectBox: subject, targetCenter: nil)
        XCTAssertEqual(rec.filter { $0.kind == .subjectOccluded }.count, 1)
        XCTAssertFalse(rec.contains { $0.kind == .objectBehindHead }, "one message, not two")
        XCTAssertEqual(rec.first { $0.kind == .subjectOccluded }?.priority, .notable)
        XCTAssertFalse(rec.first { $0.kind == .subjectOccluded }!.message.contains("laptop"), "the label is not trusted enough to name")
    }

    func testMinorOverlapNearbyObjectsAndBackgroundDoNotWarn() {
        let person = object(0, "person", subject)
        // A cup over a corner of the core.
        XCTAssertFalse(kinds(snapshot([person, object(1, "cup", CGRect(x: 0.40, y: 0.30, width: 0.08, height: 0.08))])).contains(.subjectOccluded))
        // A big object beside the person: inside the box's corner, outside the core.
        XCTAssertFalse(kinds(snapshot([person, object(1, "chair", CGRect(x: 0.30, y: 0.20, width: 0.07, height: 0.40))])).contains(.subjectOccluded))
        // An object far away.
        XCTAssertFalse(kinds(snapshot([person, object(1, "tv", CGRect(x: 0.75, y: 0.1, width: 0.2, height: 0.3))])).contains(.subjectOccluded))
        // A large object overlapping the core, but the person is still clearly visible there.
        XCTAssertFalse(kinds(snapshot([person, object(1, "chair", CGRect(x: 0.38, y: 0.26, width: 0.24, height: 0.28))])).contains(.subjectOccluded),
                       "the person's pixels still cover the core")
    }

    func testUncertainEvidenceFailsSafe() {
        let cover = object(2, "laptop", CGRect(x: 0.36, y: 0.24, width: 0.28, height: 0.34))
        let sides = [object(0, "person", CGRect(x: 0.3, y: 0.2, width: 0.08, height: 0.4)),
                     object(1, "person", CGRect(x: 0.62, y: 0.2, width: 0.08, height: 0.4))]
        XCTAssertTrue(kinds(snapshot(sides + [cover])).contains(.subjectOccluded), "premise")
        XCTAssertFalse(kinds(snapshot(sides + [cover], age: 2.0)).contains(.subjectOccluded), "stale snapshot")
        XCTAssertFalse(kinds(snapshot([cover])).contains(.subjectOccluded), "no person in the snapshot matches the subject")
        XCTAssertFalse(kinds(snapshot([object(0, "person", CGRect(x: 0.0, y: 0.7, width: 0.2, height: 0.3)), cover])).contains(.subjectOccluded),
                       "the person in the snapshot is elsewhere")
        XCTAssertFalse(kinds(nil).contains(.subjectOccluded), "no snapshot at all")
        XCTAssertFalse(ObjectRulebook().recommendations(scene: snapshot(sides + [cover]), subjectBox: nil, targetCenter: nil)
            .contains { $0.kind == .subjectOccluded }, "no live subject")
    }

    func testCarriedItemsAndImplausiblyLargeLabelsAreNotOccluders() {
        let sides = [object(0, "person", CGRect(x: 0.3, y: 0.2, width: 0.08, height: 0.4)),
                     object(1, "person", CGRect(x: 0.62, y: 0.2, width: 0.08, height: 0.4))]
        XCTAssertFalse(kinds(snapshot(sides + [object(2, "handbag", CGRect(x: 0.36, y: 0.24, width: 0.28, height: 0.34))])).contains(.subjectOccluded))
        // A "refrigerator" covering most of the frame is a misread surface, not an object.
        XCTAssertFalse(kinds(snapshot(sides + [object(2, "refrigerator", CGRect(x: 0.0, y: 0.0, width: 1, height: 0.8))])).contains(.subjectOccluded))
    }

    func testCompositionGuidanceStillWinsOverTheWarning() {
        let rec = Recommendation(kind: .subjectOccluded, priority: .notable, message: "x")
        let engine = RecommendationEngine()
        XCTAssertEqual(engine.decide(compositionIssue: .subjectTooSmall, sceneRecommendations: [rec]), .composition)
        XCTAssertEqual(engine.decide(compositionIssue: nil, sceneRecommendations: [rec]), .scene(rec))
    }
}
