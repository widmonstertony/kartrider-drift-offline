"""Call the user's local iOS MCP service, preserving structured inspection results."""
import argparse
import json
import os
import re
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT/'runtime/device.json'
BASE = os.environ.get('IOS_MCP_URL')
if not BASE and CONFIG.exists():
    BASE = json.loads(CONFIG.read_text()).get('url')

def call(name, arguments):
    if not BASE:
        raise ValueError('Set IOS_MCP_URL to the URL of your own iOS MCP service.')
    headers_path = ROOT/'analysis/ios-mcp-init.headers'
    if not headers_path.exists():
        request = urllib.request.Request(BASE.rstrip('/')+'/mcp',data=json.dumps({
            'jsonrpc':'2.0','id':1,'method':'initialize','params':{
                'protocolVersion':'2025-11-25','capabilities':{},
                'clientInfo':{'name':'kartdrift-offline-research','version':'0.1.0'}}}).encode(),
            headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'})
        with urllib.request.urlopen(request,timeout=15) as response:
            headers_path.parent.mkdir(parents=True,exist_ok=True)
            headers_path.write_text(str(response.headers))
            response.read()
        headers_path.chmod(0o600)
    headers_text = headers_path.read_text()
    match = re.search(r'Mcp-Session-Id: ([^\r\n]+)',headers_text,re.I)
    if not match:
        raise ValueError('The MCP service did not return a session ID.')
    session = match.group(1)
    request = urllib.request.Request(BASE.rstrip('/')+'/mcp',data=json.dumps({
        'jsonrpc':'2.0','id':10,'method':'tools/call',
        'params':{'name':name,'arguments':arguments}}).encode(),headers={
        'Content-Type':'application/json','Accept':'application/json, text/event-stream',
        'Mcp-Session-Id':session,'MCP-Protocol-Version':'2025-11-25'})
    with urllib.request.urlopen(request,timeout=240 if name=='install_app' else 45) as response:
        result = json.load(response)
    return result

if __name__ == '__main__':
    p=argparse.ArgumentParser()
    p.add_argument('name')
    p.add_argument('arguments',nargs='?',default='{}')
    p.add_argument('--save')
    p.add_argument('--quiet',action='store_true')
    args=p.parse_args()
    result=call(args.name,json.loads(args.arguments))
    if args.save:
        (ROOT/'analysis'/args.save).write_text(json.dumps(result,ensure_ascii=False,indent=2))
    if not args.quiet:
        result=result.get('result',result)
        if 'structuredContent' in result:
            print(json.dumps(result['structuredContent'],ensure_ascii=False,indent=2))
        else:
            for c in result.get('content',[]):
                if c['type']=='text':print(c['text'])
    if result.get('error') or result.get('result',result).get('isError'):
        raise SystemExit(1)
