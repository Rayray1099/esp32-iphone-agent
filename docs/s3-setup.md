# ESP32-S3 N8R8 screen clicker

This branch extends Henry Yuan's ESP32 iPhone Agent. Saved USB sequences run
without the app, internet, Wi-Fi or Bluetooth. Upstream AI, BLE and AirPlay
sources remain included. Bluetooth output is also available and keeps Bluetooth
on in offline mode. Partial physical validation is documented in
[the validation report](s3-validation.md).

## Hardware profile

| Signal | GPIO / configuration |
| --- | --- |
| Chip / memory | ESP32-S3, fixed 8 MB layout, 8 MB octal PSRAM |
| Display | ST7789, 320 x 240 landscape |
| MOSI / SCK / CS / DC / RESET | 5 / 2 / 15 / 6 / 7 |
| Backlight | 16, active low |
| BOOT | 0, active low |
| Native USB D- / D+ | 19 / 20 |

The pin map comes from the supplied board CSV. A CH340 connector cannot act as
the phone's USB mouse. Verify which connector exposes native USB when the board
arrives. The user confirmed the status pages display correctly. The connected
board reports 16 MB physical flash; the fixed partition layout still uses 8 MB.

## Reproducible Windows build

Install ESP-IDF **v5.5.2**, Git, Python and the ESP32-S3 IDF tools. From PowerShell
in the repository:

~~~powershell
./tools/build.ps1 -IdfPath E:/tools/esp-idf-v5.5.2
~~~

Paths containing spaces are supported. tools/bootstrap.py fetches fixed Git
commits; managed component versions are pinned in hardware/idf/dependencies.lock.
Arduino **3.3.12** runs as an IDF component alongside NimBLE **2.5.1**, TinyUSB
and pinned MicroLink. Use this IDF build for screen, enterprise Wi-Fi and OTA;
the older hardware/flash.sh is the upstream Arduino build.

After checking the board and correct serial port:

~~~powershell
./tools/build.ps1 -IdfPath E:/tools/esp-idf-v5.5.2 -Flash -Port COM7
~~~

Initial USB flashing installs bootloader, fixed partition table, OTA data and
application. Routine OTA changes the inactive app slot. Decide on backup and
recovery for any firmware already on the board before initial flashing. This
board was backed up (all 16 MB), erased and flashed on 2026-10-22. Recovery
files stay in the private local output folder and are excluded from source delivery.

## Setup and offline execution

1. Boot stopped. The TFT rotates through Run, Connections, System and Setup.
   Join the random-password hotspot shown on the setup page, or scan its Wi-Fi
   QR code. Open http://192.168.4.1.
2. Enter the 32-character controller token on the TFT. It stays in tab memory.
   The board serves every browser asset locally.
3. Enable AssistiveTouch mouse support and lock phone orientation. Calibrate
   measured horizontal/vertical HID travel. Assign a calibration ID such as
   my-iphone or my-ipad. Profiles and calibration must use the same ID and
   orientation. Older profiles use default.
4. Import a screenshot or use the grid. Add/drag numbered targets and edit press
   duration and delay after release. Save each profile in slot 0 through 31.
5. Enter up to 16 saved slots in Concurrent profiles. Each move/press/release
   completes before another target owns the single pointer.
6. Start, or choose Switch to offline. This remembers the group, restarts with
   Wi-Fi off, and stays stopped until BOOT starts the selection. USB mode also
   disables Bluetooth; Bluetooth mouse mode retains its radio for wireless clicks.

| BOOT action | Result |
| --- | --- |
| Short idle press | Cycle saved single profiles |
| Hold 1 second, release | Start selected profile or remembered group |
| Press while running | Stop and release input |
| Hold 4 seconds idle, release | Restart into hotspot setup |

The last configured group is remembered. Multiple named groups are not yet
available in the BOOT cycle. A short press changes selection to a single profile.
Closing the app or losing BLE does not stop an independent clicker run. USB
disconnect stops it; release is retried when USB returns. Keep the phone awake
and pointer settings unchanged.

