// BLE GATT link to the iOS app (docs/ble-protocol.md): cmd/reply, status heartbeat,
// video chunks and the encrypted `net` characteristic. h2zero NimBLE-Arduino; build with flash.sh
// (it force-includes nimble_cfg.h, the host buffer sizes).
#pragma once
#include <Arduino.h>

void ble_begin(const String &name);
bool ble_connected();
bool ble_pop_cmd(String &line, uint32_t wait_ms);  // next `cmd` write, oldest first
void ble_reply(const String &line);                // queued; sent before any further video
void ble_status(const String &json);               // latest wins; sent before any further video
size_t ble_video_room();                           // payload bytes per video notify; 0 = nobody listening
bool ble_video_send(const uint8_t *p, size_t n);   // waits for free buffers; false = gave up
void ble_unpair();

uint16_t ble_mtu();
uint8_t ble_phy();       // 1 or 2 (Mbit)
uint32_t ble_kbps();     // video bytes out, last second
uint32_t ble_drops();    // video notifies we failed to send
uint32_t ble_reply_drops();  // replies that never got out to a subscribed peer
int ble_peers();         // connected centrals
bool ble_mouse_connected();
String ble_mouse_label(); // friendly label when supplied by this bonded peer; otherwise its ID suffix
int ble_controller_peers(); // subscribed controller apps, distinct from HID output
String ble_mouse_status_json();  // connection state only; no addresses or keys
bool ble_mouse_send(uint8_t buttons, int8_t dx, int8_t dy, int8_t wheel = 0, int8_t pan = 0);
bool ble_keyboard_send(uint8_t modifiers, const uint8_t keys[6]);
bool ble_consumer_send(uint16_t usage);
void ble_hid_priority(bool active); // pause video until a manual HID command completes
