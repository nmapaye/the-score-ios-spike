import SwiftUI

struct ActiveSessionView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: coordinator.isPaused ? "pause.circle.fill" : "waveform.circle.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(coordinator.isPaused ? .secondary : .indigo)
                    .contentTransition(.symbolEffect(.replace))

                VStack(spacing: 8) {
                    Text(coordinator.displayedEnergy.title)
                        .font(.largeTitle.bold())
                    Text(coordinator.elapsed.shortClockText)
                        .font(.system(.title2, design: .monospaced, weight: .medium))
                        .accessibilityLabel("Elapsed time \(coordinator.elapsed.shortClockText)")
                    Text(coordinator.sessionStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if coordinator.adaptationMode == .manual {
                    ManualEnergyPicker(
                        selection: coordinator.manualEnergy,
                        onSelect: coordinator.selectManualEnergy
                    )
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        coordinator.togglePause()
                    } label: {
                        Label(
                            coordinator.isPaused ? "Resume" : "Pause",
                            systemImage: coordinator.isPaused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(coordinator.isEnding)

                    Button(role: .destructive) {
                        coordinator.finishWalk()
                    } label: {
                        Text(coordinator.isEnding ? "Ending…" : "End walk")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(coordinator.isEnding)
                }
            }
            .padding(24)
            .navigationTitle("Engineering Score")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
    }
}
