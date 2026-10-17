import Foundation

/// Which ImageNet labels from FastViT point toward which scene categories.
///
/// FastViT is an ImageNet-1k OBJECT classifier on a centre crop. It does not
/// recognise places, and none of its 1000 labels is "park" or "café". This table
/// lists only labels that plausibly co-occur with a kind of place. A match is
/// weak corroboration that can only strengthen a category the segmentation
/// already supports. It never creates a scene category on its own.
nonisolated enum SceneHintTable {

    /// Minimum classifier probability for a label to be considered at all.
    static let minimumScore = 0.10

    private static let table: [String: SceneContextCategory] = {
        var t: [String: SceneContextCategory] = [:]
        func add(_ category: SceneContextCategory, _ labels: [String]) { labels.forEach { t[$0] = category } }
        add(.beachOrWaterfront, ["seashore", "sandbar", "lakeside", "lakeshore", "breakwater", "jetty", "pier",
                                 "dock", "promontory", "coral reef", "catamaran", "trimaran", "canoe",
                                 "speedboat", "gondola"])
        add(.naturalEnvironment, ["alp", "volcano", "valley", "cliff", "geyser", "rapeseed"])
        add(.parkOrGarden, ["park bench", "greenhouse", "lawn mower", "picket fence", "birdhouse", "flowerpot",
                            "daisy", "fountain", "swing", "wheelbarrow", "worm fence"])
        add(.urbanStreet, ["street sign", "traffic light", "parking meter", "trolleybus", "streetcar", "cab",
                           "police van", "minibus", "school bus", "moving van", "fire engine", "garbage truck",
                           "pay-phone", "mailbox", "convertible", "sports car", "limousine", "minivan"])
        add(.architecturalEnvironment, ["church", "mosque", "monastery", "palace", "castle", "dome",
                                        "triumphal arch", "bell cote", "obelisk", "suspension bridge",
                                        "steel arch bridge", "viaduct", "boathouse", "barn", "lighthouse",
                                        "patio", "tile roof", "thatch", "water tower", "totem pole"])
        add(.cafeOrRestaurant, ["restaurant", "menu", "espresso", "espresso maker", "bakery", "confectionery",
                                "wine bottle", "cocktail shaker", "beer glass", "eggnog", "plate", "pizza",
                                "dining table", "coffee mug"])
        add(.indoorInterior, ["library", "home theater", "bookcase", "four-poster", "studio couch",
                              "entertainment center", "wardrobe", "desk", "television", "rocking chair",
                              "barber chair", "throne", "chiffonier", "grand piano", "bathtub",
                              "shower curtain", "washbasin", "quilt", "table lamp", "crib", "cradle",
                              "folding chair", "bookshop", "barbershop", "grocery store", "toyshop",
                              "shoe shop", "tobacco shop", "butcher shop", "cinema"])
        return t
    }()

    /// The category a classifier label supports, if any. Handles ImageNet's
    /// comma-separated synonyms and an optional leading WordNet id.
    static func category(forLabel raw: String) -> SceneContextCategory? {
        var label = raw.lowercased()
        if let range = label.range(of: "^n[0-9]{8}\\s+", options: .regularExpression) { label.removeSubrange(range) }
        for synonym in label.split(separator: ",") {
            if let category = table[synonym.trimmingCharacters(in: .whitespaces)] { return category }
        }
        return nil
    }

    /// First synonym, for display: "restaurant, eating house, ..." -> "restaurant".
    static func shortName(_ raw: String) -> String {
        var label = raw
        if let range = label.range(of: "^n[0-9]{8}\\s+", options: .regularExpression) { label.removeSubrange(range) }
        return label.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
    }
}
