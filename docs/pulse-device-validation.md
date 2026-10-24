# PULSE device and UI validation — 2026-10-22

## Installed firmware and app

Firmware 0.3.0 is flashed on the connected ESP32-S3. The 16 MB original flash
was backed up before the initial erase; the application retains the fixed 8 MB
partition layout and uses 8 MB PSRAM. The user confirmed that the ST7789 status
pages look correct. GPIOs match the supplied board pin map.

The redesigned Traditional Chinese app, PULSE 連點器 1.1, was signed through the
existing LCSign certificate, installed, launched and connected to the board.
Physical verification covered the live dashboard, saved profile loading,
adding a second target and applying CPS settings without writing those test
edits over the saved game profiles. Version 1.1 build 3 is now signed, installed
and launched on the physical iPhone. The translated 連點器 tab is visible, and
board status plus saved profiles load automatically after Bluetooth connects,
without tapping refresh. The final build retries while BLE negotiates its MTU.
The dashboard shows the previous run's 43.9 CPS and 300 clicks; no clicking was
started during installation. UART confirms that the board is stopped, with
Wi-Fi off and the Bluetooth mouse connected.

## Display and controller changes

- The TFT uses large cyan seven-segment CPS text, a requested-rate line with a
  moving dot, a 24-sample history graph, click/target/loop counters and state.
- Rendering remains in a low-priority task. Updates run at 250 ms while idle,
  500 ms while running at up to 75 requested CPS and 1 s above that rate.
- Authenticated LAN screenshots copy the complete shared framebuffer before
  encoding/sending. The live Run and Connections pages were captured from
  the physical board; host-rendered fixtures are separate evidence.
- The native app has 控制台, 編輯目標 and 連線設定 pages, prominent start/stop
  controls, screenshot target editing and saved profiles from the board.
- BLE GET run/status and profiles/page/N keep status and directory responses
  within the notification limit. The full HTTP status API remains available.
- The hotspot web dashboard has a large live CPS card and history bars.
  Chromium phone (390 × 844) and tablet (834 × 1194) checks found no horizontal
  page overflow. Browser visual fixtures use explicitly simulated status.

## Real Bluetooth click regression

Each test requested 50 CPS for 300 clicks using saved profile 3, Business Empire
fast, on the actual iPhone. The input source was the physical ESP32 Bluetooth
HID mouse; iCTRL was used only for navigation and screenshots. The PULSE TFT
was enabled in both runs. Board CPS measures BLE host submissions after initial
homing/movement; it is not a confirmation that iOS received every tap.

| Condition | Requested CPS | Board submission CPS | Submitted clicks | Inferred game taps |
| --- | ---: | ---: | ---: | ---: |
| AP + home Wi-Fi, one remote framebuffer capture during run | 50 | 35.96 | 300 | 266 |
| Wi-Fi off, Bluetooth retained | 50 | 43.88 | 300 | 282 |

Game taps are inferred from screenshot whole-dollar balance changes divided
by the previously checked single-click reward of 4,736. This is a short game
regression, not a sustained latency/distribution measurement. The previous
pre-redesign offline result was 43.68 submissions/s; the latest 43.88 result
shows no measurable loss from the new display in these short tests.

An earlier slower profile, Business Empire steady, delivered 16.60 submissions/s
and 299/300 inferred game taps. That profile remains saved for this game.
Neither mode establishes stable 50 accepted taps/s. Physical USB 150+ CPS,
1/4/16-schedule hardware saturation and prolonged runs remain unverified.

Both new runs completed, released input and were followed by an explicit stop.
The board was returned to Wi-Fi-off Bluetooth mode and remains stopped.

## Build and emulation evidence

Runtime source: 1ff9fb8e18ee04f6bc5c8e0ec236812333b8e06a.

- All seven CI jobs pass: firmware, host, S3 CPU emulator, Python 3.10/3.12
  server and native iPhone/iPad unit/UI tests.
- CI: https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/39792690037
- Device IPA: https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/39792690086
- The device IPA is com.example.esp32agent, version 1.1, build 3. It is unsigned
  in the downloadable artifact and must use the device's existing signing flow.
- QEMU tests the actual shared scheduler/renderer with simulated adapters and
  IDF boot confirmation/rollback. It does not emulate real iOS HID delivery.

Local private evidence folder: output/hardware-20261022. It is excluded from
Git because it also contains recovery and controller credentials. Share only
selected screenshots/reports, never the complete folder.

| Evidence | Purpose |
| --- | --- |
| flash-pulse.log | Verified physical firmware write |
| pulse-build3-installed.jpg | Final build 3 installed and connected dashboard |
| pulse-build3-install-report.json | Final installation and automatic BLE loading checks |
| pulse-build3-launch.json | Physical app accessibility tree after automatic loading |
| pulse-installed.jpg | Installed Chinese dashboard |
| pulse-editor-installed.jpg | Physical target editor |
| pulse-board-running.bmp | Actual board Run framebuffer |
| pulse-board-live.bmp | Actual board Connections framebuffer |
| pulse-hardware-test-report.json | Both new run metrics and balance inference |
| pulse-hardware-regression.json | AP+STA run status |
| pulse-hardware-offline.json | Wi-Fi-off run status |
| business-empire-test-report.json | Earlier fast/steady game tests |
| output/playwright/pulse-phone.png, pulse-tablet.png | Mocked browser visual checks |

## Remaining boundaries

The controller-phone → hotspot dashboard → ESP32 → target-phone Bluetooth
route is documented for a consenting target. It has not been tested with two
physical phones. One mouse pointer serializes targets; simultaneous multitouch
is not implemented. Viewing the target phone needs separate screen mirroring.

Actual TCIVS eduroam authentication, controlled RADIUS, Tailscale enrollment and
DERP, and physical OTA interruption/rollback remain pending. LAN TFT screenshots
work; this does not establish live tailnet access. The eduroam username is the
school email and password, with school CA/server validation still required.
