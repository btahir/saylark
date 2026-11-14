import FluidAudio
import Foundation

/// FluidAudio's vocabulary boosting: a second, small CTC model spots dictionary terms in the audio
/// and the transcript is rescored toward them. Costs an extra CTC pass over the audio.
public struct VocabularyBooster: Sendable {
    let session: VocabularyBoostingSession

    /// `terms` are canonical spellings; `aliases` maps a term to forms the model is known to hear instead.
    public static func load(terms: [String], aliases: [String: [String]] = [:], minSimilarity: Float? = nil) async throws -> VocabularyBooster {
        ModelPins.apply()
        let ctc = try await CtcModels.downloadAndLoad()
        let list = terms.map { CustomVocabularyTerm(text: $0, aliases: aliases[$0]) }
        let vocab = minSimilarity.map { CustomVocabularyContext(terms: list, minSimilarity: $0) } ?? CustomVocabularyContext(terms: list)
        return VocabularyBooster(session: try await VocabularyBoostingSession(vocabulary: vocab, ctcModels: ctc))
    }

    /// Returns the rescored text and the terms that were applied.
    public func rescore(_ recognition: Recognition, samples: [Float]) async -> (text: String, applied: [String]) {
        let result = recognition.raw
        guard let out = await session.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
        else { return (result.text, []) }
        let applied = out.replacements.filter(\.shouldReplace).map { "\($0.originalWord) -> \($0.replacementWord ?? "")" }
        return (out.text, applied)
    }
}
