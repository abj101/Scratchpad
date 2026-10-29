import unittest

import numpy as np

from logit_normalization import normalize_logits


class LogitNormalizationTests(unittest.TestCase):
    def test_centered_p_norm_and_class_order(self):
        logits = np.array([[4.0, 2.0, 0.0]])
        actual = normalize_logits(logits, p=2)
        expected = np.array([[2.0, 0.0, -2.0]]) / np.sqrt(8.0)
        np.testing.assert_allclose(actual, expected)
        self.assertEqual(int(actual.argmax(axis=-1)[0]), int(logits.argmax(axis=-1)[0]))
        np.testing.assert_array_equal(logits, [[4.0, 2.0, 0.0]])

    def test_shift_invariance_and_zero_vector(self):
        logits = np.array([[3.0, 1.0, -2.0], [5.0, 5.0, 5.0]])
        np.testing.assert_allclose(normalize_logits(logits), normalize_logits(logits + 7.0))
        np.testing.assert_array_equal(normalize_logits(logits)[1], np.zeros(3))

    def test_rejects_invalid_inputs(self):
        for logits, p in (([], 2), ([1, np.nan], 2), ([1, 2], 0)):
            with self.subTest(logits=logits, p=p), self.assertRaises(ValueError):
                normalize_logits(logits, p)


if __name__ == "__main__":
    unittest.main()
