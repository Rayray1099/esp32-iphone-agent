#pragma once
#include "../qrcode/qrcodegen.h"
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
  const char *qr = "";
  const char *reset = "";
  const char *output = "USB";
  const char *target = "NO TARGET";
  unsigned controllers = 0;
  int rssi = 0;
  double requestedCps = 0;
  uint64_t clicks = 0;
  uint32_t loops = 0, late = 0, heap = 0, psram = 0, uptime = 0;
  unsigned schedules = 0, point = 0;
  double cps = 0;
  bool running = false;
  bool releasing = false, inputConnected = false;
  const char *runState() const {
    return releasing ? "STOPPING" : running ? "CLICKING" : !inputConnected ? "NO TARGET" : "STOPPED";
  }
  uint32_t animationMs = 0;
  float history[24]{};
};
// Small fixed font and renderer shared by the firmware and host capture
// fixture.
class Screen {
public:
  static constexpr int Width = 320, Height = 240;
  explicit Screen(uint16_t *pixels) : fb(pixels) {}
  void render(int page, const ScreenData &d) {
    constexpr uint16_t bg = 0x0843, card = 0x10a5, muted = 0x8495;
    constexpr uint16_t cyan = 0x57ff, mint = 0x6ff3, white = 0xf7bf;
    fill(0, 0, Width, Height, bg);
    fill(12, 12, 3, 14, cyan);
    text(23, 16, "S3 / PULSE", 2, white);
    const char *titles[] = {"LIVE", "LINK", "SYSTEM", "SETUP"};
    text(266, 18, titles[page % 4], 1, cyan);
    char b[96];
    if (page == 0) {
      const uint16_t stateColor = d.releasing ? 0xfd20 : d.running ? mint : d.inputConnected ? white : 0xfd20;
      fill(12, 38, 296, 28, d.running ? 0x126a : card);
      fill(21, 48, 7, 7, stateColor);
      text(38, 47, d.runState(), 2, stateColor);
      snprintf(b, sizeof b, "%s > %s", d.output, d.target);
      text(15, 75, b, 1, d.inputConnected ? cyan : 0xfd20);
      fill(12, 91, 296, 76, card);
      const double rate = d.cps < 0 ? 0 : d.cps > 999.9 ? 999.9 : d.cps;
      snprintf(b, sizeof b, "%05.1f", rate);
      bigNumber(22, 98, b, cyan);
      text(240, 110, "CPS", 2, white);
      text(240, 133, d.running ? "LIVE" : "LAST RUN", 1, muted);
      fill(23, 158, 270, 3, 0x2949);
      int width = d.requestedCps > 0 ? int(270 * rate / d.requestedCps) : 0;
      fill(23, 158, width > 270 ? 270 : width, 3, mint);
      if (d.running) {
        int pulse = int(d.animationMs / 80 % 266);
        fill(23 + pulse, 157, 5, 5, white);
      }
      fill(12, 174, 143, 38, card);
      fill(164, 174, 144, 38, card);
      text(22, 181, "CLICKS", 1, muted);
      snprintf(b, sizeof b, "%llu", (unsigned long long)d.clicks);
      text(22, 195, b, 2, white);
      text(175, 181, "TARGET / LOOPS", 1, muted);
      snprintf(b, sizeof b, "%u / %lu", d.point + 1, (unsigned long)d.loops);
      text(175, 195, b, 2, white);
    } else if (page == 1) {
      text(14, 43, "CONNECTIONS", 2, white);
      row(68, "TARGET", d.target);
      snprintf(b, sizeof b, "%u APP / %s", d.controllers, d.ble); row(88, "CONTROL", b);
      row(108, "USB", d.usb); row(128, "MODE", d.network);
      row(148, "SSID", d.ssid); row(168, "IP", d.ip); row(188, "TAILNET", d.vpn);
      snprintf(b, sizeof b, "RSSI %d DBM", d.rssi); text(14, 205, b, 1, muted);
    } else if (page == 2) {
      text(14, 43, "SYSTEM HEALTH", 2, white);
      row(69, "FIRMWARE", "0.3.1 / ESP32-S3");
      snprintf(b, sizeof b, "%lu SEC", (unsigned long)d.uptime); row(91, "UPTIME", b);
      snprintf(b, sizeof b, "%lu B", (unsigned long)d.heap); row(113, "HEAP", b);
      snprintf(b, sizeof b, "%lu B", (unsigned long)d.psram); row(135, "PSRAM", b);
      snprintf(b, sizeof b, "%lu", (unsigned long)d.late); row(157, "LATE", b);
      row(179, "ERROR", d.error && *d.error ? d.error : "NONE"); row(200, "RESET", d.reset);
    } else {
      text(14, 43, "SETUP / UPDATE", 2, white);
      text(14, 69, d.ssid, 1, white); text(14, 87, d.password, 1, cyan);
      text(14, 108, "SCAN TO JOIN", 1, muted); text(14, 126, "192.168.4.1", 1, white);
      qr(d.qr, 205, 70);
      text(14, 153, "CONTROLLER TOKEN", 1, muted); text(14, 166, d.token, 1, white);
      row(188, "UPDATE", d.ota); text(14, 204, "HOLD BOOT 4S FOR SETUP", 1, muted);
    }
    fill(0, 220, 320, 20, 0x10a5);
    if (page == 0) {
      text(12, 226, d.profile, 1, white);
    } else {
      text(12, 226, d.runState(), 1, d.running ? mint : white);
      text(83, 226, "BOOT 1S START / PRESS STOP", 1, white);
    }
  }

private:
  uint16_t *fb;
  // Crisp large numerals without a font asset or runtime allocation.
  void bigNumber(int x, int y, const char *value, uint16_t color) {
    static const uint8_t segments[] = {0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f};
    for (const char *p = value; *p; ++p) {
      if (*p == '.') { fill(x + 1, y + 43, 6, 6, color); x += 12; continue; }
      if (*p < '0' || *p > '9') continue;
      uint8_t mask = segments[*p - '0'];
      const int lines[7][4] = {{5,0,22,5},{27,5,5,18},{27,28,5,18},
        {5,46,22,5},{0,28,5,18},{0,5,5,18},{5,23,22,5}};
      for (int i = 0; i < 7; ++i)
        fill(x + lines[i][0], y + lines[i][1], lines[i][2], lines[i][3], mask & (1 << i) ? color : 0x1927);
      x += 39;
    }
  }
  void qr(const char *data, int x, int y) {
    if (!data || !*data)
      return;
    uint8_t scratch[qrcodegen_BUFFER_LEN_FOR_VERSION(6)],
        code[qrcodegen_BUFFER_LEN_FOR_VERSION(6)];
    if (!qrcodegen_encodeText(data, scratch, code, qrcodegen_Ecc_LOW, 1, 6,
                              qrcodegen_Mask_AUTO, true))
      return;
    int size = qrcodegen_getSize(code);
    int scale = 2;
    fill(x - 8, y - 8, (size + 8) * scale, (size + 8) * scale, 0xffff);
    for (int j = 0; j < size; ++j)
      for (int i = 0; i < size; ++i)
        if (qrcodegen_getModule(code, i, j))
          fill(x + i * scale, y + j * scale, scale, scale, 0);
  }
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
