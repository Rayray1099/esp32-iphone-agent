"""Measure actual ESP32 Bluetooth taps in phone_accuracy_server's Safari fixture."""
import argparse
import json
import time
import urllib.request
from pathlib import Path
from board_uart import BoardUART

def request(path, data=None):
    body=json.dumps(data).encode() if data is not None else None
    with urllib.request.urlopen(urllib.request.Request('http://192.168.2.200:8771/'+path, data=body),timeout=4) as r:
        return json.load(r) if body is None else None

def fit(samples,axis):
    u=[s['units'][axis] for s in samples];v=[s['landed'][axis] for s in samples]
    mu=sum(u)/len(u);mv=sum(v)/len(v)
    a=sum((x-mu)*(y-mv) for x,y in zip(u,v))/sum((x-mu)**2 for x in u)
    return a,mv-a*mu

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--top',type=float,required=True,help='Verified Safari content origin in screen points');p.add_argument('--home-every',type=int,default=10);p.add_argument('--settle',type=float,default=0,help='Hardware motion settling interval in seconds');p.add_argument('--output',type=Path,default=Path('output/phone-accuracy/measured.json'));a=p.parse_args()
    samples=[];measurements=[];claimed=False;b=BoardUART()
    def command(c):
        r=b.command(c)
        if not r.startswith('ok'): raise RuntimeError(c+': '+r)
        if c == 'home' or c.startswith('move '): time.sleep(a.settle)
    def click():
        n=len(request('events')['events']);command('click');deadline=time.monotonic()+4
        while time.monotonic()<deadline:
            e=request('events')['events']
            if len(e)>n:
                item=e[n];return [item['clientX'],item['clientY']+a.top]
            time.sleep(0.03)
        raise RuntimeError('Physical click did not reach Safari')
    try:
        s=b.api('status');assert not s['running'] and s['mouse_connected'] and s['output']=='bluetooth',s
        b.api('input/claim','POST',{})
        claimed=True
        for ux,uy in [(100,400),(350,400),(220,650),(100,900),(350,900)]:
            request('state',dict(label='校正：ESP32 實際觸點',visible=False))
            command('home');command(f'move {ux} {uy}');landed=click()
            samples.append(dict(units=[ux,uy],landed=landed));print('Calibration',samples[-1],flush=True)
        lines=[fit(samples,i) for i in [0,1]]
        targets=[(.16,.34),(.84,.72),(.50,.47),(.84,.34),(.16,.55),(.50,.72),(.84,.47),(.16,.72),(.50,.34),(.84,.55),(.16,.47),(.50,.55)]
        pos=None;moves=0
        for i,(fx,fy) in enumerate(targets+targets[::-1]):
            tx=fx*440;ty=fy*956;units=[round((v-bias)/gain) for v,(gain,bias) in zip([tx,ty],lines)]
            request('state',dict(x=tx,y=ty-a.top,visible=True,label=f'20 pt 小目標 {i+1}/24'))
            if pos is None or moves>=a.home_every: command('home');pos=[0,0];moves=0
            command(f'move {units[0]-pos[0]} {units[1]-pos[1]}');pos=units;moves+=1
            landed=click();error=[landed[0]-tx,landed[1]-ty]
            row=dict(target=[tx,ty],units=units,landed=landed,error=error,hit=max(map(abs,error))<=10)
            measurements.append(row);print('Target',i+1,row,flush=True)
        hits=sum(r['hit'] for r in measurements);dy=sum(r['error'][1] for r in measurements)/len(measurements);worst=max(abs(e) for r in measurements for e in r['error'])
        result=dict(transport='physical ESP32 Bluetooth mouse via UART control',screen=[440,956],safari_content_top=a.top,target_side=20,home_every=a.home_every,settle_seconds=a.settle,calibration=samples,fit=lines,measurements=measurements,hits=hits,total=len(measurements),mean_dy=dy,max_axis_error=worst)
        a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
        summary=f'{hits}/24 hit; mean dy {dy:+.1f} pt; max error {worst:.1f} pt'
        request('state',dict(label='測試完成',visible=False,result=summary));print(summary,flush=True)
    finally:
        try:
            if claimed:
                try:
                    command('release')
                finally:
                    b.api('input/release','POST',{})
        finally:
            b.close()

if __name__=='__main__':main()
