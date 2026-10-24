"""LAN-only touch landing fixture; sends no input until run by a separate driver."""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PAGE = r'''<!doctype html><html lang="zh-Hant"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>20 pt 小按鈕測試</title><style>
*{box-sizing:border-box}html,body{margin:0;background:#101826;color:#e4eefa;font:15px system-ui;overflow:hidden;touch-action:none;height:100%}
#info{position:fixed;left:18px;right:18px;top:12px;pointer-events:none}h1{font-size:23px;margin:0 0 8px}p{margin:5px 0}#target{position:fixed;width:20px;height:20px;border:1px solid #7be5ff;background:#143d51;color:#fff;text-align:center;line-height:18px;font-size:14px;pointer-events:none}
#hit{position:fixed;width:8px;height:8px;background:#ffb454;border-radius:50%;pointer-events:none}#result{white-space:pre-wrap;font-size:13px}</style>
<div id="info"><h1>20 pt 小按鈕測試</h1><p id="label">等待 ESP32</p><p>觸點由 ESP32 藍牙滑鼠送出</p><p id="result"></p></div><div id="target">+</div><div id="hit"></div>
<script>
const target=document.querySelector('#target'),hit=document.querySelector('#hit');
let state={revision:0},sent=false;
function report(){return {w:innerWidth,h:innerHeight,dpr:devicePixelRatio,screenW:screen.width,screenH:screen.height,offsetTop:visualViewport?.offsetTop,offsetLeft:visualViewport?.offsetLeft}}
async function poll(){try{const s=await(await fetch('/state',{cache:'no-store'})).json();state=s;target.style.left=(s.x-10)+'px';target.style.top=(s.y-10)+'px';target.style.display=s.visible?'block':'none';document.querySelector('#label').textContent=s.label;document.querySelector('#result').textContent=s.result||'';if(!sent){sent=true;await fetch('/viewport',{method:'POST',body:JSON.stringify(report())})}}catch(e){}setTimeout(poll,100)}poll();
addEventListener('pointerdown',async e=>{e.preventDefault();const p={revision:state.revision,clientX:e.clientX,clientY:e.clientY,screenX:e.screenX,screenY:e.screenY,type:e.pointerType,stamp:performance.now(),...report()};hit.style.left=(e.clientX-4)+'px';hit.style.top=(e.clientY-4)+'px';await fetch('/event',{method:'POST',body:JSON.stringify(p)})},{passive:false});
</script></html>'''

class Fixture:
    def __init__(self, output):
        self.lock = threading.Condition()
        self.state = dict(revision=0, x=220, y=280, visible=True, label='等待 ESP32', result='')
        self.events = []
        self.viewport = None
        self.output = output
        output.parent.mkdir(parents=True, exist_ok=True)

    def record(self, kind, value):
        with self.lock:
            with self.output.open('a', encoding='utf-8') as f:
                f.write(json.dumps(dict(time=time.time(), kind=kind, value=value), ensure_ascii=False)+'\n')
            if kind == 'event': self.events.append(value)
            if kind == 'viewport': self.viewport = value
            self.lock.notify_all()

    def update(self, **values):
        with self.lock:
            self.state.update(values)
            self.state['revision'] += 1
            return self.state['revision']

    def next_event(self, after, timeout=4):
        deadline = time.monotonic()+timeout
        with self.lock:
            while len(self.events) <= after:
                left=deadline-time.monotonic()
                if left<=0: return None
                self.lock.wait(left)
            return self.events[after]

def serve(fixture, host, port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            if self.path == '/state':
                with fixture.lock: data=json.dumps(fixture.state).encode()
                mime='application/json'
            elif self.path == '/events':
                with fixture.lock: data=json.dumps(dict(events=fixture.events,viewport=fixture.viewport)).encode()
                mime='application/json'
            else: data=PAGE.encode();mime='text/html; charset=utf-8'
            self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        def do_POST(self):
            size=int(self.headers.get('Content-Length','0'))
            if not 0<size<=16384: self.send_error(400);return
            try: value=json.loads(self.rfile.read(size))
            except ValueError: self.send_error(400);return
            if self.path=='/state': fixture.update(**value)
            elif self.path in ('/event','/viewport'): fixture.record(self.path[1:],value)
            else: self.send_error(404);return
            self.send_response(204);self.end_headers()
    return ThreadingHTTPServer((host,port),Handler)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--host',default='192.168.2.200');p.add_argument('--port',type=int,default=8771);p.add_argument('--output',type=Path,default=Path('output/phone-accuracy/events.jsonl'));a=p.parse_args()
    print(f'Fixture http://{a.host}:{a.port}',flush=True)
    serve(Fixture(a.output),a.host,a.port).serve_forever()
