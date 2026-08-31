import SwiftUI

struct CompletionView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let completedWalk: CompletedWalk

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 84))
                .foregroundStyle(.indigo)

            VStack(spacing: 8) {
                Text("Walk complete")
                    .font(.largeTitle.bold())
                Text(completedWalk.duration.shortClockText)
                    .font(.system(.title, design: .monospaced, weight: .semibold))
                Text("\(completedWalk.adaptationMode.title) adaptation")
                    .foregroundStyle(.secondary)
            }

            Text("Saved locally: date, duration, score, and adaptation mode.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Back to scores") {
                coordinator.returnHome()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding(24)
    }
}
