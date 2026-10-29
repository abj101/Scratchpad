"""Regression checks for supervised glyph labels, separate from LM semantics."""
import unittest

import datasets
from linearize import linearize


class GlyphLabelTests(unittest.TestCase):
    def test_multiplication_cross_is_variable_shape(self):
        classes, labels = datasets._load_vocab(datasets.MATH_VOCAB)
        for raw in (r"\times", r"$\times$", "×", "x"):
            label = datasets._single_label(raw, labels)
            self.assertEqual(label, "x")
            self.assertEqual(classes[label], classes["x"])
        self.assertEqual(datasets._single_label(r"\cdot", labels), "·")
        self.assertEqual(datasets._single_label(".", labels), ".")

    def test_language_model_keeps_multiplication_semantics(self):
        self.assertEqual(linearize(r"2\times 3")[0], ["2", "·", "3"])


if __name__ == "__main__":
    unittest.main()
