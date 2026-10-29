import unittest
import json
from pathlib import Path
import tempfile
from argparse import Namespace
from unittest.mock import patch
import warnings

import numpy as np

import calibrate_v2
from calibrate_v2 import (_cache_validation_logits, _calibration_setting, _decoder_cache,
                          _sequence_evaluator, _row_entries, _softmax, final_test,
                          fit_temperature, simulate, _fit_thresholds, _formulas, VOCAB, LM)
from decoder import MathLineDecoder, Symbol
from lm import LanguageModel


class CalibrationTests(unittest.TestCase):
    def test_threshold_fit_keeps_ties_and_rejects_unsupported_labels(self):
        candidates = [
            {'label': '2', 'truth': '2', 'score': .99},
            {'label': '2', 'truth': '2', 'score': .98},
            {'label': '2', 'truth': '2', 'score': .9},
            {'label': '2', 'truth': '<unk>', 'score': .9},
            {'label': 'x', 'truth': 'x', 'score': 1.0},
        ]
        thresholds, support = _fit_thresholds(candidates, 1.0, 2, True, ['2', 'x', 'z'])
        self.assertEqual(thresholds['2'], .98)
        self.assertEqual(support['2']['acceptedSupport'], 2)
        self.assertGreater(thresholds['x'], 1)
        self.assertGreater(thresholds['z'], 1)

    def test_per_label_rejection_blocks_substitutions_and_revisions(self):
        args = self.simulation_parameters(['2', '2'], [{'2': 1}, {'2': 1}])
        args['tau_sub'] = {'2': np.nextafter(1.0, 2.0)}
        args['commit_floor'] = None  # Historical selective-threshold mode.
        result = simulate(**args)
        self.assertEqual(result['coverage'], 0)
        self.assertEqual(result['revisions'], 0)

    def test_fill_threshold_gates_only_ink_revisions(self):
        args = self.simulation_parameters(['2', '2'], [{'2': 1}, {'2': 1}])
        args['tau_sub'] = np.nextafter(1.0, 2.0)
        args['commit_floor'] = None  # Isolate the fill path from the app fallback.
        filled = simulate(**args)
        self.assertEqual(filled['finalByPath']['fill']['count'], 1)
        self.assertEqual(simulate(**args, tau_fill=np.nextafter(1.0, 2.0))['coverage'], 0)
        args['tau_sub'] = .9
        self.assertNotIn('fill', simulate(**args, tau_fill=np.nextafter(1.0, 2.0))['finalByPath'])

    def test_app_commit_floor_is_inclusive_and_ignores_disabled_labels(self):
        for probability, covered in [(.499, 0), (.5, 1), (.6, 1)]:
            args = self.simulation_parameters(['q'], [{'q': probability, '9': .3,
                                                      't': 1 - probability - .3}],
                                              Path(__file__).with_name('math-vocab-f5.json'))
            args['disabled'] = {'q'}
            result = simulate(**args)
            self.assertEqual(result['coverage'], covered)
            self.assertEqual(result['perLabelAccuracy']['q']['accuracy'], covered)
            if covered:
                self.assertEqual(result['finalByPath']['commit']['count'], 1)
            self.assertEqual(simulate(**args, commit_floor=.7)['coverage'], 0)

    def test_committed_l_is_not_filled_again(self):
        args = self.simulation_parameters(['l', '1'], [{'l': .96, '1': .04}, {'1': 1}],
                                          Path(__file__).with_name('math-vocab-f5.json'))
        args['tau_sub'] = 1
        result = simulate(**args)
        self.assertEqual(result['coverage'], 1)
        self.assertEqual(result['perLabelAccuracy']['l']['accuracy'], 1)
        self.assertEqual(result['revisions'], 0)
        self.assertNotIn('fill', result['finalByPath'])
        decoder = _decoder_cache(args['lm'], args['lambda_'])
        cached = _sequence_evaluator(args['lines'], args['lm'], args['temperature'], args['lambda_'],
                                     args['vocab'], args['class_ids'], decoder)
        for tau in [0, .5, .95, 1]:
            for fill in [.9, .99]:
                direct = simulate(**{**args, 'tau_sub': tau}, tau_fill=fill)
                direct.pop('tauSubInterval')
                self.assertEqual(cached(tau, .9, set(), fill), direct)

    def test_readonly_cache_batches_are_copied_before_torch_conversion(self):
        import torch

        class Model:
            def eval(self):
                pass

            def __call__(self, *inputs):
                for tensor in inputs:
                    self_test.assertTrue(tensor.numpy().flags.writeable)
                return torch.zeros((len(inputs[0]), 59)), None

        self_test = self
        with tempfile.TemporaryDirectory() as directory:
            paths = {key: Path(directory) / f'{key}.npy'
                     for key in ('images', 'paths', 'globals', 'targets')}
            for key, shape in {'images': (2, 32, 32), 'paths': (2, 128, 4),
                               'globals': (2, 2), 'targets': (2,)}.items():
                np.save(paths[key], np.zeros(shape, dtype=np.float32))
            with patch('calibrate_v2.train_v2._cache_paths', return_value=paths), warnings.catch_warnings():
                warnings.simplefilter('error')
                logits, targets = _cache_validation_logits(Model(), Path(directory))
            self.assertEqual(logits.shape, (2, 59))
            self.assertEqual(targets.tolist(), [0, 0])

    def test_disable_unreliable_label_before_overall_precision_gate(self):
        calls = []

        def evaluate(tau_rev, disabled):
            calls.append((tau_rev, set(disabled)))
            return {'substitutionPrecision': .995 if 'x' in disabled else .97,
                    'harmfulSwapsPer100': .1,
                    'perLabelSubstitutions': {} if 'x' in disabled else {
                        'x': {'count': 30, 'precision': .94},
                        'y': {'count': 29, 'precision': .80},
                        'z': {'count': 50, 'precision': .95}}}

        result, tau_rev, disabled = _calibration_setting(evaluate)
        self.assertEqual(calls, [(.9, set()), (.9, {'x'})])
        self.assertEqual(disabled, ['x'])
        self.assertEqual(tau_rev, .9)
        self.assertGreaterEqual(result['substitutionPrecision'], .99)

    def test_raise_revision_threshold_only_for_harmful_swaps(self):
        calls = []

        def evaluate(tau_rev, disabled):
            calls.append(tau_rev)
            return {'substitutionPrecision': .999, 'perLabelSubstitutions': {},
                    'harmfulSwapsPer100': .6 if tau_rev < .94 else .5}

        result, tau_rev, disabled = _calibration_setting(evaluate)
        self.assertEqual(calls, [.9, .92, .94])
        self.assertEqual(tau_rev, .94)
        self.assertEqual(disabled, [])
        self.assertEqual(result['harmfulSwapsPer100'], .5)

    def simulation_parameters(self, labels, probabilities, vocab_path=VOCAB):
        vocab = json.loads(vocab_path.read_text())
        classes = [row['id'] for row in vocab['classes']]
        label_class = {label: row['id'] for row in vocab['classes'] for label in row['labels']}
        symbols = []
        for index, (label, scores) in enumerate(zip(labels, probabilities)):
            vector = np.zeros(len(classes))
            for guess, value in scores.items():
                vector[classes.index(label_class[guess])] = value
            symbols.append({'label': label, 'bounds': (index * 8, 0, 5, 10),
                            'strokes': [[[index * 8, 0], [index * 8 + 5, 10]]],
                            'classProbabilities': vector})
        lm = json.loads(LM.read_text())
        return dict(lines=[{'symbols': symbols}], lm=LanguageModel(lm['vocab'], lm['ngrams']),
                    temperature=1, lambda_=0, tau_sub=.9, tau_rev=.9,
                    disabled=set(), vocab=vocab, class_ids=classes)

    def simulate_labels(self, labels, probabilities):
        return simulate(**self.simulation_parameters(labels, probabilities))

    def test_sequence_interval_cache_matches_replay_at_slash_boundary(self):
        args = self.simulation_parameters(['2', '/', '3'],
                                         [{'2': 1}, {'/': .4, '+': .35, '4': .25}, {'3': 1}])
        args['lines'] *= 2  # Verify integer aggregation across expressions too.
        args['commit_floor'] = None
        decoder = _decoder_cache(args['lm'], args['lambda_'])
        cached = _sequence_evaluator(args['lines'], args['lm'], args['temperature'], args['lambda_'],
                                     args['vocab'], args['class_ids'], decoder, commit_floor=None)
        boundary = simulate(**{**args, 'tau_sub': 0})['tauSubInterval']['upperInclusive']
        for rev, disabled in [(.9, set()), (.94, {'/'}), (.94, {'x'})]:
            for fill in [.9, .999]:
                for tau in [0, .1, boundary, np.nextafter(boundary, 1), .45, .95]:
                    direct = simulate(**{**args, 'tau_sub': tau, 'tau_rev': rev,
                                         'disabled': disabled, 'tau_fill': fill})
                    direct.pop('tauSubInterval')
                    self.assertEqual(cached(tau, rev, disabled, fill), direct)
        self.assertGreater(cached.cache_stats['hits'], 0)
        self.assertEqual(cached(boundary, .9, set())['coverage'], 1)
        self.assertLess(cached(np.nextafter(boundary, 1), .9, set())['coverage'], 1)

    def test_fill_cache_separates_thresholds_that_change_ink_revision(self):
        args = self.simulation_parameters(['2', '2'], [{'2': .96, '3': .04}, {'2': 1}])
        args['commit_floor'] = None
        decoder = _decoder_cache(args['lm'], args['lambda_'])
        cached = _sequence_evaluator(args['lines'], args['lm'], args['temperature'], args['lambda_'],
                                     args['vocab'], args['class_ids'], decoder, commit_floor=None)
        low = cached(1, .9, set(), .9)
        high = cached(1, .9, set(), .99)
        self.assertEqual(low['finalByPath']['fill']['count'], 1)
        self.assertEqual(high['coverage'], .5)
        self.assertEqual(cached(1, .9, set(), .9), low)
        self.assertEqual(cached.cache_stats, {'hits': 1, 'misses': 2})

    def test_formula_truth_folds_and_removes_function_groups_before_scoring(self):
        import io
        import zipfile
        groups = []
        traces = []
        for index, raw in enumerate(['X', 'Y', r'\sin', 'log', '2']):
            traces.append(f'<trace id="{index}">{index} 0, {index} 1</trace>')
            groups.append(f'<traceGroup><annotation type="truth">{raw}</annotation>'
                          f'<traceView traceDataRef="{index}"/></traceGroup>')
        xml = ('<ink><annotation type="truth">x+2</annotation>' + ''.join(traces) +
               '<traceGroup>' + ''.join(groups) + '</traceGroup></ink>')
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'synthetic.zip'
            inner = io.BytesIO()
            with zipfile.ZipFile(inner, 'w') as stream:
                stream.writestr('fixture.inkml', xml)
            with zipfile.ZipFile(archive, 'w') as stream:
                stream.writestr('fixture/Task1_onlineRec/MainTask_formula/Train.zip', inner.getvalue())
            with patch('calibrate_v2.datasets._writer_split', return_value='valid'):
                lines = _formulas(archive, 'valid')
            self.assertEqual([item['label'] for item in lines[0]['symbols']], ['x', '<unk>', '2'])
            self.assertEqual(lines[0]['excludedFunctionWordSymbols'], 2)

    def test_junk_probability_competes_and_stays_ink_in_simulation(self):
        args = self.simulation_parameters(['<unk>', '2'],
                                         [{'<unk>': .99, 'x': .01}, {'2': 1}],
                                         Path(__file__).with_name('math-vocab-f4.json'))
        args['lines'][0]['excludedFunctionWordSymbols'] = 2
        result = simulate(**args)
        self.assertEqual(result['unknownCovered'], 0)
        self.assertEqual(result['knownCovered'], 1)
        self.assertEqual(result['revisions'], 0)
        self.assertEqual(result['substitutionPrecision'], 1)
        self.assertEqual(result['excludedFunctionWordSymbols'], 2)

    def test_unknown_is_counted_once(self):
        result = self.simulate_labels(['<unk>'], [{'2': 1}])
        self.assertEqual(result['symbols'], 1)
        self.assertEqual(result['unknownSymbols'], 1)

    def test_unknown_wrong_coverage_and_multi_line_totals(self):
        args = self.simulation_parameters(['<unk>', '2'], [{'2': 1}, {'2': 1}])
        symbols = args['lines'][0]['symbols']
        args['lines'] = [{'symbols': [symbols[0]]}, {'symbols': [symbols[1]]}]
        result = simulate(**args)
        self.assertEqual((result['symbols'], result['unknownSymbols'], result['knownSymbols']), (2, 1, 1))
        self.assertEqual((result['unknownCovered'], result['knownCovered']), (1, 1))
        self.assertEqual(result['unknownTruthWrongUpdates'], 1)
        self.assertEqual(result['unknownWrongFinal'], 1)
        self.assertEqual(result['coverageAllSymbols'], 1)
        self.assertEqual(result['coverageRecognizableSymbols'], 1)

    def test_ink_slash_becomes_a_visible_fraction_bar(self):
        result = self.simulate_labels(['2', '/', '3'], [{'2': 1}, {'/': .6, '+': .4}, {'3': 1}])
        self.assertEqual(result['symbols'], 3)
        self.assertEqual(result['coverage'], 1)
        self.assertEqual(result['substitutionPrecision'], 1)

    def test_temperature_reduces_validation_nll(self):
        logits = np.array([[1.0, 0.0], [0.0, 1.0], [0.8, 0.2], [0.2, 0.8]])
        temperature = fit_temperature(logits, np.array([0, 1, 0, 1]))
        self.assertGreater(temperature, 0)
        self.assertLess(temperature, 1)

    def test_softmax_uses_positive_temperature(self):
        probabilities = _softmax(np.array([0.0, 1.0]), 2.0)
        self.assertAlmostEqual(float(probabilities.sum()), 1.0)
        self.assertLess(probabilities[1], 1 / (1 + np.exp(-1)))

    def test_decoder_cache_reuses_threshold_independent_result(self):
        class LM:
            @staticmethod
            def log_prob(word, context):
                return -.1 if word == "x" else -.2

        symbols = [Symbol({"x": .6, "y": .4}), Symbol({"x": .7, "y": .3}, "y")]
        direct = MathLineDecoder(LM.log_prob, .6, 0.0, 0.0).decode(
            symbols, newest_index=1, revision_indices=[0])
        cached = _decoder_cache(LM(), .6)
        actual = cached(symbols, 1, [0])
        self.assertEqual(actual[0], direct.substitution)
        self.assertEqual(actual[1], direct.revisions)
        self.assertEqual(dict(actual[2]), {0: direct.marginals[0], 1: direct.marginals[1]})
        cached(symbols, 1, [0])
        self.assertEqual(cached.cache_info().hits, 1)

    def test_fraction_seed_does_not_count_moved_ink_twice(self):
        row = {"lineSeed": [(8.0, 24.0)], "items": [0], "seededItems": {0}}
        symbol = {"bounds": (0.0, 10.0, 5.0, 10.0)}
        entries = _row_entries(row, [symbol], ["1"], ["body"], {"1": "digit"}, False)
        self.assertEqual(entries, [(8.0, 24.0)])

    def test_calibrate_writes_f5_report_even_below_99_percent(self):
        vocab_path = Path(__file__).with_name('math-vocab-f5.json')
        simulation = self.simulation_parameters(['q', 'l'], [{'9': 1}, {'1': 1}], vocab_path)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            args = Namespace(lambda_=.4, language_model=LM, archive=output / 'unused.zip',
                             vocab=vocab_path, output=output, checkpoint=None, build_dir=output,
                             calibration=output / 'calibration.json')
            with patch.object(calibrate_v2, '_formulas', return_value=simulation['lines']) as formulas, \
                 patch.object(calibrate_v2.train_v2, '_checkpoint',
                              return_value=(None, {'epoch': 1, 'sourceHashes': {}}, simulation['class_ids'])), \
                 patch.object(calibrate_v2.train_v2, '_verify_checkpoint_sources'), \
                 patch.object(calibrate_v2.train_v2, 'digest', return_value='fixture-hash'), \
                 patch.object(calibrate_v2, '_predict'), \
                 patch.object(calibrate_v2, '_cache_validation_logits',
                              return_value=(np.zeros((2, 62)), np.array([0, 1]))), \
                 patch.object(calibrate_v2, 'fit_temperature', return_value=1), \
                 patch.object(calibrate_v2, '_cache_class_probs'), \
                 patch.object(calibrate_v2, 'TAUS', (0, 1)), \
                 patch.object(calibrate_v2, 'FILL_GRID', (.9, .99)), patch('builtins.print'):
                calibrate_v2.calibrate(args)
            formulas.assert_called_once_with(args.archive, 'valid', vocab_path)
            report = json.loads(args.calibration.read_text())
            self.assertEqual(report['validation']['substitutionPrecision'], 0)
            self.assertEqual(report['simulation']['commitFloor'], .5)
            self.assertEqual(set(report['focusLabelAccuracy']), {'q', 'l', '9', '1', 't', '{', '}'})
            self.assertEqual(report['focusLabelAccuracy']['q']['accuracy'], 0)
            self.assertEqual(report['focusLabelAccuracy']['t']['accuracy'], None)
            summary = json.loads((output / 'calibration-search-summary.json').read_text())
            self.assertEqual(summary['status'], 'completed')
            self.assertEqual(summary['candidateCount'], 2)

    def test_final_test_refuses_an_existing_report_before_reading_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "test-report.json"
            report.write_text("already consumed")
            with self.assertRaises(FileExistsError):
                final_test(Namespace(report=report))


if __name__ == "__main__":
    unittest.main()
