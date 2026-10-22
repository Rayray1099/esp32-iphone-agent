#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace clicker {
constexpr size_t MaxProfiles = 32, MaxPoints = 1000, MaxSchedules = 16;
constexpr uint32_t MaxIntervalUs = 3600000000U;
struct Point {
  uint16_t x = 5000,
           y = 5000; // normalized 0..10000 in the profile's orientation
  uint32_t pressUs = 1000, delayUs = 5000;
  bool enabled = true;
};
struct Profile {
  char name[49] = "Untitled";
  uint16_t count = 0;
  uint32_t repeats = 0; // 0 = forever, 1 = once
  bool landscape = false, fast = false;
  Point points[MaxPoints];
};
struct Calibration {
  int32_t spanX = 0,
          spanY = 0; // measured HID units; never assume a phone's dimensions
  uint32_t moveIntervalUs = 8000;
  uint16_t rehomeLoops = 10;
  bool landscape = false;
};
struct Report {
  uint8_t buttons;
  int8_t dx, dy;
};
struct Transport {
  virtual ~Transport() = default;
  virtual bool connected() const = 0;
  // True means USB completion, not merely queued. False must not advance state.
  virtual bool send(Report) = 0;
};
struct Stats {
  uint64_t clicks = 0, reports = 0, late = 0, maxLateUs = 0, startedUs = 0;
  uint32_t loops = 0;
  uint16_t point = 0;
  uint8_t active = 0;
  bool running = false, releasing = false;
};
inline bool valid(const Profile &p) {
  if (!p.count || p.count > MaxPoints)
    return false;
  bool enabled = false;
  for (size_t i = 0; i < p.count; ++i) {
    const auto &q = p.points[i];
    if (q.x > 10000 || q.y > 10000 || q.pressUs < 1 ||
        q.pressUs > MaxIntervalUs || q.delayUs < 1 || q.delayUs > MaxIntervalUs)
      return false;
    enabled |= q.enabled;
  }
  return enabled;
}

// Single owner, fixed runtime storage, one outstanding report, no allocation or
// OS calls. The caller supplies a monotonic clock and services the transport
// outside the display/network tasks.
class Engine {
public:
  explicit Engine(Transport &transport) : usb(transport) {}
  bool start(const Profile *const *profiles, size_t count,
             Calibration calibration, uint64_t now) {
    if (s.running || s.releasing || !count || count > MaxSchedules ||
        !usb.connected() || calibration.spanX < 1 || calibration.spanY < 1 ||
        calibration.spanX > 32000 || calibration.spanY > 32000 ||
        calibration.moveIntervalUs < 1000)
      return false;
    for (size_t i = 0; i < count; ++i)
      if (!profiles[i] || !valid(*profiles[i]) ||
          profiles[i]->landscape != calibration.landscape)
        return false;
    cal = calibration;
    s = {};
    s.running = true;
    s.active = uint8_t(count);
    s.startedUs = now;
    slots = {};
    cursor = 0;
    owner = -1;
    phase = Phase::Home;
    home = 0;
    due = now;
    px = py = 0;
    rehomedLoops = 0;
    for (size_t i = 0; i < count; ++i) {
      slots[i].p = profiles[i];
      slots[i].due = now;
      skip(slots[i]);
    }
    return true;
  }
  void stop() {
    s.running = false;
    s.active = 0;
    s.releasing = true;
    owner = -1;
  }
  const Stats &stats() const { return s; }
  void tick(uint64_t now) {
    if (!usb.connected()) {
      if (s.running)
        stop();
      return;
    }
    if (s.releasing) {
      if (emit({0, 0, 0})) {
        s.releasing = false;
        held = false;
      }
      return;
    }
    if (!s.running || now < due)
      return;
    if (phase == Phase::Home) {
      if (!emit({0, -127, -127}))
        return;
      due = now + 2000;
      if (++home >= 255) {
        px = py = 0;
        phase = Phase::Select;
      }
      return;
    }
    if (phase == Phase::Select) {
      owner = choose(now);
      if (owner < 0)
        return;
      auto &slot = slots[size_t(owner)];
      const auto &p = slot.p->points[slot.point];
      uint64_t lateness = now - slot.due;
      if (lateness > 1000) {
        ++s.late;
        s.maxLateUs = std::max(s.maxLateUs, lateness);
      }
      tx = int32_t(int64_t(p.x) * cal.spanX / 10000);
      ty = int32_t(int64_t(p.y) * cal.spanY / 10000);
      s.point = slot.point;
      phase = Phase::Move;
    }
    if (phase == Phase::Move) {
      int32_t dx = std::clamp<int32_t>(tx - px, -10, 10);
      int32_t dy = std::clamp<int32_t>(ty - py, -10, 10);
      if (dx || dy) {
        if (!emit({0, int8_t(dx), int8_t(dy)}))
          return;
        px += dx;
        py += dy;
        due = now + cal.moveIntervalUs;
        return;
      }
      phase = Phase::Press;
    }
    auto &slot = slots[size_t(owner)];
    const auto &p = slot.p->points[slot.point];
    if (phase == Phase::Press) {
      if (!emit({1, 0, 0}))
        return;
      held = true;
      phase = Phase::Release;
      due = now + p.pressUs;
      return;
    }
    if (phase == Phase::Release) {
      if (!emit({0, 0, 0}))
        return;
      held = false;
      ++s.clicks;
      // Backpressure rebases this schedule on its completion. Never catch up
      // with a burst.
      slot.due = now + p.delayUs;
      do {
        if (++slot.point == slot.p->count) {
          slot.point = 0;
          ++slot.loops;
          ++s.loops;
          if (slot.p->repeats && slot.loops >= slot.p->repeats) {
            slot.p = nullptr;
            --s.active;
            break;
          }
        }
      } while (!slot.p->points[slot.point].enabled);
      cursor = (size_t(owner) + 1) % MaxSchedules;
      owner = -1;
      phase = Phase::Select;
      due = now;
      if (!s.active) {
        s.running = false;
        return;
      }
      if (cal.rehomeLoops && s.loops - rehomedLoops >= cal.rehomeLoops) {
        phase = Phase::Home;
        home = 0;
        rehomedLoops = s.loops;
      }
    }
  }

private:
  enum class Phase { Home, Select, Move, Press, Release };
  struct Slot {
    const Profile *p = nullptr;
    uint16_t point = 0;
    uint32_t loops = 0;
    uint64_t due = 0;
  };
  Transport &usb;
  Calibration cal;
  Stats s;
  std::array<Slot, MaxSchedules> slots{};
  Phase phase = Phase::Select;
  size_t cursor = 0;
  int owner = -1;
  uint16_t home = 0;
  uint64_t due = 0;
  int32_t px = 0, py = 0, tx = 0, ty = 0;
  bool held = false;
  uint32_t rehomedLoops = 0;
  bool emit(Report r) {
    if (!usb.send(r))
      return false;
    ++s.reports;
    return true;
  }
  static void skip(Slot &slot) {
    // Disabled trailing points still complete a loop; bound the scan to one
    // validated profile.
    while (!slot.p->points[slot.point].enabled)
      slot.point = uint16_t((slot.point + 1) % slot.p->count);
  }
  int choose(uint64_t now) const {
    int best = -1;
    uint64_t earliest = UINT64_MAX;
    for (size_t n = 0; n < MaxSchedules; ++n) {
      size_t i = (cursor + n) % MaxSchedules;
      if (slots[i].p && slots[i].due <= now && slots[i].due < earliest) {
        earliest = slots[i].due;
        best = int(i);
      }
    }
    return best;
  }
};
} // namespace clicker
