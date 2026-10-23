# Agent input accuracy and Traditional Chinese progress — build 16

## Changes under validation

The TFT displays bounded public progress summaries in Traditional Chinese for
arbitrary tasks. The actor supplies a STATUS line in its existing response;
there is no extra model request. The firmware bundles a Noto Sans CJK TC bitmap
font in flash and needs no SD card. It never displays raw private reasoning.

The prior eight-second telemetry warning is now “進度更新延遲”. This measures
missing app updates, and does not establish a Bluetooth disconnect.

Input timeout recovery no longer replays clicks, relative moves, keyboard
shortcuts, text, or API mutations. A lost acknowledgement can follow successful
input. Only explicit read/snapshot commands are replayable. Typed content is
omitted from command logs.

Precise taps require visible pointer confirmation and a bounded correction
check; a failed check prevents the click. Visual pointer centres no longer
train the touch calibration because iOS can reshape/snap the pointer over UI.
Keep-awake movement is disabled during agent startup/runs and touch probes.

Released-pointer moves send the X and Y axes separately to reduce
vector-speed-dependent iOS acceleration. Bluetooth pacing and settling are
measured below. Held-button drawing
retains simultaneous axes. Build 16 invalidates older diagonal calibration;
recalibration is required. Saved clicker profiles and board settings remain
unchanged.

The new Settings accuracy test uses a 20 × 20 point target at 12 independent
screen positions, forward and reverse, with 24 measured UIKit touch landings.
It reports actual points of error, hit count, mean vertical offset, and maximum
axis error. These validation taps never train the calibration. A UART development
command, `app accuracy`, starts the same test; `app accuracy precise` additionally
checks the pointer using live mirrored video.

Visible Zhuyin keyboards are detected by local Apple Vision OCR before ASCII
input. The controller switches input source and checks for English before
typing. Unknown/hidden keyboard layouts are not blindly toggled. HID text is
still ASCII only; CJK display support does not provide Chinese text entry.
Spotlight prompts use Cmd-Space and replace an existing query instead of
repeatedly appending it.

## Observed failure

Run 20261023-204228 ended itself at round 36 after it could not obtain a fresh
screen following an action/probe. Its final input-release command succeeded.
The user had requested observation without stopping it; no stop was sent during
the observation. Bluetooth RSSI remained around -44 to -58 dBm, with several
multi-second command delays and app suspensions. These observations do not
establish a physical Bluetooth disconnect.

Before the firmware change, touch calibration showed the same requested
vertical displacement of 816 units landing at approximately 0.703 and 0.723
of screen height with different simultaneous horizontal displacements. This
is about 19 points of vertical variation on the 956-point screen. It motivated
the axis-pacing changes measured below.

## Validation status

Local scheduler, profile integrity, telemetry, framebuffer, and OTA host tests
pass. ESP-IDF firmware builds and Swift syntax parsing pass. The macOS run on
e19bd5b passed all 115 unit tests and produced the original unsigned device IPA:
https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/39964121228
Five simulator UI tests passed on the preceding run; they were deliberately
skipped on the final run because the relevant UI had not changed.

The first build caught a nested closure missing explicit `self`. The second
caught a test that discarded its weakly held fake screen. The latter also
exposed a real missing-screen safety bypass; e19bd5b fixes both. Three manually
dispatched runs were used; subsequent firmware work used local builds only.

LCSign's remote installation channel stalled and timed out. Selecting its
local installation method succeeded without removing the existing app.
The app's update page visibly reports **1.1 (16)**. Settings, the model
configuration, Bluetooth pairing, and the five board profiles are retained.
PULSE's per-app cellular data switch was explicitly turned off and read back
as off in iOS Settings.

The build 15 application was read back before flashing and its SHA-256 matched
the previously verified image: 4e6c9c02960fa6558ba06adf0057a79a1c6c9ab9edf237ae66e9857f364b5924.
Build 16 was flashed only at application offset 0x20000 with hash verification.
Five profiles remain on the board. Private raw phone screenshots and logs stay
in ignored output folders.

