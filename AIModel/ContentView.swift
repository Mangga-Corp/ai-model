import SwiftUI

/// Root view — manages the main navigation flow.
/// Flow: Select Photos → Analyze → Preference Profile
struct ContentView: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            PhotoSelectionView { photos in
                path.append(AnalysisRoute(photos: photos))
            }
            .navigationDestination(for: AnalysisRoute.self) { route in
                PhotoAnalysisView(
                    selectedPhotos: route.photos,
                    onComplete: { profile in
                        path.append(profile)
                    }
                )
            }
            .navigationDestination(for: PhotographicPreferenceProfile.self) { profile in
                PreferenceProfileView(
                    profile: profile,
                    onBack: {
                        path.removeLast(path.count)
                    },
                    onOpenCamera: {
                        path.append(CameraRoute(profile: profile))
                    }
                )
            }
            .navigationDestination(for: CameraRoute.self) { route in
                CameraGuidanceView(
                    profile: route.profile,
                    onDismiss: {
                        path.removeLast()
                    }
                )
            }
        }
    }
}

/// Route object for navigation to the analysis screen.
struct AnalysisRoute: Hashable {
    let photos: [ReferencePhoto]
}

/// Route object for navigation to the camera screen.
///
/// Carries the measured preference profile, so the camera guide can be derived
/// from the user's actual composition habit. `PhotographicPreferenceProfile` is
/// `Hashable`, so it can ride on the navigation path directly.
struct CameraRoute: Hashable {
    let profile: PhotographicPreferenceProfile?
}

#Preview {
    ContentView()
}
