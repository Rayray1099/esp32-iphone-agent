"""Run built ESP32-S3 adapter firmware in Espressif QEMU (native or Windows/WSL)."""
from pathlib import Path
import argparse, json, subprocess, sys, os, time
ROOT=Path(__file__).resolve().parents[1]
def main():
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
    disk=str(image)
    if os.name=='nt':
        disk='/mnt/'+image.drive[0].lower()+image.as_posix()[2:]
        executable=['wsl','-d','Ubuntu','--',args.qemu]
    output=ROOT/'output/emulator';output.mkdir(parents=True,exist_ok=True)
    log=output/'qemu-s3.log'
    uart=str(log)
    if os.name=='nt':uart='/mnt/'+log.drive[0].lower()+log.as_posix()[2:]
    command=executable+['-M','esp32s3','-display','none','-monitor','none','-serial','file:'+uart,'-drive',f'file={disk},if=mtd,format=raw']
    log.write_text('')
    with (output/'qemu-process.log').open('w') as stream:
        process=subprocess.Popen(command,stdout=stream,stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+45
            while time.monotonic()<deadline and process.poll() is None:
                time.sleep(.25)
                if 'CLICKER_S3_EMULATOR_PASS' in log.read_text(errors='replace'):break
        finally:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill()
    result=log.read_text(errors='replace');print(result[-8000:])
    if 'CLICKER_S3_EMULATOR_PASS' not in result:raise SystemExit('S3 adapter emulation failed; see '+str(log))
if __name__=='__main__':main()

