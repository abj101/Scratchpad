import gzip
import json
from argparse import Namespace

import numpy as np
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import torch

import train_v2


class F4TrainingTests(unittest.TestCase):
    def test_staging_class_order_requires_junk(self):
        vocab = json.loads(train_v2.VOCAB.read_text())
        vocab['classes'] = [entry for entry in vocab['classes'] if entry['id'] != 'junk']
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'vocab.json'
            vocab['classes'].append({'id': 'junk', 'labels': ['<unk>']})
            vocab['classes'].sort(key=lambda item: item['id'])
            path.write_text(json.dumps(vocab))
            ids = train_v2.class_ids(path)
            self.assertEqual(ids, sorted(ids))
            self.assertEqual(len(ids), len(vocab['classes']))
            self.assertEqual(train_v2.label_maps(path)[2]['<unk>'], 'junk')
            vocab['classes'] = [item for item in vocab['classes'] if item['id'] != 'junk']
            vocab['classes'].append({'id': 'other', 'labels': ['<unk>']})
            vocab['classes'].sort(key=lambda item: item['id'])
            path.write_text(json.dumps(vocab))
            with self.assertRaises(ValueError):
                train_v2.class_ids(path)

    def test_f5_class_order_and_members(self):
        path = Path(__file__).with_name('math-vocab-f5.json')
        ids, _, label_class = train_v2.label_maps(path)
        self.assertEqual(len(ids), 62)
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(label_class['q'], 'glyph_u0071')
        self.assertEqual(label_class['l'], 'glyph_u006C')
        self.assertEqual(label_class['1'], 'bar')
        self.assertEqual(label_class['|'], 'bar')
        with tempfile.TemporaryDirectory() as directory:
            vocab = json.loads(path.read_text())
            vocab['classes'][0]['labels'] = ['1', 'l', '|']
            invalid = Path(directory) / 'invalid.json'
            invalid.write_text(json.dumps(vocab))
            with self.assertRaises(ValueError):
                train_v2.class_ids(invalid)

    def test_f7_class_order_and_brace_members(self):
        path = Path(__file__).with_name('math-vocab-f7.json')
        ids, _, label_class = train_v2.label_maps(path)
        self.assertEqual(len(ids), 64)
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(label_class['{'], 'glyph_u007B')
        self.assertEqual(label_class['}'], 'glyph_u007D')
        self.assertEqual(label_class['['], 'glyph_u005B')
        with tempfile.TemporaryDirectory() as directory:
            vocab = json.loads(path.read_text())
            for entry in vocab['classes']:
                if entry['id'] == 'glyph_u007B':
                    entry['labels'] = ['{', '}']
            invalid = Path(directory) / 'invalid.json'
            invalid.write_text(json.dumps(vocab))
            with self.assertRaises(ValueError):
                train_v2.class_ids(invalid)

    def test_f5_remaps_only_legacy_l_bar_records(self):
        _, _, f5 = train_v2.label_maps(Path(__file__).with_name('math-vocab-f5.json'))
        _, _, f4 = train_v2.label_maps(Path(__file__).with_name('math-vocab-f4.json'))
        legacy = {'label': 'l', 'class': 'bar'}
        self.assertEqual(train_v2.record_class(legacy, f5), 'glyph_u006C')
        self.assertEqual(train_v2.record_class(legacy, f4), 'bar')
        self.assertEqual(legacy, {'label': 'l', 'class': 'bar'})
        for label in ('1', '|'):
            self.assertEqual(train_v2.record_class({'label': label, 'class': 'bar'}, f5), 'bar')
        for row in ({'label': 'l', 'class': 'ring'}, {'label': 'q', 'class': 'junk'},
                    {'label': 'x', 'class': 'bar'}, {'label': 'absent', 'class': 'bar'}):
            with self.subTest(row=row), self.assertRaises(ValueError):
                train_v2.record_class(row, f5)
        self.assertEqual(train_v2.record_class({'label': 'l'}, f5), 'glyph_u006C')
        self.assertIsNone(train_v2.record_class({'label': 'absent'}, f5))

    def test_prepare_remaps_immutable_l_records_in_counts_and_cache_targets(self):
        vocab = Path(__file__).with_name('math-vocab-f5.json')
        ids, index, _ = train_v2.label_maps(vocab)
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            groups = train_v2.source_groups(build, True, True)
            sources = {}
            for split, paths in groups.items():
                for path in paths:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    rows = [{'label': label, 'class': class_id, 'split': split,
                             'strokes': [[[0, 0], [1, 2]]]} for label, class_id in
                            [('l', 'bar'), ('1', 'bar'), ('|', 'bar'), ('q', 'glyph_u0071')]]
                    with gzip.open(path, 'wt') as stream:
                        for row in rows:
                            stream.write(json.dumps(row) + '\n')
                    sources[path] = path.read_bytes()
            synthetic = build / 'glyph-synth/synthetic.jsonl'
            synthetic.parent.mkdir()
            synthetic.write_text('')
            output = build / 'F5'
            # This tiny source fixture tests remapping, not synthetic top-up.
            with patch.object(train_v2, 'SYNTHETIC_FLOOR', 0), patch('builtins.print'):
                train_v2.prepare(Namespace(build_dir=build, output=output, vocab=vocab,
                                           include_harvest=True, include_extras=True,
                                           include_harvest_ql=False, include_harvest_brace=False))
            meta = json.loads((output / 'prepare.json').read_text())
            self.assertEqual(meta['classes'], ids)
            self.assertFalse(meta['includeHarvestBrace'])
            for split, paths in groups.items():
                targets = np.load(train_v2._cache_paths(output, split)['targets'])
                self.assertEqual(targets.tolist(),
                                 [index['glyph_u006C'], index['bar'], index['bar'],
                                  index['glyph_u0071']] * len(paths))
                self.assertEqual(meta['counts'][split]['glyph_u006C'], len(paths))
                self.assertEqual(meta['counts'][split]['bar'], 2 * len(paths))
                self.assertEqual(meta['counts'][split]['glyph_u0071'], len(paths))
            for path, original in sources.items():
                self.assertEqual(path.read_bytes(), original)
                self.assertEqual(meta['sources'][str(path)], train_v2.digest(path))

    def test_extra_sources_extend_splits_and_lineage(self):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            base = train_v2.source_groups(build, True)
            extras = train_v2.source_groups(build, True, True)
            for split in base:
                self.assertEqual(extras[split][:len(base[split])], base[split])
            self.assertEqual(len(extras['train']) - len(base['train']), 3)
            self.assertEqual(len(extras['valid']) - len(base['valid']), 2)
            with patch.object(train_v2, 'digest', return_value='hash'):
                hashes = train_v2._source_hashes(build, train_v2.VOCAB, True, True)
                self.assertTrue(all(str(path) in hashes for files in extras.values() for path in files))
                train_v2._verify_checkpoint_sources({'sourceHashes': hashes}, build, train_v2.VOCAB)
                hashes[str(extras['train'][-1])] = 'changed'
                with self.assertRaises(ValueError):
                    train_v2._verify_checkpoint_sources({'sourceHashes': hashes}, build, train_v2.VOCAB)

    def test_harvest_ql_sources_extend_splits_and_lineage(self):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            base = train_v2.source_groups(build, True, True)
            with_ql = train_v2.source_groups(build, True, True, True)
            for split in base:
                self.assertEqual(with_ql[split][:len(base[split])], base[split])
                self.assertEqual([path.name for path in with_ql[split][len(base[split]):]],
                                 [f'mw-harvest-ql-{split}.jsonl.gz'])
            with patch.object(train_v2, 'digest', return_value='hash'):
                hashes = train_v2._source_hashes(build, train_v2.VOCAB, True, True, True)
                self.assertIn(str(build / 'datasets/mw-harvest-ql-train.jsonl.gz'), hashes)
                train_v2._verify_checkpoint_sources({'sourceHashes': hashes}, build, train_v2.VOCAB)
                # F5 checkpoints without the q/l harvest stay verifiable.
                without_ql = {key: value for key, value in hashes.items()
                              if 'mw-harvest-ql' not in key}
                train_v2._verify_checkpoint_sources({'sourceHashes': without_ql}, build,
                                                    train_v2.VOCAB)
                # Changing a q/l harvest file breaks the checkpoint lineage.
                changed = {**hashes, str(build / 'datasets/mw-harvest-ql-train.jsonl.gz'): 'changed'}
                with self.assertRaises(ValueError):
                    train_v2._verify_checkpoint_sources({'sourceHashes': changed}, build,
                                                        train_v2.VOCAB)

    def test_known_accuracy_counts_junk_guesses_as_wrong(self):
        class Predictor:
            def eval(self):
                pass

            def __call__(self, image, path, globals_):
                return torch.tensor([[0., 1.], [0., 1.], [1., 0.], [1., 0.]]), None

        batch = (torch.zeros(4, 1, 32, 32), torch.zeros(4, 128, 4),
                 torch.zeros(4, 2), torch.tensor([0, 1, 1, 0]))
        with patch.object(train_v2, 'GlyphDataset'), patch.object(train_v2, 'DataLoader', return_value=[batch]):
            result = train_v2.evaluate_model(Predictor(), Path('/unused'), ['known', 'junk'],
                                             torch.device('cpu'), 4, 0)
        self.assertEqual(result['classTop1'], .5)
        self.assertEqual(result['knownClassTop1'], .5)
        self.assertEqual(result['junkRecall'], .5)
        self.assertEqual(result['junkPrecision'], .5)


if __name__ == '__main__':
    unittest.main()
