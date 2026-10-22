from pathlib import Path
import subprocess
import shutil
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'output/host'
OUT.mkdir(parents=True,exist_ok=True)
compiler=shutil.which('clang++') or shutil.which('g++')
if not compiler:raise SystemExit('Install clang++ or g++')
for name in ['clicker_test','screen_capture']:
    exe=OUT/(name+('.exe' if __import__('os').name=='nt' else ''))
    subprocess.run([compiler,'-std=c++17','-O2','-Wall','-Wextra','-Werror',str(ROOT/f'hardware/tests/{name}.cpp'),'-o',str(exe)],check=True)
    subprocess.run([str(exe)]+([str(ROOT/'output/screens')] if name=='screen_capture' else []),check=True)
subprocess.run([__import__('sys').executable,str(ROOT/'tools/test_ota.py')],check=True)
