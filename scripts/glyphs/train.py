#!/usr/bin/env python3
"""Writer-held-out stroke training. Capture is read only by final evaluate."""
from __future__ import annotations

import argparse
import base64
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import random
import shutil
import subprocess
import tarfile

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset

from raster import rasterize, _self_check as raster_check

ROOT = Path(__file__).resolve().parents[2]
VOCAB = ROOT / 'Sources/CanvasKit/Resources/vocab.json'
SEED = 20261003


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def bundle_digest(directory):
    h = hashlib.sha256()
    files = sorted(p for p in Path(directory).rglob('*') if p.is_file())
    if not files:
        raise ValueError('compiled model bundle missing or empty')
    for path in files:
        h.update(str(path.relative_to(directory)).encode())
        h.update(bytes.fromhex(digest(path)))
    return h.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def vocabulary(path):
    classes = json.loads(Path(path).read_text())['classes']
    labels = {c['label']: c for c in classes}
    assert len(labels) == len(classes) == 158
    groups = sorted({c['group'] for c in classes})
    ids = {}
    for c in classes:
        for raw_id in c['hwrt_ids']:
            if raw_id in ids:
                if labels[ids[raw_id]]['group'] != c['group']:
                    raise ValueError(f'conflicting HWRT ID {raw_id}')
            else:
                ids[raw_id] = c['label']
    return labels, groups, ids


def writer_split(writer):
    if not writer or str(writer).casefold() == 'ayush':
        raise ValueError('missing or prohibited training writer')
    value = hashlib.sha256(f'{SEED}:hwrt:{writer}'.encode()).digest()
    return 'valid' if int.from_bytes(value[:8], 'big') % 5 == 0 else 'train'


def points(strokes):
    if not isinstance(strokes, list) or not strokes:
        raise ValueError('empty/non-list strokes')
    result = []
    for stroke in strokes:
        # Capture uses a stroke dictionary; HWRT and synthetic use point arrays.
        if isinstance(stroke, dict):
            stroke = stroke['points']
        path = []
        for p in stroke:
            x, y = (p['x'], p['y']) if isinstance(p, dict) else p[:2]
            if not all(isinstance(v, (float, int)) and math.isfinite(v) and abs(v) <= 200000 for v in (x, y)):
                raise ValueError('invalid coordinate')
            path.append([x, y])
        if path:
            result.append(path)
    if not result:
        raise ValueError('empty ink')
    return result


def render(record):
    pixels = np.frombuffer(rasterize(points(record['strokes'])).tobytes(), dtype=np.uint8).copy()
    if not (pixels == 0).any():
        raise ValueError('blank raster')
    return pixels


def records(args, labels, ids):
    csv.field_size_limit(64 * 1024 * 1024)
    seen = set()
    with tarfile.open(args.hwrt, 'r|bz2') as archive:
        for member in archive:
            if Path(member.name).name not in ('train-data.csv', 'test-data.csv'):
                continue
            seen.add(Path(member.name).name)
            # TextIOWrapper probes seekable(), unavailable on Python 3.12 tar streams.
            reader = csv.DictReader((line.decode('utf-8') for line in archive.extractfile(member)), delimiter=';')
            for row in reader:
                label = ids.get(int(row['symbol_id']))
                if label is None:
                    continue
                if not row['user_id'] or not row['user_id'].strip():
                    raise ValueError('missing raw writer')
                writer = str(row['user_id'])
                yield {'label': label, 'writer': writer, 'split': writer_split(writer),
                       'source': 'HWRT raw ODbL', 'strokes': json.loads(row['data'])}
    if seen != {'train-data.csv', 'test-data.csv'}:
        raise ValueError(f'incomplete HWRT archive: {seen}')
    with Path(args.synthetic).open() as f:
        for line in f:
            r = json.loads(line)
            if str(r.get('writer', '')).casefold() == 'ayush' or r.get('split') == 'test':
                raise ValueError('held-out capture disguised as synthetic')
            if r['label'] not in labels or r['source_license'] not in ('Hershey permitted-use notice', 'SIL Open Font License 1.1'):
                raise ValueError('unapproved synthetic source')
            yield {**r, 'writer': None, 'split': 'train', 'source': r['source_family']}


