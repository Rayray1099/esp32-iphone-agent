#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace clicker {
inline uint32_t crc32(const void *data, size_t n) {
  uint32_t c = ~0u;
  auto *p = static_cast<const uint8_t *>(data);
  while (n--) {
    c ^= *p++;
    for (int b = 0; b < 8; ++b)
      c = (c >> 1) ^ (0xedb88320u & uint32_t(-int32_t(c & 1)));
  }
  return ~c;
}
struct RecordHeader {
  uint32_t magic = 0x32504353, version = 1, size = 0, crc = 0;
};
inline RecordHeader recordHeader(const void *data, size_t size) {
  return {0x32504353, 1, uint32_t(size), crc32(data, size)};
}
inline bool validRecord(const RecordHeader &h, size_t fileSize,
                        const void *data, size_t size) {
  return h.magic == 0x32504353 && h.version == 1 && h.size == size &&
         fileSize == sizeof(h) + size && h.crc == crc32(data, size);
}
// One sequential upload, with idempotent retries. Bounds are checked before
// subtraction or memory access so a malformed offset cannot wrap around.
inline bool appendChunk(uint8_t *buffer, size_t size, size_t &used,
                        size_t offset, const uint8_t *data, size_t count) {
  if (!buffer || !data || !count || used > size || offset > size ||
      count > size - offset)
    return false;
  if (offset == used) {
    memcpy(buffer + offset, data, count);
    used += count;
    return true;
  }
  return offset <= used && count <= used - offset &&
         !memcmp(buffer + offset, data, count);
}
} // namespace clicker
