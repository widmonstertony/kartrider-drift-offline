"""Call a user-configured Android MCP; keep credentials outside source control."""
import argparse
import json
import os
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def call(name, arguments):
    config_path = Path(os.environ.get(
        'ANDROID_MCP_CONFIG', str(ROOT / 'runtime/android-device.json')))
    config = json.loads(config_path.read_text())

    def request(method, params, session=None):
        headers = {'Authorization': 'Bearer ' + config['token'],
                   'Content-Type': 'application/json', 'Accept': 'application/json'}
        if session:
            headers['Mcp-Session-Id'] = session
        req = urllib.request.Request(config['url'], headers=headers, data=json.dumps({
            'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode())
        with urllib.request.urlopen(req, timeout=135) as response:
            return json.load(response), response.headers.get('Mcp-Session-Id')

    if not config.get('session'):
        _, config['session'] = request('initialize', {
            'protocolVersion': '2025-06-18', 'capabilities': {},
            'clientInfo': {'name': 'kartdrift-preservation', 'version': '0.1'}})
        config_path.write_text(json.dumps(config))
        config_path.chmod(0o600)
    return request('tools/call', {'name': name, 'arguments': arguments},
                   config['session'])[0]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('arguments', nargs='?', default='{}')
    parser.add_argument('--save', type=Path)
    parser.add_argument('--quiet', action='store_true')
    args = parser.parse_args()
    result = call(args.name, json.loads(args.arguments))
    if args.save:
        args.save.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    if not args.quiet:
        for content in result.get('result', {}).get('content', []):
            if content.get('type') == 'text':
                print(content['text'])
    if result.get('error') or result.get('result', {}).get('isError'):
        raise SystemExit(1)
