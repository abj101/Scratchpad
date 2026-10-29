#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Polishes recognized handwriting with the on-device system language model.
@available(macOS 26, *)
public final class FoundationModelsPolisher: TextPolisher {
    private static let instructions = """
        You are a minimal proofreader for text recognized from handwriting, where words may be \
        run together, split wrongly or misread by a letter. Make only the smallest corrections: \
        word spacing, misspellings, capitalization and punctuation. An unfamiliar word may be \
        fixed only when a small spelling or spacing change turns it into a known word that fits \
        the context ("howar you" becomes "How are you"). If no known word fits, it is a name: \
        keep its letters exactly as written (capitalizing it is fine) and never split or respell \
        it. Never rephrase, reword, add, remove or reorder words, and never change the meaning. \
        If the text is already correct, return it unchanged. The context is the text before it, \
        only to show where sentences start; do not repeat it. Reply with the corrected text \
        only, no commentary.
        """

    /// Proofreading is a content transformation; the default guardrails flag even
    /// "howar you" as unsafe. `ScribePolish.merge` still reverts any rewrite.
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    public init() {}

    public var isAvailable: Bool {
        Self.model.availability == .available
    }

    public func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(model: Self.model, instructions: Self.instructions).prewarm()
    }

    /// Any failure (guardrails, context window, model errors) yields nil so the caller falls back.
    public func polish(_ raw: String, context: String) async -> String? {
        // A fresh session per request: no history to grow or leak between phrases.
        let session = LanguageModelSession(model: Self.model, instructions: Self.instructions)
        let prompt = """
            Context (already written, do not repeat):
            \(context.isEmpty ? "(none, this starts the text)" : context)

            New text to correct:
            \(raw)
            """
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy))
            return response.content
        } catch {
            return nil
        }
    }
}
#endif
