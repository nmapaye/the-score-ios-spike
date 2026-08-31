import SwiftUI

@main
@MainActor
struct ScorePrototypeApp: App {
    @StateObject private var coordinator = AppCoordinator.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
        }
    }
}
