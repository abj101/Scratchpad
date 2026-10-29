"""Small pure-logic checks for the conditional MathWriting harvest."""
import unittest
from unittest.mock import patch
from pathlib import Path
import xml.etree.ElementTree as ET

import numpy as np
import torch

import harvest


class HarvestTests(unittest.TestCase):
    def test_candidate_rejects_unknown_fraction_and_too_many_strokes(self):
        def ink(label, count=2):
            root = ET.Element("ink")
            ET.SubElement(root, "annotation", {"type": "normalizedLabel"}).text = label
            for index in range(count):
                ET.SubElement(root, "trace", {"id": str(index)}).text = "0 0 0, 1 0 1"
            return root

        self.assertIsNone(harvest._candidate(ink(r"a+Q"), "train/a.inkml"))
        self.assertIsNone(harvest._candidate(ink(r"\frac{a}{b}"), "train/a.inkml"))
        self.assertIsNone(harvest._candidate(ink("a+b", count=10), "train/a.inkml"))
        self.assertEqual(harvest._candidate(ink("a+b"), "train/a.inkml")[:2],
                         ("a", ["a", "+", "b"]))

    def test_only_labels_candidate_filter_keeps_q_and_ell_inks(self):
        def ink(label, count=2):
            root = ET.Element("ink")
            ET.SubElement(root, "annotation", {"type": "normalizedLabel"}).text = label
            for index in range(count):
                ET.SubElement(root, "trace", {"id": str(index)}).text = "0 0 0, 1 0 1"
            return root

        # q and \ell are unknown to linearize(), so the normal filter drops their inks.
        self.assertIsNone(harvest._candidate(ink("q+1"), "train/q.inkml"))
        self.assertIsNone(harvest._candidate(ink(r"\ell+1"), "train/l.inkml"))
        targets = ("q", "l")
        self.assertEqual(harvest._candidate(ink("q+1"), "train/q.inkml", targets)[1], ["q", "+", "1"])
        self.assertEqual(harvest._candidate(ink(r"\ell+1"), "train/l.inkml", targets)[1], ["l", "+", "1"])
        # Inks without a target and inks with a real unknown symbol still fail.
        self.assertIsNone(harvest._candidate(ink("a+1"), "train/a.inkml", targets))
        self.assertIsNone(harvest._candidate(ink("q+Q"), "train/q.inkml", targets))

    def test_target_acceptance_relaxes_only_the_target_symbols(self):
        aligned = [{"label": "q", "probability": .06},
                   {"label": "a", "probability": .95},
                   {"label": "1", "probability": .92}]
        self.assertFalse(harvest._accept(aligned, (.30, .70)))
        self.assertTrue(harvest._accept(aligned, (.30, .70), ("q", "l")))
        # Any non-target symbol keeps the normal per-symbol threshold.
        weak = [dict(aligned[0], probability=.9), dict(aligned[1], probability=.2),
                dict(aligned[2], probability=.99)]
        self.assertFalse(harvest._accept(weak, (.30, .01), ("q",)))
        # ... and the normal geometric mean is enforced over the non-target symbols.
        low_mean = [dict(aligned[0]), aligned[1], dict(aligned[2], probability=.31)]
        self.assertFalse(harvest._accept(low_mean, (.30, .70), ("q",)))  # mean .54 < .70
        # The relaxed target floor is still enforced, and a target must be present.
        self.assertFalse(harvest._accept([dict(aligned[0], probability=.04), aligned[1], aligned[2]],
                                        (.30, .70), ("q",)))
        self.assertFalse(harvest._accept(aligned[1:], (.30, .70), ("q",)))

    def test_multiplication_ink_uses_supervised_x_label(self):
        root = ET.Element("ink")
        ET.SubElement(root, "annotation", {"type": "normalizedLabel"}).text = r"a\times b"
        for index in range(2):
            ET.SubElement(root, "trace", {"id": str(index)}).text = "0 0 0, 1 0 1"
        self.assertEqual(harvest._candidate(root, "train/times.inkml")[1], ["a", "x", "b"])

    def test_delayed_short_stroke_moves_behind_containing_right_stroke(self):
        strokes = [
            [[0, 0, 0], [0, 10, 1]],
            [[10, 0, 2], [14, 0, 3]],
            [[0, 1, 4], [0.5, 1, 5]],
        ]
        self.assertEqual(harvest.delayed_stroke_reorder(strokes), [strokes[0], strokes[2], strokes[1]])

    def test_dp_chooses_highest_scoring_stroke_groups(self):
        distribution = lambda a, b: np.asarray([a, b], dtype=np.float64)
        probabilities = {
            (0, 1): distribution(.6, .4),
            (0, 2): distribution(.9, .1),
            (1, 1): distribution(.5, .5),
            (1, 2): distribution(.1, .9),
            (2, 1): distribution(.1, .9),
        }
        strokes = [[[0, 0, 0]], [[1, 0, 1]], [[2, 0, 2]]]
        with patch.object(harvest, "_group_probabilities", return_value=probabilities):
            result = harvest.align(strokes, ["a", "b"], {"a": "A", "b": "B"},
                                   {"A": 0, "B": 1}, {"A": 2, "B": 2},
                                   None, 1.0)
        self.assertIsNotNone(result)
        self.assertEqual([len(row["strokes"]) for row in result], [2, 1])
        self.assertEqual([row["label"] for row in result], ["a", "b"])

    def test_group_features_drop_ink_timestamps(self):
        class Model:
            def __call__(self, image, path, globals_):
                self.image_shape = tuple(image.shape)
                return torch.zeros((len(image), 2)), None

        model = Model()
        groups = harvest._group_probabilities(model, [[[0, 0, 1], [1, 0, 2]]], 1, 1.0)
        self.assertEqual(model.image_shape, (1, 1, 32, 32))
        self.assertIn((0, 1), groups)

    def test_group_caps_read_prepared_stage1_cache(self):
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            np.save(cache / "train-targets.npy", np.asarray([0, 0, 0, 1, 1], dtype=np.uint8))
            np.save(cache / "train-raw-record-offsets.npy", np.asarray([0, 1, 3, 8, 10, 14]))
            self.assertEqual(harvest.stage1_group_caps(cache, ["A", "B"]), {"A": 5, "B": 4})


if __name__ == "__main__":
    unittest.main()
