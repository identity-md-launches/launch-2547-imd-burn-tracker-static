#!/usr/bin/env python3
"""Verify saved result.json bytes against mainnet event hashes; optional --fetch from IPFS.
Requires only Python's standard library and Foundry's cast. Default mode is fully offline.
"""
import argparse
import json
import pathlib
import re
import subprocess
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--fetch', action='store_true', help='fetch the original IPFS bytes before verifying')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
rows = json.loads((root / 'test/fixtures/results-provenance.json').read_text())

def no_duplicates(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError('duplicate key: ' + key)
        out[key] = value
    return out

for entry in rows:
    path = root / entry['path']
    raw = urllib.request.urlopen(entry['url'], timeout=30).read() if args.fetch else path.read_bytes()
    digest = subprocess.check_output(['cast', 'keccak', '0x' + raw.hex()], text=True).strip()
    event_hash = '0x' + entry['completionLog']['data'][66:130]
    assert digest == entry['keccak256'] == event_hash, entry['requestId']
    assert len(raw) == entry['bytes']
    doc = json.loads(raw, object_pairs_hook=no_duplicates)
    assert doc['jobId'] == entry['jobId']
    assert re.fullmatch(r'[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}', doc['jobId'])
    assert raw == json.dumps(doc, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
    if args.fetch:
        path.write_bytes(raw)
    print(path.name, len(raw), digest, 'verified')
