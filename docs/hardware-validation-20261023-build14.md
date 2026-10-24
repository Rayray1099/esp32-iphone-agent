# Agent startup and AirPlay recovery validation - build 14

Validated on 2026-10-23 with iPhone app 1.1 (14), an ESP32-S3 N8R8 with
ST7789 display, and the user's iPhone running iOS 27.0. App sources are at
commit d7bcd4a (startup changes in a8ccd21). Firmware source changes are
included alongside this report.

## Result and failure mechanism

The reported Start failure had two parts. The app displayed a farewell
transition before startup was established, and AirPlay's connected status
did not guarantee that the board held a usable H.264 replay window. The
board's 4 MiB GOP arena could fill, clear itself, and then wait for an IDR
indefinitely. The app's BLE fallback read the same unavailable source.

The firmware now exposes legacy AirPlay eventPort 7101 and sends bounded
RTSP /command binary-plist forceKeyFrame requests on the sender's event
socket. HTTP/1.1 on that channel stalled initial video on this iPhone;
RTSP/1.0 was required. Keyframes are requested at half arena capacity, half
AU count, or while waiting for IDR, with a two-second request limit. A new
SPS/PPS invalidates the previous GOP so it cannot reuse old picture references.
Only receiving a usable IDR restores readiness.

The app shows explicit preparation stages and elapsed time, supports
startup cancellation, and retains an actionable「啟動失敗・尚未執行」state.
The farewell overlay and delay were removed. Live Activity begins in the
starting phase and changes to running after agent startup. Cancelled queued
input claims cannot execute later. HTTP 503 receives a bounded five-second
IDR grace and is not retried over BLE. Stream revision checks prevent older
HTTP requests mutating a replacement stream.

## Actual device checks

| Check | Observed result |
| --- | --- |
| Installation | Original CI IPA installed through LCSign over the existing app; Settings visibly confirmed 1.1 (14). Same bundle identifier and signing identity. |
| Start and cancel | Tapped the actual Start button; saw「準備啟動中」and「驗證即時螢幕畫面」; cancelled. App showed「已停止・啟動已取消」. UART recorded stream off and input release, with no later agent start. |
| Repeated startup | Two consecutive no-action screen-reading tasks completed without reconnecting AirPlay. The model described the actual Home Screen. |
| Fresh Bluetooth input | A new Start-button run replaced the previous Calculator result 46 with 23 + 19 = 42. iCTRL independently read both the expression and result and captured the screen. UART recorded mouse movements/clicks, finished: done Calculator shows 23+19 = 42., stream off and input release. The run finished at 18:49:08 Taipei. |
| Video renewal stress | Random-noise animation caused three automatic keyframe renewals, generations 5 -> 8 -> 11 -> 14. All sampled diagnostics showed overflows=0. Brief waiting-IDR intervals recovered automatically. |
| Cellular | Control Center visibly showed cellular data off. Local video requests also disallow cellular access. |
| Remote screen | Authenticated /api/v1/screen returned a valid 320 x 240 BMP and was visually inspected. Setup-page captures contain local controller credentials and remain private. |
| Saved data | Five profiles remain; selection remains {"profiles":[3]}. |
| Final state | Agent complete, board running=false, releasing=false, output CPS 0, Bluetooth mouse connected, no last error. Video diagnostic remained ready with zero overflows. |

iCTRL was used for installation, entering the test task, pressing Start,
and independent observation. During the fresh Calculator run, the agent
performed the phone interaction through ESP32 Bluetooth HID. iCTRL did not
enter the calculation. The earlier build-14 run that simply opened an
existing result of 46 was not counted as a fresh calculation.

## Tests and artifacts

[Actions run 39937331757](https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/39937331757)
passed 101 unit tests and 5 UI tests and produced the device IPA. This
includes startup cancellation, persistent startup failure, and command
cancellation coverage. The first run's cancellation fixture ended before
the simulator could take its screenshot and tap Stop; its pending duration
was increased, followed by one necessary retry. No additional Actions runs
were started for device testing or artifact preparation.

Local C bplist/GOP tests passed with warnings treated as errors. The new
regression verifies that encoder config invalidates retained pictures and
requires a fresh IDR. The host test suite also passed scheduler,
persistence/transfer and OTA tests and rendered the framebuffer fixtures.
These host tests are simulated checks, separate from the physical results.

The firmware built locally and was flashed at application offset 0x20000;
flash verification passed. Only the application was replaced. Bootloader,
partition table, settings and profiles were preserved. A verified recovery
application was saved privately before flashing.

| Artifact | Size and SHA-256 |
| --- | --- |
| Original unsigned IPA ESP32-Agent-unsigned.ipa | 5,206,634 bytes; 03944ac1934273dd9e6346cb1fc43b1e71f853d6277c2c08b41a5dd6653a897c |
| Flashed s3_clicker.bin | 1,808,464 bytes; 718ac7a77e5c277fb07545ab11956ad3ccaf5e69ebc167cc5a80e415f3d249cf |
| Recovery application | 95925f984d054520d6999dfcb8a25ad4242979f88f757866861c8855399dbad3 |

The original CI IPA was ZIP-validated and its bundle ID
com.example.esp32agent, version 1.1 and build 14 were read from Info.plist.
The original package was copied for LCSign installation without repacking.
An accurate build-14 update manifest and release notes are prepared locally.
Publishing replacement release assets was rejected by automatic approval
review with "blocked by policy". At the time of this report the public
ios-latest release remains build 13; build 14 is already installed on the
test iPhone and retained locally.

## Limits

This verifies the reproduced video-buffer failure, clear startup/cancel
states, repeated startup and one fresh guided input task. It does not prove
reliable unattended navigation in every app. App opening sometimes needs
explicit Spotlight instructions and hardware-keyboard language switching.
The configured model's response times varied substantially.

The planner briefly saw an earlier app frame immediately after backgrounding
in one screen-reading run; a subsequent actor frame was current. Startup
freshness is therefore not claimed to exclude every previous app frame.
The new event channel was exercised as legacy unencrypted AirPlay on this
iPhone; encrypted HomeKit event channels were not tested.

Missing-video error UI was tested in the simulator. A deliberate physical
missing-source fault was not injected after the repair. No new iPad simulator
run, eduroam authentication, Tailscale relay, OTA rollback, CPS benchmark or
Shopee reward claim is asserted by this build-14 validation. The earlier
successful Shopee observation is recorded in the build-13 report.

Private evidence is in ignored output/agent-20261023/: the CI log, full
iCTRL replies, UART logs, confirmed-version/cancel/result screenshots and
automatic-keyframes-stress.log. Raw phone captures, tokens, API credentials
and signing material are not included in source control.
