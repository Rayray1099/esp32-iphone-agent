'use strict';
const $ = id => document.getElementById(id);
const state = {token:'',points:[{x:5000,y:5000,press_us:1000,delay_us:5000,enabled:true}],selected:0,dirty:false,pointer:{x:0,y:0},received:0,background:null};
const tell = (message,error=false) => { $('notice').textContent=message;$('notice').classList.toggle('error',error); };
async function api(path,method='GET',body) {
  const response=await fetch('/api/v1/'+path,{method,headers:{Authorization:'Bearer '+state.token,...(body===undefined?{}:{'Content-Type':'application/json'})},body:body===undefined?undefined:JSON.stringify(body)});
  const raw=await response.text();let data;try{data=JSON.parse(raw);}catch{data={error:raw};}
  if(!response.ok)throw new Error(data.error||('Request failed: '+response.status));return data;
}
const action=fn=>async event=>{try{await fn(event);}catch(error){tell(error.message,true);}};
const uint=(value,min=1,max=3600000000)=>{const n=Number(value);if(!Number.isSafeInteger(n)||n<min||n>max)throw new Error(`Enter an integer from ${min} to ${max}.`);return n;};
function profile(){return {schema:1,name:$('name').value.trim(),repeats:uint($('repeats').value,0,1000000000),landscape:$('orientation').value==='landscape',fast:false,points:state.points};}
function validate(p){if(!p||typeof p.name!=='string'||!p.name.trim()||new TextEncoder().encode(p.name).length>48||!Array.isArray(p.points)||p.points.length<1||p.points.length>1000)throw new Error('A profile needs a name and 1–1000 targets.');
  uint(p.repeats??0,0,1000000000);let enabled=false;for(const q of p.points){uint(q.x,0,10000);uint(q.y,0,10000);uint(q.press_us);uint(q.delay_us);enabled ||= q.enabled!==false;}if(!enabled)throw new Error('Enable at least one target.');return p;}
