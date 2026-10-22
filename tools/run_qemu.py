"""Run built ESP32-S3 adapter firmware in Espressif QEMU (native or Windows/WSL)."""
from pathlib import Path
import argparse, json, subprocess, sys, os, time, struct, binascii
ROOT=Path(__file__).resolve().parents[1]
def main():
    if hasattr(sys.stdout, 'reconfigure'):sys.stdout.reconfigure(errors='replace')
    parser=argparse.ArgumentParser()
    parser.add_argument('--qemu',required=True)
    parser.add_argument('--python',default=sys.executable)
    args=parser.parse_args()
    build=ROOT/'hardware/emulator/build'
    metadata=json.loads((build/'flasher_args.json').read_text())
    image=build/'qemu-flash.bin'
    command=[args.python,'-m','esptool','--chip','esp32s3','merge_bin','--fill-flash-size','8MB','-o',str(image)]
    for offset,name in metadata['flash_files'].items():command.extend([offset,str(build/name)])
    subprocess.run(command,check=True)
    executable=[args.qemu]
    original=image.read_bytes()
    app=(build/metadata['app']['file']).read_bytes()
    original=bytearray(original)
    original[0x300000:0x300000+len(app)]=app
    disk=str(image)
    if os.name=='nt':
        disk='/mnt/'+image.drive[0].lower()+image.as_posix()[2:]
        executable=['wsl','-d','Ubuntu','--',args.qemu]
    output=ROOT/'output/emulator';output.mkdir(parents=True,exist_ok=True)
    log=output/'qemu-s3.log'
    uart=str(log)
    if os.name=='nt':uart='/mnt/'+log.drive[0].lower()+log.as_posix()[2:]
    command=executable+['-M','esp32s3','-display','none','-monitor','none','-serial','file:'+uart,'-drive',f'file={disk},if=mtd,format=raw']
    combined=[]
    for scenario in [1,2]:
      staged=bytearray(original)
      for offset,seq,state in [(0x19000,1,2),(0x1a000,2,0)]:
        crc=binascii.crc32(struct.pack('<I',seq),0xffffffff)&0xffffffff
        staged[offset:offset+32]=struct.pack('<I20sII',seq,bytes([255])*20,state,crc)
      staged[0x5e0000]=scenario
      image.write_bytes(staged)
      log.write_text('')
      with (output/f'qemu-process-{scenario}.log').open('w') as stream:
        process=subprocess.Popen(command,stdout=stream,stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+45
            while time.monotonic()<deadline and process.poll() is None:
                time.sleep(.25)
                data=log.read_bytes()
                if b'CLICKER_S3_EMULATOR_PASS' in data:break
                if len(data)>200000 or b'abort() was called' in data or b'assert failed' in data:break
        finally:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill()
      result=log.read_text(errors='replace')
      (output/f'qemu-s3-{scenario}.log').write_text(result,encoding='utf-8')
      print(result[-5000:])
      required='startup confirmation PASS' if scenario==1 else 'failed-boot rollback PASS'
      if 'CLICKER_S3_EMULATOR_PASS' not in result or required not in result:raise SystemExit('S3 adapter emulation failed; see '+str(log))
      combined.append(result)
    log.write_text('\n'.join(combined),encoding='utf-8')
if __name__=='__main__':main()

