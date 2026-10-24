#include "../hid_bridge/src/clicker/engine.h"
#include "../hid_bridge/src/clicker/integrity.h"
#include <array>
#include <cassert>
#include <cstdio>
#include <memory>
using namespace clicker;
int main() {
  assert(crc32("123456789", 9) == 0xcbf43926u);
  auto p = std::make_unique<Profile>();
  p->count = 1000;
  auto h = recordHeader(p.get(), sizeof *p);
  const size_t fileSize = sizeof h + sizeof *p;
  assert(validRecord(h, fileSize, p.get(), sizeof *p));
  for (size_t truncated : {size_t(0), sizeof h, fileSize - 1})
    assert(!validRecord(h, truncated, p.get(), sizeof *p));
  auto bad = h;
  ++bad.version;
  assert(!validRecord(bad, fileSize, p.get(), sizeof *p));
  bad = h;
  ++bad.size;
  assert(!validRecord(bad, fileSize, p.get(), sizeof *p));
  ++p->points[999].x;
  assert(!validRecord(h, fileSize, p.get(), sizeof *p));
  std::array<uint8_t, 196608> buffer{}, source{};
  for (size_t i = 0; i < source.size(); ++i)
    source[i] = uint8_t(i * 31);
  size_t used = 0;
  assert(
      !appendChunk(buffer.data(), buffer.size(), used, 5, source.data(), 10));
  for (size_t offset = 0; offset < source.size(); offset += 192) {
    assert(appendChunk(buffer.data(), buffer.size(), used, offset,
                       source.data() + offset, 192));
    size_t before = used;
    assert(appendChunk(buffer.data(), buffer.size(), used, offset,
                       source.data() + offset, 192));
    assert(used == before);
  }
  assert(buffer == source && used == source.size());
  uint8_t conflict = uint8_t(buffer[0] ^ 1);
  assert(!appendChunk(buffer.data(), buffer.size(), used, 0, &conflict, 1));
  assert(!appendChunk(buffer.data(), buffer.size(), used, SIZE_MAX,
                      source.data(), 1));
  assert(!appendChunk(buffer.data(), buffer.size(), used, buffer.size(),
                      source.data(), 1));
  assert(!appendChunk(buffer.data(), buffer.size(), used, 0, source.data(), 0));
  std::puts("record/transfer: PASS (CRC, truncation, version, corruption, "
            "192KB upload, retries, order, bounds)");
}
