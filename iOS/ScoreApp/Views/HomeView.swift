import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Engineering Score")
                            .font(.largeTitle.bold())
                        Text("One complete test score with a persistent theme and movement-linked layers.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Adaptation")
                            .font(.headline)

                        Picker(
                            "Adaptation",
                            selection: Binding(
                                get: { coordinator.adaptationMode },
                                set: coordinator.selectAdaptationMode
                            )
                        ) {
                            Text("Auto").tag(PresentedAdaptationMode.automatic)
                            Text("Manual").tag(PresentedAdaptationMode.manual)
                        }
                        .pickerStyle(.segmented)

                        Text(coordinator.motionPermission.explanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if coordinator.adaptationMode == .manual {
                            ManualEnergyPicker(
                                selection: coordinator.manualEnergy,
                                onSelect: coordinator.selectManualEnergy
                            )
                        }
                    }
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                    Button {
                        coordinator.startWalk()
                    } label: {
                        Label("Start walk", systemImage: "figure.walk")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(coordinator.isStarting)

                    Text("No route, pace target, workout record, microphone, camera, or account is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("Choose a score")
        }
    }
}

struct ManualEnergyPicker: View {
    let selection: PresentedEnergy
    let onSelect: (PresentedEnergy) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PresentedEnergy.manualCases, id: \.self) { energy in
                Button(energy.title) {
                    onSelect(energy)
                }
                .buttonStyle(.borderedProminent)
                .tint(selection == energy ? .indigo : .gray.opacity(0.45))
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Manual intensity")
    }
}