function dirty(){state.dirty=true;}
function addPoint(x=5000,y=5000){if(state.points.length>=1000)throw new Error('Maximum 1,000 targets per profile.');state.points.push({x,y,press_us:1000,delay_us:5000,enabled:true});state.selected=state.points.length-1;dirty();render();}
function render(){
  const markers=$('markers');markers.replaceChildren();$('points').replaceChildren();$('targetCount').textContent=state.points.length+' target'+(state.points.length===1?'':'s');
  $('canvas').classList.toggle('landscape',$('orientation').value==='landscape');$('canvasHint').hidden=state.points.length>1||!!state.background;
  state.points.forEach((q,i)=>{const marker=document.createElement('button');marker.type='button';marker.className='marker'+(state.selected===i?' selected':'')+(q.enabled?'':' disabled');
    marker.textContent=String(i+1);marker.setAttribute('aria-label',`Target ${i+1}, x ${q.x}, y ${q.y}`);marker.style.left=q.x/100+'%';marker.style.top=q.y/100+'%';
    marker.addEventListener('pointerdown',event=>{event.stopPropagation();state.selected=i;marker.setPointerCapture(event.pointerId);marker.classList.add('selected');});
    marker.addEventListener('pointermove',event=>{if(!marker.hasPointerCapture(event.pointerId))return;const r=$('canvas').getBoundingClientRect();q.x=Math.round(Math.max(0,Math.min(10000,(event.clientX-r.left)/r.width*10000)));q.y=Math.round(Math.max(0,Math.min(10000,(event.clientY-r.top)/r.height*10000)));marker.style.left=q.x/100+'%';marker.style.top=q.y/100+'%';dirty();});
    marker.addEventListener('pointerup',event=>{marker.releasePointerCapture(event.pointerId);render();});markers.append(marker);
    const row=document.createElement('div');row.className='point-row';const n=document.createElement('span');n.className='point-number';n.textContent='#'+(i+1);row.append(n);
    const enabled=document.createElement('input');enabled.type='checkbox';enabled.checked=q.enabled;enabled.setAttribute('aria-label',`Enable target ${i+1}`);enabled.onchange=()=>{q.enabled=enabled.checked;dirty();render();};row.append(enabled);
    for(const [key,label,max] of [['x','X',10000],['y','Y',10000],['press_us','Press µs',3600000000],['delay_us','After µs',3600000000]]){const wrap=document.createElement('label');wrap.textContent=label;const input=document.createElement('input');input.type='number';input.min=key==='x'||key==='y'?'0':'1';input.max=String(max);input.value=q[key];input.setAttribute('aria-label',`${label} target ${i+1}`);input.onchange=action(()=>{q[key]=uint(input.value,Number(input.min),max);dirty();render();});wrap.append(input);row.append(wrap);}
    const tools=document.createElement('div');tools.className='tools';
    for(const [label,title,fn] of [['↑','Move up',()=>{if(i){[state.points[i-1],state.points[i]]=[state.points[i],state.points[i-1]];}}],['↓','Move down',()=>{if(i+1<state.points.length){[state.points[i+1],state.points[i]]=[state.points[i],state.points[i+1]];}}],['⧉','Duplicate',()=>{if(state.points.length>=1000)throw new Error('Maximum 1,000 targets.');state.points.splice(i+1,0,{...q});}],['×','Delete',()=>{if(state.points.length===1)throw new Error('Keep at least one target.');state.points.splice(i,1);}]]){const button=document.createElement('button');button.textContent=label;button.setAttribute('aria-label',`${title} target ${i+1}`);button.onclick=action(()=>{fn();dirty();render();});tools.append(button);}row.append(tools);$('points').append(row);
  });
}
function applyProfile(p){validate(p);$('name').value=p.name;$('repeats').value=p.repeats??0;$('orientation').value=p.landscape?'landscape':'portrait';state.points=p.points.map(q=>({...q,enabled:q.enabled!==false}));state.selected=0;state.dirty=false;render();}
async function save(){const p=validate(profile());await api('profiles/'+$('slot').value,'PUT',p);state.dirty=false;tell('Profile verified and saved on the board.');}
async function refresh(){try{const s=await api('status');$('connection').textContent=s.running?'● Running':'● Board connected';$('authPanel').hidden=true;$('status').textContent=JSON.stringify(s,null,2);
  const metrics=[['USB clicks',s.clicks??0],['USB CPS',Number(s.usb_cps??0).toFixed(1)],['Schedules',s.active??0],['Late events',s.late??0]];$('runStats').replaceChildren();for(const [label,value]of metrics){const card=document.createElement('div');card.className='stat';const strong=document.createElement('strong');strong.textContent=value;const span=document.createElement('span');span.textContent=label;card.append(strong,span);$('runStats').append(card);}return s;
}catch(error){$('connection').textContent='○ Not connected';throw error;}}
for(let i=0;i<32;i++){const o=document.createElement('option');o.value=i;o.textContent='Slot '+i;$('slot').append(o);}
document.querySelectorAll('[data-tab]').forEach(button=>button.onclick=()=>{document.querySelectorAll('.tab').forEach(tab=>tab.hidden=tab.id!==button.dataset.tab);document.querySelectorAll('[data-tab]').forEach(b=>b.classList.toggle('active',b===button));});
$('connect').onclick=action(async()=>{state.token=$('token').value.trim();if(state.token.length!==32)throw new Error('Enter the 32-character controller token shown on the board.');await refresh();tell('Connected. Profiles run independently after saving.');});
$('add').onclick=action(()=>addPoint());$('canvas').onpointerdown=action(event=>{if(event.target.closest('.marker'))return;const r=$('canvas').getBoundingClientRect();addPoint(Math.round((event.clientX-r.left)/r.width*10000),Math.round((event.clientY-r.top)/r.height*10000));});
$('orientation').onchange=()=>{dirty();render();};$('name').oninput=dirty;$('repeats').oninput=dirty;$('slot').onchange=()=>{$('schedules').value=$('slot').value;};
$('zoom').oninput=()=>{$('canvas').style.width=$('zoom').value+'%';};
$('screenshot').onchange=action(event=>{const file=event.target.files[0];if(!file)return;if(file.size>20000000)throw new Error('Choose an image smaller than 20 MB.');if(state.background)URL.revokeObjectURL(state.background);state.background=URL.createObjectURL(file);$('background').src=state.background;$('background').hidden=false;render();});
$('applyDelay').onclick=action(()=>{const delay=uint(Number($('bulkDelay').value)*Number($('bulkUnit').value));state.points.forEach(q=>q.delay_us=delay);dirty();render();});
$('fast').onclick=action(()=>{const cps=uint($('cps').value,1,500);const period=Math.round(1000000/cps);state.points.forEach(q=>{q.press_us=1000;q.delay_us=Math.max(1,period-1000);});dirty();render();tell(`Requested ${cps} CPS per sequence before movement and USB limits. USB output will be measured during execution.`);});
$('save').onclick=action(save);$('load').onclick=action(async()=>{applyProfile(await api('profiles/'+$('slot').value));tell('Loaded the saved board profile.');});
$('export').onclick=action(()=>{const p=validate(profile()),blob=new Blob([JSON.stringify(p,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='clicker-profile.json';a.click();URL.revokeObjectURL(url);});
$('import').onchange=action(async event=>{const file=event.target.files[0];if(!file)return;if(file.size>196608)throw new Error('Profile file too large.');applyProfile(JSON.parse(await file.text()));dirty();tell('Imported. Save to the board before starting.');});
$('start').onclick=action(async()=>{if(state.dirty)throw new Error('Save your edited profile to the board first.');const profiles=$('schedules').value.split(',').map(x=>uint(x.trim(),0,31));if(profiles.length>16)throw new Error('Choose up to 16 schedules.');await api('run/start','POST',{profiles,nonce:crypto.randomUUID?crypto.randomUUID():('web-'+Date.now()+'-'+Math.random())});tell('Saved profiles started. BOOT stops input immediately.');await refresh();});
$('stop').onclick=action(async()=>{await api('run/stop','POST',{});tell('Stop requested; held input will be released.');await refresh();});
$('offline').onclick=action(async()=>{await save();await api('mode/offline','POST',{});tell('Restarting with both radios off. Use BOOT to select a profile, hold 1 second and release to start; hold 4 seconds while idle to return to setup.');});
$('saveCalibration').onclick=action(async()=>{await api('calibration','PUT',{span_x:uint($('spanX').value,1,32000),span_y:uint($('spanY').value,1,32000),landscape:$('calOrientation').value==='landscape',move_interval_us:8000,rehome_loops:10});tell('Calibration saved for this orientation.');});
document.querySelectorAll('[data-nudge]').forEach(button=>button.onclick=action(async()=>{await api('pointer','POST',{command:'move '+button.dataset.nudge});const [x,y]=button.dataset.nudge.split(' ').map(Number);state.pointer.x=Math.max(0,state.pointer.x+x);state.pointer.y=Math.max(0,state.pointer.y+y);}));
$('home').onclick=action(async()=>{await api('pointer','POST',{command:'home'});state.pointer={x:0,y:0};tell('Pointer homed to top left.');});
$('record').onclick=action(()=>{const x=uint($('spanX').value,1,32000),y=uint($('spanY').value,1,32000);addPoint(Math.min(10000,Math.round(state.pointer.x/x*10000)),Math.min(10000,Math.round(state.pointer.y/y*10000)));tell('Recorded the current pointer estimate as a target.');});
$('testSurface').onclick=event=>{state.received++;$('received').textContent=state.received+' taps received';$('testSurface').dataset.lastPosition=event.offsetX+','+event.offsetY;};
$('capture').onclick=action(async()=>{const r=await fetch('/api/v1/screen',{headers:{Authorization:'Bearer '+state.token}});if(!r.ok)throw new Error(await r.text());const old=$('screen').src;$('screen').src=URL.createObjectURL(await r.blob());if(old.startsWith('blob:'))URL.revokeObjectURL(old);});
$('networkForm').onsubmit=action(async event=>{event.preventDefault();const method=$('eapMethod').value,body={mode:$('netMode').value,ssid:$('ssid').value,pass:method==='personal'?$('password').value:'',unix_time:Math.floor(Date.now()/1000)};
  if(method!=='personal')body.eap={method,identity:$('identity').value,username:$('username').value,password:$('password').value,server:$('serverName').value,ca:$('ca').value,phase2:$('phase2').value,client_cert:$('clientCert').value,client_key:$('clientKey').value};
  await api('network','PUT',body);$('password').value='';$('clientKey').value='';tell('Network settings accepted. Reconnect through the hotspot if school Wi-Fi changes its channel or rejects authentication.');});
$('vpnEnable').onclick=action(async()=>{await api('tailscale','PUT',{enabled:true,name:$('vpnName').value,auth_key:$('vpnKey').value});$('vpnKey').value='';tell('Tailscale enrollment started. Watch connection diagnostics for the assigned IP.');});
$('vpnDisable').onclick=action(async()=>{await api('tailscale','PUT',{enabled:false});tell('Tailscale disabled.');});
$('update').onclick=action(async()=>{const file=$('otaFile').files[0];if(!file)throw new Error('Select a signed .ota package.');if(file.size>0x2e0000+172)throw new Error('Package is too large for this board.');
  await new Promise((resolve,reject)=>{const request=new XMLHttpRequest();request.open('POST','/api/v1/ota');request.setRequestHeader('Authorization','Bearer '+state.token);request.upload.onprogress=event=>{if(event.lengthComputable){$('otaProgress').value=event.loaded/event.total*100;$('otaMessage').textContent='Uploading '+Math.round(event.loaded/event.total*100)+'%';}};request.onload=()=>request.status<300?resolve():reject(new Error(request.responseText));request.onerror=()=>reject(new Error('Upload interrupted. The previous boot slot remains selected.'));request.send(file);});$('otaMessage').textContent='Verified. Board restarting; reconnect in a few seconds.';});
$('reboot').onclick=action(async()=>{await api('system/reboot','POST',{});tell('Board restarting.');});
let logTimer;
$('logToggle').onclick=action(async()=>{
  if(logTimer){clearInterval(logTimer);logTimer=null;$('logToggle').textContent='Stream event log';return;}
  const update=async()=>{$('eventLog').textContent=JSON.stringify(await api('logs'),null,2);};
  await update();logTimer=setInterval(()=>update().catch(()=>{}),1500);$('logToggle').textContent='Stop log stream';
});
$('taskStats').onclick=action(async()=>{$('taskInfo').textContent=JSON.stringify(await api('system/tasks'),null,2);});
setInterval(()=>{if(state.token)refresh().catch(()=>{});},2000);render();
