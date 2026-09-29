"""Rebuild the saved old renderer with today's identical performance driver.

The isolated copy is benchmark-only; it never replaces the working tree's sources.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--renderer', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
project = Path(__file__).resolve().parents[2]
snapshot_root = project / 'test-output/baseline-sources'
snapshot_root.mkdir(parents=True, exist_ok=True)
copy = Path(tempfile.mkdtemp(prefix='textlet-baseline-source-', dir=snapshot_root))
for directory in ['Sources', 'Tests', 'scripts']:
    shutil.copytree(project / directory, copy / directory)
for name in ['Info.plist', 'AppIcon.icns']:
    shutil.copy2(project / name, copy / name)
renderer = args.renderer.read_text()
# The old renderer has no cache-hit/pass counters. Zero means unavailable here;
# bitmap count and actual rasterization counters still come from its real code.
marker = '    private var tiles:'
assert renderer.count(marker) == 1
renderer = renderer.replace(marker, '''    var rowCacheHits: Int { 0 }
    var rowRenderPasses: Int { 0 }
    var cachedTileCount: Int { renderedTileCount }
    var skippedTouchBarFormatUpdates: Int { 0 }
''' + marker)
(copy / 'Sources/RowRenderingTextView.swift').write_text(renderer)
# New cache-specific correctness tests cannot compile against the old renderer.
# Keep all performance drivers unchanged; refuse the unsupported correctness mode.
(copy / 'Tests/RowsIntegrationTests.swift').write_text('''#if ROW_RENDERER
import AppKit
func runRowsIntegrationCheck(app: Textlet, output: URL) {
    fatalError("Baseline build supports performance comparison only")
}
#endif
''')
subprocess.run(['bash', str(copy / 'scripts/build-experimental.sh'), str(args.output.resolve())], check=True)
print('Baseline source snapshot:', copy)
