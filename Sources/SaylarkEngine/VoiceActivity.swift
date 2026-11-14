import FluidAudio
import Foundation

/// Silero voice detection (FluidAudio's Core ML port). One instance per process; each stream keeps
/// its own `VadStreamState`. Works on fixed 4096-sample (256 ms) chunks.
public struct VoiceActivity: VoiceDetecting {
    public static let chunkSize = VadManager.chunkSize

    let manager: VadManager

    public static func load() async throws -> VoiceActivity {
        ModelPins.apply()
        return VoiceActivity(manager: try await VadManager(config: .default))
    }

    public func makeState() -> VadStreamState { VadStreamState.initial() }

    /// Speech probability for one chunk, advancing `state`.
    public func probability(of chunk: [Float], state: inout VadStreamState) async throws -> Float {
        let result = try await manager.processStreamingChunk(chunk, state: state)
        state = result.state
        return result.probability
    }
}
