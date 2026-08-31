import CoreMotion
import Foundation

@MainActor
final class CoreMotionSource: MotionObserving {
    var onPermissionChange: ((MotionPermission) -> Void)?
    var onObservation: ((PresentedMotionObservation) -> Void)?

    private(set) var permission: MotionPermission

    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private var staleTimer: Timer?
    private var latestCadence: Double?
    private var latestCadenceDate: Date?
    private var latestActivity = PresentedActivity.unknown
    private var latestConfidence = PresentedMotionConfidence.low
    private var latestActivityDate: Date?
    private var latestInputDate: Date?
    private var updatesStartedAt: Date?
    private var lastEmittedStaleState: Bool?
    private var isRunning = false

    init() {
        permission = Self.currentPermission()
    }

    func requestAuthorizationAndStart() {
        guard permission == .notDetermined else {
            startIfAuthorized()
            return
        }

        startUpdates()
    }

    func startIfAuthorized() {
        permission = Self.currentPermission()
        onPermissionChange?(permission)

        guard permission == .authorized else {
            if permission == .notDetermined {
                return
            }
            emitFallbackObservation()
            return
        }

        startUpdates()
    }

    func stop() {
        guard isRunning else { return }
        pedometer.stopUpdates()
        activityManager.stopActivityUpdates()
        staleTimer?.invalidate()
        staleTimer = nil
        updatesStartedAt = nil
        isRunning = false
    }

    private func startUpdates() {
        guard Self.motionInputIsAvailable else {
            setPermission(.unavailable)
            emitFallbackObservation()
            return
        }
        guard !isRunning else { return }

        isRunning = true
        updatesStartedAt = Date()
        latestCadence = nil
        latestCadenceDate = nil
        latestActivity = .unknown
        latestConfidence = .low
        latestActivityDate = nil
        latestInputDate = nil
        lastEmittedStaleState = nil

        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissionAfterCallback(error: error)
                guard let data else { return }

                if let cadence = data.currentCadence?.doubleValue {
                    self.latestCadence = max(0, cadence * 60)
                    self.latestCadenceDate = data.endDate
                }
                self.latestInputDate = max(self.latestInputDate ?? .distantPast, data.endDate)
                self.emitObservation(now: Date())
            }
        }

        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            Task { @MainActor [weak self] in
                guard let self, let activity else { return }
                self.refreshPermissionAfterCallback(error: nil)
                self.latestActivity = Self.presentedActivity(from: activity)
                self.latestConfidence = Self.presentedConfidence(from: activity.confidence)
                // `startDate` describes when the classified activity began and can
                // predate this session by minutes. Receipt time is the freshness
                // signal for the live classification callback.
                let receivedAt = Date()
                self.latestActivityDate = receivedAt
                self.latestInputDate = max(self.latestInputDate ?? .distantPast, receivedAt)
                self.emitObservation(now: receivedAt)
            }
        }

        staleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitObservation(now: Date())
            }
        }
    }

    private func refreshPermissionAfterCallback(error: Error?) {
        let updated = Self.currentPermission()
        if updated != permission {
            setPermission(updated)
        }

        if error != nil, updated == .denied || updated == .restricted {
            stop()
            emitFallbackObservation()
        }
    }

    private func emitObservation(now: Date) {
        let timestamp: Date
        let isStale: Bool
        if let latestInputDate {
            timestamp = latestInputDate
            isStale = now.timeIntervalSince(latestInputDate) > 10
        } else {
            // Core Motion may take several seconds to deliver its first sample.
            // Treat that as startup latency and expose Manual only after the same
            // ten-second freshness window used for an interrupted stream.
            guard let updatesStartedAt, now.timeIntervalSince(updatesStartedAt) > 10 else {
                return
            }
            timestamp = updatesStartedAt
            isStale = true
        }

        // Fresh callbacks can arrive several times per second. Forward all fresh
        // observations because ScoreCore owns smoothing and dwell policy. For stale
        // input, forward only the state change so the UI does not churn.
        guard !isStale || lastEmittedStaleState != true else { return }
        lastEmittedStaleState = isStale

        let freshCadence = latestCadenceDate.flatMap { sampleDate in
            now.timeIntervalSince(sampleDate) <= 10 ? latestCadence : nil
        }
        let activityIsFresh = latestActivityDate.map { now.timeIntervalSince($0) <= 10 } ?? false

        onObservation?(
            PresentedMotionObservation(
                cadenceStepsPerMinute: freshCadence,
                activity: activityIsFresh ? latestActivity : .unknown,
                confidence: activityIsFresh ? latestConfidence : .low,
                timestamp: timestamp,
                isStale: isStale
            )
        )
    }

    private func emitFallbackObservation() {
        onObservation?(
            PresentedMotionObservation(
                cadenceStepsPerMinute: nil,
                activity: .unknown,
                confidence: .low,
                timestamp: Date(),
                isStale: true
            )
        )
    }

    private func setPermission(_ newValue: MotionPermission) {
        guard permission != newValue else { return }
        permission = newValue
        onPermissionChange?(newValue)
    }

    private static var motionInputIsAvailable: Bool {
        CMPedometer.isCadenceAvailable() && CMMotionActivityManager.isActivityAvailable()
    }

    private static func currentPermission() -> MotionPermission {
        guard motionInputIsAvailable else { return .unavailable }

        switch CMPedometer.authorizationStatus() {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    private static func presentedActivity(from activity: CMMotionActivity) -> PresentedActivity {
        if activity.running { return .running }
        if activity.walking { return .walking }
        if activity.cycling { return .cycling }
        if activity.automotive { return .automotive }
        if activity.stationary { return .stationary }
        return .unknown
    }

    private static func presentedConfidence(from confidence: CMMotionActivityConfidence) -> PresentedMotionConfidence {
        switch confidence {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        @unknown default:
            return .low
        }
    }
}
