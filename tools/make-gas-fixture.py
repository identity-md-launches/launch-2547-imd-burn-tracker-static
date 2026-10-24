#!/usr/bin/env python3
"""Make a clearly synthetic, realistic 4,545-byte stress document from a real result."""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
fixture_dir = root / 'test/fixtures'
doc = json.loads((fixture_dir / 'result-1975.json').read_bytes())
original_files = doc['files'][:]
def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
while True:
    trial = dict(doc, files=doc['files'] + [original_files[len(doc['files']) % len(original_files)]], testPadding='')
    if len(canonical(trial)) > 4545:
        break
    doc = trial
doc['testPadding'] = 'x' * (4545 - len(canonical(doc)))
raw = canonical(doc)
assert len(raw) == 4545
(fixture_dir / 'result-gas-4545.json').write_bytes(raw)
print('4,545 bytes:', len(doc['files']), 'file records,', len(doc['testPadding']), 'padding bytes')