## Physical small-target measurements

All test taps were emitted by the physical ESP32 Bluetooth HID mouse. iCTRL
opened test screens and recorded screenshots; it did not supply the measured
taps. Safari's content origin was independently measured at 129 screen points
using an iCTRL tap at y=500 and its DOM landing at clientY=371. The Safari
fixture uses a 20 x 20 CSS-point target at 12 locations, forward then reverse;
the native fixture measures UIKit screen points. Neither test changes its
calibration using validation landings.

| Configuration | Hits / 24 | Mean vertical offset | Maximum axis error |
| --- | ---: | ---: | ---: |
| Axis-separated, 8 ms pacing, home every 10 moves | 15 | +2.9 pt | 22.4 pt |
| 8 ms pacing, home every tap | 12 | +6.2 pt | 16.3 pt |
| 16 ms pacing, brief home drain | 20 | +0.6 pt | 14.3 pt |
| 16 ms pacing plus 150 ms external settling | 23 | -2.9 pt | 11.0 pt |
| Same settling, home every tap | 23 | +1.5 pt | 14.0 pt |
| Final firmware with settling built in, Safari | **24** | **+0.7 pt** | **8.7 pt** |
| Final firmware, native app calibrated path | **24** | **-1.2 pt** | **7.7 pt** |

The phone negotiated a 15 ms BLE connection interval. Manual Bluetooth moves
now use 16 ms report pacing and a 150 ms settling interval after homing and
movement. This reduces changes in iOS acceleration caused by report batching.
It is an evidence-backed improvement, not proof that batching explains every
miss. USB pacing and the independent stationary fast-repeat scheduler are
unchanged. Moving between distant targets is deliberately slower. Native
commands measured roughly 0.7-2.0 s for target movement in the 24-point test.

The native app calibrated to 555 x 1208 mouse units; its independent check was
about 0.1 percent. The subsequent 24 validation taps all landed inside their
20-point targets. These two successful runs are limited evidence for this
phone/orientation/pointer configuration, not a guarantee for games or smaller
controls.

Reproduction: run `python tools/phone_accuracy_server.py`, open its local URL
in Safari, verify the viewport origin, then run
`python tools/phone_accuracy_driver.py --top 129`. Both tools are local
development fixtures; the driver asserts idle Bluetooth output before claiming
input and releases input afterward. In the native app use Settings >
20 pt small-button test after calibration, or the UART `app accuracy` command.

Evidence stays under ignored `output/phone-accuracy/` and
`output/agent-20261023/`: `firmware-final.json`,
`small-target-native-result.jpg`, `build16-installed-version.jpg`, and
`uart-1792768402424866900.log`.

## Remaining failures and practical limits

The separate live-video precise-target test failed to identify the pointer on
its first target and correctly refused to click. Pixel-based pointer checks
still produce inconsistent offsets around keyboard controls. The calibrated
path's 24/24 result does not establish that visual aiming is fixed.

A safe AI test asked only to open Spotlight and enter Weather, with no launch
or messaging. Model requests succeeded and the real TFT displayed Chinese
public progress including opening Spotlight and clearing its search. The
typing/search task did not complete: layout recognition did not reliably catch
the visible input state, and the actor retried clearing and typing. The test
was explicitly stopped at round 16 to prevent a retry loop; input release
succeeded. English-input handling and reliable visual aiming remain open.
No end-to-end app-opening speed claim is made.

Final firmware application: 2,866,320 bytes, SHA-256
`b7b989839aad6db03977d0f3ca975f8ca0787333247291e072017d5a902b08c3`.
Original unsigned app IPA SHA-256:
`38f32824b46b773713813a6832c5d7d2b7839ec5461e21fc9cc49237c297d4b0`.
Application-only flashing at 0x20000 passed esptool hash verification.

After testing, the existing iOS shortcut **Tako QA Lock Screen** was executed.
Its visible action is “鎖定螢幕並關閉顯示器”; iCTRL independently reported
`locked: true`. The phone was left locked with the agent stopped.