def coverage_split(rows):
    """Seeded writer partition, repairing absent groups without breaking existing coverage."""
    by_group = {}
    for row in rows:
        if row['writer'] is not None:
            by_group.setdefault(row['group'], set()).add(row['writer'])
    assignment = {w: writer_split(w) for writers in by_group.values() for w in writers}
    writer_groups = {w: {g for g, writers in by_group.items() if w in writers} for w in assignment}
    for group, writers in sorted(by_group.items()):
        if len(writers) < 2:
            raise ValueError(f'{group} lacks two independent writers')
        for destination in ('train', 'valid'):
            if any(assignment[w] == destination for w in writers):
                continue
            source = 'valid' if destination == 'train' else 'train'
            candidates = [w for w in writers if all(
                sum(assignment[v] == source for v in by_group[g]) > 1 for g in writer_groups[w])]
            if not candidates:
                raise ValueError(f'cannot repair writer coverage for {group}')
            selected = min(candidates, key=lambda w: hashlib.sha256(f'{SEED}:repair:{w}'.encode()).digest())
            assignment[selected] = destination
    for writers in by_group.values():
        assert {assignment[w] for w in writers} == {'train', 'valid'}
    return assignment


def prepare(args):
    labels, groups, ids = vocabulary(args.vocab)
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    if (out / 'test-report.json').exists():
        raise ValueError('final test consumed; do not overwrite training lineage')
    cached = []
    total = 0
    # One archive pass, bounded raster batches; retain compact pixels, never raw strokes.
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        iterator = iter(records(args, labels, ids))
        while True:
            batch = []
            for _ in range(256):
                try:
                    batch.append(next(iterator))
                except StopIteration:
                    break
            if not batch:
                break
            for r, pixels in zip(batch, pool.map(render, batch, chunksize=16)):
                cached.append((pixels, {'label': r['label'], 'group': labels[r['label']]['group'],
                    'writer': r['writer'], 'source': r['source'], 'source_id': r.get('source_id'),
                    'seed': r.get('seed'), 'source_license': r.get('source_license', 'ODbL 1.0'),
                    'source_url': r.get('source_url'), 'source_notice': r.get('source_notice')}))
                total += 1
            if total % 4096 < 256:
                print(f'prepared {total}', flush=True)
    assignment = coverage_split([r for _, r in cached])
    arrays = {'train': [], 'valid': []}
    targets = {'train': [], 'valid': []}
    label_counts = {s: Counter() for s in arrays}
    writers = {s: set() for s in arrays}
    sources = Counter()
    with (out / 'records.jsonl').open('w') as manifest:
        for pixels, r in cached:
            s = assignment[r['writer']] if r['writer'] is not None else 'train'
            r['split'] = s
            arrays[s].append(pixels)
            targets[s].append(groups.index(r['group']))
            label_counts[s][r['label']] += 1
            if r['writer'] is not None:
                writers[s].add(r['writer'])
            sources[r['source']] += 1
            manifest.write(json.dumps(r, ensure_ascii=False) + '\n')
    assert writers['train'].isdisjoint(writers['valid']) and all(writers.values())
    assert all(label_counts['train'][label] >= 300 for label in labels)
    for split in arrays:
        np.savez(out / f'{split}.npz', images=np.stack(arrays[split]), targets=np.array(targets[split], dtype=np.int64))
    info = {'seed': SEED, 'groups': groups, 'vocab_sha256': digest(args.vocab),
        'raw_sha256': digest(args.hwrt), 'synthetic_sha256': digest(args.synthetic),
        'raster_sha256': digest(Path(__file__).with_name('raster.py')),
        'sources': dict(sources), 'label_counts': {s: dict(v) for s, v in label_counts.items()},
        'writers': {s: sorted(v) for s, v in writers.items()},
        'validation_policy': 'HWRT 20% global writer hash holdout with deterministic group coverage repair; synthetic train only',
        'validation_missing_labels': [l for l in labels if not label_counts['valid'][l]],
        'source_group_writer_counts': {g: {s: len({r['writer'] for _, r in cached
            if r['writer'] is not None and r['group'] == g and r['split'] == s})
            for s in ('train', 'valid')} for g in groups},
        'capture_policy': 'Ayush excluded from prepare/train/validation; final test only'}
    write_json(out / 'prepare.json', info)
    print(f'prepared {total} records', flush=True)


