# English typing and search validation

## Changes

`search TEXT` combines Spotlight focus, source selection, field clearing and
typing into one actor operation. It does not press Return or open a result;
the actor inspects the resulting screen before selecting an app. This removes
model calls between opening search and entering its query. Command logs redact
the query and typed content.

Background keyboard OCR uses CPU Vision. Hardware-source checks crop the
centered selector to 64% of each frame dimension and scale its width to at most
440 pixels. Crop boxes map back to full-frame coordinates before pixel sampling.
A selected source requires both horizontal pill edges and vertical contrast;
bright translucent unselected rows cannot prove selection. QWERTY software
key caps alone cannot confirm the hardware layout. Source cycling is bounded,
never types probe text in user fields, releases Control on failure, and waits
for a fresh frame after release before typing.

The BLE keyboard descriptor declares Input2 and Output2 (LEDs). Output2 was
missing from GATT; it is now initialized after the existing input reports to
retain their handles. Advertising now identifies a keyboard, the PnP version
is 0300, and Service Changed requests bonded clients to rediscover services.
Mouse and consumer reports remain present; firmware does not erase bonds.

## Current physical evidence, 2026-10-24

The keyboard-first descriptor experiment fixed the observed ASCII translation
failure on this paired iPhone. Report IDs and GATT input creation order stay
unchanged: keyboard report 2 precedes mouse report 1 and consumer report 3 in
the descriptor. Fresh pairing alone did not fix the earlier phonetic output.
The descriptor order is the first change correlated with exact physical input;
this does not establish which internal iOS behavior caused the failure.

Physical ESP32 Bluetooth output produced exact `Abc123_XyZ`,
`AaBbCc_123-xyZZ!!`, and `Repeat_ttEE_0011!?` in a synthetic Safari field.
The last result and the full lowercase/uppercase alphabet with repeated digits
and punctuation were independently recorded exactly by DOM input events.
iOS Settings now exposes Hardware Keyboard; it was absent before the descriptor
order change. The real
build-21 app's production search path entered exact `Weather` and
`Abc123_XyZ` in Spotlight. The latter followed explicitly selecting
Traditional Zhuyin in the system selector. A separate search after selecting Traditional handwriting also entered exact
Weather. These tests do not cover arbitrary applications or every installed source.

Build-21 harness totals were 19.99 seconds for Weather and 12.75 seconds for
Abc123_XyZ. They include input claim, capture setup, leaving the app, search,
and final freshness verification; they are not isolated typing latency. The
handwriting-start test took 27.40 seconds, with most delay before source selection.

The firmware was flashed only to app slot 0 at 0x20000 with hash verification.
The keyboard-first 2,866,976-byte image SHA256 was
`58dcb68e47e6a5e2b4ee8b583b6d8879eee579a3758fe86d81ff079d90585d0a`.
A verified copy was retained before the video-refresh change. The final
2,867,024-byte application SHA256 is
`8a3277c56eb44fa6278efa55d7aa846862d860c159d705ecdff60c1df8f10d31`;
its application-only flash passed hash verification.
All five profiles and calibration storage remain present. The pre-change
app-slot backup has 3,014,656 bytes and SHA256
`c8e9ae3500173bd4aedb548700c27bba211d48f340e4b11e23e50c462213808b`.
The first 921600-baud backup read failed with a corrupt packet; the 460800
retry passed. Bootloader, partitions, NVS and profile flash were not rewritten.
The ESP32 was forgotten and paired again once with the user's authorization.

`tools/phone_keyboard_server.py` serves a LAN-only synthetic input fixture and
records key codes, translated keys, input and composition events. Use only
synthetic strings. It records sequence numbers because concurrent HTTP arrival
order is not guaranteed; writes are serialized. Local event output is ignored
by Git and contains no fixture screenshots in the committed source.

## Source-capture optimization

Build 22 added a keyboard-source-specific capture path. Physical build-23
testing then showed that the selector can dismiss while Control is still held.
Its extra 200 ms capture margin and full-screen quiet fallback could discard
the transient selector and run OCR after it disappeared. Build 24 removes that
margin and quiet fallback. It requires healthy video captured strictly after
the HID reply, plus a recent Wi-Fi board watermark and the latest frame decoded.
The source wait is bounded to 1.2 seconds; failure releases Control and enters
no text. Explicit snap mode still requests a snapshot, with the same freshness
requirement. OCR must confirm the selected English row, and Control release
needs another fresh capture. No cached source assumption or probe text in a
user's field is used. Logs separate HID, capture and OCR time.

