#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Names notes with the on-device system language model.
@available(macOS 26, *)
public final class FoundationModelsNamer: NoteNamer {
    @Generable
    struct Suggestion {
        @Guide(description: "A 2-5 word title describing the note's topic, no punctuation; omit if the note has no clear topic")
        var title: String?
    }

    private static let instructions = """
        You name notes. Read the note and reply with a title of 2 to 5 words naming its main subject.
        Reuse words from the note. Never invent a topic. No punctuation.
        If the note is mainly math, name the mathematical topic its expressions show.
        If the note is gibberish, random letters, or has no clear subject, reply with no title.

        Note: milk, eggs, bread, coffee beans
        Title: Milk Eggs Bread

        Note: x^2 + 5x + 6 = 0, factor it, roots x = -2 and x = -3
        Title: Quadratic Equation Practice

        Note: d/dx sin(x) = cos(x), d/dx cos(x) = -sin(x)
        Title: Derivative of Sine

        Note: hhhhshshhshshs
        Title: (none)
        """

    public init() {}

    public var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Guardrail and context-window failures yield nil (keep the fallback title); other errors are rethrown.
    public func suggestTitle(for text: String) async throws -> String? {
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let prompt = "Note:\n\(text)\n\nTitle:"
            let response = try await session.respond(to: prompt, generating: Suggestion.self,
                                                     options: GenerationOptions(sampling: .greedy))
            return response.content.title.flatMap(NoteTitle.cleanSuggestion)
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            return nil
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            return nil
        }
    }
}
#endif
