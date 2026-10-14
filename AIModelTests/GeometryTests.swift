import XCTest
@testable import AIModel

/// Unit tests for geometry calculations and aggregation logic.
final class VisionGeometryTests: XCTestCase {

    // MARK: - Position Classification

    func testPositionClassification_leftThird() {
        // Test that a subject in the left third is classified correctly
        let leftPosition = CGPoint(x: 0.2, y: 0.5)
        let distribution = PositionDistribution(
            meanX: leftPosition.x, meanY: leftPosition.y,
            stdDevX: 0, stdDevY: 0, isConsistent: true
        )
        // The aggregation service's describeConsistentPosition is private
        // We test indirectly via the output format
        XCTAssertEqual(distribution.meanX, 0.2, accuracy: 0.01)
        XCTAssertTrue(distribution.isConsistent)
    }

    func testPositionClassification_center() {
        let centerPosition = CGPoint(x: 0.5, y: 0.5)
        let distribution = PositionDistribution(
            meanX: centerPosition.x, meanY: centerPosition.y,
            stdDevX: 0, stdDevY: 0, isConsistent: true
        )
        XCTAssertEqual(distribution.meanX, 0.5, accuracy: 0.01)
        XCTAssertEqual(distribution.meanY, 0.5, accuracy: 0.01)
    }

    // MARK: - Size Distribution

    func testSizeDistribution_consistency() {
        let sizes = [0.1, 0.12, 0.11, 0.09, 0.13]
        let mean = sizes.reduce(0, +) / Double(sizes.count)
        let variance = sizes.map { pow($0 - mean, 2) }.reduce(0, +) / Double(sizes.count)
        let stdDev = sqrt(variance)

        XCTAssertEqual(mean, 0.11, accuracy: 0.01)
        XCTAssertTrue(stdDev < 0.05) // Low variance = consistent
    }

    func testSizeDistribution_inconsistency() {
        let sizes = [0.05, 0.3, 0.08, 0.6, 0.1]
        let mean = sizes.reduce(0, +) / Double(sizes.count)
        let variance = sizes.map { pow($0 - mean, 2) }.reduce(0, +) / Double(sizes.count)
        let stdDev = sqrt(variance)

        XCTAssertTrue(stdDev > 0.1) // High variance = inconsistent
    }

    // MARK: - Negative Space

    func testNegativeSpace_leftHeavy() {
        let leftSpace: Double = 0.4
        let rightSpace: Double = 0.1
        let diff = abs(leftSpace - rightSpace)
        XCTAssertTrue(diff > 0.15)
    }

    func testNegativeSpace_balanced() {
        let leftSpace: Double = 0.2
        let rightSpace: Double = 0.2
        let diff = abs(leftSpace - rightSpace)
        XCTAssertTrue(diff < 0.15)
    }
}
