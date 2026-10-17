import Foundation
import CoreGraphics

/// The main person as the region analyzer needs to know them.
nonisolated struct SubjectRegionContext: Sendable, Equatable {
    /// Vision's person box, image space.
    let box: CGRect
    /// Boxes of other detected people that could contaminate DETR's merged person mask.
    let otherBoxes: [CGRect]
}

/// Feature A: turns DETR's per-pixel class map into measured semantic regions.
///
/// INPUT. `SegmentationGrid` is a semantic class map stretched over the whole
/// frame (no crop, no letterbox), top-left origin, so a cell (x, y) of a W x H
/// grid is the image point ((x + 0.5) / W, (y + 0.5) / H). Areas are therefore
/// shares of the whole image, and no orientation or aspect correction is needed.
///
/// METHOD (all deterministic, one pass over the grid per step)
///  1. Each DETR class maps to a `SemanticFamily` (see `SegmentationTaxonomy`);
///     classes outside the label table are unsupported and measured as such.
///  2. Connected components (4-connectivity) are labelled per family. A fragment
///     smaller than 0.06% of the image is speckle: it counts toward nothing.
///  3. A family is a valid mask when its counted pixels reach 0.2% of the image.
///     Smaller regions are reported as `tooSmall` and get NO geometry.
///  4. For valid masks: area, union bounding box, centre of mass, fill ratio,
///     fragment count, border-band share, depth and relation to the person.
///  5. The person's mask is the merged `person` class inside the Vision box. It
///     is valid with at least 0.2% of the image and 15% of the box covered.
///
/// LIMITS. DETR gives one label per pixel and no confidence, so nothing here is
/// a probability, and objects of one class cannot be separated into instances.
nonisolated enum SegmentationRegionAnalyzer {

    static let fragmentFraction = 0.0006
    static let minimumFragmentCells = 16
    static let validRegionFraction = 0.002
    static let borderBand = 0.15
    static let ringGrowth = 0.30
    static let minimumSupportedFraction = 0.05
    static let minimumMaskCoverage = 0.15
    static let depthStride = 2
    static let minimumDepthSamples = 50

    struct Analysis {
        var regions: [SemanticRegion] = []
        var human: HumanMaskMeasurement?
        var allPeopleFraction = 0.0
        var environmentFraction = 0.0
        var unsupportedFraction = 0.0
        var unsupportedLabels: [RawLabelShare] = []
        var gridWidth = 0
        var gridHeight = 0
        /// Set when the grid cannot be trusted at all.
        var problem: String?
    }

    // MARK: Union-find

    private struct UnionFind {
        var parent: [Int32] = []

        mutating func make() -> Int32 {
            let label = Int32(parent.count)
            parent.append(label)
            return label
        }

        mutating func find(_ x: Int32) -> Int32 {
            var root = x
            while parent[Int(root)] != root {
                parent[Int(root)] = parent[Int(parent[Int(root)])]
                root = parent[Int(root)]
            }
            return root
        }

        mutating func union(_ a: Int32, _ b: Int32) -> Int32 {
            let ra = find(a), rb = find(b)
            if ra == rb { return ra }
            let (low, high) = ra < rb ? (ra, rb) : (rb, ra)
            parent[Int(high)] = low
            return low
        }
    }

    private struct Fragment {
        var family: Int16 = -1
        var size = 0
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        var sumX = 0, sumY = 0
    }

    // MARK: Analysis

    static func analyze(_ grid: SegmentationGrid, depth: DepthGrid?, subject: SubjectRegionContext?) -> Analysis {
        var out = Analysis()
        let w = grid.width, h = grid.height, n = w * h
        out.gridWidth = w
        out.gridHeight = h

        guard w > 0, h > 0, grid.classIndices.count == n else {
            out.problem = "the class map is empty or its size is inconsistent"
            return out
        }
        guard !grid.labels.isEmpty else {
            out.problem = "the model has no label table to interpret its classes"
            return out
        }

        let mapping = SegmentationTaxonomy.Mapping(labels: grid.labels)
        let familyCount = mapping.families.count
        let personIndex = mapping.personFamily
        let total = Double(n)

        // 1. Family per cell, and class histogram.
        var family = [Int16](repeating: -1, count: n)
        var classCounts = [Int](repeating: 0, count: 256)
        var supportedCells = 0
        for i in 0..<n {
            let c = Int(grid.classIndices[i])
            classCounts[c] += 1
            if c < mapping.familyOfClass.count, mapping.familyOfClass[c] >= 0 {
                family[i] = Int16(mapping.familyOfClass[c])
                supportedCells += 1
            }
        }

        out.unsupportedFraction = 1 - Double(supportedCells) / total
        out.unsupportedLabels = (0..<256)
            .filter { c in classCounts[c] > 0 && !(c < mapping.familyOfClass.count && mapping.familyOfClass[c] >= 0) }
            .sorted { classCounts[$0] != classCounts[$1] ? classCounts[$0] > classCounts[$1] : $0 < $1 }
            .prefix(5)
            .map { RawLabelShare(label: $0 < grid.labels.count ? grid.labels[$0] : "class \($0)",
                                 areaFraction: Double(classCounts[$0]) / total) }

        guard Double(supportedCells) / total >= minimumSupportedFraction else {
            out.problem = String(format: "only %.1f%% of pixels have a class this analysis supports; the output looks degenerate",
                                 Double(supportedCells) / total * 100)
            return out
        }

        // 2. Connected components per family (4-connectivity).
        //
        // A person, or something they carry, HIDES the region behind them rather than
        // dividing it, so two pieces of one region separated only by such pixels are
        // joined. Without this, anyone standing in front of a wall or a lawn would
        // make that background look fragmented.
        let occluder = mapping.families.map { $0.group == .person || $0.group == .carriedItem }
        var uf = UnionFind()
        var label = [Int32](repeating: -1, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let f = family[i]
                if f < 0 { continue }

                var left: Int32 = -1
                if x > 0, family[i - 1] == f {
                    left = label[i - 1]
                } else if x > 0, !occluder[Int(f)] {
                    var lx = x - 1
                    while lx >= 0, family[y * w + lx] >= 0, occluder[Int(family[y * w + lx])] { lx -= 1 }
                    if lx >= 0, lx < x - 1, family[y * w + lx] == f { left = label[y * w + lx] }
                }

                var up: Int32 = -1
                if y > 0, family[i - w] == f {
                    up = label[i - w]
                } else if y > 0, !occluder[Int(f)] {
                    var ly = y - 1
                    while ly >= 0, family[ly * w + x] >= 0, occluder[Int(family[ly * w + x])] { ly -= 1 }
                    if ly >= 0, ly < y - 1, family[ly * w + x] == f { up = label[ly * w + x] }
                }
                if left < 0 && up < 0 {
                    label[i] = uf.make()
                } else if left >= 0 && up >= 0 {
                    label[i] = uf.union(left, up)
                } else {
                    label[i] = max(left, up)
                }
            }
        }

        var fragments = [Fragment](repeating: Fragment(), count: uf.parent.count)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if family[i] < 0 { continue }
                let root = Int(uf.find(label[i]))
                label[i] = Int32(root)
                fragments[root].family = family[i]
                fragments[root].size += 1
                fragments[root].minX = min(fragments[root].minX, x)
                fragments[root].maxX = max(fragments[root].maxX, x)
                fragments[root].minY = min(fragments[root].minY, y)
                fragments[root].maxY = max(fragments[root].maxY, y)
                fragments[root].sumX += x
                fragments[root].sumY += y
            }
        }

        let fragmentCells = max(minimumFragmentCells, Int(total * fragmentFraction))
        let validCells = max(fragmentCells, Int(total * validRegionFraction))
        let significant = fragments.map { $0.size >= fragmentCells }

        // 3. One scan for per-family statistics.
        var familyCells = [Int](repeating: 0, count: familyCount)
        var familyPixels = [Int](repeating: 0, count: familyCount)
        var familyBorder = [Int](repeating: 0, count: familyCount)
        var familyInBox = [Int](repeating: 0, count: familyCount)
        var familyRing = [Int](repeating: 0, count: familyCount)
        var familyDepth = [[Float]](repeating: [], count: familyCount)
        var significantClassCounts = [Int](repeating: 0, count: 256)

        let box = subject?.box
        let ring = box.map { ImageSpace.expanded($0, by: ringGrowth) }
        let bandX = max(1, Int((Double(w) * borderBand).rounded()))
        let bandY = max(1, Int((Double(h) * borderBand).rounded()))

        let isCarried = mapping.families.map { $0.group == .carriedItem }
        var ringCells = 0, boxCells = 0
        var personCells = 0, carriedCells = 0
        var humanCount = 0
        var hMinX = Int.max, hMaxX = -1, hMinY = Int.max, hMaxY = -1
        var humanDepth: [Float] = []

        for y in 0..<h {
            let py = (Double(y) + 0.5) / Double(h)
            for x in 0..<w {
                let i = y * w + x
                let f = Int(family[i])
                let p = CGPoint(x: (Double(x) + 0.5) / Double(w), y: py)
                let inBox = box?.contains(p) ?? false
                let inRing = !inBox && (ring?.contains(p) ?? false)
                if inBox { boxCells += 1 }
                if f < 0 {
                    if inRing { ringCells += 1 }
                    continue
                }
                familyCells[f] += 1
                let isPerson = f == personIndex
                if isPerson { personCells += 1 }
                if isCarried[f] { carriedCells += 1 }
                // The band around the person measures the SURROUNDINGS, so the
                // person and the things they carry are left out of it.
                if inRing && !isPerson && !isCarried[f] { ringCells += 1 }

                guard significant[Int(label[i])] else { continue }
                familyPixels[f] += 1
                significantClassCounts[Int(grid.classIndices[i])] += 1
                if x < bandX || x >= w - bandX || y < bandY || y >= h - bandY { familyBorder[f] += 1 }

                let sampleDepth = depth != nil && x % depthStride == 0 && y % depthStride == 0
                if isPerson {
                    if inBox {
                        humanCount += 1
                        hMinX = min(hMinX, x); hMaxX = max(hMaxX, x)
                        hMinY = min(hMinY, y); hMaxY = max(hMaxY, y)
                        if sampleDepth, let depth { humanDepth.append(depth.value(atNormalized: p)) }
                    }
                } else {
                    if inBox { familyInBox[f] += 1 }
                    if inRing { familyRing[f] += 1 }
                    if sampleDepth, let depth { familyDepth[f].append(depth.value(atNormalized: p)) }
                }
            }
        }

        out.allPeopleFraction = Double(personCells) / total
        // Surroundings = supported pixels that are neither a person nor something they carry.
        out.environmentFraction = Double(supportedCells - personCells - carriedCells) / total

        // 4. Per-family fragment aggregates.
        var fMinX = [Int](repeating: Int.max, count: familyCount)
        var fMaxX = [Int](repeating: -1, count: familyCount)
        var fMinY = [Int](repeating: Int.max, count: familyCount)
        var fMaxY = [Int](repeating: -1, count: familyCount)
        var fSumX = [Int](repeating: 0, count: familyCount)
        var fSumY = [Int](repeating: 0, count: familyCount)
        var fCount = [Int](repeating: 0, count: familyCount)
        var fLargest = [Int](repeating: 0, count: familyCount)
        for (root, fragment) in fragments.enumerated() where fragment.family >= 0 && significant[root] {
            let f = Int(fragment.family)
            fMinX[f] = min(fMinX[f], fragment.minX); fMaxX[f] = max(fMaxX[f], fragment.maxX)
            fMinY[f] = min(fMinY[f], fragment.minY); fMaxY[f] = max(fMaxY[f], fragment.maxY)
            fSumX[f] += fragment.sumX; fSumY[f] += fragment.sumY
            fCount[f] += 1
            fLargest[f] = max(fLargest[f], fragment.size)
        }

        // 5. The person's mask.
        if let subject {
            if personIndex == nil {
                out.human = HumanMaskMeasurement(
                    isValid: false, invalidReason: "the model's label table has no person class",
                    maskPixelCount: 0, maskAreaFraction: nil, maskBoundingBox: nil,
                    coverageOfDetectionBox: nil, mayIncludeOtherPeople: false, medianNearness: nil)
            } else {
                let coverage = boxCells > 0 ? Double(humanCount) / Double(boxCells) : 0
                let valid = humanCount >= validCells && coverage >= minimumMaskCoverage
                let reason: String?
                if valid { reason = nil }
                else if humanCount == 0 { reason = "no person pixels fall inside the detection box" }
                else if coverage < minimumMaskCoverage {
                    reason = String(format: "person pixels cover only %.0f%% of the detection box", coverage * 100)
                } else { reason = "the person region is too small to measure" }

                let overlapsOthers = subject.otherBoxes.contains { other in
                    let overlap = ImageSpace.intersectionArea(other, subject.box)
                    return overlap / max(1e-9, min(ImageSpace.area(other), ImageSpace.area(subject.box))) > 0.10
                }
                let maskBox: CGRect? = valid
                    ? CGRect(x: Double(hMinX) / Double(w), y: Double(hMinY) / Double(h),
                             width: Double(hMaxX - hMinX + 1) / Double(w), height: Double(hMaxY - hMinY + 1) / Double(h))
                    : nil
                out.human = HumanMaskMeasurement(
                    isValid: valid, invalidReason: reason, maskPixelCount: humanCount,
                    maskAreaFraction: valid ? Double(humanCount) / total : nil,
                    maskBoundingBox: maskBox,
                    coverageOfDetectionBox: boxCells > 0 ? coverage : nil,
                    mayIncludeOtherPeople: valid && overlapsOthers,
                    medianNearness: valid && humanDepth.count >= minimumDepthSamples ? Double(median(humanDepth)) : nil)
            }
        }

        // 6. Environmental regions.
        var regions: [SemanticRegion] = []
        for f in 0..<familyCount where f != personIndex && familyPixels[f] > 0 {
            let fam = mapping.families[f]
            let pixels = familyPixels[f]

            let labels = (0..<min(256, mapping.familyOfClass.count))
                .filter { mapping.familyOfClass[$0] == f && significantClassCounts[$0] > 0 }
                .sorted { significantClassCounts[$0] != significantClassCounts[$1]
                    ? significantClassCounts[$0] > significantClassCounts[$1] : $0 < $1 }
                .map { RawLabelShare(label: grid.labels[$0], areaFraction: Double(significantClassCounts[$0]) / total) }

            var geometry: RegionGeometry?
            var regionDepth: RegionDepth?
            var relation: RegionSubjectRelation?
            let valid = pixels >= validCells && fCount[f] > 0

            if valid {
                let bw = fMaxX[f] - fMinX[f] + 1, bh = fMaxY[f] - fMinY[f] + 1
                let bounding = CGRect(x: Double(fMinX[f]) / Double(w), y: Double(fMinY[f]) / Double(h),
                                      width: Double(bw) / Double(w), height: Double(bh) / Double(h))
                geometry = RegionGeometry(
                    boundingBox: bounding,
                    boundingBoxArea: Double(bw * bh) / total,
                    centroid: CGPoint(x: (Double(fSumX[f]) / Double(pixels) + 0.5) / Double(w),
                                      y: (Double(fSumY[f]) / Double(pixels) + 0.5) / Double(h)),
                    fillRatio: Double(pixels) / Double(max(1, bw * bh)),
                    componentCount: fCount[f],
                    largestComponentShare: Double(fLargest[f]) / Double(pixels),
                    borderBandShare: Double(familyBorder[f]) / Double(pixels),
                    touchedEdges: ImageSpace.touchedEdges(of: bounding))
                if familyDepth[f].count >= minimumDepthSamples {
                    regionDepth = RegionDepth(medianNearness: Double(median(familyDepth[f])),
                                              sampleCount: familyDepth[f].count)
                }
                if subject != nil, ringCells > 0 {
                    relation = RegionSubjectRelation(ringShare: Double(familyRing[f]) / Double(ringCells),
                                                     insideSubjectBoxShare: Double(familyInBox[f]) / Double(pixels))
                }
            }

            regions.append(SemanticRegion(
                family: fam, rawLabels: labels, pixelCount: pixels,
                specklePixelCount: familyCells[f] - pixels,
                areaFraction: Double(pixels) / total,
                validity: valid ? .valid : .tooSmall,
                geometry: geometry, depth: regionDepth, subjectRelation: relation, modelConfidence: nil))
        }

        out.regions = regions.sorted {
            $0.areaFraction != $1.areaFraction ? $0.areaFraction > $1.areaFraction : $0.family.key < $1.family.key
        }
        return out
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}
