#pragma once
#include <cstdint>
#include <cstddef>
namespace clicker {
// Strict, bounded decoding: reject overlong encodings, surrogates and truncation.
inline bool nextUtf8(const char *&text, uint32_t &code) {
  const auto *p = reinterpret_cast<const unsigned char *>(text);
  if (!*p) return false;
  unsigned count = 0; uint32_t minimum = 0;
  if (*p < 0x80) { code = *p; count = 1; }
  else if (*p >= 0xc2 && *p <= 0xdf) { code = *p & 31; count = 2; minimum = 0x80; }
  else if (*p >= 0xe0 && *p <= 0xef) { code = *p & 15; count = 3; minimum = 0x800; }
  else if (*p >= 0xf0 && *p <= 0xf4) { code = *p & 7; count = 4; minimum = 0x10000; }
  else { ++text; return false; }
  for (unsigned i = 1; i < count; ++i) {
    if (!p[i] || (p[i] & 0xc0) != 0x80) { ++text; return false; }
    code = (code << 6) | (p[i] & 63);
  }
  if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) { ++text; return false; }
  text += count;
  return true;
}
inline bool validSummary(const char *text) {
  while (*text) {
    uint32_t code;
    if (!nextUtf8(text, code) || code < 32 || (code >= 0x7f && code <= 0x9f) ||
        (code >= 0x2028 && code <= 0x202e) || (code >= 0x2066 && code <= 0x2069)) return false;
  }
  return true;
}
} // namespace clicker
