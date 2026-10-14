import Foundation
import Combine

/// ViewModel for the preference profile screen (Page 3).
/// Displays the aggregated results with traceable evidence.
@MainActor
final class PreferenceProfileViewModel: ObservableObject {

    @Published var profile: PhotographicPreferenceProfile
    @Published var selectedInsight: PreferenceInsight?

    var insightsGroupedByCategory: [(category: InsightCategory, insights: [PreferenceInsight])] {
        profile.insights
            .reduce(into: [InsightCategory: [PreferenceInsight]]()) { result, insight in
                result[insight.category, default: []].append(insight)
            }
            .sorted { first, second in
                // Sort by evidence strength, strongest first.
                let firstStrength = ProfileInsightFormatters.evidenceStrengthOrder
                    .firstIndex(of: first.1.first?.evidenceStrength ?? .insufficient)
                    ?? ProfileInsightFormatters.evidenceStrengthOrder.count
                let secondStrength = ProfileInsightFormatters.evidenceStrengthOrder
                    .firstIndex(of: second.1.first?.evidenceStrength ?? .insufficient)
                    ?? ProfileInsightFormatters.evidenceStrengthOrder.count
                return firstStrength < secondStrength
            }
            .map { ($0.key, $0.value) }
    }

    init(profile: PhotographicPreferenceProfile) {
        self.profile = profile
    }

}
