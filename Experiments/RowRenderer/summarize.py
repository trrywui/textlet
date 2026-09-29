#!/usr/bin/env python3
"""Summarize renderer runs without confusing sampled maxima and system peak."""
import collections
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('Benchmarks/2026-09-27/row-renderer')
summary = {}
for path in sorted(root.glob('*.json')):
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or 'samples' not in data or 'editTimingIncludingDisplay' not in data:
        continue
    groups = collections.defaultdict(list)
    for sample in data['samples']:
        groups[sample['stage']].append(sample)
    summary[path.stem] = {
        'mode': data['mode'], 'edits': data['edits'],
        'gpuBefore': path.with_suffix(path.suffix + '.gpu-before.txt').read_text().strip() if path.with_suffix(path.suffix + '.gpu-before.txt').exists() else None,
        'gpuAfter': path.with_suffix(path.suffix + '.gpu-after.txt').read_text().strip() if path.with_suffix(path.suffix + '.gpu-after.txt').exists() else None,
        'systemPeakMiB': max(s['peakFootprintMiB'] for s in data['samples']),
        'editTimingIncludingDisplay': data['editTimingIncludingDisplay'],
        'stages': {
            name: {
                'sampleMaxMiB': max(s['footprintMiB'] for s in values),
                'lastMiB': values[-1]['footprintMiB'],
                'samples': len(values), 'activeSamples': sum(s['active'] for s in values),
                'width': values[-1]['width'], 'height': values[-1]['height'], 'scale': values[-1]['scale'],
                'textUTF16Length': values[-1]['textUTF16Length'],
                'bitmapMiBEstimate': max(s.get('bitmapBytesEstimate', 0) for s in values) / 1048576,
            } for name, values in groups.items()
        },
    }
(root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
for name, run in summary.items():
    print(name, 'system peak', round(run['systemPeakMiB'], 2), 'MiB')
    for stage in ['small-edit', 'large-edit', 'large-idle', 'dense-edit', 'dense-scroll', 'small-again']:
        item = run['stages'][stage]
        print(' ', stage, 'max', round(item['sampleMaxMiB'], 2), 'last', round(item['lastMiB'], 2),
              'active', f"{item['activeSamples']}/{item['samples']}")