Build 25 recovers a missed selector frame by cycling again, up to twelve
attempts. A missed frame never reaches OCR. A device error or cancellation
still stops immediately, and failure to verify the final Control release
cannot proceed to typing. The capture cutoff remains strictly after the HID
reply. Source-wait diagnostics record capture age, decoded and board-latest
timestamps, transport state, the last HTTP batch and rejected publications.
They aggregate within each wait to avoid logging every received frame.
The UART search harness now holds an expiring iOS background assertion, as
the normal run does, while it leaves the app.

Subsequent physical checks found that the first post-reply capture can precede
the selector's appearance. Selection now yields for 300 ms while video keeps
decoding, then inspects the latest eligible frame. This does not add 300 ms to
the capture cutoff: an earlier valid menu capture remains eligible. Release
still requires a fresh post-release capture. Cancellation during rendering
releases Control before OCR.

Build 26 samples common pill margins across menu rows instead of the ends of
each label, which vary between English and shorter Chinese labels. It compares
both horizontal edges with adjacent rows and accepts measured low contrast
while rejecting fading, absent and ambiguous two-row highlights. Diagnostics
record source categories, geometry and contrast scores, without underlying app
text. Five synthetic-image regression methods reproduce the observed geometry;
the actual Swift classifier also passed local pixel-shim checks against the
existing fixture, the live selected/unselected pair, and twelve failed trace
frames. Twelve actual-source render/retry checks passed with HID stubs. Native
Vision and real-phone results are recorded separately below.

Wi-Fi setup now asks for a fresh keyframe after the authenticated video-auth
reply queues successfully. The existing AirPlay API only sets a coalesced flag;
its RTSP worker performs network I/O with the existing two-second global throttle.
The BLE callback does no RTSP work. Cached GOP replay and actual-IDR readiness
remain the fallback. This addresses a source-level difference from BLE startup,
which already requested an IDR; a request alone does not prove its receipt.

## Pointer drift correction

Relative moves accumulated error even after a fresh calibration. Returning to
the corner reset the error. The app now starts each distinct gesture using the
same from-corner path used by calibration. Repeating the same rounded target
skips motion, and held-button drags remain continuous. A reconnect or failed
corner reset invalidates the remembered position. This trades extra movement
time for bounded accumulated drift; it does not make iOS relative mouse input
absolute or promise pixel accuracy.

## Validation

`python tools/host_tests.py` passes scheduler, persistence/transfer, progress,
framebuffer generation and five OTA tests. ESP-IDF firmware builds and fits
its app partition. Swift syntax and whitespace checks pass. Extracted actual
Swift code passed seven freshness scenarios, three recovery scenarios and
five classifier/pixel scenarios. Full Vision execution requires macOS XCTest.
Build 21 passed simulator unit tests and device packaging, was installed over
the existing app, and visibly reported version 1.1 (21). Settings, calibration
and model configuration were retained. Build 22 passed all 137 unit tests. Build 23 passed all 141 unit tests and
device packaging, and was installed with the same signing identity and bundle
over the existing app. The update page visibly reports 1.1 (23). No app deletion
was used. UI tests were skipped because the UI did not change. The final run is
https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/40068655594.
The original unsigned IPA has 5,269,410 bytes and SHA256
`2b961356bf2451e0b02b98566e106ce1c1fc6f89b61c43fa27159b48ec7cd3bc`;
its transfer to the phone was downloaded back and hash-verified before signing.

Build 24 passed 145/145 macOS simulator unit tests and physical-device packaging
in one additional manually dispatched run:
https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/40070831885.
Its unsigned IPA is 5,269,573 bytes, SHA256
`ecc314bd358d0a6035cdceba5439d11729f2e4c5292e712e5940faa56be2593e`.
The phone's uploaded copy was downloaded back and matched before signing.
Ten extracted actual-source freshness checks also passed locally. The new
regressions cover a single transient frame 50 ms after acknowledgement,
pre-reply/equal-time rejection, continuously changing screens, safe timeout
and Control release, cancellation, and explicit snap mode.

