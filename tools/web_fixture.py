"""Browser-only fixture. It does not emulate firmware, Wi-Fi or USB."""
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from pathlib import Path
import json
import argparse
ROOT=Path(__file__).resolve().parents[1]
PROFILES={}
STATUS={'running':False,'clicks':0,'usb_cps':0,'active':0,'late':0,'network':{'mode':'ap','ssid':'ESP32Agent-DEMO','ip':'192.168.4.1'},'tailscale':{'state':'disabled'},'fixture':True}
class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs):super().__init__(*args,directory=str(ROOT/'web'),**kwargs)
    def log_message(self,*args):pass
    def do_GET(self):
        if self.path.startswith('/api/v1/'):return self.api()
        return super().do_GET()
    def do_POST(self):self.api()
    def do_PUT(self):self.api()
    def do_DELETE(self):self.api()
    def api(self):
        if self.headers.get('Authorization')!='Bearer '+('0'*32):
            self.send_response(401);self.end_headers();self.wfile.write(b'{"error":"Invalid fixture token"}');return
        path=self.path.removeprefix('/api/v1/')
        data=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))) or b'{}')
        result={'ok':True};code=200
        if path=='status':result=STATUS
        elif path.startswith('profiles/'):
            slot=path.split('/')[1]
            if self.command=='GET':result=PROFILES.get(slot,{'name':'Fixture profile','repeats':0,'landscape':False,'points':[{'x':5000,'y':5000,'press_us':1000,'delay_us':5000,'enabled':True}]})
            else:PROFILES[slot]=data
        elif path=='run/start':STATUS.update(running=True,active=len(data['profiles']))
        elif path=='run/stop':STATUS.update(running=False,active=0)
        elif path=='mode/offline':STATUS.update(running=False,active=0)
        elif path=='screen':
            image=ROOT/'output/screens/tft-0.bmp'
            self.send_response(200);self.send_header('Content-Type','image/bmp');self.end_headers();self.wfile.write(image.read_bytes());return
        self.send_response(code);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(json.dumps(result).encode())
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8098);args=parser.parse_args()
    print(f'Browser fixture http://127.0.0.1:{args.port}; token: 32 zeros',flush=True)
    ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
