import FluidAudio

/// The speech models download from Hugging Face on first use. FluidAudio fetches `main` by
/// default, which the model owner can change at any time; Saylark pins each repository to the
/// commit it was tested with, so every install gets the same files. Bump these on purpose, after
/// testing, together with a FluidAudio update.
public enum ModelPins {
    public static let revisions: [String: String] = [
        "FluidInference/parakeet-ultra-coreml": "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
        "FluidInference/silero-vad-coreml": "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
        "FluidInference/parakeet-ctc-110m-coreml": "accdafd8cf8a2ff1cabe3c11e54416b405d409aa",
    ]

    /// Call before any model download. Idempotent; keeps any other overrides already set.
    public static func apply() {
        var overrides = ModelRegistry.revisionOverrides
        for (repo, commit) in revisions where overrides[repo] == nil { overrides[repo] = commit }
        ModelRegistry.revisionOverrides = overrides
    }
}
