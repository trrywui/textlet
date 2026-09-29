"""Sequential, isolated CPU/cache comparison. Never opens the user's session."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--name', required=True)
parser.add_argument('--budget', type=int, default=32)
parser.add_argument('--position', choices=['head', 'middle', 'tail'], default='head')
parser.add_argument('--rate', type=int, default=20)
parser.add_argument('--scroll-span', type=int, default=80)
parser.add_argument('--profile', action='store_true', help='Diagnostic only: sample the actual input and scroll phases')
parser.add_argument('--native-touchbar', action='store_true', help='Diagnostic control: keep AppKit formatting updates')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
report = args.output.resolve() / (args.name + '.json')
if report.exists():
    raise SystemExit('Refusing to overwrite ' + str(report))
binary = args.app.resolve() / 'Contents/MacOS/textlet-rows'
if not binary.exists():
    binary = args.app.resolve() / 'Contents/MacOS/textlet'

def gpu():
    value = subprocess.check_output(['/usr/sbin/ioreg', '-r', '-c', 'AppleMuxControl', '-l'], text=True)
    active = re.search(r'"ActiveGPU" = "([^"]+)"', value)
    switches = re.search(r'"SwitchCount" = <([0-9a-f]+)>', value)
    return {'time': time.time(), 'activeGPU': active.group(1) if active else None,
            'switchCountHex': switches.group(1) if switches else None}

session_root = Path(__file__).resolve().parents[2] / 'test-output/sessions'
session_root.mkdir(parents=True, exist_ok=True)
session = tempfile.mkdtemp(prefix='textlet-balance-', dir=session_root)
audit = {'gpu': [gpu()], 'session': session, 'binary': str(binary),
         'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest()}
command = [str(binary), '--data-dir', session, '--real-usage-benchmark', str(report),
           '--benchmark-position', args.position, '--benchmark-rate', str(args.rate),
           '--benchmark-scroll-span', str(args.scroll_span)]
phase_file = Path(session) / 'phase.txt'
if args.profile:
    command += ['--benchmark-phase-log', str(phase_file)]
audit['command'] = command
env = dict(os.environ, TEXTLET_ROW_CACHE_MIB=str(args.budget))
env['TEXTLET_NATIVE_TOUCHBAR_UPDATES'] = '1' if args.native_touchbar else '0'
audit['nativeTouchBarUpdates'] = args.native_touchbar
with report.with_suffix('.stdout.txt').open('w') as stream:
    process = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 180
    profiled = set()
    profilers = []
    while process.poll() is None:
        if time.monotonic() > deadline:
            process.terminate()
            raise RuntimeError('Timed out: ' + args.name)
        time.sleep(0.2 if args.profile else 2)
        audit['gpu'].append(gpu())
        if args.profile and phase_file.exists():
            phase = phase_file.read_text()
            if phase in ['continuous-input', 'continuous-scroll'] and phase not in profiled:
                profiled.add(phase)
                audit.setdefault('profiles', []).append({'phase': phase, 'time': time.time()})
                profilers.append(subprocess.Popen(['/usr/bin/sample', str(process.pid), '3', '1', '-file',
                                  str(report.with_suffix('.' + phase + '.sample.txt'))], stdout=stream, stderr=stream))
    for profiler in profilers:
        profiler.wait(timeout=10)
audit['exitCode'] = process.returncode
report.with_suffix('.audit.json').write_text(json.dumps(audit, indent=2) + '\n')
result = json.loads(report.read_text())
stable = len({(x['activeGPU'], x['switchCountHex']) for x in audit['gpu']}) == 1 and all(x['activeGPU'] and x['switchCountHex'] for x in audit['gpu'])
dimensions = {(s['width'], s['height'], s['scale']) for s in result['samples']}
conditions = dimensions == {(1680, 940, 2)} and result['inputStartLength'] == 36611
if args.scroll_span <= 20 and 'scrollMovedEvents' in result:
    conditions = conditions and result['scrollMovedEvents'] == 160
print(args.name, 'GPU stable:', stable, 'checks:', result['checks'], flush=True)
for stage, values in result['summaries'].items():
    print(stage, {k: round(values[k], 2) for k in ['avgCpuPercentOfOneCore', 'cpuSecondsMeasured', 'wallSeconds', 'maxFootprintMiB', 'deliveryLatenessP95Milliseconds']}, flush=True)
if process.returncode != 0 or not stable or not conditions or not all(result['checks'].values()):
    raise SystemExit('Invalid run; preserve data and investigate.')