Build 24 was signed with the existing certificate and installed over the
existing app. Its update screen visibly reported 1.1 (24). LCSign's server
installation stalled; switching its installation service to local installation
succeeded. The app was never deleted. A physical full AI run typed a fresh
`Clock` query, opened `com.apple.mobiletimer`, and completed four steps in
about 49 seconds; selected-source OCR needed three attempts. No alarm or timer
was changed. This is a different task from the Weather run, so its shorter
total is not a controlled speed comparison.

Build 24's first synthetic `Abc123_XyZ` harness attempt failed before typing
because no eligible post-reply selector frame was available. After explicitly
choosing the software Traditional Zhuyin keyboard, a full AI search task also
stopped at the first missed selector frame. These are reproducible limits,
not successful typing tests. An external UART keyframe-request experiment
obtained one fresh observation but then timed out during a later IDR gap;
it was not integrated into production code. These results motivated build 25's
bounded retries while retaining freshness and release checks.

Build 25 passed 149/149 simulator unit tests and physical-device packaging:
https://github.com/Rayray1099/esp32-iphone-agent/actions/runs/40073453756.
Its unsigned IPA has 5,272,429 bytes, SHA256
`4f1068ee35ac101317e0cfdd0ed1e469a35e06cadf9495a5628715d3c6701732`.
The phone copy was downloaded back and hash-verified, signed with the existing
identity, and installed without deleting the app. The update page visibly
reported 1.1 (25), with calibration 543 x 1185 and residual 0.8% retained.
LCSign had to remain foreground during its direct local installation; switching
to the old app immediately after accepting the installation left build 24.

Build 25 is not a reliable automatic English-selection pass. Its first new
`Qa25_AaZz_019` search acknowledged all HID commands but visibly produced only
`019`. A second `Qa25Z7` trace exhausted twelve source attempts and stopped
before typing. Live selector screenshots show missing, fading, or non-English
selections; command acknowledgement alone cannot establish correct text.
After manual English selection, the unchanged firmware typed exact
`abcDEF123_!?`, `AbcXYZ_456`, and `Fast25_AbCd123` in the synthetic Safari field.
DOM input events confirmed letters, case, digits and punctuation, with Control
and Command released. The last case typed immediately after `source release`.
These controls isolate automatic selection rather than justify a BLE pacing
change. A live English highlight had only about 10 gray levels of horizontal
contrast, below the old detector's threshold of 12.

Mouse pacing stays at 16 ms per BLE report and 150 ms settling, with separate
axes for released movement. The first 24 small-target taps on keyboard-first
firmware hit 17 of 24 targets, with +2.7 pt mean vertical error and 19.4 pt
maximum axis error. These taps did not train calibration. Fresh calibration alone gave 12/24 and a 20.9 pt maximum error. A separate
Safari test with independent calibration and a reset before each target hit
24/24, with -1.3 pt mean vertical error and 7.3 pt maximum axis error. This was
physical ESP32 input; iCTRL only opened the fixture and verified its viewport
origin at 129 points. Build 23's first native run after reconnect, before fresh
calibration, was 12/24 with a 25.0 pt maximum and two missing touch events. Its
fresh-calibration repeat hit 24/24, with +0.0 pt mean vertical offset and 9.7 pt
maximum axis error. The test used 20 x 20 screen-point targets across 12
positions, forward and reverse, without training calibration from its landings.
The earlier build-16 24/24 result is not reused as current evidence.

Build 23 entered exact Weather in a 13.82-second production-path search harness
run: ready 0.00 s, setup 3.36 s, search 9.66 s, final capture 0.80 s. A preceding
attempt stopped safely because it could not prove a post-action frame; the
debug harness does not establish the same background allowance as a full run.
A full AI run opened the actual Weather app and completed in about 79 seconds.
The first search's six source observations were unknown; the actor recovered
using the already-present Weather result. This demonstrates completion, but
does not count as a reliable new-query typing pass. It motivated build 24's
transient-menu fix. Board framebuffer captures during the real run showed
step 1, Search, Chinese action text, and the final Completed state.

Private screenshots, raw phone logs, synthetic events and recovery binaries
stay in ignored output folders. Cellular data and PULSE's per-app cellular
permission remain disabled. LCSign transfer services are disabled outside
installation. Final build-24 device results and phone lock will be recorded
after remaining device tests.
