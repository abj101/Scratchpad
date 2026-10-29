"""Small synthetic-source checks; no public or capture data is read."""
import argparse
from collections import Counter
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

import datasets
import resolver


class ExtrasTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.classes, self.labels = datasets._load_vocab(
            Path(__file__).with_name("math-vocab-f4.json"))
        self.args = argparse.Namespace(build_dir=self.root, mw_archive=self.root / "mw.tgz",
            crohme_archive=self.root / "crohme.zip", hwrt=self.root / "hwrt.tar",
            prepare=self.root / "prepare.json", synthetic=self.root / "synthetic.jsonl",
            v1_vocab=datasets.V1_VOCAB)
        self.args.prepare.write_text(json.dumps({"writers": {"train": ["train"], "valid": ["valid"]}}))
        self.make_archives()

    @staticmethod
    def ink(ui, writer, labels):
        groups = "".join(f'<traceGroup id="{i}"><annotation type="truth">{label}</annotation>'
                         f'<traceView traceDataRef="{i}"/></traceGroup>' for i, label in enumerate(labels))
        traces = "".join(f'<trace id="{i}">0 0, 1 1</trace>' for i in range(len(labels)))
        return (f'<ink><annotation type="UI">{ui}</annotation><annotation type="writer">{writer}</annotation>'
                f'{traces}{groups}</ink>').encode()

    @staticmethod
    def zip_bytes(entries):
        stream = io.BytesIO()
        with ZipFile(stream, "w") as archive:
            for name, value in entries.items():
                archive.writestr(name, value)
        return stream.getvalue()

    def make_archives(self):
        raws = ["x", "X", "E", r"\sin", "sin", "xy", "Y", r"\alpha"]
        symbols = b"".join((json.dumps({"label": label, "sourceSampleId": "sample", "strokeIndices": [0]})
                              + "\n").encode() for label in raws)
        with tarfile.open(self.args.mw_archive, "w:gz") as archive:
            for name, value in {"symbols.jsonl": symbols, "train/sample.inkml": self.ink("sample", "train", ["x"])}.items():
                info = tarfile.TarInfo(name)
                info.size = len(value)
                archive.addfile(info, io.BytesIO(value))
        train_writer = next(str(i) for i in range(100) if datasets._writer_split(str(i)) == "train")
        valid_writer = next(str(i) for i in range(100) if datasets._writer_split(str(i)) == "valid")
        self.writers = (train_writer, valid_writer)
        folders = ["Train/isolatedTest2012/both_GT.txt", "Train/isolatedTest2013b/iso_GT.txt",
            "Train/isolatedTrain2014/trainingSymbols/iso_GT.txt", "Train/isolatedTrain2014/trainingJunk/junk_GT.txt"]
        isolated = {name: b"" for name in folders}
        isolated[folders[0]] = b"exprtrain_0,E\nexprvalid_0,E\ntestonly_0,E\n"
        for name, ui in (("a", "exprtrain"), ("b", "exprtrain"), ("c", "exprvalid"), ("d", "testonly")):
            isolated[f"Train/isolatedTest2012/{name}.inkml"] = self.ink(ui, train_writer, ["E"])
        formula = {"train.inkml": self.ink("exprtrain", train_writer, ["E", "X", "x", r"\sin"]),
                   "valid.inkml": self.ink("exprvalid", valid_writer, ["E", "X", "x", "log"])}
        outer = {"fixture/Task1_onlineRec/MainTask_formula/Train.zip": self.zip_bytes(formula),
                 "fixture/Task1_onlineRec/MainTask_formula/valid.zip": self.zip_bytes({"test.inkml": self.ink("testonly", "testwriter", ["E"])}),
                 "fixture/Task1_onlineRec/subTask_symbols/Train.zip": self.zip_bytes(isolated)}
        self.args.crohme_archive.write_bytes(self.zip_bytes(outer))

    def hwrt_records(self, *args):
        for index, raw in enumerate(("x", "X", "E", r"\sin", "__unmapped_hwrt_symbol__", "Y")):
            yield {"source": "HWRT raw ODbL", "label": raw, "writer": "valid" if index % 2 else "train",
                   "strokes": [[[0, 0], [1, 1]]]}

    def run_loaders(self, directory, extras=False):
        import train
        directory.mkdir()
        results = {}
        results["mw-symbols"] = datasets._mw_symbols(self.args, directory, self.classes, self.labels, extras)
        results["crohme"] = datasets._crohme(self.args, directory, self.classes, self.labels, extras)
        with patch.object(train, "records", self.hwrt_records):
            results["hwrt"] = datasets._hwrt(self.args, directory, self.classes, self.labels, extras)
        return results

    def rows(self, path):
        with gzip.open(path, "rt") as stream:
            return [json.loads(line) for line in stream]

    def test_exact_case_fold_junk_and_function_word_rules(self):
        self.assertEqual(datasets.CASE_FOLD, dict(zip("CKOPSUVWXZ", "ckopsuvwxz")))
        for raw, label in datasets.CASE_FOLD.items():
            self.assertEqual(datasets.extended_label(raw, self.labels), label)
        for raw in ("Y", "M", "N", "q", r"\alpha", r"\{", r"\}", r"\exists"):
            self.assertEqual(datasets.extended_label(raw, self.labels), "<unk>")
        for raw in ("xy", "__unmapped_hwrt_symbol__", "<unk>"):
            self.assertIsNone(datasets.extended_label(raw, self.labels))
        for raw in (*datasets.MULTI_COMMANDS, *datasets.MULTI_COMMANDS.values(), r"$\mathrm{sin}$"):
            self.assertTrue(datasets.is_function_word(raw))
            self.assertIsNone(datasets.extended_label(raw, self.labels))
        self.assertFalse(datasets.is_function_word("sin x"))
        self.assertEqual(datasets.extended_label(r"\left X", self.labels), "x")
        self.assertEqual(resolver.member_weights("junk", (0, 0, 1, 1), {}), {"<unk>": 1.0})

    def test_base_gzip_bytes_match_pre_f4_golden_outputs(self):
        directory = self.root / "base"
        self.run_loaders(directory)
        # SHA-256 values generated with the pre-F4 loaders on these synthetic fixtures.
        expected = GOLDEN
        self.assertEqual({path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in directory.glob("*.jsonl.gz")}, expected)

    def test_extras_reuse_splits_dedup_and_do_not_read_test_zip(self):
        directory = self.root / "extras"
        original = datasets._zip_member
        def training_only(outer, suffix):
            self.assertNotIn("valid.zip", suffix)
            return original(outer, suffix)
        with patch.object(datasets, "_zip_member", training_only):
            results = self.run_loaders(directory, extras=True)
        self.assertEqual(len(list(directory.glob("*.jsonl.gz"))), 5)
        self.assertFalse((directory / ".pipeline-metadata.json").exists())
        self.assertEqual(results["mw-symbols"]["records"], {"train": 4})
        self.assertEqual(results["crohme"]["records"], {"train": 3, "valid": 2})
        self.assertEqual(results["crohme"]["dropped"]["duplicate_symbol"], 1)
        self.assertEqual(results["crohme"]["dropped"]["heldout_source_expression"], 2)
        self.assertEqual(results["hwrt"]["records"], {"train": 1, "valid": 2})
        for path in directory.glob("*.jsonl.gz"):
            for row in self.rows(path):
                self.assertIn("rawLabel", row)
                self.assertEqual(row["class"], self.classes[row["label"]])
                self.assertIsNone(datasets._single_label(row["rawLabel"], self.labels))
        before = {path.name: path.read_bytes() for path in directory.glob("*.jsonl.gz")}
        with self.assertRaises(FileExistsError):
            datasets._mw_symbols(self.args, directory, self.classes, self.labels, extras=True)
        self.assertEqual(before, {path.name: path.read_bytes() for path in directory.glob("*.jsonl.gz")})


    def test_extras_command_preserves_existing_files_and_reports_junk_splits(self):
        import train
        directory = self.root / "datasets"
        directory.mkdir()
        old_files = {"mw-symbols-train.jsonl.gz": b"unchanged base bytes",
                     "stats.json": b"unchanged stats bytes",
                     ".pipeline-metadata.json": b"unchanged metadata bytes",
                     "harvest-train.jsonl.gz": b"unchanged harvest bytes"}
        for name, value in old_files.items():
            (directory / name).write_bytes(value)
        with patch.object(train, "records", self.hwrt_records), patch("builtins.print"):
            datasets._extras(self.args, directory, self.classes, self.labels)
        for name, value in old_files.items():
            self.assertEqual((directory / name).read_bytes(), value)
        stats = json.loads((self.root / "orchestration-v2-wave3/extras-stats.json").read_text())
        self.assertEqual(stats["sources"]["mw-symbols"]["recordsByKind"],
                         {"junk": {"train": 3}, "caseFold": {"train": 1}, "q": {}})
        self.assertEqual(stats["sources"]["crohme"]["recordsByKind"],
                         {"junk": {"train": 2, "valid": 1}, "caseFold": {"train": 1, "valid": 1}, "q": {}})
        with self.assertRaises(FileExistsError):
            datasets._extras(self.args, directory, self.classes, self.labels)
        self.args.replace_extras = True
        with patch.object(train, "records", self.hwrt_records), patch("builtins.print"):
            datasets._extras(self.args, directory, self.classes, self.labels)
        for name, value in old_files.items():
            self.assertEqual((directory / name).read_bytes(), value)

    def test_f5_loaders_emit_q_extras_with_unchanged_splits(self):
        import train
        self.classes, self.labels = datasets._load_vocab(Path(__file__).with_name("math-vocab-f5.json"))
        raws = ["x", "q", "E", "l"]
        symbols = b"".join((json.dumps({"label": label, "sourceSampleId": "sample", "strokeIndices": [0]})
                             + "\n").encode() for label in raws)
        with tarfile.open(self.args.mw_archive, "w:gz") as archive:
            for name, value in {"symbols.jsonl": symbols,
                                "train/sample.inkml": self.ink("sample", "train", ["q"])}.items():
                info = tarfile.TarInfo(name)
                info.size = len(value)
                archive.addfile(info, io.BytesIO(value))
        formula = {"train.inkml": self.ink("exprtrain", self.writers[0], ["q", "l"]),
                   "valid.inkml": self.ink("exprvalid", self.writers[1], ["q", "l"])}
        self.args.crohme_archive.write_bytes(self.zip_bytes({
            "fixture/Task1_onlineRec/MainTask_formula/Train.zip": self.zip_bytes(formula),
            "fixture/Task1_onlineRec/subTask_symbols/Train.zip": self.zip_bytes({
                name: b"" for name in ["Train/isolatedTest2012/both_GT.txt",
                    "Train/isolatedTest2013b/iso_GT.txt",
                    "Train/isolatedTrain2014/trainingSymbols/iso_GT.txt",
                    "Train/isolatedTrain2014/trainingJunk/junk_GT.txt"]}),
        }))
        hwrt = [{"source": "HWRT raw ODbL", "label": label, "writer": writer,
                 "strokes": [[[0, 0], [1, 1]]]} for label, writer in
                [("q", "train"), ("q", "valid"), ("l", "train")]]
        directory = self.root / "f5"
        directory.mkdir()
        with patch.object(train, "records", return_value=iter(hwrt)), patch("builtins.print"):
            datasets._extras(self.args, directory, self.classes, self.labels)
        outputs = list(directory.glob("*.jsonl.gz"))
        self.assertEqual(len(outputs), 5)
        for path in outputs:
            q_rows = [row for row in self.rows(path) if row["rawLabel"] == "q"]
            self.assertEqual(len(q_rows), 1, path.name)
            self.assertEqual((q_rows[0]["label"], q_rows[0]["class"]), ("q", "glyph_u0071"))
            self.assertFalse(any(row["label"] == "l" for row in self.rows(path)))
        stats = json.loads((self.root / "orchestration-v2-wave3/extras-stats.json").read_text())
        self.assertEqual(stats["sources"]["crohme"]["recordsByKind"]["q"], {"train": 1, "valid": 1})

    def test_f5_q_is_known_and_retained_in_extras(self):
        classes, labels = datasets._load_vocab(Path(__file__).with_name("math-vocab-f5.json"))
        self.assertEqual(datasets.TOKEN_MAP["q"], "q")
        self.assertEqual(datasets._source_label("q", labels, True, Counter()), "q")
        self.assertEqual(classes["q"], "glyph_u0071")
        self.assertEqual(classes["l"], "glyph_u006C")
        self.assertIsNone(datasets._source_label("l", labels, True, Counter()))
        self.assertEqual(datasets.extended_label("q", self.labels), "<unk>")
        counts = {kind: Counter() for kind in ("junk", "caseFold", "q", "qBySplit")}
        row = datasets._source_record("fixture", "valid", None, "q", [[[0, 0], [1, 1]]],
                                      "fixture", classes, "q", True, counts)
        self.assertEqual((row["label"], row["class"], row["rawLabel"]), ("q", "glyph_u0071", "q"))
        self.assertEqual(counts["qBySplit"], {"valid": 1})

    def test_f7_braces_are_known_and_retained_in_extras(self):
        classes, labels = datasets._load_vocab(Path(__file__).with_name("math-vocab-f7.json"))
        self.assertEqual(classes["{"], "glyph_u007B")
        self.assertEqual(classes["}"], "glyph_u007D")
        self.assertEqual(datasets.TOKEN_MAP["{"], "{")
        self.assertEqual(datasets._source_label("{", labels, True, Counter()), "{")
        self.assertEqual(datasets._source_label("\\}", labels, True, Counter()), "}")
        self.assertIsNone(datasets._source_label("[", labels, True, Counter()))
        self.assertEqual(datasets.extended_label("\\{", self.labels), "<unk>")
        counts = {kind: Counter() for kind in ("junk", "caseFold", "q", "qBySplit")}
        row = datasets._source_record("fixture", "train", None, "{", [[[0, 0], [1, 1]]],
                                      "fixture", classes, "{", True, counts)
        self.assertEqual((row["label"], row["class"], row["rawLabel"]),
                         ("{", "glyph_u007B", "{"))
        self.assertEqual(counts["qBySplit"], {"train": 1})


GOLDEN = {'hwrt-valid.jsonl.gz': 'ac73670af3abed54ac6fb4695131f4099be9fbe39d6076c5d0264a6bbdae9d83', 'mw-symbols-train.jsonl.gz': 'acf2553ac3208d1da55b1b7224b6c416f9b28470bc9316e2bcb55d6a28811114', 'crohme-valid.jsonl.gz': '81aa2821d42f6beab5a95b0a3dd9509197946f67289a5b6d0bfb290ec5032f5f', 'hwrt-train.jsonl.gz': '3d5413c27d65426deed60d25ef3ca5fddd120b442bb429838d7a7e0de95010ed', 'crohme-train.jsonl.gz': '5bd203f973cb3749a2bb0d70a777b644719db1d61baebe63c1714b72777e2fd0', 'crohme-test.jsonl.gz': 'ac73670af3abed54ac6fb4695131f4099be9fbe39d6076c5d0264a6bbdae9d83'}

if __name__ == "__main__":
    unittest.main()
