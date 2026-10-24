# PULSE 0.3.2 / iOS 1.1 build 5 validation - 2026-10-23

Firmware 0.3.2 is flashed on the physical ESP32-S3. PULSE 1.1 build 5 is
signed, installed and launched on the physical iPhone through the existing
LCSign setup. The app About page visibly reports 1.1 (5). Runtime source is
2466197ca898c5382e739bbf89e6abda01fb7130.

## Display and controller changes

- All four TFT pages use smooth Inter glyphs on a clean dark background. The
  main page has large cyan CPS, amber Stopped, green Clicking, coral Stopping
  and red Disconnected. LAST RUN distinguishes a stopped result from live output.
- The transport pill and authenticated Bluetooth target label distinguish the
  mouse target from controller app connections. The actual board shows
  iPhone / 93:75 and one app after the new app connects.
- A small progress indicator animates while clicking. Rendering stays outside
  the timing task, with the existing 250/500/1000 ms idle/active cadence. Glyphs
  are bounded 4-bit coverage arrays in flash; there is no runtime font parser or
  extra framebuffer. Inter is included under the SIL Open Font License.
- The Traditional Chinese app supports individual and bulk script selection,
  select all, counted deletion and explicit Cancel. An alert replaces the
  action sheet that hid its cancel action during the earlier simulator tests.
- Imported screenshots keep their original aspect ratio. Target positions and
  drags use the same fitted image rectangle. Import sets portrait/landscape
  from the image.

## Automated checks

All seven CI jobs passed at the runtime source:
[CI run 39887587606](https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/39887587606).
The [physical-device IPA build](https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/39887587588) also passed.

- iPhone and iPad each passed 85 unit tests and three UI tests: bulk deletion
  including cancellation, target editor flow, and screenshot aspect ratio.
- ESP-IDF firmware build, existing bplist/GOP tests, host scheduler, record/CRC,
  chunked transfer and five OTA package tests passed.
- S3 QEMU passed startup confirmation and failed-boot rollback, 16 schedules
  with 1,000 targets, and all four framebuffer pages. USB, BLE, Wi-Fi and TFT
  adapters are simulated in QEMU; these are not physical phone measurements.
- Python 3.10 and 3.12 server tests and lint passed.
- Local firmware, host and QEMU checks also passed before flashing. Host
  renderer fixtures include clicking, stopped, disconnected, releasing,
  enterprise authentication errors and OTA verification/signature errors.

## Physical board and iPhone checks

- Backed up and compared all five original scripts and their selection before
  flashing. Wrote only the application at 0x20000; esptool verified its hash.
  Bootloader, partition table, calibration and profile storage were preserved.
- Captured the real board framebuffer through the authenticated LAN screen
  endpoint and visually checked the smooth text, cyan CPS, amber stopped state,
  Bluetooth transport and iPhone label. This confirms the rendered framebuffer;
  no new camera view of the physical LCD was used. The user previously
  confirmed that the panel displays the status pages correctly.
- Installed build 5, launched it, verified its About version and automatic
  Bluetooth loading of the five board scripts.
- Imported portrait screenshots from the actual photo picker. The image frame
  measured about 198 by 430 points, matching 440:956. Visually checked the
  fitted image and dragged target 1; its frame moved to the requested location.
  The selected photo itself contains an older editor screenshot, so UI visible
  inside that photo is part of the source image. No edited script was saved.
- Created disposable slots 30 and 31 through UART, restored the original
  selection, and selected only those two in the app. Cancel preserved both
  files on the board. Confirming deletion removed only those two. Compared
  the entire original profile JSON and selection afterward: unchanged.
- Returned to Wi-Fi-off Bluetooth output, stopped with releasing=false and
  mouse_connected=true. Selected script remains Business Empire fast (3).
  No click run was started during this display/app update.

## Delivery and limits

The delivery includes source, the built firmware, fixed-layout USB recovery
files, an Ed25519-signed 0.3.2 OTA package, public verification key, unsigned
build 5 IPA, screen fixtures and CI results. It excludes profile backups,
network credentials, phone tokens, private keys and the full device backup.
The IPA needs local signing on another device.

This update does not establish a new physical CPS benchmark. Earlier measured
Bluetooth results and remaining hardware checks are documented in
[pulse-device-validation.md](pulse-device-validation.md). Actual TCIVS/eduroam
authentication, Tailscale enrollment/DERP and physical OTA interruption/rollback
remain unverified.

Private local evidence is under output/hardware-20261023: flash-032.log,
pulse-032-build.log, pulse-032-host.log, emulator-032-run.log,
board-stopped-032.png, phone-build5-version.png, phone-build5-game-import.png,
phone-build5-bulk-validation.json and board-032-final-check.json. Do not share
the whole hardware evidence directory.
