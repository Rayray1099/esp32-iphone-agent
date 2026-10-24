"""LAN-only synthetic keyboard fixture. Never enter personal text on this page."""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PAGE = '''<!doctype html><html lang="zh-Hant"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ESP32 keyboard test</title><style>body{background:#101826;color:#e4eefa;font:18px system-ui;padding:16px}input{font:24px monospace;width:95%;padding:12px}pre{font:13px monospace;white-space:pre-wrap}</style>
<h1>ESP32 英文輸入測試</h1><p>僅輸入測試字串，不要輸入私人資料。</p>
<input id="test" aria-label="ESP32 keyboard test" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
<button onclick="field.value='';send({type:'reset'})">清空</button><pre id="log"></pre>
<script>
const field=document.querySelector('#test'), log=document.querySelector('#log');
let sequence=0;
function send(e){e.sequence=++sequence;log.textContent=JSON.stringify(e)+'\\n'+log.textContent.slice(0,3000);fetch('/event',{method:'POST',body:JSON.stringify(e)})}
for(const type of ['keydown','keyup','beforeinput','input','compositionstart','compositionupdate','compositionend'])
field.addEventListener(type,e=>send({type,key:e.key,code:e.code,data:e.data,inputType:e.inputType,composing:e.isComposing,ctrl:e.ctrlKey,shift:e.shiftKey,meta:e.metaKey,value:field.value,time:performance.now()}));
</script></html>'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--port', type=int, default=8767)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    record_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            data = PAGE.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)
        def do_POST(self):
            length = int(self.headers.get('Content-Length', 0))
            if self.path != '/event' or not 0 < length <= 8192:
                self.send_error(400); return
            event = json.loads(self.rfile.read(length))
            with record_lock, args.output.open('a', encoding='utf-8') as file:
                file.write(json.dumps({'time': time.time(), 'event': event}, ensure_ascii=False)+'\n')
            self.send_response(204); self.end_headers()

    print(f'Keyboard fixture listening on {args.port}', flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()

if __name__ == '__main__': main()
