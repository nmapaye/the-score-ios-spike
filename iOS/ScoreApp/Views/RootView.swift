import SwiftUI

struct RootView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        Group {
            switch coordinator.screen {
            case .onboarding:
                OnboardingView()
            case .home:
                HomeView()
            case .active:
                ActiveSessionView()
            case let .completion(completedWalk):
                CompletionView(completedWalk: completedWalk)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.screen)
        .alert(
            "Prototype issue",
            isPresented: Binding(
                get: { coordinator.presentedError != nil },
                set: { if !$0 { coordinator.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) {
                coordinator.dismissError()
            }
        } message: {
            Text(coordinator.presentedError ?? "Unknown error")
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppCoordinator.preview())
}
