# S3 local API v1

HTTP base /api/v1/. Send Authorization: Bearer YOUR-TFT-TOKEN on API calls.
Static editor assets are public. BLE keeps existing framing:
REQUEST-ID v1 METHOD path JSON. Versioned commands require an encrypted bonded
connection. Replies are ID ok JSON or ID err JSON. Existing HID commands remain.
Query capabilities before using extensions on another firmware.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | capabilities | Version, capacity, timing limits |
| GET | status | Full HTTP run, memory, network, VPN, OTA, errors |
| GET | run/status | Compact BLE-safe run/CPS/output/profile/network status |
| GET | profiles | Full saved summaries; use HTTP for large directories |
| GET | profiles/page/0 through profiles/page/7 | Four profile summaries per page, fits BLE response |
| GET/PUT/DELETE | profiles/0 through profiles/31 | Read/save/remove |
| POST | run/start | profiles array, fresh nonce of 8 to 64 characters |
| POST | run/stop | Stop/release request |
| GET/PUT | run/selection | Remember profiles array for BOOT/offline |
| POST | mode/offline, mode/setup | Restart stopped in chosen mode |
| GET/PUT | calibration | span_x, span_y, landscape, device |
| POST | pointer | command: home or move dx dy |
| POST | input/claim, input/release | AI mode arbitration |
| GET/PUT | input/output | Select usb or bluetooth while stopped |
| PUT | device/label | BLE only: bind a short friendly name to the authenticated sender |
| GET/PUT | network | Redacted status / Wi-Fi and enterprise config |
| GET/PUT | tailscale | Redacted status / enrollment |
| GET | logs, system/tasks | Bounded events / task and heap data |
| GET | screen | 320 x 240 BMP; HTTP only |
| POST | ota | Signed binary; HTTP only |
| POST | system/reboot | Release input, restart |

Profile example:

~~~json
{"schema":1,"name":"Fast repeat","device":"my-iphone","repeats":0,"landscape":false,"fast":true,"points":[{"x":5000,"y":5000,"press_us":1000,"delay_us":5667,"enabled":true}]}
~~~

Coordinates are 0 to 10000 in profile orientation. Device IDs use 1 to 32 ASCII
letters, digits, underscores or hyphens. Old imports use default. Concurrent
profiles must share device ID and orientation. repeats:0 means continuous.
Timing is 1 to 3,600,000,000 microseconds; at most 1000 points, one enabled.
Repeated coordinates skip movement automatically. Fast timing keeps calibrated
paced movement for distinct positions.

Large BLE documents use one active transfer, capped at 196608 bytes, expiring
after 120 seconds idle:

1. POST transfer/begin with fresh UUID id, destination path, size and crc32.
   Identical retries acknowledge current offset.
2. POST transfer/chunk with id, offset and base64 data, at most 192 decoded
   bytes. Exact duplicate chunks are acknowledged; conflicting/out-of-order
   chunks fail. Advance using acknowledged offsets.
3. POST transfer/commit with id. Byte count, CRC, schema and destination are
   checked before saving. Recent commit retries are acknowledged. Do not reuse
   committed IDs for another upload.
4. POST transfer/read with id and path:profiles/N, then transfer/read-chunk with
   id, offset, optional limit of 1 to 192. Check size/CRC before applying.
   Respect negotiated BLE payload limits.

Start nonces use a 32-entry RAM retry cache. Duplicate starts do not restart a
finished run; use a fresh nonce for an intentional new start. Cache resets on
reboot. Profile records have version/size/CRC and temp-file rename. Full physical
power-loss persistence remains to be tested.

The AI lease arbitrates modes, not separate user identities. Legacy paired
debug clients remain trusted and must not inject HID during an AI run. Use one
controller at a time for large document transfers. Passwords and enrollment
keys must never be included in logs or exported profiles.

Bluetooth output uses the encrypted HID service (0x1812), report ID 1, with
one bonded subscribed mouse host. Pair ESP32 Agent in iPhone Settings and enable
AssistiveTouch. input/output takes {"output":"bluetooth"} or {"output":"usb"}.
status.output_cps counts completed USB reports or BLE host submissions as named
by cps_basis; BLE submission is not proof that iOS accepted the tap. usb_cps
stays zero in Bluetooth mode. Offline with USB disables both radios; offline
with Bluetooth keeps BLE enabled and disables Wi-Fi. Use separate calibration
IDs for USB and Bluetooth, since pointer acceleration can differ.

Firmware 0.3.1 shows the HID target separately from subscribed controller apps.
The native app sends device/label with {"name":"iPhone"} once per encrypted
connection. Names are bounded to 24 printable ASCII characters for the TFT font;
other names fall back to PHONE. The display appends only the last two bytes of
the bonded Bluetooth identity, for example PHONE / 93:75. Labels belong to the
sending connection and are cleared on disconnect; a controller cannot label
another connected target. USB hosts appear as USB HOST because the HID device
cannot obtain their operating-system device name. input/output includes the
target label and controller count.

Deleting a saved profile repairs the remembered selection: surviving selected
profiles stay selected; otherwise the first available profile is selected. An
empty store has an empty selection. The native bulk manager sends one confirmed
DELETE per selected profile and refreshes after errors instead of blindly
retrying an uncertain deletion. Stop/release is required before deletion.

The CH340/UART and native CDC accept the same versioned debug protocol without
the BLE response-size cap. tools/board_uart.py uses UART with reset lines off.
Physical serial command 0 localinfo returns local setup credentials; the helper
requires --save-local-info and never prints them. Keep that file out of Git.