class TinyCNN(nn.Module):
    def __init__(self, count):
        super().__init__()
        self.layers = nn.Sequential(nn.Conv2d(1, 16, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(16, 32, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(32, 48, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Flatten(), nn.Linear(48 * 4 * 4, 128), nn.ReLU(), nn.Dropout(.25), nn.Linear(128, count))

    def forward(self, image):
        # Core ML supplies native 0 black / 255 white grayscale pixels.
        return self.layers(1.0 - image / 255.0)


def seeded():
    random.seed(SEED)
    np.random.seed(SEED)
    torch.manual_seed(SEED)
    torch.set_num_threads(4)
    torch.use_deterministic_algorithms(True, warn_only=True)


def loader(path, batch, shuffle=False):
    a = np.load(path)
    dataset = TensorDataset(torch.from_numpy(a['images'].reshape(-1, 1, 32, 32).astype(np.float32)),
                           torch.from_numpy(a['targets']))
    return DataLoader(dataset, batch_size=batch, shuffle=shuffle, num_workers=0,
                      generator=torch.Generator().manual_seed(SEED))


def probabilities(model, images):
    with torch.no_grad():
        return torch.softmax(model(images), dim=1)


def train(args):
    seeded()
    out = Path(args.output)
    if (out / 'test-report.json').exists():
        raise ValueError('final test consumed; retraining on its errors is prohibited')
    info = json.loads((out / 'prepare.json').read_text())
    expected = {
        'vocab_sha256': digest(args.vocab),
        'raster_sha256': digest(Path(__file__).with_name('raster.py')),
        'raw_sha256': digest(args.hwrt),
        'synthetic_sha256': digest(args.synthetic),
    }
    mismatches = {key: (info.get(key), value) for key, value in expected.items()
                  if info.get(key) != value}
    if mismatches:
        raise ValueError(f'prepared cache source hashes do not match live inputs: {mismatches}')
    _, groups, _ = vocabulary(args.vocab)
    if info['seed'] != SEED or info['groups'] != groups:
        raise ValueError('prepared cache seed or canonical groups changed')
    if not all((out / name).is_file() for name in ('train.npz', 'valid.npz', 'records.jsonl')):
        raise ValueError('prepared cache is incomplete')
    if not info['writers']['train'] or not info['writers']['valid']:
        raise ValueError('prepared cache has an empty writer partition')
    if not set(info['writers']['train']).isdisjoint(info['writers']['valid']):
        raise ValueError('prepared cache writer partitions overlap')
    for counts in info['source_group_writer_counts'].values():
        if any(counts.values()) and not all(counts.values()):
            raise ValueError('a source-backed group lacks independent train/validation writers')
    record_count = sum(info['sources'].values())
    split_count = sum(sum(counts.values()) for counts in info['label_counts'].values())
    if not record_count or record_count != split_count:
        raise ValueError('prepared cache source and split counts are inconsistent')
    device = torch.device(args.device)
    model = TinyCNN(len(info['groups'])).to(device)
    training = loader(out / 'train.npz', args.batch, True)
    validation = loader(out / 'valid.npz', args.batch)
    counts = torch.bincount(training.dataset.tensors[1], minlength=len(info['groups'])).float()
    weights = counts.sum() / (len(counts) * counts)
    loss_fn = nn.CrossEntropyLoss(weight=weights.to(device))
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode='max', factor=.5, patience=4)
    training_config = {'dropout': .25, 'weight_decay': 1e-4,
        'scheduler': 'ReduceLROnPlateau(valid accuracy, factor=0.5, patience=4)'}
    best = -1
    history = []
    for epoch in range(args.epochs):
        model.train()
        loss_sum = 0.0
        for x, y in training:
            x, y = x.to(device), y.to(device)
            optimizer.zero_grad()
            loss = loss_fn(model(x), y)
            loss.backward()
            optimizer.step()
            loss_sum += loss.item() * len(y)
        model.eval()
        correct = 0
        with torch.no_grad():
            for x, y in validation:
                correct += int((model(x.to(device)).argmax(1).cpu() == y).sum())
        accuracy = correct / len(validation.dataset)
        row = {'epoch': epoch + 1, 'loss': loss_sum / len(training.dataset),
            'writer_valid_accuracy': accuracy, 'learning_rate': optimizer.param_groups[0]['lr']}
        history.append(row)
        print(json.dumps(row), flush=True)
        scheduler.step(accuracy)
        if accuracy > best:
            best = accuracy
            torch.save({'state': {k: v.cpu() for k, v in model.state_dict().items()},
                'groups': info['groups'], 'epoch': epoch + 1, 'valid_accuracy': accuracy,
                'vocab_sha256': info['vocab_sha256'], 'training_config': training_config,
                'source_hashes': {key: info[key] for key in expected}, 'seed': SEED}, out / 'best.pt')
        write_json(out / 'training.json', {'history': history, 'arguments': vars(args),
            'device': str(device), 'training_config': training_config,
            'source_hashes': {key: info[key] for key in expected}})


def checkpoint(args):
    out = Path(args.output)
    saved = torch.load(out / 'best.pt', map_location='cpu', weights_only=True)
    info = json.loads((out / 'prepare.json').read_text())
    source_hashes = {key: info[key] for key in ('vocab_sha256', 'raster_sha256', 'raw_sha256', 'synthetic_sha256')}
    if saved['vocab_sha256'] != digest(args.vocab) or saved.get('source_hashes') != source_hashes:
        raise ValueError('checkpoint source lineage does not match the prepared cache')
    if source_hashes['raster_sha256'] != digest(Path(__file__).with_name('raster.py')):
        raise ValueError('checkpoint raster lineage does not match the current raster')
    if saved['seed'] != SEED:
        raise ValueError('checkpoint seed changed')
    _, groups, _ = vocabulary(args.vocab)
    assert saved['groups'] == groups
    model = TinyCNN(len(groups))
    model.load_state_dict(saved['state'])
    return model.eval(), saved


def export(args):
    import coremltools as ct
    model, saved = checkpoint(args)
    example = torch.zeros(1, 1, 32, 32)
    traced = torch.jit.trace(nn.Sequential(model, nn.Softmax(dim=1)).eval(), example)
    converted = ct.convert(traced, inputs=[ct.ImageType(name='glyphImage', shape=example.shape,
        color_layout=ct.colorlayout.GRAYSCALE, scale=1.0)],
        classifier_config=ct.ClassifierConfig(saved['groups'], predicted_feature_name='group'),
        convert_to='mlprogram', minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16)
    converted.short_description = 'Stroke glyph groups; 32L black ink on white, raster v1'
    converted.user_defined_metadata['vocab_sha256'] = saved['vocab_sha256']
    out = Path(args.output)
    package = out / 'MathGlyphs.mlpackage'
    if package.exists():
        shutil.rmtree(package)
    converted.save(str(package))
    destination = Path(args.resources)
    destination.mkdir(parents=True, exist_ok=True)
    compiled = out / 'MathGlyphs.mlmodelc'
    if compiled.exists():
        shutil.rmtree(compiled)
    subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(package), str(out)], check=True)
    size = sum(p.stat().st_size for p in compiled.rglob('*') if p.is_file())
    assert size < 1_000_000, size
    spec = converted.get_spec()
    description = spec.description
    predicted_feature = description.predictedFeatureName
    probabilities_feature = description.predictedProbabilitiesName
    output_names = {v.name: str(v.type) for v in description.output}
    assert predicted_feature in output_names and probabilities_feature in output_names, output_names
    native = ct.models.CompiledMLModel(str(compiled), compute_units=ct.ComputeUnit.ALL)
    data = np.load(out / 'valid.npz')['images']
    errors = []
    from PIL import Image
    for i in (0, len(data) // 2, len(data) - 1):
        p = probabilities(model, torch.from_numpy(data[i].reshape(1, 1, 32, 32).astype(np.float32)))[0].numpy()
        result = native.predict({'glyphImage': Image.fromarray(data[i].reshape(32, 32), mode='L')})
        dictionary = result[probabilities_feature]
        assert set(dictionary) == set(saved['groups'])
        assert abs(sum(dictionary.values()) - 1.0) < .003
        assert result[predicted_feature] == max(dictionary, key=dictionary.get)
        error = max(abs(float(p[j]) - float(dictionary[g])) for j, g in enumerate(saved['groups']))
        errors.append(error)
        assert error < 0.003, (i, error)
    target = destination / compiled.name
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(compiled, target)
    image = spec.description.input[0].type.imageType
    assert spec.description.input[0].name == 'glyphImage' and (image.width, image.height) == (32, 32)
    selection_path = out / 'selection.json'
    selection = json.loads(selection_path.read_text()) if selection_path.exists() else None
    write_json(out / 'export.json', {'checkpoint_sha256': digest(out / 'best.pt'),
        'compiled_bundle_sha256': bundle_digest(target), 'compiled_bytes': size, 'precision': 'float16',
        'parity_max_probability_errors': errors, 'group_count': len(saved['groups']),
        'checkpoint_epoch': saved['epoch'], 'checkpoint_valid_accuracy': saved['valid_accuracy'],
        'training_config': saved.get('training_config', {'dropout': 0, 'weight_decay': 0, 'scheduler': 'none'}),
        'checkpoint_selection': selection,
        'source_hashes': saved['source_hashes'],
        'input': 'glyphImage, 32x32 CVPixelBuffer OneComponent8; black=0 white=255; scale=1',
        'preprocessing': 'CNN converts raw grayscale to ink using 1-pixel/255',
        'outputs': output_names, 'predicted_feature': predicted_feature,
        'probabilities_feature': probabilities_feature,
        'parity_backend': 'Core ML CompiledMLModel; ComputeUnit.ALL'})


def evaluate(args):
    _, saved = checkpoint(args)
    out = Path(args.output)
    report_path = out / 'test-report.json'
    if report_path.exists():
        raise ValueError('final test already evaluated; preserve report, no repeat/model selection')
    labels, groups, _ = vocabulary(args.vocab)
    capture_files = sorted(Path(args.capture).glob('*.json'))
    records_ = [json.loads(p.read_text()) for p in capture_files]
    assert len(records_) == 790
    counts = Counter(r['label'] for r in records_)
    assert counts == Counter({l: 5 for l in labels})
    for r in records_:
        assert r.get('writer') == 'ayush' and r.get('split') == 'test', r.keys()
    import coremltools as ct
    from PIL import Image
    compiled_path = Path(args.resources) / 'MathGlyphs.mlmodelc'
    compiled_hash = bundle_digest(compiled_path)
    exported = json.loads((out / 'export.json').read_text())
    assert exported['compiled_bundle_sha256'] == compiled_hash
    assert exported['checkpoint_sha256'] == digest(out / 'best.pt')
    deployed = ct.models.CompiledMLModel(str(compiled_path), compute_units=ct.ComputeUnit.ALL)
    probabilities_ = []
    for record in records_:
        pixels = render(record).reshape(32, 32)
        result = deployed.predict({'glyphImage': Image.fromarray(pixels, mode='L')})
        dictionaries = [v for v in result.values() if isinstance(v, dict)]
        assert len(dictionaries) == 1 and set(dictionaries[0]) == set(groups)
        values = [float(dictionaries[0][g]) for g in groups]
        assert all(math.isfinite(v) and 0 <= v <= 1 for v in values)
        assert abs(sum(values) - 1) < .003
        assert result['group'] == max(dictionaries[0], key=dictionaries[0].get)
        probabilities_.append(values)
    p = np.array(probabilities_, dtype=np.float64)
    targets = np.array([groups.index(labels[r['label']]['group']) for r in records_])
    predicted = p.argmax(1)
    confusion = np.zeros((len(groups), len(groups)), dtype=np.int64)
    np.add.at(confusion, (targets, predicted), 1)
    label_accuracy = {l: float((predicted[[r['label'] == l for r in records_]] == groups.index(labels[l]['group'])).mean()) for l in labels}
    synthetic = {l: label_accuracy[l] for l in labels if not labels[l]['hwrt_ids']}
    group_accuracy = {g: float(confusion[i, i] / confusion[i].sum()) for i, g in enumerate(groups)}
    disabled = sorted(l for l in labels if (label_accuracy[l] < 0.85 if not labels[l]['hwrt_ids'] else group_accuracy[labels[l]['group']] < 0.95))
    eligible_mask = np.array([r['label'] not in disabled for r in records_])
    correct = predicted == targets
    report = {'evaluation_backend': 'Core ML CompiledMLModel; ComputeUnit.ALL; deployed FP16 bundle',
        'compiled_bundle_sha256': compiled_hash, 'label_accuracy_definition': 'Correctness of canonical group prediction per source label; resolved member accuracy belongs to R6',
        'overall_group_top1': float(correct.mean()), 'overall_95_gate_passed': bool(correct.mean() >= .95),
        'synthetic_only_label_top1': synthetic, 'synthetic_85_gate_passed': all(a >= .85 for a in synthetic.values()),
        'label_accuracy': label_accuracy, 'group_accuracy': group_accuracy, 'groups': groups,
        'confusion_matrix': confusion.tolist(), 'disabled_labels': disabled,
        'eligible_sample_coverage': float(eligible_mask.mean()),
        'eligible_only_accuracy': float(correct[eligible_mask].mean()) if eligible_mask.any() else None,
        'eligible_only_accuracy_is_filtered': True, 'checkpoint_epoch': saved['epoch'],
        'checkpoint_sha256': digest(out / 'best.pt'), 'export': json.loads((out / 'export.json').read_text()) if (out / 'export.json').exists() else {'status': 'unavailable'},
        'precision': 'float16', 'test_records': len(records_), 'capture_sha256': {p.name: digest(p) for p in sorted(Path(args.capture).glob('*.json'))},
        'predictions': [{'source_file': capture_files[i].name, 'file_label': r['label'], 'group': groups[int(predicted[i])],
            'probability': float(p[i].max()), 'runner_up_probability': float(np.sort(p[i])[-2]),
            'margin': float(np.sort(p[i])[-1] - np.sort(p[i])[-2])} for i, r in enumerate(records_)]}
    write_json(report_path, report)
    write_json(Path(args.resources) / 'MathGlyphs-manifest.json', {'version': 1, 'groups': groups,
        'vocab_sha256': digest(args.vocab), 'compiledBytes': report['export'].get('compiled_bytes'),
        'precision': 'float16', 'compiledBundleSHA256': compiled_hash,
        'evaluationBackend': report['evaluation_backend'], 'disabledLabels': disabled, 'threshold': .85, 'margin': .3,
        'overallGroupTop1': report['overall_group_top1'], 'overall95GatePassed': report['overall_95_gate_passed'],
        'eligibleSampleCoverage': report['eligible_sample_coverage'],
        'input': 'glyphImage: 32x32 grayscale black=0 white=255; native scale=1; internal inversion/255'})
    print(json.dumps({k: v for k, v in report.items() if k in ('overall_group_top1', 'disabled_labels', 'eligible_sample_coverage')}))


def selfcheck(args):
    seeded()
    raster_check()
    stream = io.BytesIO()
    csv_bytes = 'symbol_id;user_id;data;user_agent\r\n31;9;[];"é\nagent"\r\n'.encode()
    with tarfile.open(fileobj=stream, mode='w:bz2') as archive:
        for name in ('train-data.csv', 'test-data.csv'):
            member = tarfile.TarInfo(name)
            member.size = len(csv_bytes)
            archive.addfile(member, io.BytesIO(csv_bytes))
    stream.seek(0)
    with tarfile.open(fileobj=stream, mode='r|bz2') as archive:
        rows = [row for member in archive for row in csv.DictReader(
            (line.decode('utf-8') for line in archive.extractfile(member)), delimiter=';')]
    assert rows == [{'symbol_id': '31', 'user_id': '9', 'data': '[]', 'user_agent': 'é\nagent'}] * 2
    fixtures = json.loads((ROOT / 'Tests/CanvasKitTests/Fixtures/raster/fixtures.json').read_text())['fixtures']
    for fixture in fixtures:
        assert rasterize(fixture['strokes']).tobytes() == base64.b64decode(fixture['pixels']), fixture['name']
    labels, groups, _ = vocabulary(args.vocab)
    assert writer_split('50') == 'train'
    assert {w: writer_split(w) for w in ('1', '9', '11')} == {'1': 'train', '9': 'valid', '11': 'valid'}
    coverage_rows = [{'group': 'a', 'writer': w} for w in ('1', '2')] + [
        {'group': 'b', 'writer': w} for w in ('2', '3')]
    assert coverage_split(coverage_rows) == {'1': 'train', '2': 'valid', '3': 'train'}
    assert writer_split('100') == writer_split('100')
    split = {s: {str(i) for i in range(1, 1000) if writer_split(str(i)) == s} for s in ('train', 'valid')}
    assert split['train'].isdisjoint(split['valid']) and len(split['valid']) == 193
    assert labels['0']['group'] == labels['o']['group'] == labels['O']['group']
    try:
        writer_split('ayush')
        raise AssertionError('Ayush admitted')
    except ValueError:
        pass
    model = TinyCNN(len(groups)).eval()
    image = torch.full((2, 1, 32, 32), 255.)
    image[0, 0, 15:17, 2:30] = 0
    p = probabilities(model, image)
    assert p.shape == (2, len(groups)) and torch.allclose(p.sum(1), torch.ones(2), atol=1e-6)
    seeded()
    second = TinyCNN(len(groups)).eval()
    assert torch.equal(p, probabilities(second, image))
    assert sum(t.numel() for t in model.parameters()) < 200000
    seeded()
    probe = probabilities(TinyCNN(3).eval(), torch.full((1, 1, 32, 32), 255.))[0]
    assert torch.allclose(probe, torch.tensor([.3316288292, .3295248151, .3388462961]), atol=1e-7)
    print('split, raster, canonical group and fixed-seed CNN self-check passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'train', 'export', 'evaluate', 'selfcheck'])
    parser.add_argument('--vocab', default=str(VOCAB))
    parser.add_argument('--output', default=str(ROOT / 'build/glyph-training'))
    parser.add_argument('--resources', default=str(ROOT / 'Sources/CanvasKit/Resources'))
    parser.add_argument('--hwrt')
    parser.add_argument('--synthetic')
    parser.add_argument('--capture')
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--epochs', type=int, default=40)
    parser.add_argument('--batch', type=int, default=256)
    parser.add_argument('--lr', type=float, default=.001)
    parser.add_argument('--device', default='mps')
    args = parser.parse_args()
    required = {'prepare': ('hwrt', 'synthetic'), 'train': ('hwrt', 'synthetic'), 'evaluate': ('capture',)}
    for field in required.get(args.command, ()):
        if not getattr(args, field):
            parser.error(f'--{field} required for {args.command}')
    globals()[args.command](args)


if __name__ == '__main__':
    main()
