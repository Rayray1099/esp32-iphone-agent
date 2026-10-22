# S3 implementation and validation report — 2026-10-22

This is a board-ready development build with verified software/simulator
results. **No physical ESP32 or iPhone has been tested during this work.**
The 150 CPS target remains unmeasured. Board pins came from the supplied CSV.

## Delivered implementation

| Feature | Implementation |
| --- | --- |
| Saved offline clicker | 32 profiles, 1000 points each, 16 schedules; default stopped |
| Timing | Integer microseconds, completion-driven USB state machine, bounded backlog |
| Arbitration | One pointer, earliest deadline, rotating ties, complete move/press/release |
| Optimization | Fixed runtime slots, PSRAM profiles/framebuffer/JSON, no timing-loop allocation, repeated coordinates skip movement |
| BOOT | Cycle, hold-to-start, press-to-stop, hold-to-setup |
| Web editor | Local assets, screenshot/grid, draggable numbered targets, CRUD/reorder, units, import/export |
| Native editor | iPhone/iPad, photos/freeze mirror, target CRUD/reorder, JSON, BLE transfers, calibration |
| Display | Run/connections/system/setup/update, QR, progress, framebuffer snapshots |
| eduroam | IDF PEAP/TTLS/TLS, username/password/certs, CA/server/time validation, AP+STA recovery |
| Tailscale | Pinned MicroLink client, persistent identity, DERP, four peers, controller token |
| OTA | Ed25519 package verification, SHA256/image/board/project validation, two slots, rollback |
| Remote diagnostics | Authenticated BMP, bounded event log, heap/task data, controls/reboot/update |

Source lives in hardware/hid_bridge, hardware/idf, web and ios. Upstream
attribution and existing AI/AirPlay code are retained. Test fixtures are clearly
separate from production adapters.

## Executed checks

| Check | Result and evidence |
| --- | --- |
| ESP-IDF 5.5.2 production firmware | Builds locally on Windows with spaces in path and in Linux Actions; about 1.7 MB, 43% slot headroom in the measured build |
| Host scheduler | PASS: actual shared engine, 16 x 1000 targets, finite/continuous, disabled tails, bounds/orientation/device mismatches, blocked USB, disconnect/release, stop and button transitions |
| Async USB simulation | PASS: 1ms completion transport, no duplicate press advancement, ordered releases, no recurring homing for one position |
| Fairness | PASS: 16 distinct positions each complete, first round serves every schedule once, three rounds give three clicks each |
| Record/transfer helpers | PASS: actual firmware helper code, CRC known vector, truncation, wrong version/size, corrupted payload, 192KB upload, duplicate/conflicting/out-of-order chunks and overflow offsets |
| Signed package tests | PASS: valid package, bad key/signature, corrupted body, truncated package, wrong board and oversized metadata; 5 test cases |
| S3 CPU emulation | PASS: ESP32-S3 QEMU, actual IDF FreeRTOS/timer, shared engine/button/renderer; 16,000 completed simulated clicks and four rendered pages |
| Boot confirmation | PASS: real IDF app state changes PENDING_VERIFY to VALID on staged OTA slot |
| Failed-boot rollback | PASS: real bootloader rejects unconfirmed staged slot after restart and boots the previous VALID slot |
| TFT capture | Six shared-renderer captures including certificate error and bad-signature update; demo values, never hardware measurements |
| Browser | Real headless Chromium at 390px phone and 834px tablet; connect/save/load/start/stop, add/duplicate/delete, drag/reorder, malformed/valid imports, export roundtrip, 1us bulk delay, screen BMP refresh; no horizontal page overflow in checked layouts |
| iOS CI | Native unit and Clicker UI flow run on macOS iPhone/iPad simulators; latest all-green baseline below |
| Upstream regression | bplist/GOP sanitizer tests and server tests on Python 3.10/3.12 pass in Actions |

All seven jobs passed at source ba87a35:
https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/39735192616

Later source adds transfer helpers, per-device calibration, offline group saving,
asynchronous transport/fairness tests, and QEMU boot rollback. Consult the final
Actions run and delivery manifest for its exact commit. A baseline result does
not prove later source unless its own jobs pass.

