import FluidAudio
import Testing
@testable import SaylarkEngine

@Suite struct ModelPinsTests {
    /// Every model Saylark downloads is pinned to a full commit hash, never `main`.
    @Test func everyModelIsPinnedToACommit() {
        ModelPins.apply()
        for repo in ["FluidInference/parakeet-ultra-coreml", "FluidInference/silero-vad-coreml", "FluidInference/parakeet-ctc-110m-coreml"] {
            let rev = ModelRegistry.revisionOverrides[repo]
            #expect(rev?.count == 40 && rev?.allSatisfy(\.isHexDigit) == true, "\(repo) is not pinned")
        }
    }
}
