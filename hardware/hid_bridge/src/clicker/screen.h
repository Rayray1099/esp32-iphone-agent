#pragma once
#include "../qrcode/qrcodegen.h"
#include "smooth_font.h"
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
  uint16_t stateColor() const {
    return releasing ? 0xfc6e : running ? 0x6ff3 : !inputConnected ? 0xfa6b : 0xfdc6;
  }
  uint32_t animationMs = 0;
  float history[24]{};
};
// Bounded font rasterizer shared by firmware and host capture fixtures.
class Screen {
public:
  static constexpr int Width = 320, Height = 240;
  explicit Screen(uint16_t *pixels) : fb(pixels) {}
  void render(int page, const ScreenData &d) {
    constexpr uint16_t bg = 0x0863, muted = 0x8495;
    constexpr uint16_t cyan = 0x57ff, mint = 0x6ff3, white = 0xf7bf;
    fill(0, 0, Width, Height, bg);
    for (int i = 0; i < 5; ++i) {
      const int heights[] = {5, 10, 18, 10, 5};
      rounded(18 + i * 3, 24 - heights[i] / 2, 2, heights[i], 1, cyan);
    }
    smooth(40, 13, "PULSE", font14, white);
    const char *titles[] = {"LIVE", "LINK", "SYSTEM", "SETUP"};
    if (page != 0) smooth(249, 15, titles[page % 4], font11, muted);
    char b[96];
    if (page == 0) {
      const uint16_t stateColor = d.stateColor();
      const char *title = d.releasing ? "Stopping" : d.running ? "Clicking" : d.inputConnected ? "Stopped" : "Disconnected";
      rounded(207, 13, 95, 21, 10, 0x1126);
      smooth(218, 16, std::strcmp(d.output, "BT") == 0 ? "BLUETOOTH" : "USB OUTPUT", font11, cyan);
      smooth(18, 43, title, font26, stateColor);
      smooth(19, 78, d.inputConnected ? d.target : "Pair a phone to start", font11, muted, 287);
      fill(18, 99, 284, 1, 0x1947);
      const double rate = d.cps < 0 ? 0 : d.cps > 999.9 ? 999.9 : d.cps;
      snprintf(b, sizeof b, "%.1f", rate);
      smooth(15, 98, b, font58, cyan);
      smooth(226, 114, "CPS", font18, cyan);
      smooth(226, 140, d.running ? "LIVE RATE" : "LAST RUN", font11, muted);
      rounded(18, 164, 284, 3, 1, 0x1947);
      int width = d.requestedCps > 0 ? int(284 * rate / d.requestedCps) : 0;
      rounded(18, 164, width > 284 ? 284 : width, 3, 1, d.running ? mint : 0x326d);
      if (d.running) {
        int pulse = int(d.animationMs / 80 % 278);
        rounded(18 + pulse, 163, 6, 5, 2, mint);
      }
      smooth(18, 176, "Clicks", font11, muted);
      snprintf(b, sizeof b, "%llu", (unsigned long long)d.clicks);
      smooth(18, 192, b, font14, white, 99);
      fill(114, 181, 1, 25, 0x1947);
      smooth(130, 176, "Loops", font11, muted);
      snprintf(b, sizeof b, "%lu", (unsigned long)d.loops); smooth(130, 192, b, font14, white, 73);
      fill(212, 181, 1, 25, 0x1947);
      smooth(228, 176, "Requested", font11, muted);
      snprintf(b, sizeof b, "%.0f /s", d.requestedCps); smooth(228, 192, b, font14, white, 78);
    } else if (page == 1) {
      smooth(18, 43, "Connections", font26, white);
      row(78, "Target", d.target);
      snprintf(b, sizeof b, "%u app / %s", d.controllers, d.ble); row(97, "Control", b);
      row(116, "USB", d.usb); row(135, "Mode", d.network);
      row(154, "SSID", d.ssid); row(173, "IP", d.ip); row(192, "Tailnet", d.vpn);
    } else if (page == 2) {
      smooth(18, 43, "System", font26, white);
      row(78, "Firmware", "0.3.2 / ESP32-S3");
      snprintf(b, sizeof b, "%lu sec", (unsigned long)d.uptime); row(97, "Uptime", b);
      snprintf(b, sizeof b, "%lu B", (unsigned long)d.heap); row(116, "Heap", b);
      snprintf(b, sizeof b, "%lu B", (unsigned long)d.psram); row(135, "PSRAM", b);
      snprintf(b, sizeof b, "%lu", (unsigned long)d.late); row(154, "Late", b);
      row(173, "Error", d.error && *d.error ? d.error : "None"); row(192, "Reset", d.reset);
    } else {
      smooth(18, 43, "Setup", font26, white);
      smooth(18, 80, d.ssid, font11, white, 177);
      smooth(18, 99, d.password, font11, cyan, 177);
      smooth(18, 122, "Scan to join Wi-Fi", font11, muted, 177);
      smooth(18, 139, "192.168.4.1", font14, white, 177);
      qr(d.qr, 211, 81);
      smooth(18, 165, "CONTROLLER TOKEN", font11, muted);
      smooth(18, 181, d.token, font11, white, 284);
      row(199, "Update", d.ota);
    }
    fill(18, 216, 284, 1, 0x1947);
    if (page == 0) {
      smooth(18, 222, d.profile, font11, muted, 208);
      rounded(247, 226, 4, 4, 2, d.controllers ? mint : muted);
      snprintf(b, sizeof b, "%u app", d.controllers); smooth(260, 222, b, font11, muted);
    } else {
      smooth(18, 222, d.runState(), font11, d.stateColor(), 86);
      smooth(111, 222, "BOOT 1s start / press stop", font11, muted);
    }
  }

private:
  uint16_t *fb;
  static uint16_t blend(uint16_t bg, uint16_t fg, unsigned alpha) {
    unsigned r = (((bg >> 11) & 31) * (15 - alpha) + ((fg >> 11) & 31) * alpha + 7) / 15;
    unsigned g = (((bg >> 5) & 63) * (15 - alpha) + ((fg >> 5) & 63) * alpha + 7) / 15;
    unsigned b = ((bg & 31) * (15 - alpha) + (fg & 31) * alpha + 7) / 15;
    return (r << 11) | (g << 5) | b;
  }
  void smooth(int x, int y, const char *value, const SmoothFont &font, uint16_t color, int maxWidth = 320) {
    const int right = x + maxWidth < 320 ? x + maxWidth : 320;
    if (!value) return;
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
      const unsigned char code = *p >= font.first && *p <= font.last ? *p : '?';
      if (code < font.first || code > font.last) continue;
      const auto &glyph = font.glyphs[code - font.first];
      if (x + glyph.advance > right) break;
      for (int row = 0; row < glyph.height; ++row)
        for (int col = 0; col < glyph.width; ++col) {
          int at = row * glyph.width + col;
          unsigned packed = font.pixels[glyph.offset + at / 2];
          unsigned alpha = at % 2 ? packed & 15 : packed >> 4;
          int px = x + glyph.x + col, py = y + glyph.y + row;
          if (alpha && px >= 0 && px < right && py >= 0 && py < Height) {
            auto &pixel = fb[py * Width + px]; pixel = alpha == 15 ? color : blend(pixel, color, alpha);
          }
        }
      x += glyph.advance;
    }
  }
  void rounded(int x, int y, int w, int h, int radius, uint16_t color) {
    for (int row = 0; row < h; ++row) {
      int dy = row < radius ? radius - row : row >= h - radius ? row - (h - radius - 1) : 0;
      int inset = 0;
      while (inset < radius && (radius - inset) * (radius - inset) + dy * dy > radius * radius) ++inset;
      fill(x + inset, y + row, w - 2 * inset, 1, color);
    }
  }
  // Crisp large numerals without a font asset or runtime allocation.
  void bigNumber(int x, int y, const char *value, uint16_t color) {
    static const uint8_t segments[] = {0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f};
    for (const char *p = value; *p; ++p) {
      if (*p == '.') { fill(x + 1, y + 43, 6, 6, color); x += 12; continue; }
      if (*p == ' ') { x += 39; continue; }
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
    smooth(18, y, label, font11, 0x8495, 76);
    smooth(97, y, value, font11, 0xf7bf, 205);
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
