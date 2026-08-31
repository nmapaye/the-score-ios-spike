import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A walk with a score")
                            .font(.largeTitle.bold())
                        Text("Hear one musical idea change shape as your movement changes. This build uses disposable engineering audio.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 18) {
                        Image(systemName: coordinator.isPreviewPlaying ? "waveform.circle.fill" : "waveform.circle")
                            .font(.system(size: 72))
                            .foregroundStyle(.indigo)
                            .contentTransition(.symbolEffect(.replace))

                        Text(coordinator.previewEnergy.title)
                            .font(.title2.weight(.semibold))
                            .contentTransition(.numericText())

                        Text(coordinator.isPreviewPlaying ? "Listen through the layer change" : "About 14 seconds")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            coordinator.playAdaptivePreview()
                        } label: {
                            Label(
                                coordinator.isPreviewPlaying ? "Replay adaptive preview" : "Play adaptive preview",
                                systemImage: "play.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Auto uses cadence and broad activity labels only while a session is running. It saves no motion stream, route, or health data.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Continue with Auto") {
                            coordinator.finishOnboardingWithAutomaticMode()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(!coordinator.didHearPreview)

                        Button("Use Manual without Motion") {
                            coordinator.finishOnboardingWithManualMode()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(!coordinator.didHearPreview)

                        if !coordinator.didHearPreview {
                            Text("Play the preview before choosing an adaptation mode.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Score Prototype")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
