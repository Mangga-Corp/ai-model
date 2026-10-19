import SwiftUI

// Presentation-only wording, symbols and colours for Object and Environment
// Analysis. Nothing here measures or interprets anything.

/// Stable colours for segmentation regions, shared by the overlay and the legend
/// so a colour always names the same region.
nonisolated enum RegionPalette {

    static func rgb(for family: SemanticFamily) -> (r: Double, g: Double, b: Double) {
        let base = baseColour(for: family.group)
        // Object-like regions of one group (chair, table, cup...) share a hue; vary the
        // brightness by name so neighbouring regions stay distinguishable.
        guard !family.group.mergesSurfaceClasses else { return base }
        let step = Double(stableHash(family.key) % 4) / 3.0
        let scale = 0.65 + 0.35 * step
        return (min(1, base.r * scale), min(1, base.g * scale), min(1, base.b * scale))
    }

    private static func stableHash(_ s: String) -> Int {
        s.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
    }

    private static func baseColour(for group: ElementGroup) -> (r: Double, g: Double, b: Double) {
        switch group {
        case .person: return (1.00, 1.00, 1.00)
        case .sky: return (0.45, 0.70, 1.00)
        case .water: return (0.00, 0.35, 0.86)
        case .landform: return (0.55, 0.40, 0.24)
        case .vegetation: return (0.16, 0.66, 0.27)
        case .naturalGround: return (0.90, 0.78, 0.47)
        case .pavedSurface: return (0.47, 0.47, 0.47)
        case .architecture: return (0.90, 0.47, 0.16)
        case .wall: return (0.78, 0.63, 0.78)
        case .opening: return (0.63, 0.24, 0.63)
        case .interiorSurface: return (0.35, 0.24, 0.12)
        case .furniture: return (0.86, 0.16, 0.16)
        case .furnishing: return (0.98, 0.47, 0.63)
        case .foodAndDrink: return (0.98, 0.90, 0.16)
        case .vehicle: return (0.00, 0.78, 0.78)
        case .streetFixture: return (0.00, 0.47, 0.47)
        case .animal: return (1.00, 0.00, 1.00)
        case .carriedItem: return (0.47, 1.00, 0.47)
        case .other: return (0.24, 0.24, 0.24)
        }
    }
}

extension SemanticFamily {
    var swatch: Color {
        let c = RegionPalette.rgb(for: self)
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

extension ElementRole {
    var label: String {
        switch self {
        case .dominant: return "Dominant"
        case .secondary: return "Secondary"
        case .uncertain: return "Uncertain"
        }
    }

    var color: Color {
        switch self {
        case .dominant: return .orange
        case .secondary: return .blue
        case .uncertain: return .gray
        }
    }
}

extension SceneContextCategory {
    var symbol: String {
        switch self {
        case .indoorInterior: return "sofa"
        case .cafeOrRestaurant: return "cup.and.saucer"
        case .urbanStreet: return "building.2"
        case .architecturalEnvironment: return "building.columns"
        case .parkOrGarden: return "tree"
        case .naturalEnvironment: return "mountain.2"
        case .beachOrWaterfront: return "beach.umbrella"
        case .studioOrPlainBackground: return "rectangle"
        case .mixedEnvironment: return "square.grid.2x2"
        case .unknown: return "questionmark.circle"
        }
    }
}

extension SubjectScaleBand {
    var label: String {
        switch self {
        case .small: return "Small in frame"
        case .moderate: return "Moderate size"
        case .large: return "Large in frame"
        }
    }
}

extension HorizontalOffsetBand {
    var label: String {
        switch self {
        case .centered: return "Centered"
        case .slightlyOff: return "Slightly off-center"
        case .offCenter: return "Off-center"
        }
    }
}

extension ProminenceBand {
    var label: String {
        switch self {
        case .environmentDominates: return "Environment dominates"
        case .balanced: return "Balanced"
        case .subjectDominates: return "Subject dominates"
        }
    }
}

extension PresencePattern {
    var label: String {
        switch self {
        case .none: return "Not seen"
        case .single: return "One photo"
        case .occasional: return "Occasional"
        case .recurring: return "Recurring"
        }
    }
}

extension EnvironmentFacet {
    var title: String {
        switch self {
        case .segmentation: return "Object segmentation"
        case .dominantElements: return "Dominant elements"
        case .sceneContext: return "Scene context"
        case .composition: return "Position and scale"
        }
    }
}

enum EnvironmentFormat {
    static func pct(_ v: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f%%", v * 100) }

    static func zone(_ h: HorizontalZone, _ v: VerticalZone) -> String { "\(h.label.lowercased()) · \(v.label.lowercased())" }

    static func point(_ p: CGPoint) -> String { String(format: "(%.2f, %.2f)", p.x, p.y) }
}
