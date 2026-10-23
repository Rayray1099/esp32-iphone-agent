# PULSE 0.3.1 / iOS build 4 validation — 2026-10-23

Firmware 0.3.1 was built locally, flashed to the connected ESP32-S3 at
0x20000, and verified by esptool's flash hash check. The bootloader, partition
table, original profiles and calibration were preserved. A separate JSON
backup of all five profiles and the selection was saved before flashing.

## Changes

- The TFT prominently shows CLICKING, STOPPED, STOPPING or NO TARGET. The
  selected input transport and Bluetooth target identity suffix remain visible
  on the main page. The Connections page distinguishes subscribed controller
  apps from the HID target. Idle CPS is explicitly marked LAST RUN.
- A bonded native app can supply its friendly device label once per link.
  Until the new app is installed, the physical phone displays PHONE / 93:75.
- The app has a Traditional Chinese bulk profile manager with individual
  selection, select all/deselect all, a counted confirmation and sequential
  deletions. The board repairs selections after deletion.
- Imported and mirrored images use their own aspect ratio, with markers and
  drag coordinates sharing the exact image rectangle. Import sets the profile
  orientation from the image. Zoom changes the canvas size without stretching.

## Checks completed

- Local ESP-IDF firmware build passed.
- Host scheduler simulation, record/transfer checks and five OTA package tests
  passed. Renderer fixtures cover clicking, stopped, disconnected and releasing.
- ESP32-S3 QEMU passed both startup confirmation and failed-boot rollback
  scenarios, 16 schedules × 1000 targets and all four framebuffer pages. USB,
  Bluetooth, Wi-Fi and panel adapters are simulated in these emulator checks.
- A compiled Swift executable ran the shared geometry calculations for
  440×956, 956×440 and 768×1024 images at phone and tablet widths. Aspect
  ratios, bounds and center/edge coordinate mapping passed. UIKit/SwiftUI
  sources and iOS tests passed Swift syntax parsing on Windows.
- On the actual board, two disposable test profiles were created and removed;
  deleting the selected test profile repaired the selection. All five original
  profiles and their original selection were then verified unchanged.
- An authenticated remote framebuffer capture from the physical board visibly
  shows STOPPED, BT and PHONE / 93:75. The original screen panel wiring was
  previously confirmed by the user; no new camera view was available.
- The board was returned to Wi-Fi-off Bluetooth mode. Final UART status is
  stopped, releasing=false, with the Bluetooth mouse connected. No click run
  was started during this update.

## iPhone build blocker

Source commit 56c2f03 contains the app changes and sets build number 4. GitHub
did not create runs on push, and an explicit CI dispatch returned HTTP 422:
“Actions has been disabled for this repository.” The repository permissions API
reports enabled=true and both workflows report active; no account-level cause
has been established. The user has been asked to inspect GitHub account notices.

The phone still has version 1.1 build 3. Build 4 has not been compiled with
Xcode, tested in an iPhone/iPad simulator or installed. Added UI tests cover bulk
selection, cancellation, deletion and screenshot aspect ratio; these tests are
pending the macOS runner. Local Swift geometry/syntax checks do not replace them.

The original distorted editor screenshot was captured from the actual phone
before changes. It remains private because it contains personal app content.

## Local evidence

Evidence is in output/hardware-20261023, excluded from Git:

- flash-031.log
- emulator-build.log and emulator-run.log
- profile-delete-device-test.json and board-final-check.json
- board-stopped-031.bmp

Host log: output/pulse-031-host.log. Firmware log: output/pulse-031-build.log.
Do not share the entire hardware evidence directory or its profile/network data.
