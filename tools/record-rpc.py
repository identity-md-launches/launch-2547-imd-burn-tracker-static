#!/usr/bin/env python3
"""Read-only RPC recorder for reproducible mainnet test fixtures. Standard library only.
Run locally, then point forge --fork-url at http://127.0.0.1:18545.
Never forwards transaction submission methods. No credentials or environment variables.
"""
import argparse
import http.server
import json
import pathlib
import threading
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--upstream', default='https://ethereum-rpc.publicnode.com')
parser.add_argument('--output', default='test/fixtures/mainnet-rpc.json')
parser.add_argument('--port', type=int, default=18545)
args = parser.parse_args()
records = {}
lock = threading.Lock()
allowed = {'eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber', 'eth_getBlockByHash',
           'eth_getCode', 'eth_getStorageAt', 'eth_getBalance', 'eth_getTransactionCount',
           'eth_getTransactionByHash', 'eth_getTransactionReceipt', 'eth_getLogs', 'eth_call',
           'eth_getProof', 'net_version', 'web3_clientVersion', 'eth_getBlockReceipts', 'eth_gasPrice'}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        query = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        calls = query if isinstance(query, list) else [query]
        replies = []
        for q in calls:
            if q['method'] not in allowed:
                replies.append({'jsonrpc':'2.0', 'id':q['id'], 'error':{'code':-32601, 'message':'read-only recorder: method not supported'}}); continue
            key = json.dumps([q['method'], q.get('params', [])], separators=(',', ':'))
            with lock:
                result = records.get(key)
            if result is None:
                req = urllib.request.Request(args.upstream, json.dumps(q).encode(), {'Content-Type':'application/json', 'User-Agent':'curl/8.5.0'})
                try:
                    response = json.load(urllib.request.urlopen(req, timeout=30))
                except Exception as error:
                    print(q['method'], str(error), flush=True)
                    self.send_error(502); return
                result = {k:v for k,v in response.items() if k not in ('id','jsonrpc')}
                with lock:
                    records[key] = result
                    pathlib.Path(args.output).write_text(json.dumps(records, indent=2)+'\n')
            replies.append(dict(result, id=q['id'], jsonrpc='2.0'))
        data = json.dumps(replies if isinstance(query, list) else replies[0]).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
print('Read-only RPC recorder on 127.0.0.1:'+str(args.port), flush=True)
http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