Timings accept integer microseconds from 1 to 3,600,000,000. **1 microsecond
settings do not produce a one-million-CPS mouse.** Full-speed USB and iOS limit
actual taps. 150 CPS is a USB hardware target, not a measured result. Bluetooth requested
50 CPS produced 43.88 BLE submissions/s in the latest offline 300-click test;
the game accepted fewer taps. Connected Wi-Fi can reduce throughput. Displayed USB
CPS uses completed clicks after initial homing. Distant targets are slower.

## eduroam

Use your **school email as the full username and your password**. Leave outer
identity blank in the web form to reuse the username, or enter the school's
anonymous identity. PEAP uses the IDF supplicant's negotiated MSCHAPv2/GTC inner
methods. TTLS supports MSCHAPv2, PAP or EAP. EAP-TLS uses client certificates.

The trusted CA and authentication server DNS name must come from the school's
official configuration. TCIVS's current realm, CA and server are not established
by another school's guide; none are hardcoded. Server and certificate checks
remain enabled. The S3 supports 2.4 GHz Wi-Fi.

Setup sends current time for certificate date validation. A cold boot without
a valid clock may require setup to supply time before eduroam connects. This
version has no battery-backed RTC. After connection it requests NTP. AP+station
mode keeps direct setup and AirPlay available if school clients are isolated.
Failed joins use backoff and eventually enable a recovery hotspot.

School credentials stay in board NVS and are omitted from status, logs and
profile exports. This build does not enable flash encryption or irreversible
eFuses. Use the protected hotspot or a trusted LAN for local HTTP, and the
encrypted tailnet path for internet diagnostics.

## Tailscale diagnostics

Create a dedicated enrollment key in your own Tailscale account. Enter it in
Remote & updates, choose a device name and enable Tailscale. Pinned MicroLink
provides a community Tailscale-compatible client with 4 peers, persistent
identity, STUN and DERP fallback. Its separate setup server is disabled.
No public Funnel is created.

Open http://BOARD-TAILNET-IP from an authorized tailnet device and enter the
controller token. View BMP screen snapshots, recent events, task/memory data,
run controls, reboot and signed OTA. Keys are absent from source and packages.
Enrollment, reconnect and relay behavior still need actual board testing.

## Signed OTA and recovery

Two 0x2e0000 app slots use ESP-IDF rollback. The Ed25519 signature binds board
ID, version, image size and SHA256. Firmware contains only the public key.
Keep the private signing key outside the repository.

~~~powershell
python tools/ota.py pack --private E:/ESP32-signing/s3-clicker-ed25519.pem --image hardware/idf/build/s3_clicker.bin --version 0.3.0 --output output/delivery/s3-clicker-0.3.0.ota
~~~

Upload the .ota file in Remote & updates. Input is released before flash writes.
The board verifies stream hash, IDF image and project before switching slots.
It confirms after 10 seconds of storage/task/display/PSRAM health checks; an
unconfirmed image rolls back at reboot. Profiles/settings are preserved.
Production HTTP uploads and flash-write interruption still need hardware tests.
For recovery hold BOOT while resetting into the ROM loader and use USB flashing.
Changing the trusted signing key requires a matching firmware/trust migration.

## iPhone and iPad app

On macOS install XcodeGen, run xcodegen generate inside ios/, then open the
project. Copy Config/Local.xcconfig.example to Local.xcconfig and set your Apple
development team and bundle ID. Build the IPhoneAgent scheme for your device.
The Traditional Chinese PULSE 連點器 tab opens the live CPS dashboard by default
and offers screenshot/frozen-mirror targets, JSON import/export,
BLE chunk upload/download, calibration and saved run controls. The hotspot page
has the full network and remote/OTA forms; native network configuration currently
uses a JSON editor. TestFlight or a signed IPA requires your Apple signing
account. Simulator tests do not produce a device-installable IPA.

See [API details](s3-api.md) and [validation/remaining work](s3-validation.md).

## One phone controlling another

With the target owner's agreement, pair the ESP32 mouse to the target phone and
enable AssistiveTouch. Connect the controller phone to the board hotspot and
use its authenticated web dashboard at http://192.168.4.1. Save calibration
for the target phone. The single pointer clicks targets in order; it does not
produce simultaneous multitouch. Viewing the target screen requires separate
mirroring. Two physical phones have not yet been tested together.
