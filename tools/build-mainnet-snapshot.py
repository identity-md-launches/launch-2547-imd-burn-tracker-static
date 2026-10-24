#!/usr/bin/env python3
"""Convert recorded read-only fork RPC responses into an offline EVM fixture."""
import json
import pathlib

source = pathlib.Path('test/fixtures/mainnet-rpc.json')
rows = json.loads(source.read_text())
accounts = {}
block = None
for key, response in rows.items():
    method, params = json.loads(key)
    if 'result' not in response:
        raise ValueError('RPC failure in recording: ' + key)
    result = response['result']
    if method == 'eth_getBlockByNumber' and params[0] == hex(26_263_700):
        block = result
    elif method in ('eth_getCode', 'eth_getStorageAt'):
        address = params[0].lower()
        account = accounts.setdefault(address, {'address':address, 'code':'0x', 'slots':{}})
        if method == 'eth_getCode':
            account['code'] = result
        else:
            account['slots']['0x'+params[1][2:].zfill(64)] = '0x'+result[2:].zfill(64)
assert block is not None
out = []
for account in sorted(accounts.values(), key=lambda a:a['address']):
    if account['address'] not in ('0xa43e6f75ee006411f79ac1c84120606c2330de82', '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7'):
        continue
    out.append({'address':account['address'], 'code':account['code'], 'slotCount':len(account['slots']),
                'storage':[{'key':k, 'value':v} for k,v in sorted(account['slots'].items())]})
fixture = {'chainId':1, 'blockNumber':int(block['number'],16), 'blockHash':block['hash'],
           'timestamp':int(block['timestamp'],16), 'source':'https://ethereum-rpc.publicnode.com',
           'accountCount':len(out), 'accounts':out}
pathlib.Path('test/fixtures/mainnet-state.json').write_text(json.dumps(fixture, indent=2)+'\n')
for a in out:
    print(a['address'], 'code bytes', (len(a['code'])-2)//2, 'storage slots', a['slotCount'])
