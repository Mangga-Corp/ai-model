import XCTest
import CoreGraphics
@testable import AIModel

/// Object and Environment Analysis: the taxonomy, region measurement and its
/// coordinate handling, mask validity, the element ranking, scene inference,
/// composition measures, cross-photo aggregation, and the unavailable-versus-empty
/// distinction. Fixtures are synthetic class maps painted with real DETR label names.
final class EnvironmentAnalysisTests: XCTestCase {

    // MARK: - Fixtures

    private let names = ["--", "person", "tie", "chair", "dining table", "cup", "tree", "grass", "flower",
                         "sky (other)", "building (other)", "wall (brick)", "wall (other)", "sea", "sand",
                         "pavement", "floor (wood)", "ceiling", "bench", "car", "rock", "mountain", "dirt", "cow", "table", "bicycle"]

    /// A class map painted in cell coordinates; (0, 0) is the TOP-LEFT cell.
    private struct Canvas {
        let width: Int
        let height: Int
        var cells: [String]

        init(_ width: Int = 100, _ height: Int = 100, fill: String = "--") {
            self.width = width
            self.height = height
            cells = [String](repeating: fill, count: width * height)
        }

        mutating func paint(_ name: String, x: Range<Int>, y: Range<Int>) {
            for yy in y where yy >= 0 && yy < height {
                for xx in x where xx >= 0 && xx < width { cells[yy * width + xx] = name }
            }
        }
    }

    private func grid(_ canvas: Canvas) -> SegmentationGrid {
        let indices = canvas.cells.map { name -> UInt8 in UInt8(names.firstIndex(of: name) ?? 0) }
        return SegmentationGrid(width: canvas.width, height: canvas.height, classIndices: indices, labels: names)
    }

    private func human(_ box: CGRect, confidence: Double = 0.9, id: Int = 0, upper: CGRect? = nil) -> HumanCandidate {
        HumanCandidate(id: id, box: box, confidence: confidence, upperBodyBox: upper, upperBodyConfidence: upper == nil ? nil : 0.9)
    }

    private let personBox = CGRect(x: 0.40, y: 0.50, width: 0.15, height: 0.40)

    /// Paints the person where `personBox` says they are.
    private func paintPerson(_ c: inout Canvas) { c.paint("person", x: 40..<55, y: 50..<90) }

    private func evidence(humans: [HumanCandidate], classifier: [ScoredLabel]? = nil, depthContrast: Double? = nil) -> PhotoEvidence {
        PhotoEvidence(
            humans: humans.isEmpty ? .nothingDetected : .produced(humans),
            pose: .nothingDetected, faces: .nothingDetected, imageRoll: .nothingDetected,
            segmentation: .skipped("test"),
            depth: depthContrast.map { .produced(DepthSummary(gridWidth: 100, gridHeight: 100, meanNearness: 0.5, contrast: $0)) } ?? .skipped("test"),
            sceneContext: classifier.map { .produced($0) } ?? .skipped("not run"), runs: [])
    }

    private func interpret(_ canvas: Canvas?, humans: [HumanCandidate] = [], classifier: [ScoredLabel]? = nil,
                           depth: DepthGrid? = nil, depthContrast: Double = 0.3) -> EnvironmentAnalysisResult {
        let ev = evidence(humans: humans, classifier: classifier, depthContrast: depth == nil ? nil : depthContrast)
        let selection = SubjectSelector.select(from: humans)
        let positioning = SubjectPositioningMeasurer.measure(selection: selection, evidence: ev)
        return EnvironmentInterpreter.interpret(
            selection: selection, evidence: ev,
            artifacts: PhotoArtifacts(segmentation: canvas.map(grid), depth: depth), positioning: positioning)
    }

    private func analyze(_ canvas: Canvas, depth: DepthGrid? = nil, subject: SubjectRegionContext? = nil) -> SegmentationRegionAnalyzer.Analysis {
        SegmentationRegionAnalyzer.analyze(grid(canvas), depth: depth, subject: subject)
    }

    private func region(of a: SegmentationRegionAnalyzer.Analysis, _ key: String) -> SemanticRegion? {
        a.regions.first { $0.family.key == key }
    }

    // MARK: - Taxonomy

    func testFamilyKeyStripsQualifiersAndRejectsPlaceholders() {
        XCTAssertEqual(SegmentationTaxonomy.familyKey(forLabel: "wall (brick)"), "wall")
        XCTAssertEqual(SegmentationTaxonomy.familyKey(forLabel: "sky (other)"), "sky")
        XCTAssertEqual(SegmentationTaxonomy.familyKey(forLabel: "dining table"), "dining table")
        XCTAssertNil(SegmentationTaxonomy.familyKey(forLabel: "--"), "the model's placeholder entries are unsupported")
        XCTAssertNil(SegmentationTaxonomy.familyKey(forLabel: ""))
    }

    func testSurfaceClassesMergeButObjectsStaySeparate() {
        let mapping = SegmentationTaxonomy.Mapping(labels: ["--", "person", "tree", "grass", "flower", "chair", "couch"])
        let keys = mapping.families.map(\.key)
        XCTAssertTrue(keys.contains("vegetation"), "tree, grass and flower are one 'Trees and grass' region")
        XCTAssertFalse(keys.contains("tree"))
        XCTAssertTrue(keys.contains("chair") && keys.contains("couch"), "object classes are not merged")
        let vegetation = mapping.families.first { $0.key == "vegetation" }
        XCTAssertEqual(vegetation?.memberKeys, ["flower", "grass", "tree"])
        XCTAssertEqual(mapping.familyOfClass[0], -1, "the placeholder maps to no unit")
        XCTAssertEqual(mapping.familyOfClass[2], mapping.familyOfClass[3], "tree and grass share a unit")
        XCTAssertNotNil(mapping.personFamily)
    }

    // MARK: - A. Region measurement and coordinates

