"""Fetch pinned build inputs. Clones live in ignored hardware/idf/components."""
from pathlib import Path
import json
import subprocess
import shutil

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'hardware/idf/deps'
DEPS = {
    'arduino': ('espressif/arduino-esp32', '94afccf35fb1e401facddbcf9e13bcf7c76a31d8'),
    'nimble': ('h2zero/NimBLE-Arduino', '5ae2c43f62c5a588a25c1de68f7d17b6f3b75adb'),
    'microlink-source': ('CamM2325/microlink', '216da3300f0493b0860247d43f7af5ce29df63a5'),
    'lib-builder': ('espressif/esp32-arduino-lib-builder', 'ce4c80a2f6cbf8c55ba246ffa2000fcdb33d9e6c'),
    'tinyusb-source': ('hathach/tinyusb', '702e55db3899885900b18c8d388a9cf92c624331'),
}

def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)

def main():
    BASE.mkdir(parents=True, exist_ok=True)
    for name, (repo, revision) in DEPS.items():
        dest = BASE / name
        if not (dest / '.git').exists():
            run('git', 'init', str(dest))
            run('git', 'remote', 'add', 'origin', f'https://github.com/{repo}.git', cwd=dest)
        head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=dest, capture_output=True, text=True)
        if head.stdout.strip() != revision:
            run('git', 'fetch', '--depth', '1', 'origin', revision, cwd=dest)
            run('git', 'checkout', '--detach', revision, cwd=dest)
    # Only the selected Arduino libraries are built; omit unrelated Matter/SR dependencies.
    (BASE / 'arduino/idf_component.yml').write_text('dependencies:\n  idf: ">=5.5,<5.6"\n  espressif/mdns: "1.11.2"\n  espressif/libsodium: "1.0.22"\n  joltwallet/littlefs: "1.22.1"\n', encoding='utf-8')
    (BASE / 'nimble/CMakeLists.txt').write_text('file(GLOB_RECURSE sources src/*.c src/*.cpp)\nidf_component_register(SRCS ${sources} INCLUDE_DIRS src REQUIRES arduino bt nvs_flash)\ntarget_compile_options(${COMPONENT_LIB} PRIVATE -Wno-error=overloaded-virtual -include "${CMAKE_CURRENT_LIST_DIR}/../../../hid_bridge/nimble_cfg.h")\n', encoding='utf-8')
    usb = BASE / 'lib-builder/components/arduino_tinyusb'
    shutil.copytree(BASE / 'tinyusb-source/src', usb / 'tinyusb/src', dirs_exist_ok=True)
    (usb / 'tinyusb/hw/bsp').mkdir(parents=True, exist_ok=True)
    print('Pinned build inputs ready.')

if __name__ == '__main__':
    main()
