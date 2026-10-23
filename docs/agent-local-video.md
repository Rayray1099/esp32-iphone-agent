# Local video and background agent

The phone mirrors to the ESP32 over AirPlay. The board forwards incremental H.264
access units over authenticated local HTTP when available; bonded BLE remains the
command and HID transport and is the video fallback. OpenH264 2.6.0 performs CPU
decoding and JPEG conversion inside the app, including while another app is in front.
Run bash ios/tools/build_openh264.sh before XcodeGen. The build pins source commit
652bdb7719f30b52b08e506645a7322ff1b2cc6f and bundles its BSD license.

Local video requests disable cellular and expensive network access, use only private
IPv4 addresses received from the paired board, and reject redirects. Model requests
use the configured endpoint. To ensure the whole phone cannot use cellular,
turn cellular data off in iOS; the request setting controls only the video session.

Map ESP32 mouse **button 4** to **Home** in Settings → Accessibility → Touch →
AssistiveTouch → Devices → ESP32 Agent → Customize Additional Buttons. Send
the board command button 4 while iOS is waiting to learn the button, select Home,
and verify it returns to Home from the app. Submitting a consumer Home or Command-H
HID report does not prove iOS performed it.

The video-auth command is available only to an encrypted, bonded BLE sender. Its
reply goes only to that sender and is omitted from app debug logs. It grants the
existing local controller bearer token, so treat it as a private credential. HTTP
requires the protected board hotspot or a trusted LAN. No public endpoint is enabled.

Authenticated GET endpoints:

- /api/v1/video/gop: consistent raw Annex-B snapshot for diagnostics.
- /api/v1/video/frames?generation=N&after=K: incremental S3VF response. A generation
  change returns SPS/PPS and all units from the new IDR; subsequent requests return
  only units after K. X-Board-Uptime-Ms and X-Video-Captured-Ms support freshness checks.

S3VF uses little-endian fields: magic (4 bytes), generation (u32), next index (u32),
record count (u32), then records: capture milliseconds (u32), payload size (u32),
flags (u8: IDR=4, config=8), Annex-B payload. The producer is locked only while
copying into a bounded PSRAM snapshot; socket I/O occurs after releasing the lock.

The agent requires a decoded frame matching a recent board watermark before its
first model decision. After actions it requires a newer capture or stops.
Hardware validation is recorded separately; this describes behavior, not a claim
that a complete task has passed.
