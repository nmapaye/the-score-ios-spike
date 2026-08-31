# Physical-device test matrix

Run this matrix on a physical iPhone with the release-like build configuration. Record app commit, Xcode build, device model, iOS version, headphone model and firmware, score pack checksum, start and end time, battery state, Low Power Mode state, and result for every row. Save a short screen recording or timestamped log where practical. A blank row is pending.

## Required acceptance matrix

| Area | Setup and action | Pass condition | Evidence to capture |
| --- | --- | --- | --- |
| First-run preview | Fresh install. Start the audible preview before answering any Motion prompt. | Preview is audible and demonstrates an arrangement change before the system permission sheet appears. | Screen recording and permission state. |
| Motion allowed | Grant Motion permission, start a walk, hold each cadence band steadily for at least the stabilization period. | Auto mode receives current observations. Eligible energy changes occur at a legal musical boundary without a click. | Observation timestamps, requested and applied tiers, transport frames. |
| Motion denied | Fresh install or reset privacy settings, deny Motion, then start a session. | App does not loop the prompt or fail. It selects Manual Steady and Easy, Steady, and Brisk remain usable. | Screen recording and mode log. |
| Motion restricted or unavailable | Run with a restriction if the test device can provide one, otherwise use the shell's injected unavailable state. | The experience matches denied permission and explains Manual mode without claiming sensor access. | State log and UI capture. |
| Stale input | During Auto playback, use the engineering hook to stop new observations for more than ten seconds. | Current musical state stays coherent, input becomes stale, and Manual mode is exposed. No arbitrary tier change occurs. | Last observation time, stale transition time, audio log. |
| Manual fallback | After denial or stale input, request Easy, Brisk, then Steady. | Each request applies at the next legal boundary. Stems stay phase aligned and the UI shows the applied tier. | Requested and applied frames plus short audio capture. |
| Short Surge | Walk steadily, then run long enough for a medium- or high-confidence running classification. | Surge begins only after a legal boundary, lasts no more than twelve seconds, then returns coherently. Low-confidence running alone does not trigger it. | Classification, confidence, start and expiry timestamps. |
| Lock Screen controls | Lock the phone during a session. Use headphone or Lock Screen Play/Pause, then end through the available Stop action. | Metadata remains visible, commands reach the current session once, pause and resume do not create duplicate players, and ending uses the outro. | Lock Screen recording or photos and event log. |
| Locked-screen long walk | With Motion allowed, walk for 60 to 90 minutes with the screen locked. Include stable cadence changes and one stop. Repeat across phone-in-hand, pocket, and bag placements over the test set. | Playback remains continuous, observations do not silently stop, stale fallback appears when warranted, and there are no material clicks, drift, or phase breaks. | Full timestamped transport and observation log, placement, battery delta. |
| Incoming call | During playback, accept an incoming call, speak briefly, then end it. Repeat once by declining. | Music yields to the call. Resume follows the documented app policy and rebuilds one synchronized graph without overlap or lost state. | Interruption reason, graph generation, resume frame, audio route. |
| Siri | Invoke Siri during a session, issue a short request, and dismiss it. | Audio interruption is handled once. Playback resumes or remains paused according to system intent, with no duplicate nodes or stale UI. | Interruption and route log. |
| Wired or USB headphone removal | If supported by the device, remove the active headphones during playback. | Playback pauses and does not unexpectedly continue on the speaker. Reconnection leaves the session recoverable. | Route-before and route-after values plus video. |
| Bluetooth disconnect | Play through Bluetooth headphones, turn them off or move out of range, then reconnect. | The old route is released safely. No unintended speaker playback, crash, or duplicate transport occurs. | Route-change reasons and graph generation. |
| Bluetooth route switch | Switch during playback between two available Bluetooth or AirPlay routes, then return. | Each reconfiguration preserves one canonical position and synchronized nodes. Audible recovery follows one documented policy. | Route timeline, scheduled frame, short audio capture. |
| Engine reconfiguration | Trigger a route sample-rate change or the engineering reconfiguration hook during a transition. | Pending work is cancelled once, the graph rebuilds once, all stems restart from one shared transport position, and no orphan player remains. | Old and new formats, graph count, node count, resume frame. |
| Low Power Mode | Start at 30 percent battery or lower, enable Low Power Mode, lock the screen, and walk for at least 30 minutes. | Background audio and observations follow the same stale-input policy. CPU or scheduling pressure does not cause repeated underruns or UI divergence. | Battery, thermal state, underrun count, observation gaps. |
| App background and foreground | During a walk, unlock the phone, open another app, return, lock again, and repeat. | One session and one transport remain active. The screen reflects the engine state after every return. | Lifecycle and transport identifiers. |
| End and outro | End from foreground, Lock Screen or headphone control where supported, and after an interruption. | One outro is scheduled at an authored boundary, controls become inactive after completion, and one allowed summary is stored. | Outro boundary, completion event, stored summary fields. |
| Summary privacy | Complete sessions in Auto and Manual modes, then inspect app storage through the engineering view or debugger. | Stored records contain only pack ID, date, duration, and adaptation mode. No raw observations, cadence history, activity history, or route data exists. | Redacted storage dump and schema version. |

## Stop conditions

Stop the current run and preserve logs if audio moves to the speaker after headphone loss, the engine creates overlapping playback, a call cannot take audio focus, the app becomes unresponsive, or the transport loses phase. These are material failures, not acceptable test noise.

Any locked-screen observation gap longer than the stale threshold must exercise fallback and be reported. Do not discard it as an outlier without a repeat under the same phone placement and power state.

## Exit gate

The locked-screen Auto claim remains unproven until the long-walk, stale-input, interruption, route-change, Low Power Mode, engine-reconfiguration, and privacy rows pass on physical devices with complete evidence. Passing simulator tests or a short desk test does not satisfy this gate.
