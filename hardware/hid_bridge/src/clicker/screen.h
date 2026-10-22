#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
namespace clicker {
struct ScreenData {
  const char *profile = "No saved profile";
  const char *network = "offline";
  const char *ip = "";
  const char *usb = "disconnected";
  const char *ble = "off";
  const char *vpn = "off";
  const char *error = "";
  const char *ssid = "";
  const char *password = "";
  const char *token = "";
  const char *ota = "idle";
  uint64_t clicks = 0;
  uint32_t loops = 0, late = 0, heap = 0, psram = 0, uptime = 0;
  unsigned schedules = 0, point = 0;
  double cps = 0;
  bool running = false;
};
// Small fixed font and renderer shared by the firmware and host capture
// fixture.
class Screen {
public:
  static constexpr int Width = 320, Height = 240;
  explicit Screen(uint16_t *pixels) : fb(pixels) {}
  void render(int page, const ScreenData &d) {
    fill(0, 0, 320, 240, 0x0862);
    fill(0, 0, 320, 30, 0x18e5);
    text(10, 8, "S3 CLICKER", 2, 0xffff);
    const char *titles[] = {"RUN", "CONNECTIONS", "SYSTEM", "SETUP / UPDATE"};
    text(10, 40, titles[page % 4], 2, 0x4fbc);
    char b[96];
    if (page == 0) {
      text(10, 66, d.profile, 2, 0xffff);
      text(10, 91, d.running ? "RUNNING" : "STOPPED", 2,
           d.running ? 0x67e9 : 0xfdaa);
      snprintf(b, sizeof b, "%llu CLICKS", (unsigned long long)d.clicks);
      text(10, 119, b, 2, 0xffff);
      snprintf(b, sizeof b, "USB %.1f CPS", d.cps);
      text(10, 145, b, 2, 0x4fbc);
      snprintf(b, sizeof b, "%u SCHEDULES   POINT %u", d.schedules,
               d.point + 1);
      text(10, 176, b, 1, 0xffff);
      snprintf(b, sizeof b, "LOOPS %lu   LATE %lu", (unsigned long)d.loops,
               (unsigned long)d.late);
      text(10, 193, b, 1, 0xffff);
    } else if (page == 1) {
      row(69, "MODE", d.network);
      row(91, "SSID", d.ssid);
      row(113, "IP", d.ip);
      row(135, "USB", d.usb);
      row(157, "BLE", d.ble);
      row(179, "TAILNET", d.vpn);
    } else if (page == 2) {
      row(69, "FIRMWARE", "0.2.0 / S3 N8R8");
      snprintf(b, sizeof b, "%lu SEC", (unsigned long)d.uptime);
      row(91, "UPTIME", b);
      snprintf(b, sizeof b, "%lu B", (unsigned long)d.heap);
      row(113, "HEAP", b);
      snprintf(b, sizeof b, "%lu B", (unsigned long)d.psram);
      row(135, "PSRAM", b);
      snprintf(b, sizeof b, "%lu", (unsigned long)d.late);
      row(157, "LATE", b);
      row(179, "ERROR", d.error);
    } else {
      row(68, "HOTSPOT", d.ssid);
      row(88, "PASSWORD", d.password);
      row(108, "OPEN", "HTTP://192.168.4.1");
      text(10, 133, "CONTROLLER TOKEN", 1, 0x4fbc);
      text(10, 149, d.token, 1, 0xffff);
      row(176, "UPDATE", d.ota);
      text(10, 197, "HOLD BOOT 4 SEC FOR SETUP", 1, 0xffff);
    }
    fill(0, 218, 320, 22, 0x18e5);
    text(8, 225, "BOOT: CYCLE / HOLD 1S START / PRESS STOP", 1, 0xffff);
  }

private:
  uint16_t *fb;
  void fill(int x, int y, int w, int h, uint16_t c) {
    for (int j = y; j < y + h && j < 240; j++)
      for (int i = x; i < x + w && i < 320; i++)
        if (i >= 0 && j >= 0)
          fb[j * 320 + i] = c;
  }
  void row(int y, const char *label, const char *value) {
    text(10, y, label, 1, 0x4fbc);
    text(90, y, value, 1, 0xffff);
  }
  static const char *glyph(char c) {
    static const char *letters[] = {
        "0111010001111111000110001", "1111010001111101000111110",
        "0111110000100001000001111", "1111010001100011000111110",
        "1111110000111101000011111", "1111110000111101000010000",
        "0111110000101111000101111", "1000110001111111000110001",
        "1111100100001000010011111", "0011100010000101001001100",
        "1000110010111001001010001", "1000010000100001000011111",
        "1000111011101011000110001", "1000111001101011001110001",
        "0111010001100011000101110", "1111010001111101000010000",
        "0111010001100011001101111", "1111010001111101001010001",
        "0111110000011100000111110", "1111100100001000010000100",
        "1000110001100011000101110", "1000110001100010101000100",
        "1000110001101011101110001", "1000101010001000101010001",
        "1000101010001000010000100", "1111100010001000100011111"};
    static const char *digits[] = {
        "0111010011101011100101110", "0010001100001000010001110",
        "0111010001000100010011111", "1111000001001100000111110",
        "0001000110010101111100010", "1111110000111100000111110",
        "0111010000111101000101110", "1111100001000100010001000",
        "0111010001011101000101110", "0111010001011110000101110"};
    if (c >= 'a' && c <= 'z')
      c -= 32;
    if (c >= 'A' && c <= 'Z')
      return letters[c - 'A'];
    if (c >= '0' && c <= '9')
      return digits[c - '0'];
    if (c == '.')
      return "0000000000000000000000100";
    if (c == ':')
      return "0000000100000000010000000";
    if (c == '/')
      return "0000100010001000100010000";
    if (c == '-')
      return "0000000000111110000000000";
    return "0000000000000000000000000";
  }
  void text(int x, int y, const char *s, int scale, uint16_t c) {
    if (!s)
      return;
    for (; *s && x + 5 * scale < 320; s++, x += 6 * scale) {
      auto *g = glyph(*s);
      for (int j = 0; j < 5; j++)
        for (int i = 0; i < 5; i++)
          if (g[j * 5 + i] == '1')
            fill(x + i * scale, y + j * scale, scale, scale, c);
    }
  }
};
} // namespace clicker
