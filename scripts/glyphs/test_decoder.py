import unittest

from decoder import MathLineDecoder, Symbol, _self_check


class DecoderTests(unittest.TestCase):
    def test_tau_fill_matches_swift_fixture(self):
        _self_check()

    def test_junk_dominance_never_substitutes_or_fills(self):
        decoder = MathLineDecoder(lambda *_: 0, lambda_=0)
        junk = Symbol({"<unk>": .99, "x": .01})
        self.assertIsNone(decoder.decode([junk]).substitution)
        result = decoder.decode([junk, Symbol({"+": 1})])
        self.assertEqual(result.revisions, ())
        self.assertGreater(result.marginals[0]["<unk>"], .98)

    def test_q_scores_as_p_in_word_and_frozen_context_without_renaming(self):
        calls = []
        def log_prob(word, context):
            calls.append((word, context))
            self.assertNotEqual(word, "q")
            self.assertNotIn("q", context)
            return -.1
        symbols = [Symbol({"q": 1}, displayed_label="q") for _ in range(13)]
        result = MathLineDecoder(log_prob).decode(symbols)
        self.assertEqual(result.substitution.label, "q")
        self.assertTrue(all(row == {"q": 1.0} for row in result.marginals))
        self.assertIn(("p", ("p", "p", "p")), calls)

    def test_braces_score_as_brackets_in_word_and_frozen_context(self):
        calls = []
        def log_prob(word, context):
            calls.append((word, context))
            self.assertNotIn(word, ("{", "}"))
            self.assertFalse(set(context) & {"{", "}"})
            return -.1
        symbols = [Symbol({"{": 1}, displayed_label="{") for _ in range(13)]
        result = MathLineDecoder(log_prob).decode(symbols)
        self.assertEqual(result.substitution.label, "{")
        self.assertTrue(all(row == {"{": 1.0} for row in result.marginals))
        self.assertIn(("[", ("[", "[", "[")), calls)
        calls.clear()
        MathLineDecoder(log_prob).decode([Symbol({"}": 1}, displayed_label="}")
                                         for _ in range(13)])
        self.assertIn(("]", ("]", "]", "]")), calls)

    def test_tau_fill_defaults_to_tau_rev(self):
        symbols = [Symbol({"x": .95, "z": .05}), Symbol({"+": 1})]
        default = MathLineDecoder(lambda *_: 0, lambda_=0, tau_rev=.9)
        self.assertEqual([item.label for item in default.decode(symbols).revisions], ["x"])
        strict = MathLineDecoder(lambda *_: 0, lambda_=0, tau_rev=.9, tau_fill=.97)
        self.assertEqual(strict.decode(symbols).revisions, ())
        symbols[0] = Symbol({"x": .95, "z": .05}, displayed_label="z")
        self.assertEqual([item.label for item in strict.decode(symbols).revisions], ["x"])


if __name__ == "__main__":
    unittest.main()
