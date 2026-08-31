import Foundation

@MainActor
final class AppPreferences: PreferencePersisting {
    private enum Key {
        static let completedOnboarding = "scorePrototype.completedOnboarding"
        static let adaptationMode = "scorePrototype.adaptationMode"
        static let manualEnergy = "scorePrototype.manualEnergy"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var completedOnboarding: Bool {
        get { defaults.bool(forKey: Key.completedOnboarding) }
        set { defaults.set(newValue, forKey: Key.completedOnboarding) }
    }

    var adaptationMode: PresentedAdaptationMode {
        get {
            defaults.string(forKey: Key.adaptationMode)
                .flatMap(PresentedAdaptationMode.init(rawValue:)) ?? .automatic
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.adaptationMode)
        }
    }

    var manualEnergy: PresentedEnergy {
        get {
            let saved = defaults.string(forKey: Key.manualEnergy)
                .flatMap(PresentedEnergy.init(rawValue:))
            return PresentedEnergy.manualCases.contains(saved ?? .steady) ? saved ?? .steady : .steady
        }
        set {
            guard PresentedEnergy.manualCases.contains(newValue) else { return }
            defaults.set(newValue.rawValue, forKey: Key.manualEnergy)
        }
    }
}
