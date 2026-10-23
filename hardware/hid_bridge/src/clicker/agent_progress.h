#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cerrno>
#include "utf8.h"
namespace clicker {
// Fixed-size telemetry, independent of the HID scheduler and profile storage.
struct AgentProgress {
  uint32_t run = 0, atMs = 0, elapsed = 0;
  unsigned step = 0, limit = 0, frameMs = 0, modelMs = 0, hidMs = 0;
  char phase[16] = "idle", action[32] = "Ready";
  char summary[97] = ""; // Optional public action summary, never raw reasoning.
  bool active() const {
    return run && std::strcmp(phase, "done") && std::strcmp(phase, "failed") &&
           std::strcmp(phase, "stopped") && std::strcmp(phase, "idle");
  }
  bool visible(uint32_t now) const { return run && (active() || uint32_t(now - atMs) < 15000); }
  bool stale(uint32_t now) const { return active() && uint32_t(now - atMs) >= 8000; }
  bool update(const char *line, uint32_t now) {
    AgentProgress next;
    if (!line || std::strlen(line) >= 272) return false;
    char text[272]; std::memcpy(text, line, std::strlen(line) + 1);
    char *parts[9], *p = text;
    for (auto &part : parts) {
      while (*p == ' ') ++p;
      if (!*p) return false;
      part = p;
      while (*p && *p != ' ') ++p;
      if (*p) *p++ = 0;
    }
    while (*p == ' ') ++p;
    if (*p) {
      if (*p++ != '|') return false;
      if (std::strlen(p) >= sizeof next.summary || !validSummary(p)) return false;
      std::memcpy(next.summary, p, std::strlen(p) + 1);
    }
    if (std::strlen(parts[1]) >= sizeof next.phase || std::strlen(parts[8]) >= sizeof next.action) return false;
    const int positions[] = {0, 2, 3, 4, 5, 6, 7};
    uint32_t numbers[7];
    for (unsigned i = 0; i < 7; ++i) {
      const char *value = parts[positions[i]];
      for (const char *q = value; *q; ++q) if (*q < '0' || *q > '9') return false;
      errno = 0; char *end;
      auto n = std::strtoul(value, &end, 10);
      if (errno || *end || n > UINT32_MAX) return false;
      numbers[i] = uint32_t(n);
    }
    next.run = numbers[0]; next.step = numbers[1]; next.limit = numbers[2];
    next.frameMs = numbers[3]; next.modelMs = numbers[4]; next.hidMs = numbers[5]; next.elapsed = numbers[6];
    std::memcpy(next.phase, parts[1], std::strlen(parts[1]) + 1);
    std::memcpy(next.action, parts[8], std::strlen(parts[8]) + 1);
    const char *phases[] = {"preparing", "looking", "waiting", "planning", "thinking", "acting", "retrying", "help", "stopping", "done", "failed", "stopped"};
    bool valid = false;
    for (auto phase : phases) if (!std::strcmp(next.phase, phase)) valid = true;
    if (!valid || !next.run || next.run < run || next.limit > 1000 || next.step > next.limit ||
        next.frameMs > 3600000 || next.modelMs > 3600000 || next.hidMs > 3600000 ||
        next.elapsed > 604800) return false;
    // A delayed heartbeat cannot revive a terminal run.
    if (next.run == run && !active() && next.active()) return false;
    for (const char *p = next.action; *p; ++p)
      if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
            (*p >= '0' && *p <= '9') || *p == '_' || *p == '-')) return false;
    next.atMs = now;
    *this = next;
    return true;
  }
};
} // namespace clicker
