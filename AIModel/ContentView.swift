import SwiftUI

/// Root view — manages the main navigation flow.
/// Flow: Select Photos → Analysis (progress, then results) → Photo detail /
/// Preference Profile → Camera Guidance.
///
/// The analysis session lives here, above the navigation stack, so results
/// survive pushing and popping screens and are never recomputed.
struct ContentView: View {
    @State private var path = NavigationPath()
    @StateObject private var session = AnalysisSession()

    var body: some View {
        NavigationStack(path: $path) {
            PhotoSelectionView { photos in
                path.append(AnalysisRoute(photos: photos))
            }
            .navigationDestination(for: AnalysisRoute.self) { route in
                AnalysisFlowView(
                    session: session,
                    photos: route.photos,
                    onOpenCamera: {
                        path.append(CameraRoute(profile: session.cameraGuidanceProfile()))
                    },
                    onExit: {
                        path.removeLast(path.count)
                    }
                )
            }
            .navigationDestination(for: PhotoDetailRoute.self) { route in
                PhotoResultDetailView(session: session, photoID: route.photoID)
            }
            .navigationDestination(for: ProfileRoute.self) { _ in
                ProfileDetailView(session: session)
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