QEMU evidence: output/emulator/qemu-s3.log. Each scenario must contain
CLICKER_S3_EMULATOR_PASS; scenario 1 also prints startup confirmation PASS,
scenario 2 failed-boot rollback PASS. The host preloads valid app images and OTA
metadata because the S3 emulator does not implement every application flash-MMU
path used by image verification. **This validates boot selection/confirmation/
rollback, not the production HTTP upload or real flash power-loss behavior.**
USB, BLE, Wi-Fi and TFT adapters are simulated in this firmware. This is an
ESP-IDF/QEMU alternative to Wokwi; no Wokwi session is claimed.

## Reproduce

~~~powershell
python tools/host_tests.py
python tools/bundle_web.py
./tools/build.ps1 -IdfPath E:/tools/esp-idf-v5.5.2
# In an exported IDF environment:
idf.py -C hardware/emulator build
python tools/run_qemu.py --qemu /path/to/qemu-system-xtensa
# Windows can use an Espressif QEMU Linux binary through WSL:
python tools/run_qemu.py --qemu /mnt/e/tools/qemu-s3/qemu/bin/qemu-system-xtensa --python C:/Users/bestm/.espressif/python_env/idf5.5_py3.10_env/Scripts/python.exe
# Browser-only API fixture (32 zeros as token):
python tools/web_fixture.py --port 8098
~~~

On macOS run xcodegen generate in ios, then xcodebuild test using an available
iPhone or iPad simulator. CI defines the same build and tests.

## Explicit gaps and limitations

- Real USB emission CPS and taps accepted by iOS are unmeasured. USB polling,
  completion latency, iOS pointer processing and paced movement set the limit.
  1us is a requested field value, not a guaranteed physical interval.
- Actual TCIVS login and a controlled RADIUS authentication matrix have not run.
  No school password was requested. Exact school CA/server/realm remain editable.
  Cold boots need valid time supplied before enterprise certificate validation.
- Tailscale enrollment, live screen viewing, reconnection and blocked-UDP DERP
  fallback have not run against a real enrolled board. No key was supplied.
- Production OTA HTTP upload, interrupted flash writes and physical failed-boot
  rollback are pending. Host signature tests and emulator rollback are distinct.
- Full LittleFS interruption/power-loss and production BLE/HTTP integration
  are pending. Tests exercise the shared CRC/chunk logic, not a physical filesystem.
- AI input lease is mode-level. Existing paired legacy debug clients are trusted.
  Keep a single active input controller during AI execution.
- One last schedule group is saved. BOOT cycles single profiles; multiple named
  saved groups are not implemented. Both editors accept a group of up to16 slots.
- Native networking is a JSON editor, native zoom is limited, and native timing
  edits use microseconds. The web page has the full forms, units and zoom.
- Remote screen captures copy rows asynchronously and may straddle a render.
  Event streaming is bounded polling, not a serial-console or debugger tunnel.
- Screen snapshot API returns board TFT pixels, not the phone screen. Upstream
  AirPlay still handles phone mirroring separately.
- Checked-in Xcode project contains app/unit sources; regenerate with XcodeGen
  to include the UI-test target. A signed physical-device IPA needs Apple signing.
- Panel presence cannot be detected by framebuffer health alone. Validate
  actual panel/backlight/USB/power when hardware arrives.

## Hardware acceptance sequence

1. Verify board model, flash/PSRAM, native USB connector, power, BOOT, display
   colors/rotation/backlight. Preserve any needed original firmware first.
2. Calibrate portrait and landscape for each phone/tablet and save IDs.
3. Benchmark requested 10/50/100/150/200 CPS and saturation. Record completed
   USB reports separately from taps counted on the receiving test surface.
4. Test one position versus distant targets, with 1/4/16 schedules. Check
   long-run drift, rehoming, late events, memory and stop response.
5. Restart stopped, close app, disable both radios and run saved group via BOOT.
6. Verify TCIVS enterprise server validation and wrong-password/certificate errors.
7. Enroll Tailscale, view screen/logs, reconnect, block direct UDP and test DERP.
8. Upload valid/bad-signature/corrupt/oversized/interrupted OTA packages. Test
   failed startup rollback, saved settings, USB recovery and extended operation.
