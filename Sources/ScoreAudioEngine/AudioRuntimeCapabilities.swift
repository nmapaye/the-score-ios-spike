import AudioToolbox
import Foundation

public enum AudioRuntimeCapabilities {
    /// Some command-line and sandboxed hosts ship AVFAudio headers but expose no
    /// Audio Unit components at runtime. AVAudioPlayerNode aborts instead of
    /// throwing in that state, so callers must preflight before creating a node.
    public static var supportsScheduledSoundPlayer: Bool {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Generator,
            componentSubType: kAudioUnitSubType_ScheduledSoundPlayer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AudioComponentFindNext(nil, &description) != nil
    }
}