    func testAreaCentroidAndZonesAreInImageSpaceWithTopLeftOrigin() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 60..<100, y: 0..<30)      // top-right block, 40 x 30
        let building = try XCTUnwrap(region(of: analyze(c), "architecture"))
        let g = try XCTUnwrap(building.geometry)
        XCTAssertEqual(building.areaFraction, 0.12, accuracy: 1e-9)
        XCTAssertEqual(Double(g.centroid.x), 0.80, accuracy: 0.01)
        XCTAssertEqual(Double(g.centroid.y), 0.15, accuracy: 0.01)
        XCTAssertEqual(g.horizontal, .right)
        XCTAssertEqual(g.vertical, .upper, "y grows downward: the top rows are the upper zone")
        XCTAssertEqual(g.boundingBox.minX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(g.boundingBox.minY, 0.0, accuracy: 1e-9)
        XCTAssertEqual(g.boundingBox.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(g.boundingBox.height, 0.3, accuracy: 1e-9)
    }

    func testAPersonDoesNotFragmentTheRegionBehindThem() throws {
        var c = Canvas(fill: "wall (other)")
        c.paint("person", x: 40..<55, y: 0..<100)                // a column that splits the wall in two
        let wall = try XCTUnwrap(region(of: analyze(c), "wall"))
        let g = try XCTUnwrap(wall.geometry)
        XCTAssertEqual(g.componentCount, 1, "a person hides the wall, they do not divide it")
        XCTAssertEqual(g.largestComponentShare, 1.0, accuracy: 1e-9)
        XCTAssertEqual(wall.areaFraction, 0.85, accuracy: 1e-9, "the hidden pixels are not counted as wall")

        var split = Canvas(fill: "wall (other)")
        split.paint("tree", x: 40..<55, y: 0..<100)               // a real tree does divide it
        XCTAssertEqual(try XCTUnwrap(region(of: analyze(split), "wall")?.geometry).componentCount, 2)
    }

    func testBottomLeftRegionIsLowerLeft() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("pavement", x: 0..<30, y: 70..<100)
        let g = try XCTUnwrap(region(of: analyze(c), "pavedSurface")?.geometry)
        XCTAssertEqual(g.horizontal, .left)
        XCTAssertEqual(g.vertical, .lower)
    }

    func testNonSquareGridGivesShareOfTheWholeImage() throws {
        var c = Canvas(200, 50, fill: "sky (other)")
        c.paint("building (other)", x: 0..<100, y: 0..<50)       // the left half of a wide frame
        let building = try XCTUnwrap(region(of: analyze(c), "architecture"))
        XCTAssertEqual(building.areaFraction, 0.5, accuracy: 1e-9, "area is a share of the whole image, independent of aspect")
        XCTAssertEqual(Double(try XCTUnwrap(building.geometry).centroid.x), 0.25, accuracy: 0.01)
    }

    func testMaskAreaAndBoundingBoxAreaStayDistinctForDisconnectedRegions() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("tree", x: 0..<20, y: 0..<20)                    // two opposite corners
        c.paint("tree", x: 80..<100, y: 80..<100)
        let vegetation = try XCTUnwrap(region(of: analyze(c), "vegetation"))
        let g = try XCTUnwrap(vegetation.geometry)
        XCTAssertEqual(vegetation.areaFraction, 0.08, accuracy: 1e-9, "mask area counts only the two blobs")
        XCTAssertEqual(g.boundingBoxArea, 1.0, accuracy: 1e-9, "the union box spans the frame")
        XCTAssertEqual(g.componentCount, 2, "two pieces are reported as one combined region with two fragments")
        XCTAssertEqual(g.fillRatio, 0.08, accuracy: 1e-9)
        XCTAssertEqual(g.largestComponentShare, 0.5, accuracy: 1e-9)
        XCTAssertFalse(ObjectSegmentationResult.isInstanceSegmentation)
    }

    func testSpeckleIsIgnoredAndNeverBecomesARegion() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("car", x: 10..<12, y: 10..<12)                   // 4 cells: below the fragment size
        let a = analyze(c)
        XCTAssertNil(region(of: a, "car"), "a few stray pixels are not an object")
        XCTAssertEqual(try XCTUnwrap(region(of: a, "sky")).specklePixelCount, 0)
    }

    func testRegionBelowMeasurableSizeHasNoGeometry() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("car", x: 10..<13, y: 10..<16)                   // 18 cells: counted, but too small to measure
        let car = try XCTUnwrap(region(of: analyze(c), "car"))
        XCTAssertEqual(car.validity, .tooSmall)
        XCTAssertNil(car.geometry, "a too-small mask must not produce a plausible-looking box or area ratio")
        XCTAssertNil(car.depth)
        XCTAssertFalse(car.isValid)
    }

    func testModelConfidenceIsNeverFabricated() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<50, y: 0..<50)
        XCTAssertTrue(analyze(c).regions.allSatisfy { $0.modelConfidence == nil }, "DETR gives no per-pixel confidence")
    }

    func testCarriedItemsAreNotSurroundings() throws {
        var c = Canvas(fill: "sky (other)")                       // 100% sky
        paintPerson(&c)                                          // 600 cells
        c.paint("tie", x: 41..<51, y: 60..<70)                   // 100 cells carried
        let a = analyze(c)
        XCTAssertEqual(a.allPeopleFraction, 0.05, accuracy: 0.0101)
        XCTAssertEqual(a.environmentFraction, 1.0 - a.allPeopleFraction - 0.01, accuracy: 1e-9,
                       "people and what they carry are removed from the surroundings")
        let result = interpret(c, humans: [human(personBox)])
        XCTAssertFalse(result.segmentation.environmentalRegions.contains { $0.family.key == "tie" })
        XCTAssertTrue(result.segmentation.validRegions.contains { $0.family.key == "tie" }, "the region is still listed")
    }

    // MARK: - The person's mask

    func testHumanMaskIsRestrictedToTheDetectionBox() throws {
        var c = Canvas(fill: "wall (other)")
        c.paint("person", x: 40..<60, y: 40..<80)                // 800 cells, inside the box
        c.paint("person", x: 80..<95, y: 10..<30)                // 300 cells, someone else outside it
        let subject = SubjectRegionContext(box: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.50), otherBoxes: [])
        let a = analyze(c, subject: subject)
        let mask = try XCTUnwrap(a.human)
        XCTAssertTrue(mask.isValid)
        XCTAssertEqual(try XCTUnwrap(mask.maskAreaFraction), 0.08, accuracy: 1e-9, "only person pixels inside the box")
        XCTAssertEqual(a.allPeopleFraction, 0.11, accuracy: 1e-9, "all merged people are still reported separately")
        let box = try XCTUnwrap(mask.maskBoundingBox)
        XCTAssertEqual(box.minX, 0.4, accuracy: 1e-9)
        XCTAssertEqual(box.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(box.height, 0.4, accuracy: 1e-9)
    }

    func testHumanMaskIsInvalidWhenItCoversLittleOfTheBox() throws {
        var c = Canvas(fill: "wall (other)")
        c.paint("person", x: 45..<55, y: 50..<56)                // 60 cells in a 1500-cell box
        let subject = SubjectRegionContext(box: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.50), otherBoxes: [])
        let mask = try XCTUnwrap(analyze(c, subject: subject).human)
        XCTAssertFalse(mask.isValid)
        XCTAssertNil(mask.maskAreaFraction, "no area is derived from an invalid mask")
        XCTAssertNil(mask.maskBoundingBox)
        XCTAssertTrue(mask.invalidReason?.contains("cover only") ?? false)
    }

    func testOverlappingSecondPersonIsFlagged() throws {
        var c = Canvas(fill: "wall (other)")
        c.paint("person", x: 40..<60, y: 40..<80)
        let subject = SubjectRegionContext(
            box: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.50),
            otherBoxes: [CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)])
        XCTAssertTrue(try XCTUnwrap(analyze(c, subject: subject).human).mayIncludeOtherPeople)
    }

    func testRingShareReflectsWhatSurroundsThePerson() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<100, y: 0..<100)      // building everywhere...
        c.paint("sky (other)", x: 0..<100, y: 0..<30)            // ...except a sky band at the top
        paintPerson(&c)
        let a = analyze(c, subject: SubjectRegionContext(box: personBox, otherBoxes: []))
        let building = try XCTUnwrap(region(of: a, "architecture")?.subjectRelation)
        let sky = try XCTUnwrap(region(of: a, "sky")?.subjectRelation)
        XCTAssertGreaterThan(building.ringShare, sky.ringShare, "the band around the person is mostly building")
        XCTAssertGreaterThan(building.ringShare + sky.ringShare, 0.99, "person pixels are excluded, so the band is fully accounted for")
    }

    func testRegionDepthComesFromTheDepthMapAtTheSameImagePoints() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<50, y: 0..<100)
        var values = [Float](repeating: 0.1, count: 100 * 100)
        for y in 0..<100 { for x in 0..<50 { values[y * 100 + x] = 0.9 } }     // left half near, right half far
        let a = analyze(c, depth: DepthGrid(width: 100, height: 100, nearness: values))
        XCTAssertEqual(try XCTUnwrap(region(of: a, "architecture")?.depth).medianNearness, 0.9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(region(of: a, "sky")?.depth).medianNearness, 0.1, accuracy: 0.001)
        XCTAssertNil(region(of: analyze(c), "architecture")?.depth, "without a depth map there is no depth, not a default")
    }

    // MARK: - Unavailable, invalid and empty are different states

    func testMissingDegenerateAndEmptyOutputsAreDistinct() {
        let missing = interpret(nil).segmentation
        if case .unavailable = missing.availability {} else { XCTFail("no class map is 'unavailable'") }
        XCTAssertEqual(missing.assessment.status, .unavailable)

        let degenerate = interpret(Canvas(fill: "--")).segmentation          // every pixel is a placeholder
        if case .invalid = degenerate.availability {} else { XCTFail("an all-placeholder map is 'invalid'") }
        XCTAssertFalse(degenerate.availability.hasValidOutput)

        let empty = interpret(Canvas(fill: "person")).segmentation           // valid output, only people
        XCTAssertEqual(empty.availability, .noEnvironmentalRegions)
        XCTAssertTrue(empty.availability.hasValidOutput)
        XCTAssertEqual(empty.assessment.status, .determined, "a genuinely empty result is a result")
        XCTAssertTrue(empty.regions.isEmpty)
    }

    func testSegmentationFailureKeepsTheHumanAnalysis() {
        let result = interpret(nil, humans: [human(personBox)])
        XCTAssertEqual(result.segmentation.assessment.status, .unavailable)
        XCTAssertEqual(result.elements.outcome, .unavailable)
        XCTAssertEqual(result.scene.assessment.status, .unavailable)
        XCTAssertNotNil(result.composition.subject, "the person is still measured from Vision's box")
        XCTAssertEqual(result.composition.assessment.status, .determined)
        XCTAssertNotNil(result.composition.scale)
    }

    // MARK: - B. Ranking

    private func region(_ key: String, group: ElementGroup = .architecture, area: Double, largest: Double = 1,
                        ring: Double? = nil, depth: Double? = nil, pieces: Int = 1,
                        kind: RegionKind = .surface) -> SemanticRegion {
        let family = SemanticFamily(key: key, displayName: key.capitalized, group: group, kind: kind, memberKeys: [key])
        let geometry = RegionGeometry(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5), boundingBoxArea: 0.25,
            centroid: CGPoint(x: 0.5, y: 0.5), fillRatio: 0.5, componentCount: pieces,
            largestComponentShare: largest, borderBandShare: 0.2, touchedEdges: [])
        return SemanticRegion(
            family: family, rawLabels: [], pixelCount: Int(area * 10_000), specklePixelCount: 0, areaFraction: area,
            validity: .valid, geometry: geometry,
            depth: depth.map { RegionDepth(medianNearness: $0, sampleCount: 100) },
            subjectRelation: ring.map { RegionSubjectRelation(ringShare: $0, insideSubjectBoxShare: 0) },
            modelConfidence: nil)
    }

    private func segmentation(_ regions: [SemanticRegion], environment: Double = 0.9) -> ObjectSegmentationResult {
        ObjectSegmentationResult(
            availability: regions.isEmpty ? .noEnvironmentalRegions : .available, gridWidth: 100, gridHeight: 100,
            regions: regions, allPeopleFraction: 0.1, human: nil, environmentFraction: environment,
            unsupportedFraction: 0, unsupportedLabels: [],
            assessment: Assessment(status: .determined, quality: .high, explanation: "", evidence: [], limitations: []))
    }

    private let withSubject = EnvironmentElementRanker.Context(subjectPresent: true, subjectAmbiguous: false, depthTrusted: false)

    func testSizeAloneDoesNotDecideDominance() {
        let scattered = region("grass", group: .vegetation, area: 0.30, largest: 0.15, ring: 0.05, pieces: 9)
        let coherent = region("building", area: 0.15, largest: 1.0, ring: 0.60)
        let result = EnvironmentElementRanker.rank(segmentation([scattered, coherent]), context: withSubject)
        XCTAssertEqual(result.candidates.first?.familyKey, "building",
                       "a smaller, coherent region beside the person outranks a larger scattered one")
        XCTAssertGreaterThan(result.candidates[0].score, result.candidates[1].score)
    }

    func testPersonAndCarriedItemsAreNeverCandidates() {
        let carried = region("skis", group: .carriedItem, area: 0.30)
        let wall = region("wall", group: .wall, area: 0.20, ring: 0.4)
        let result = EnvironmentElementRanker.rank(segmentation([carried, wall]), context: withSubject)
        XCTAssertEqual(result.candidates.map(\.familyKey), ["wall"])
        XCTAssertFalse(result.candidates.contains { $0.group == .person })
    }

    func testNoDominantElementIsForcedWhenEvidenceIsWeak() {
        let weak = region("grass", group: .vegetation, area: 0.03, largest: 0.3, ring: 0.0, pieces: 6)
        let result = EnvironmentElementRanker.rank(segmentation([weak]), context: withSubject)
        XCTAssertEqual(result.outcome, .noStandoutElement)
        XCTAssertTrue(result.dominant.isEmpty)
        XCTAssertEqual(result.assessment.status, .insufficientEvidence)
        XCTAssertEqual(result.candidates.count, 1, "the candidate is still listed, with a non-dominant role")
    }

    func testStrongScoreWithWeakSupportIsOnlyUncertain() {
        let tiny = region("flag", group: .streetFixture, area: 0.03, largest: 1.0, ring: 1.0)
        let result = EnvironmentElementRanker.rank(segmentation([tiny]), context: withSubject)
        XCTAssertGreaterThanOrEqual(result.candidates[0].score, EnvironmentElementRanker.dominantMinimumScore)
        XCTAssertEqual(result.candidates[0].role, .uncertain, "3% of the frame cannot support a dominant role")
    }

    func testCloseScoresAreCoDominantAndNoMoreThanTwo() {
        let a = region("building", area: 0.40, ring: 0.5)
        let b = region("road", group: .pavedSurface, area: 0.40, ring: 0.5)
        let c = region("sky", group: .sky, area: 0.40, ring: 0.5)
        let result = EnvironmentElementRanker.rank(segmentation([a, b, c]), context: withSubject)
        XCTAssertEqual(result.dominant.count, 2, "at most two elements are co-dominant")
        XCTAssertEqual(result.candidates.count, 3)
    }

    func testUnavailableTermsAreDroppedAndStatedNotGuessed() {
        let r = region("building", area: 0.30, ring: nil, depth: nil)
        let result = EnvironmentElementRanker.rank(segmentation([r]),
                                                   context: .init(subjectPresent: false, subjectAmbiguous: false, depthTrusted: false))
        let terms = result.candidates[0].components
        XCTAssertFalse(terms.first { $0.name == "Adjacency to the person" }!.used)
        XCTAssertFalse(terms.first { $0.name == "Relative depth" }!.used)
        XCTAssertTrue(terms.first { $0.name == "Extent" }!.used)
        XCTAssertTrue((0.0...1.0).contains(result.candidates[0].score))
        XCTAssertTrue(result.assessment.limitations.contains { $0.contains("adjacency") })
    }

    func testRankingIsDeterministicAndBreaksTiesByAreaThenName() {
        let regions = [region("b", area: 0.2, ring: 0.3), region("a", area: 0.2, ring: 0.3), region("c", area: 0.25, ring: 0.3)]
        let first = EnvironmentElementRanker.rank(segmentation(regions), context: withSubject)
        let second = EnvironmentElementRanker.rank(segmentation(Array(regions.reversed())), context: withSubject)
        XCTAssertEqual(first, second, "input order must not change the result")
        XCTAssertEqual(first.candidates.map(\.familyKey), ["c", "a", "b"])
    }

    func testRegionsBelowTheFloorAreMeasuredButNotRanked() {
        let result = EnvironmentElementRanker.rank(segmentation([region("cup", group: .foodAndDrink, area: 0.01, kind: .object)]),
                                                   context: withSubject)
        XCTAssertEqual(result.outcome, .noEnvironmentalRegions)
        XCTAssertEqual(result.assessment.status, .insufficientEvidence)
        XCTAssertNotEqual(result.assessment.status, .unavailable)
    }

    func testLargeSceneRanksTheBuildingAboveThePersonSized() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<100, y: 20..<100)     // 80% building behind the person
        paintPerson(&c)
        let result = interpret(c, humans: [human(personBox)])
        XCTAssertEqual(result.elements.dominant.first?.familyKey, "architecture")
        XCTAssertFalse(result.elements.candidates.contains { $0.familyKey == "person" })
    }

    // MARK: - C. Scene context

    private func beachScene() -> Canvas {
        var c = Canvas(fill: "sky (other)")
        c.paint("sea", x: 0..<100, y: 25..<62)
        c.paint("sand", x: 0..<100, y: 62..<100)
        paintPerson(&c)
        return c
    }

    func testBeachComesFromWaterAndSand() {
        let scene = interpret(beachScene(), humans: [human(personBox)]).scene
        XCTAssertEqual(scene.primary, .beachOrWaterfront)
        XCTAssertEqual(scene.setting, .outdoor)
        XCTAssertEqual(scene.assessment.status, .determined)
        XCTAssertLessThanOrEqual(scene.assessment.quality, .moderate, "segmentation alone never reaches high")
    }

    func testTreesAndABuildingDoNotProveAPark() {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<50, y: 15..<85)
        c.paint("tree", x: 50..<100, y: 15..<85)
        c.paint("pavement", x: 0..<100, y: 85..<100)
        let scene = interpret(c).scene
        XCTAssertNotEqual(scene.primary, .parkOrGarden)
        XCTAssertFalse(scene.secondary.contains { $0.category == .parkOrGarden })
    }

    func testVegetationAloneIsNaturalAndAParkNeedsAParkCue() {
        var trees = Canvas(fill: "sky (other)")
        trees.paint("tree", x: 0..<100, y: 20..<100)
        XCTAssertEqual(interpret(trees).scene.primary, .naturalEnvironment, "trees without a park cue stay broad")

        var park = Canvas(fill: "sky (other)")
        park.paint("tree", x: 0..<100, y: 20..<60)
        park.paint("grass", x: 0..<100, y: 60..<100)              // open lawn is a park cue
        let scene = interpret(park).scene
        XCTAssertEqual(scene.primary, .parkOrGarden)
        XCTAssertTrue(scene.secondary.contains { $0.category == .naturalEnvironment }, "the broader category is kept as secondary")
    }

    private func room() -> Canvas {
        var c = Canvas(fill: "wall (other)")
        c.paint("ceiling", x: 0..<100, y: 0..<15)
        c.paint("floor (wood)", x: 0..<100, y: 65..<100)
        c.paint("chair", x: 10..<30, y: 55..<80)
        return c
    }

    func testIndoorInteriorFromCeilingFloorAndFurniture() {
        let scene = interpret(room()).scene
        XCTAssertEqual(scene.setting, .indoor)
        XCTAssertEqual(scene.primary, .indoorInterior)
    }

    func testCafeNeedsTheClassifierToAgree() {
        var c = room()
        c.paint("dining table", x: 40..<70, y: 60..<80)
        c.paint("cup", x: 50..<55, y: 55..<60)
        let without = interpret(c).scene
        XCTAssertEqual(without.primary, .indoorInterior, "tables and chairs do not separate a café from a home")
        XCTAssertTrue(without.secondary.contains { $0.category == .cafeOrRestaurant })

        let with = interpret(c, classifier: [ScoredLabel(label: "restaurant, eating house, eating place, eatery", score: 0.30)]).scene
        XCTAssertEqual(with.primary, .cafeOrRestaurant)
        XCTAssertTrue(with.classifierHints.contains { $0.used })
    }

    func testClassifierCannotCreateACategoryOnItsOwn() {
        let wallOnly = Canvas(fill: "wall (other)")
        let scene = interpret(wallOnly, classifier: [ScoredLabel(label: "seashore, coast, seacoast, sea-coast", score: 0.6)]).scene
        XCTAssertNotEqual(scene.primary, .beachOrWaterfront)
        XCTAssertTrue(scene.classifierHints.allSatisfy { !$0.used }, "a hint with no segmentation support is shown but not used")
    }

    func testPlainWallIsAPlainBackgroundNotAPlace() {
        var c = Canvas(fill: "wall (other)")
        paintPerson(&c)
        let scene = interpret(c, humans: [human(personBox)]).scene
        XCTAssertEqual(scene.primary, .studioOrPlainBackground)
        XCTAssertLessThanOrEqual(scene.assessment.quality, .low, "a plain wall and a backdrop cannot be told apart")
    }

    func testBareRockIsNotCalledNatural() {
        let scene = interpret(Canvas(fill: "rock")).scene
        XCTAssertNotEqual(scene.primary, .naturalEnvironment, "the model also calls stone walls and cliffs 'rock'")
    }

    func testOutdoorWallWithPavingIsAnUrbanOrBuiltPlace() {
        var c = Canvas(fill: "wall (other)")
        c.paint("pavement", x: 0..<100, y: 60..<100)
        let scene = interpret(c).scene
        XCTAssertEqual(scene.setting, .outdoor)
        XCTAssertEqual(scene.primary, .urbanStreet)
        XCTAssertEqual(scene.character, .built)
    }

    func testABicycleBesideAWallIsNotAStreet() {
        var c = Canvas(fill: "wall (other)")
        c.paint("dirt", x: 0..<100, y: 60..<100)
        c.paint("bicycle", x: 10..<40, y: 70..<90)
        let scene = interpret(c).scene
        XCTAssertEqual(scene.setting, .outdoor)
        XCTAssertNotEqual(scene.primary, .urbanStreet, "a street needs paving; one bicycle and a wall do not make one")
        XCTAssertTrue([.architecturalEnvironment, .mixedEnvironment].contains(scene.primary),
                      "a wall beside a dirt yard is built or mixed, never a street (got \(scene.primary.displayName))")
    }

    func testTooLittleVisibleEnvironmentGivesUnknownNotAGuess() {
        var c = Canvas(fill: "wall (other)")
        c.paint("person", x: 0..<100, y: 0..<95)                 // the person fills the frame
        let scene = interpret(c, humans: [human(CGRect(x: 0, y: 0, width: 1, height: 0.95))]).scene
        XCTAssertEqual(scene.primary, .unknown)
        XCTAssertEqual(scene.assessment.status, .insufficientEvidence)
    }

    func testObservedCuesAreSeparateFromTheInterpretation() {
        let scene = interpret(beachScene(), humans: [human(personBox)]).scene
        XCTAssertFalse(scene.observedCues.isEmpty)
        XCTAssertTrue(scene.observedCues.contains { $0.group == .water })
        let origins = Set(scene.assessment.evidence.map(\.origin))
        XCTAssertTrue(origins.contains(.derivedMeasurement) && origins.contains(.interpretation))
    }

    func testHintTableUnderstandsImageNetSynonymsAndWordNetPrefixes() {
        XCTAssertEqual(SceneHintTable.category(forLabel: "restaurant, eating house, eating place, eatery"), .cafeOrRestaurant)
        XCTAssertEqual(SceneHintTable.category(forLabel: "n04111531 restaurant"), .cafeOrRestaurant)
        XCTAssertEqual(SceneHintTable.category(forLabel: "seashore, coast, seacoast, sea-coast"), .beachOrWaterfront)
        XCTAssertNil(SceneHintTable.category(forLabel: "tabby cat"))
    }

    // MARK: - D. Position and scale

    func testSubjectMeasurementsReuseTheExistingPositioning() throws {
        var c = Canvas(fill: "wall (other)")
        paintPerson(&c)
        let ev = evidence(humans: [human(personBox)])
        let selection = SubjectSelector.select(from: [human(personBox)])
        let positioning = SubjectPositioningMeasurer.measure(selection: selection, evidence: ev)
        let result = interpret(c, humans: [human(personBox)])
        let subject = try XCTUnwrap(result.composition.subject)
        XCTAssertEqual(subject.box, positioning.subjectBox)
        XCTAssertEqual(subject.boxAreaRatio, try XCTUnwrap(positioning.normalizedArea), accuracy: 1e-12)
        XCTAssertEqual(subject.horizontal, positioning.horizontal)
        XCTAssertEqual(subject.vertical, positioning.vertical)
    }

    func testPersonBoxAndPersonMaskAreaAreReportedSeparately() throws {
        var c = Canvas(fill: "wall (other)")
        paintPerson(&c)                                          // 15 x 40 cells = 6% of the image
        let subject = try XCTUnwrap(interpret(c, humans: [human(personBox)]).composition.subject)
        XCTAssertEqual(subject.boxAreaRatio, 0.06, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(subject.maskAreaRatio), 0.06, accuracy: 1e-9)

        var sparse = Canvas(fill: "wall (other)")
        sparse.paint("person", x: 42..<50, y: 50..<80)           // 240 cells inside the 600-cell box
        let narrow = try XCTUnwrap(interpret(sparse, humans: [human(personBox)]).composition.subject)
        XCTAssertEqual(narrow.boxAreaRatio, 0.06, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(narrow.maskAreaRatio), 0.024, accuracy: 1e-9, "the mask is smaller than its box")
    }

    func testScaleBandsAndBoundaryMarking() {
        func scale(_ v: Double) -> Banded<SubjectScaleBand> {
            CompositionMeasurer.band(v, low: CompositionMeasurer.smallScaleCut, high: CompositionMeasurer.largeScaleCut,
                                     labels: (SubjectScaleBand.small, .moderate, .large), margin: { $0 * CompositionMeasurer.scaleMargin })
        }
        XCTAssertEqual(scale(0.04).band, .small)
        XCTAssertEqual(scale(0.20).band, .moderate)
        XCTAssertEqual(scale(0.50).band, .large)
        XCTAssertFalse(scale(0.04).isNearBoundary)
        XCTAssertFalse(scale(0.20).isNearBoundary)
        XCTAssertTrue(scale(0.105).isNearBoundary, "5% above the cut-off is soft, not firm")
        XCTAssertTrue(scale(0.34).isNearBoundary)
    }

    func testDescriptorsComeFromMeasurementsWithStatedBasis() throws {
        var c = Canvas(fill: "building (other)")
        c.paint("person", x: 80..<85, y: 60..<80)                // a small person at the right
        let box = CGRect(x: 0.78, y: 0.58, width: 0.09, height: 0.24)
        let composition = interpret(c, humans: [human(box)]).composition
        let kinds = composition.descriptors.map(\.kind)
        XCTAssertTrue(kinds.contains(.subjectSmallInFrame))
        XCTAssertTrue(kinds.contains(.subjectOffCenter))
        XCTAssertTrue(kinds.contains(.environmentProminent))
        XCTAssertTrue(composition.descriptors.allSatisfy { !$0.basis.isEmpty }, "no descriptor without the measurement behind it")
        XCTAssertEqual(composition.scale?.band, .small)
        XCTAssertEqual(composition.horizontalOffset?.band, .offCenter)
    }

    func testElementSizeIsComparedMaskToMaskWhenBothMasksAreValid() throws {
        var c = Canvas(fill: "building (other)")
        paintPerson(&c)
        let m = try XCTUnwrap(interpret(c, humans: [human(personBox)]).composition.elements.first { $0.familyKey == "architecture" })
        XCTAssertEqual(try XCTUnwrap(m.relativeToSubject).basis, .maskToMask)
        XCTAssertEqual(try XCTUnwrap(m.relativeToSubject).ratio, 0.94 / 0.06, accuracy: 0.01)
    }

    func testElementSizeFallsBackToBoxesWhenThereIsNoValidMask() throws {
        let c = Canvas(fill: "building (other)")                  // no person pixels at all
        let m = try XCTUnwrap(interpret(c, humans: [human(personBox)]).composition.elements.first)
        XCTAssertEqual(try XCTUnwrap(m.relativeToSubject).basis, .boxToBox)
    }

    func testElementsAreStillMeasuredWithoutASubject() {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<50, y: 0..<100)
        let composition = interpret(c).composition
        XCTAssertNil(composition.subject)
        XCTAssertNil(composition.scale)
        XCTAssertFalse(composition.elements.isEmpty)
        XCTAssertEqual(composition.assessment.status, .insufficientEvidence)
        XCTAssertNil(composition.elements.first?.relativeToSubject, "no subject, no relative size")
    }

    func testEvenlySpreadVegetationIsNotNearTheEdges() {
        var spread = Canvas(fill: "sky (other)")
        spread.paint("tree", x: 0..<100, y: 20..<100)
        XCTAssertFalse(interpret(spread).composition.descriptors.contains { $0.kind == .vegetationNearEdges })

        var framed = Canvas(fill: "sky (other)")                  // a green frame around an open centre
        framed.paint("tree", x: 0..<100, y: 0..<100)
        framed.paint("sky (other)", x: 20..<80, y: 20..<80)
        XCTAssertTrue(interpret(framed).composition.descriptors.contains { $0.kind == .vegetationNearEdges })
    }

    // MARK: - Aggregation

    private func photoResult(order: Int, canvas: Canvas?, humans: [HumanCandidate] = []) -> PhotoResult {
        let ev = evidence(humans: humans)
        let prepared = PreparedPhoto(id: UUID(), selectionOrder: order, localIdentifier: "p\(order)", outcome: .unreadable("test"))
        return PhotoResultBuilder.build(prepared: prepared, record: nil, evidence: ev,
                                        artifacts: PhotoArtifacts(segmentation: canvas.map(grid), depth: nil))
    }

    private func aggregate(_ results: [PhotoResult]) throws -> EnvironmentProfile {
        try XCTUnwrap(ProfileAggregator.aggregate(results).environment)
    }

    func testSceneFindingCountsOnlyValidObservations() throws {
        let results = [photoResult(order: 0, canvas: beachScene()), photoResult(order: 1, canvas: beachScene()),
                       photoResult(order: 2, canvas: nil)]
        let env = try aggregate(results)
        let f = env.sceneDependent.sceneCategory
        XCTAssertEqual(f.validObservationCount, 2)
        XCTAssertEqual(f.counts[.beachOrWaterfront], 2)
        XCTAssertEqual(f.pattern, .recurring)
        XCTAssertEqual(f.excludedPhotoIDs, [results[2].id], "a photo with no segmentation is excluded, not counted against")
        XCTAssertEqual(env.eligiblePhotoCount, 2)
        XCTAssertEqual(env.coverage[.segmentation]?.unavailablePhotoIDs, [results[2].id])
    }

    func testOnePhotoIsNotAPreference() throws {
        let env = try aggregate([photoResult(order: 0, canvas: beachScene())])
        XCTAssertEqual(env.sceneDependent.sceneCategory.pattern, .singleObservation)
        XCTAssertNil(env.sceneDependent.sceneCategory.dominant)
    }

    func testElementPresenceUsesPhotosWithValidSegmentationAsTheDenominator() throws {
        var trees = Canvas(fill: "sky (other)")
        trees.paint("tree", x: 0..<100, y: 20..<100)
        let results = [photoResult(order: 0, canvas: trees), photoResult(order: 1, canvas: trees),
                       photoResult(order: 2, canvas: beachScene()), photoResult(order: 3, canvas: nil)]
        let env = try aggregate(results)
        let vegetation = try XCTUnwrap(env.sceneDependent.groupTendencies.first { $0.group == .vegetation })
        XCTAssertEqual(vegetation.eligiblePhotoCount, 3, "the photo whose segmentation failed is not in the denominator")
        XCTAssertEqual(vegetation.presentCount, 2)
        XCTAssertEqual(vegetation.pattern, .recurring)
        XCTAssertEqual(vegetation.dominantWhenPresent, 1.0)
        XCTAssertTrue(vegetation.condition.contains("Conditional"), "a scene tendency states when it applies")
    }

    func testTransferableCompositionDoesNotDependOnSegmentation() throws {
        var wall = Canvas(fill: "wall (other)")
        paintPerson(&wall)
        let humans = [human(personBox)]
        let results = [photoResult(order: 0, canvas: wall, humans: humans),
                       photoResult(order: 1, canvas: nil, humans: humans),      // segmentation failed
                       photoResult(order: 2, canvas: wall, humans: humans)]
        let t = try aggregate(results).transferable
        XCTAssertEqual(t.subjectScale.validObservationCount, 3, "the person is measured even when segmentation fails")
        XCTAssertEqual(t.subjectScale.counts[.small], 3, "a 6% box is a small subject")
        XCTAssertEqual(t.environmentProminence.validObservationCount, 2, "prominence needs segmentation: the failed photo is excluded, not guessed")
    }

    func testPhotosWithoutEnvironmentDoNotBreakAggregation() throws {
        var legacy = photoResult(order: 0, canvas: beachScene())
        legacy.environment = nil
        let env = try aggregate([legacy, photoResult(order: 1, canvas: beachScene())])
        XCTAssertEqual(env.sceneDependent.sceneCategory.validObservationCount, 1)
        XCTAssertEqual(env.coverage[.sceneContext]?.unavailablePhotoIDs, [legacy.id])
    }

    func testCameraHandOffIsIdenticalWithAndWithoutEnvironmentData() throws {
        var wall = Canvas(fill: "wall (other)")
        paintPerson(&wall)
        let upper = CGRect(x: 0.40, y: 0.50, width: 0.15, height: 0.20)
        let with = [photoResult(order: 0, canvas: wall, humans: [human(personBox, upper: upper)]),
                    photoResult(order: 1, canvas: wall, humans: [human(personBox, upper: upper)])]
        let without = with.map { r -> PhotoResult in var copy = r; copy.environment = nil; return copy }
        let a = CameraProfileBridge.make(profile: ProfileAggregator.aggregate(with), results: with)
        let b = CameraProfileBridge.make(profile: ProfileAggregator.aggregate(without), results: without)
        XCTAssertEqual(a.photoCount, 2, "the camera still receives the measured subject targets")
        XCTAssertEqual(a.photoCount, b.photoCount)
        XCTAssertEqual(a.subjectPositionDistribution?.meanX, b.subjectPositionDistribution?.meanX)
        XCTAssertEqual(a.subjectSizeDistribution?.meanArea, b.subjectSizeDistribution?.meanArea)
    }

    // MARK: - Integration with the per-photo result

    func testBuilderAttachesTheEnvironmentAnalysisAndIsDeterministic() throws {
        let result = photoResult(order: 0, canvas: beachScene(), humans: [human(personBox)])
        let env = try XCTUnwrap(result.environment)
        XCTAssertEqual(env.scene.primary, .beachOrWaterfront)
        XCTAssertEqual(env, try XCTUnwrap(photoResult(order: 0, canvas: beachScene(), humans: [human(personBox)]).environment),
                       "the same evidence gives the same analysis")
    }

    func testUnreadablePhotosAreUnavailableEverywhere() throws {
        let prepared = PreparedPhoto(id: UUID(), selectionOrder: 0, localIdentifier: "x", outcome: .unreadable("bad file"))
        let env = try XCTUnwrap(PhotoResultBuilder.unreadable(prepared, reason: "bad file").environment)
        XCTAssertEqual(env.segmentation.assessment.status, .unavailable)
        XCTAssertEqual(env.elements.assessment.status, .unavailable)
        XCTAssertEqual(env.scene.assessment.status, .unavailable)
        XCTAssertEqual(env.composition.assessment.status, .unavailable)
    }

    // MARK: - Hardening: semantic reliability is separate from structural validity

    private func reasonText(_ r: SemanticRegion?) -> String { r?.reliability.reason ?? "" }

    func testAnObjectClassCoveringHalfTheFrameIsSetAsideButStillListed() throws {
        var c = Canvas(fill: "wall (other)")
        c.paint("cow", x: 0..<100, y: 30..<82)                   // 52% "cow": a mislabelled surface, in effect
        let result = interpret(c)
        let cow = try XCTUnwrap(result.segmentation.regions.first { $0.family.key == "cow" })
        XCTAssertTrue(cow.isValid, "structurally the mask is fine and is still measured")
        XCTAssertFalse(cow.reliability.isEligible, "but its label is not trusted")
        XCTAssertTrue(reasonText(cow).contains("52%"))
        XCTAssertTrue(result.segmentation.setAsideRegions.contains { $0.family.key == "cow" })
        XCTAssertFalse(result.segmentation.environmentalRegions.contains { $0.family.key == "cow" })
        XCTAssertFalse(result.elements.candidates.contains { $0.familyKey == "cow" }, "never ranked")
        XCTAssertFalse(result.composition.elements.contains { $0.familyKey == "cow" }, "never measured as an element")
        XCTAssertEqual(result.segmentation.environmentFraction, 0.48, accuracy: 1e-9,
                       "its area is neither scenery nor empty: it is removed from the interpretable surroundings")
    }

    func testTheHalfFrameCutOffIsInclusiveAndOnlyForObjectClasses() throws {
        func cowRegion(rows: Int) throws -> SemanticRegion {
            var c = Canvas(fill: "wall (other)")
            c.paint("cow", x: 0..<100, y: 0..<rows)
            return try XCTUnwrap(interpret(c).segmentation.regions.first { $0.family.key == "cow" })
        }
        XCTAssertTrue(try cowRegion(rows: 49).reliability.isEligible, "49% is below the cut-off")
        XCTAssertFalse(try cowRegion(rows: 50).reliability.isEligible, "50% is set aside")

        let wall = Canvas(fill: "wall (other)")                   // a surface may legitimately fill the frame
        XCTAssertTrue(try XCTUnwrap(interpret(wall).segmentation.regions.first { $0.family.key == "wall" }).reliability.isEligible)
    }

    func testARegionSetAsideIsUnknownNotAnEmptyBackground() {
        var c = Canvas(fill: "person")                           // a close-up: person and a "cow" scarf
        c.paint("cow", x: 0..<100, y: 48..<100)
        let result = interpret(c, humans: [human(CGRect(x: 0, y: 0, width: 1, height: 0.5))])
        XCTAssertEqual(result.segmentation.availability, .noEnvironmentalRegions)
        XCTAssertEqual(result.segmentation.assessment.status, .determined, "the output decoded")
        XCTAssertTrue(result.segmentation.assessment.explanation.contains("set aside"))
        XCTAssertEqual(result.elements.outcome, .noEnvironmentalRegions)
        XCTAssertTrue(result.elements.assessment.explanation.contains("Cow"), "the ranking says why nothing is ranked")
        XCTAssertEqual(result.scene.primary, .unknown)
        XCTAssertEqual(result.scene.assessment.status, .insufficientEvidence)
        XCTAssertFalse(result.segmentation.interpretation.isEligible)
    }

    func testUncorroboratedRockIsSetAsideButRockWithSkyOrMountainsIsKept() throws {
        func rock(_ build: (inout Canvas) -> Void) throws -> SemanticRegion {
            var c = Canvas(fill: "rock")
            build(&c)
            return try XCTUnwrap(interpret(c).segmentation.regions.first { $0.family.key == "landform" })
        }
        XCTAssertFalse(try rock { _ in }.reliability.isEligible, "bare rock may be a stone wall")
        XCTAssertFalse(try rock { $0.paint("tree", x: 0..<20, y: 0..<20) }.reliability.isEligible,
                       "4% of vegetation does not make 90%+ rock scenery")
        XCTAssertTrue(try rock { $0.paint("sky (other)", x: 0..<100, y: 0..<20) }.reliability.isEligible, "sky corroborates")
        XCTAssertTrue(try rock { $0.paint("mountain", x: 0..<30, y: 0..<30) }.reliability.isEligible, "a mountain class corroborates")
        XCTAssertTrue(try rock { $0.paint("tree", x: 0..<100, y: 0..<60) }.reliability.isEligible, "rock is only part of the nature here")
    }

    func testASmallRockInAnotherSceneIsLeftAlone() throws {
        var c = Canvas(fill: "wall (other)")
        c.paint("rock", x: 0..<20, y: 0..<20)                    // 4%
        XCTAssertTrue(try XCTUnwrap(interpret(c).segmentation.regions.first { $0.family.key == "landform" }).reliability.isEligible)
    }

    func testAStoneWallLabelledRockIsNeitherRankedNorCalledNature() {
        let result = interpret(Canvas(fill: "rock"))
        XCTAssertFalse(result.elements.candidates.contains { $0.group == .landform })
        XCTAssertNotEqual(result.scene.primary, .naturalEnvironment)
        XCTAssertEqual(result.scene.primary, .unknown)
    }

    func testUnsupportedAndOutOfTableLabelsNeverBecomeRegions() throws {
        // 3000 cells use a class index beyond the label table; 2000 use the "--" placeholder.
        var indices = [UInt8](repeating: UInt8(names.firstIndex(of: "wall (other)")!), count: 100 * 100)
        for i in 0..<3000 { indices[i] = 200 }
        for i in 3000..<5000 { indices[i] = 0 }
        let grid = SegmentationGrid(width: 100, height: 100, classIndices: indices, labels: names)
        let a = SegmentationRegionAnalyzer.analyze(grid, depth: nil, subject: nil)
        XCTAssertEqual(a.unsupportedFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.regions.map(\.family.key), ["wall"], "no region is invented for an unsupported class")
        XCTAssertTrue(a.unsupportedLabels.contains { $0.label == "class 200" })
        XCTAssertTrue(a.unsupportedLabels.contains { $0.label == "--" })
    }

    // MARK: - Hardening: interpretation eligibility

    func testAMajorityOfUnsupportedPixelsWithholdsDominanceAndScene() throws {
        var c = Canvas(fill: "--")                               // 60% placeholder, 40% wall
        c.paint("wall (other)", x: 0..<100, y: 0..<40)
        let result = interpret(c)
        XCTAssertEqual(result.segmentation.availability, .available, "the map decoded")
        XCTAssertFalse(result.segmentation.interpretation.isEligible)
        XCTAssertTrue(result.segmentation.interpretation.reason?.contains("labels this analysis supports") ?? false)
        XCTAssertEqual(result.elements.outcome, .noStandoutElement)
        XCTAssertTrue(result.elements.dominant.isEmpty)
        XCTAssertTrue(result.elements.candidates.allSatisfy { $0.role == .uncertain }, "listed for reference, no role")
        XCTAssertEqual(result.scene.primary, .unknown)
        XCTAssertEqual(result.scene.assessment.status, .insufficientEvidence)
        XCTAssertFalse(result.scene.observedCues.isEmpty, "what was observed is still shown")
    }

    func testLittleVisibleSurroundingsWithholdsDominanceAndRegionDescriptors() {
        var c = Canvas(fill: "person")                           // a 2-cell tree frame around a full-frame person
        c.paint("tree", x: 0..<100, y: 0..<2); c.paint("tree", x: 0..<100, y: 98..<100)
        c.paint("tree", x: 0..<2, y: 0..<100); c.paint("tree", x: 98..<100, y: 0..<100)
        let result = interpret(c, humans: [human(CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96))])
        XCTAssertLessThan(result.segmentation.environmentFraction, ObjectSegmentationResult.minimumInterpretableSurroundings)
        XCTAssertTrue(result.elements.dominant.isEmpty)
        XCTAssertEqual(result.elements.assessment.status, .insufficientEvidence)
        XCTAssertTrue(result.elements.assessment.explanation.contains("frame shows"))
        XCTAssertFalse(result.composition.descriptors.contains { $0.kind == .vegetationNearEdges },
                       "an interpretation about the surroundings is withheld when they are barely visible")
        XCTAssertNotNil(result.composition.subject, "the person is still measured")
    }

    func testEligibilityStatesAreReportedWithReasons() {
        var c = Canvas(fill: "wall (other)")
        XCTAssertTrue(interpret(c).segmentation.interpretation.isEligible)
        c.paint("person", x: 0..<100, y: 0..<95)
        XCTAssertFalse(interpret(c).segmentation.interpretation.isEligible)
        XCTAssertNotNil(interpret(c).segmentation.interpretation.reason)
        XCTAssertFalse(interpret(nil).segmentation.interpretation.isEligible)
    }

    // MARK: - Hardening: the score breakdown explains the actual calculation

    func testBreakdownReproducesTheScoreWhenEveryTermIsAvailable() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<100, y: 20..<100)
        paintPerson(&c)
        let depth = DepthGrid(width: 100, height: 100, nearness: (0..<10_000).map { Float($0 % 100) / 100 })
        let candidate = try XCTUnwrap(interpret(c, humans: [human(personBox)], depth: depth).elements.candidates.first { $0.familyKey == "architecture" })
        XCTAssertTrue(candidate.components.allSatisfy(\.used), "all four terms were available")
        XCTAssertEqual(candidate.components.map(\.effectiveWeight).reduce(0, +), 1.0, accuracy: 1e-9)
        XCTAssertEqual(candidate.components.map { $0.value * $0.effectiveWeight }.reduce(0, +), candidate.score, accuracy: 1e-9)
        XCTAssertEqual(candidate.components.map(\.weight), [0.40, 0.25, 0.20, 0.15])
        XCTAssertEqual(candidate.components.map(\.effectiveWeight), candidate.components.map(\.weight),
                       "with nothing missing, effective equals nominal")
    }

    func testBreakdownIsRenormalisedExactlyWhenTermsAreMissing() throws {
        let r = region("building", area: 0.30, largest: 0.5)
        let result = EnvironmentElementRanker.rank(segmentation([r]),
                                                   context: .init(subjectPresent: false, subjectAmbiguous: false, depthTrusted: false))
        let c = try XCTUnwrap(result.candidates.first)
        let byName = Dictionary(uniqueKeysWithValues: c.components.map { ($0.name, $0) })
        XCTAssertEqual(try XCTUnwrap(byName["Extent"]).effectiveWeight, 0.40 / 0.60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(byName["Coherence"]).effectiveWeight, 0.20 / 0.60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(byName["Adjacency to the person"]).effectiveWeight, 0)
        XCTAssertEqual(try XCTUnwrap(byName["Relative depth"]).effectiveWeight, 0)
        XCTAssertEqual(c.score, (1.0 * 0.40 + 0.5 * 0.20) / 0.60, accuracy: 1e-9, "(extent 1.0 × .40 + coherence .5 × .20) ÷ .60")
        XCTAssertEqual(c.components.map { $0.value * $0.effectiveWeight }.reduce(0, +), c.score, accuracy: 1e-9)
    }

    func testRelativeDepthIsUsedOnlyWhenTheDepthMapHasContrast() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<100, y: 20..<100)
        paintPerson(&c)
        let depth = DepthGrid(width: 100, height: 100, nearness: (0..<10_000).map { Float($0 % 100) / 100 })

        func depthTerm(_ contrast: Double) throws -> ScoreComponent {
            let r = interpret(c, humans: [human(personBox)], depth: depth, depthContrast: contrast)
            let cand = try XCTUnwrap(r.elements.candidates.first { $0.familyKey == "architecture" })
            return try XCTUnwrap(cand.components.first { $0.name == "Relative depth" })
        }
        XCTAssertTrue(try depthTerm(0.30).used)
        let flat = try depthTerm(0.03)                            // below the 0.04 contrast requirement
        XCTAssertFalse(flat.used)
        XCTAssertEqual(flat.effectiveWeight, 0)
        let r = interpret(c, humans: [human(personBox)], depth: depth, depthContrast: 0.03)
        XCTAssertNil(r.segmentation.regions.first { $0.family.key == "architecture" }?.depth, "no depth is attached to regions either")
    }

    func testCombinedObjectRegionsReportTheirPieces() throws {
        var c = Canvas(fill: "wall (other)")
        c.paint("chair", x: 5..<25, y: 60..<75)                  // two separate chairs, one combined region
        c.paint("chair", x: 70..<90, y: 60..<75)
        let candidate = try XCTUnwrap(interpret(c).elements.candidates.first { $0.familyKey == "chair" })
        XCTAssertEqual(candidate.pieceCount, 2)
    }

    // MARK: - Hardening: position, scale and mask compatibility

    func testAContaminatedPersonMaskIsNotComparedMaskToMask() throws {
        var c = Canvas(fill: "building (other)")
        c.paint("person", x: 30..<60, y: 40..<90)
        let primary = human(CGRect(x: 0.30, y: 0.40, width: 0.30, height: 0.50), id: 0)
        let other = human(CGRect(x: 0.50, y: 0.45, width: 0.25, height: 0.40), confidence: 0.8, id: 1)
        let composition = interpret(c, humans: [primary, other]).composition
        let subject = try XCTUnwrap(composition.subject)
        XCTAssertTrue(subject.maskMayIncludeOtherPeople, "another person overlaps the box")
        XCTAssertNotNil(subject.maskAreaRatio, "the mask area is still reported, as a flagged measurement")
        let building = try XCTUnwrap(composition.elements.first { $0.familyKey == "architecture" })
        XCTAssertEqual(try XCTUnwrap(building.relativeToSubject).basis, .boxToBox,
                       "masks are compared only when both are valid and compatible")
        XCTAssertTrue(composition.assessment.limitations.contains { $0.contains("person's box instead of the mask") })
    }

    func testBorderlineFlagsFollowTheStatedThresholds() {
        func scale(_ v: Double) -> Banded<SubjectScaleBand> {
            CompositionMeasurer.band(v, low: CompositionMeasurer.smallScaleCut, high: CompositionMeasurer.largeScaleCut,
                                     labels: (SubjectScaleBand.small, .moderate, .large), margin: { $0 * CompositionMeasurer.scaleMargin })
        }
        // cut 0.10, margin 15% of the cut = 0.015; cut 0.35, margin 0.0525.
        XCTAssertTrue(scale(0.1149).isNearBoundary);  XCTAssertFalse(scale(0.1151).isNearBoundary)
        XCTAssertTrue(scale(0.0851).isNearBoundary);  XCTAssertFalse(scale(0.0849).isNearBoundary)
        XCTAssertTrue(scale(0.4024).isNearBoundary);  XCTAssertFalse(scale(0.4026).isNearBoundary)
        XCTAssertEqual(scale(0.0999).band, .small);   XCTAssertEqual(scale(0.10).band, .moderate)
        XCTAssertEqual(scale(0.3499).band, .moderate); XCTAssertEqual(scale(0.35).band, .large)

        func offset(_ v: Double) -> Banded<HorizontalOffsetBand> {
            CompositionMeasurer.band(v, low: CompositionMeasurer.centeredCut, high: CompositionMeasurer.offCenterCut,
                                     labels: (HorizontalOffsetBand.centered, .slightlyOff, .offCenter), margin: { _ in CompositionMeasurer.offsetMargin })
        }
        XCTAssertTrue(offset(0.0799).isNearBoundary); XCTAssertFalse(offset(0.0801).isNearBoundary)
        XCTAssertTrue(offset(0.1201).isNearBoundary); XCTAssertFalse(offset(0.1199).isNearBoundary)
        XCTAssertFalse(offset(0.10).isNearBoundary, "mid-band is firm")

        func prominence(_ v: Double) -> Banded<ProminenceBand> {
            CompositionMeasurer.band(v, low: CompositionMeasurer.subjectDominatesCut, high: CompositionMeasurer.environmentDominatesCut,
                                     labels: (ProminenceBand.subjectDominates, .balanced, .environmentDominates),
                                     margin: { $0 * CompositionMeasurer.prominenceMargin })
        }
        XCTAssertTrue(prominence(0.8049).isNearBoundary);  XCTAssertFalse(prominence(0.8051).isNearBoundary)
        XCTAssertTrue(prominence(2.299).isNearBoundary);   XCTAssertFalse(prominence(2.301).isNearBoundary)
    }

    // MARK: - Hardening: scene rules

    func testSkyWithACeilingAndFurnitureLeavesTheSettingUndetermined() {
        var c = Canvas(fill: "wall (other)")
        c.paint("sky (other)", x: 0..<100, y: 0..<25)             // outdoor 3
        c.paint("tree", x: 0..<100, y: 25..<50)                   // outdoor 3
        c.paint("ceiling", x: 0..<30, y: 50..<60)                 // indoor 3
        c.paint("chair", x: 0..<50, y: 60..<70)                   // indoor 3
        let scene = interpret(c).scene
        XCTAssertEqual(scene.setting, .undetermined)
        XCTAssertTrue(scene.settingReasons.joined().contains("both indoor and outdoor"))
        XCTAssertNotEqual(scene.primary, .indoorInterior)
        XCTAssertNotEqual(scene.primary, .parkOrGarden)
        XCTAssertNotEqual(scene.primary, .naturalEnvironment)
    }

    func testPavingWithoutBuildingsOrTrafficIsNotAStreet() {
        var c = Canvas(fill: "sky (other)")
        c.paint("pavement", x: 0..<100, y: 55..<100)
        let scene = interpret(c).scene
        XCTAssertEqual(scene.setting, .outdoor)
        XCTAssertNotEqual(scene.primary, .urbanStreet)
    }

    func testAHeavilyCroppedPlainBackgroundStaysLowQuality() {
        var c = Canvas(fill: "wall (other)")
        c.paint("person", x: 0..<100, y: 0..<80)                  // 20% of the frame is background
        let scene = interpret(c, humans: [human(CGRect(x: 0, y: 0, width: 1, height: 0.8))]).scene
        XCTAssertLessThanOrEqual(scene.assessment.quality, .low)
    }

    func testClassifierDisagreementNeitherOverridesNorLowersTheSegmentationReading() {
        let plain = interpret(beachScene(), humans: [human(personBox)]).scene
        let disagree = interpret(beachScene(), humans: [human(personBox)], classifier: [
            ScoredLabel(label: "restaurant, eating house, eating place, eatery", score: 0.6),
            ScoredLabel(label: "library", score: 0.3),
        ]).scene
        XCTAssertEqual(disagree.primary, plain.primary, "an unsupported classifier label cannot override segmentation")
        XCTAssertEqual(disagree.assessment.quality, plain.assessment.quality)
        XCTAssertEqual(disagree.classifierHints.count, 2)
        XCTAssertTrue(disagree.classifierHints.allSatisfy { !$0.used })
    }

    func testAMissingClassifierChangesNothingExceptANote() {
        let seg = interpret(beachScene(), humans: [human(personBox)]).segmentation
        let ran = SceneContextInterpreter.interpret(seg, classifier: .produced([]))
        let failed = SceneContextInterpreter.interpret(seg, classifier: .failed("model missing"))
        let skipped = SceneContextInterpreter.interpret(seg, classifier: .skipped("not run"))
        for other in [failed, skipped] {
            XCTAssertEqual(other.primary, ran.primary)
            XCTAssertEqual(other.assessment.quality, ran.assessment.quality)
            XCTAssertTrue(other.classifierHints.isEmpty)
        }
        XCTAssertTrue(failed.assessment.limitations.contains { $0.contains("model missing") })
    }

    func testInvalidSegmentationLeavesEverySegmentationDependentResultUnavailable() {
        let result = interpret(Canvas(fill: "--"), humans: [human(personBox)])
        XCTAssertEqual(result.elements.assessment.status, .unavailable)
        XCTAssertEqual(result.scene.assessment.status, .unavailable)
        XCTAssertNotNil(result.composition.subject, "Vision's person box is unaffected")
    }

    // MARK: - Hardening: aggregation

    private func treesPhoto(_ order: Int) -> PhotoResult {
        var c = Canvas(fill: "sky (other)")
        c.paint("tree", x: 0..<100, y: 20..<100)
        return photoResult(order: order, canvas: c)
    }

    /// The person fills the frame and only a sliver of wall is visible: decoded, but uninterpretable.
    private func closeUpPhoto(_ order: Int) -> PhotoResult {
        var c = Canvas(fill: "person")
        c.paint("wall (other)", x: 0..<100, y: 95..<100)
        return photoResult(order: order, canvas: c, humans: [human(CGRect(x: 0, y: 0, width: 1, height: 0.95))])
    }

    func testAnUninterpretablePhotoIsNeverCountedAsLackingAnElement() throws {
        let results = [treesPhoto(0), treesPhoto(1), closeUpPhoto(2)]
        XCTAssertEqual(results[2].environment?.segmentation.availability, .available, "it decoded fine")
        let env = try aggregate(results)
        let vegetation = try XCTUnwrap(env.sceneDependent.groupTendencies.first { $0.group == .vegetation })
        XCTAssertEqual(vegetation.eligiblePhotoCount, 2, "the close-up says nothing about whether trees were there")
        XCTAssertEqual(vegetation.presentCount, 2)
        XCTAssertEqual(env.eligiblePhotoCount, 2)
        XCTAssertTrue(env.limitations.contains { $0.contains("too incomplete to interpret") })
    }

    func testASetAsideElementIsUnknownNotAbsentInThatPhoto() throws {
        func photo(_ order: Int, cowRows: Int) -> PhotoResult {
            var c = Canvas(fill: "wall (other)")
            c.paint("cow", x: 0..<100, y: 0..<cowRows)
            return photoResult(order: order, canvas: c)
        }
        let results = [photo(0, cowRows: 60),                      // 60% cow: set aside
                       photo(1, cowRows: 10),                      // 10% cow: eligible, present
                       photo(2, cowRows: 0)]                       // no cow
        let env = try aggregate(results)
        XCTAssertEqual(env.eligiblePhotoCount, 3)
        let cow = try XCTUnwrap(env.sceneDependent.familyTendencies.first { $0.key == "cow" })
        XCTAssertEqual(cow.presentCount, 1)
        XCTAssertEqual(cow.eligiblePhotoCount, 2, "the photo where a cow was set aside is neither present nor absent")
        XCTAssertEqual(cow.pattern, .single, "one photo is an observation, not a habit")
        XCTAssertTrue(env.limitations.contains { $0.contains("set aside") })
        let animals = try XCTUnwrap(env.sceneDependent.groupTendencies.first { $0.group == .animal })
        XCTAssertEqual(animals.eligiblePhotoCount, 2)
    }

    func testOnePhotoIsAnObservationAtEveryLevelOfTheProfile() throws {
        let env = try aggregate([treesPhoto(0)])
        XCTAssertEqual(env.sceneDependent.sceneCategory.pattern, .singleObservation)
        XCTAssertNil(env.sceneDependent.sceneCategory.dominant)
        XCTAssertEqual(env.transferable.environmentProminence.pattern, .noEvidence, "no subject, nothing to compare")
        XCTAssertTrue(env.sceneDependent.groupTendencies.allSatisfy { $0.pattern == .single })
    }

    func testSceneDependentTendenciesAlwaysStateTheirCondition() throws {
        let env = try aggregate([treesPhoto(0), treesPhoto(1)])
        XCTAssertFalse(env.sceneDependent.groupTendencies.isEmpty)
        XCTAssertTrue((env.sceneDependent.groupTendencies + env.sceneDependent.familyTendencies).allSatisfy { $0.condition.contains("Conditional") })
        XCTAssertTrue(env.sceneDependent.placements.allSatisfy { $0.condition.contains("Conditional") })
        XCTAssertTrue(env.transferable.note.contains("any scene"))
    }

    func testCameraHandOffIgnoresSetAsideAndUninterpretableEnvironmentData() throws {
        var wall = Canvas(fill: "wall (other)")
        paintPerson(&wall)
        wall.paint("cow", x: 0..<100, y: 0..<55)
        let upper = CGRect(x: 0.40, y: 0.50, width: 0.15, height: 0.20)
        let with = [photoResult(order: 0, canvas: wall, humans: [human(personBox, upper: upper)]),
                    photoResult(order: 1, canvas: nil, humans: [human(personBox, upper: upper)]),
                    closeUpPhoto(2)]
        let without = with.map { r -> PhotoResult in var copy = r; copy.environment = nil; return copy }
        let a = CameraProfileBridge.make(profile: ProfileAggregator.aggregate(with), results: with)
        let b = CameraProfileBridge.make(profile: ProfileAggregator.aggregate(without), results: without)
        XCTAssertEqual(a.photoCount, b.photoCount)
        XCTAssertEqual(a.subjectPositionDistribution?.meanX, b.subjectPositionDistribution?.meanX)
        XCTAssertEqual(a.subjectPositionDistribution?.meanY, b.subjectPositionDistribution?.meanY)
        XCTAssertEqual(a.subjectSizeDistribution?.meanArea, b.subjectSizeDistribution?.meanArea)
    }

    func testTheHighlightRasterEmphasisesOnlyTheChosenRegion() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<50, y: 0..<100)
        let g = grid(c)
        func alpha(_ image: UIImage?, x: Int, y: Int) throws -> UInt8 {
            let cg = try XCTUnwrap(image?.cgImage)
            let data = try XCTUnwrap(cg.dataProvider?.data)
            let bytes = CFDataGetBytePtr(data)!
            return bytes[(y * cg.width + x) * 4 + 3]
        }
        let all = OverlayRasterizer.segmentation(g)
        let building = OverlayRasterizer.segmentation(g, highlight: "architecture")
        XCTAssertEqual(try alpha(all, x: 10, y: 50), try alpha(all, x: 90, y: 50), "without a highlight every region shares one opacity")
        XCTAssertGreaterThan(try alpha(building, x: 10, y: 50), try alpha(building, x: 90, y: 50) * 4,
                             "the highlighted region is far stronger than the rest")
    }

    func testASetAsideRegionIsDrawnFaintlyButNotRemoved() throws {
        var c = Canvas(fill: "sky (other)")
        c.paint("building (other)", x: 0..<50, y: 0..<100)
        let g = grid(c)
        func alpha(_ image: UIImage?, x: Int, y: Int) throws -> UInt8 {
            let cg = try XCTUnwrap(image?.cgImage)
            let data = try XCTUnwrap(cg.dataProvider?.data)
            return CFDataGetBytePtr(data)![(y * cg.width + x) * 4 + 3]
        }
        let plain = OverlayRasterizer.segmentation(g)
        let aside = OverlayRasterizer.segmentation(g, setAside: ["architecture"])
        XCTAssertEqual(try alpha(aside, x: 90, y: 50), try alpha(plain, x: 90, y: 50), "a region that is used is drawn as before")
        XCTAssertGreaterThan(try alpha(aside, x: 10, y: 50), 0, "the set-aside region is still drawn: it is what the model said")
        XCTAssertLessThan(try alpha(aside, x: 10, y: 50), try alpha(plain, x: 10, y: 50) / 2,
                          "but far fainter than a region that is used")
        // Choosing it in the legend still shows it at the normal highlight strength.
        let chosen = OverlayRasterizer.segmentation(g, highlight: "architecture", setAside: ["architecture"])
        XCTAssertEqual(try alpha(chosen, x: 10, y: 50), try alpha(OverlayRasterizer.segmentation(g, highlight: "architecture"), x: 10, y: 50))
    }
}
