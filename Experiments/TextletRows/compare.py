"""Run complete native/rows apps sequentially with isolated sessions and GPU auditing."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--native-app', type=Path, required=True)
parser.add_argument('--rows-app', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)

def gpu():
    value = subprocess.check_output(['/usr/sbin/ioreg', '-r', '-c', 'AppleMuxControl', '-l'], text=True)
    active = re.search(r'"ActiveGPU" = "([^"]+)"', value)
    switches = re.search(r'"SwitchCount" = <([0-9a-f]+)>', value)
    return {'time': time.time(), 'activeGPU': active.group(1) if active else None,
            'switchCountHex': switches.group(1) if switches else None}

runs = {}
session_root = Path(__file__).resolve().parents[2] / 'test-output/sessions'
session_root.mkdir(parents=True, exist_ok=True)
for mode, bundle, executable in [('native', args.native_app, 'textlet'), ('rows', args.rows_app, 'textlet-rows')]:
    binary = bundle.resolve() / 'Contents/MacOS' / executable
    session = tempfile.mkdtemp(prefix='textlet-comparison-' + mode + '-', dir=session_root)
    output = args.output.resolve() / (mode + '.json')
    gpu_samples = [gpu()]
    print('START', mode, gpu_samples[-1], flush=True)
    with (args.output / (mode + '.stdout.txt')).open('w') as stream:
        process = subprocess.Popen(['caffeinate', '-d', '-i', str(binary), '--data-dir', session,
                                    '--rendering-comparison', str(output)], stdout=stream, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 150
        while process.poll() is None:
            if time.monotonic() > deadline:
                process.terminate()
                raise RuntimeError('Timed out: ' + mode)
            time.sleep(2)
            gpu_samples.append(gpu())
    gpu_samples.append(gpu())
    audit = {'gpu': gpu_samples, 'session': session, 'binary': str(binary),
             'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'exitCode': process.returncode}
    (args.output / (mode + '.audit.json')).write_text(json.dumps(audit, indent=2) + '\n')
    if process.returncode != 0:
        raise RuntimeError('Nonzero exit: ' + mode)
    result = json.loads(output.read_text())
    runs[mode] = result
    print('DONE', mode, result['checks'], flush=True)

summary = {'modes': {}, 'checks': {}, 'scope': 'MiB of own process phys_footprint; not system-wide memory or GPU VRAM'}
all_gpu = []
for mode, result in runs.items():
    all_gpu.extend(json.loads((args.output / (mode + '.audit.json')).read_text())['gpu'])
    stages = {}
    for stage in dict.fromkeys(x['stage'] for x in result['samples']):
        values = [x for x in result['samples'] if x['stage'] == stage]
        stages[stage] = {'count': len(values), 'foregroundCount': sum(x['active'] and x['keyWindow'] for x in values),
                         'maxMiB': max(x['footprintMiB'] for x in values), 'lastMiB': values[-1]['footprintMiB'],
                         'peakMiB': max(x['peakFootprintMiB'] for x in values),
                         'dimensions': sorted({(x['width'], x['height'], x['scale']) for x in values}),
                         'fonts': sorted({(x['font'], x['fontSize']) for x in values})}
    summary['modes'][mode] = {'stages': stages, 'timings': result['timings'], 'checks': result['checks']}
summary['checks']['gpuStableAndKnown'] = len({(x['activeGPU'], x['switchCountHex']) for x in all_gpu}) == 1 and all(x['activeGPU'] and x['switchCountHex'] for x in all_gpu)
summary['checks']['sameFixture'] = runs['native']['fixture'] == runs['rows']['fixture']
summary['checks']['sameOperationCounts'] = runs['native']['operations'] == runs['rows']['operations']
summary['checks']['bothRunChecksPass'] = all(all(x['checks'].values()) for x in runs.values())
comparison_stages = ['small-edit', 'large-edit', 'large-idle', 'dense-edit', 'dense-scroll', 'dense-idle']
for key in ['dimensions', 'fonts']:
    summary['checks']['same-' + key] = all(summary['modes']['native']['stages'][s][key] == summary['modes']['rows']['stages'][s][key] for s in comparison_stages)
summary['GPU'] = all_gpu[0]['activeGPU']
summary['switchCountHex'] = all_gpu[0]['switchCountHex']
project = Path(__file__).resolve().parents[2]
files = sorted((project / 'Sources').glob('*.swift')) + sorted((project / 'Tests').glob('*.swift'))
files += [project / 'scripts/build.sh', project / 'scripts/build-experimental.sh', Path(__file__).resolve()]
summary['sourceSHA256'] = {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(args.output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
print('COMPARISON CHECKS', summary['checks'], flush=True)
for stage in comparison_stages:
    print(stage, {m: round(summary['modes'][m]['stages'][stage]['maxMiB'], 2) for m in runs}, flush=True)
if not all(summary['checks'].values()):
    raise SystemExit('Invalid comparison conditions; preserve data and investigate before reporting a benefit.')
