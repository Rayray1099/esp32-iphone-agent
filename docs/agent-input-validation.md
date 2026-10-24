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

English typing is not yet verified working. In a private synthetic Safari
fixture, typing `Abc123_XyZ` produced `Aㄖㄏㄅㄉˇ_XㄗZ`. DOM keyboard events
confirmed the expected physical codes (`KeyB`, etc.), while iOS translated
unshifted keys to phonetic symbols. Selecting English using the software globe
or Ctrl-Space menu did not repair it. iOS General > Keyboard did not show a
Hardware Keyboard entry. A normal Bluetooth reconnect after the registration
fix also did not repair it. A fresh device pairing is pending.

The registration firmware was flashed only to app slot 0 at 0x20000; flash
verification passed. Its SHA256 is
`edec93ae03f2c1a7a9555efc8eaacf81e00d708038d42bd3f1894347c8d11f4b`.
All five profiles, calibration storage, and the bond remain present. The
pre-change app-slot backup has 3,014,656 bytes and SHA256
`c8e9ae3500173bd4aedb548700c27bba211d48f340e4b11e23e50c462213808b`;
the running image portion matches the preceding firmware hash. The first
921600-baud backup read failed with a corrupt packet; the 460800 retry passed.
Bootloader, partitions, NVS and profile flash were not rewritten.

`tools/phone_keyboard_server.py` serves a LAN-only synthetic input fixture and
records key codes, translated keys, input and composition events. Use only
synthetic strings. It records sequence numbers because concurrent HTTP arrival
order is not guaranteed; writes are serialized. Local event output is ignored
by Git and contains no fixture screenshots in the committed source.

## Validation

`python tools/host_tests.py` passes scheduler, persistence/transfer, progress,
framebuffer generation and five OTA tests. The ESP-IDF firmware compiles,
links and fits its app partition. Swift syntax and whitespace checks pass.
Extracted actual Swift functions passed three recovery scenarios and five
fixture pixel/classifier scenarios on Windows; actual Vision execution needs
macOS XCTest. Build 20 CI passed simulator tests and device packaging; the
physical phone currently has build 18, so that is not production validation of
the new source selector.

Build 21 combines the crop/highlight/release-frame changes. Its simulator tests,
device installation, physical typing, and search timings are pending.

Mouse movement pacing stays at 16 ms per BLE report and 150 ms settling, with
separate axes for released movement. Earlier 24/24 small-target results belong
to the preceding mouse validation, not to this keyboard change. No new speed
or task-completion claim is made before physical tests.
