# Architecture and scope

## Purpose

This spike isolates the hardest product claims behind small interfaces. It asks whether one fixed-tempo, composer-authored score can stay phase locked while motion queues musically legal arrangement changes. The iOS layer supplies observations and app lifecycle events. It does not decide musical timing.

## Module boundaries

```text
iOS SwiftUI shell
  |-- Core Motion adapter --------> ScoreCore
  |-- audio session and controls -> ScoreAudioEngine
  `-- local summary store --------> ScoreCore contracts

ScoreLab -------------------------> ScoreCore + ScoreAudioEngine
ScoreAudioEngine -----------------> ScoreCore
ScoreCore ------------------------> Foundation only
```

`ScoreCore` owns the product rules. Its public values describe a score pack, a motion observation, the current arrangement, and the privacy-limited session summary. Its deterministic services own musical boundary calculations, allowed section transitions, cadence smoothing, hysteresis, stabilization, dwell time, stale-input handling, manual fallback, Surge expiry, and session lifecycle state. A pack can include a composer-authored `energySectionMap`, which maps every energy tier to a known section. Validation requires complete, reachable mappings rather than inventing section choices at runtime.

`ScoreAudioEngine` owns playback. One canonical sample clock drives synchronized player nodes. Every stem remains scheduled and phase aligned even when its gain is silent. Gain changes are queued at bar boundaries, section changes at phrase boundaries, and recovery rebuilds the graph as one coordinated operation. If the requested frame is too close for the scheduling window, the transport returns the later exact boundary it accepted. The arrangement controller adopts that frame only after confirming that target, boundary, reason, ordering, and alignment are unchanged. This prevents the product state from claiming an earlier transition than the audio engine scheduled. The transport does not classify motion or persist sessions.

`ScoreLab` is an engineering executable. It validates pack structure and replays fixed traces for steady walking, stop and start, running Surge, stale observations, and manual fallback. Its output supports diagnosis and is not product analytics.

The `iOS` shell owns permission prompts, `CMPedometer`, `CMMotionActivity`, `AVAudioSession`, lifecycle events, Now Playing information, remote commands, interruption notifications, route-change notifications, SwiftUI state, and local storage. It converts Apple framework values into `ScoreCore` contracts and calls the engine through its public transport interface.

## Data and control flow

1. The user hears an adaptive preview before the app asks for Motion permission.
2. Starting a walk loads one pack and starts its canonical transport.
3. The motion adapter emits cadence, classification, confidence, timestamp, source, and freshness information. It sends no raw accelerometer stream.
4. `ScoreCore` smooths observations and determines a requested energy tier. A change must pass hysteresis, five-second stabilization, and twelve-second dwell rules before it is eligible.
5. The arrangement controller chooses the next legal musical boundary. The engine schedules the change with at least its configured lead time.
6. Medium- or high-confidence running can request a Surge for at most twelve seconds. There is no Run mode or workout record.
7. After ten seconds without a current observation, the existing coherent arrangement remains audible and the UI exposes Manual mode. Denied permission starts Manual Steady.
8. Ending a walk queues the authored outro. Only pack ID, date, duration, and adaptation mode may enter the local session summary.

## Musical model

A score pack declares a fixed BPM, meter, sample rate, exact loop frames, stems, sections, intensity mixes, the optional composer `energySectionMap`, legal section transitions, intro and outro assets, entitlement, and content provenance. Frame positions are derived from one origin rather than repeatedly adding floating-point durations. This avoids cumulative timing drift.

V1 uses procedural arrangement. Authored audio and authored transition rules are selected at runtime. It does not synthesize a composition, generate model audio, continuously time-stretch to cadence, or mix arbitrary user songs.

## Privacy boundary

The spike processes motion on device. It does not request location, HealthKit, microphone, camera, contacts, or network access. It must not save routes, raw motion samples, cadence histories, activity histories, or health data. Session summaries are local and contain only the four fields described above.

## Fault behavior

- Invalid pack metadata fails before playback and reports the offending pack element.
- Late or noisy motion holds the current musical state rather than forcing a transition.
- Denied Motion permission keeps the session usable through Manual Steady, Easy, and Brisk controls.
- An interruption or audio-engine reconfiguration pauses scheduling, rebuilds all synchronized nodes, and resumes from one shared transport position.
- Transition, phase-monitor, outro-fade, preview, and advancement work is cancelled with generation checks when a session stops or rebuilds. A failed replacement pack invalidates the prepared transport instead of leaving the prior pack startable.
- Headphone removal follows system safety behavior and must not cause automatic speaker playback without an explicit user action.
- A failed outro or unrecoverable engine error ends cleanly and preserves only an allowed session summary.

## Deliberate exclusions

This repository contains no backend, account, GPS, route map, HealthKit, Apple Watch app, StoreKit purchase flow, premium catalog, production music, creator marketplace, place detection, danger detection, social feed, Android target, runtime AI audio, generated composition, or user-song integration.
