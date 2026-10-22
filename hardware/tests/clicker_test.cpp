#include "../hid_bridge/src/clicker/button.h"
#include "../hid_bridge/src/clicker/engine.h"
#include <cassert>
#include <cstdio>
#include <memory>
#include <vector>
using namespace clicker;
struct FakeUSB : Transport {
  bool online = true, blocked = false;
  std::vector<Report> reports;
  bool connected() const override { return online; }
  bool send(Report r) override {
    if (blocked)
      return false;
    reports.push_back(r);
    return true;
  }
};
void drive(Engine &e, uint64_t &time, uint64_t duration) {
  uint64_t end = time + duration;
  for (; time < end; time += 1000)
    e.tick(time);
}
// Completion-based transport: a report is queued once and takes 1ms to finish.
struct AsyncUSB : Transport {
  bool online = true, pending = false;
  uint64_t now = 0, completeAt = 0;
  Report queued{};
  std::vector<Report> completed;
  bool connected() const override { return online; }
  bool send(Report r) override {
    if (pending) {
      if (now < completeAt)
        return false;
      completed.push_back(queued);
      pending = false;
      if (queued.buttons == r.buttons && queued.dx == r.dx && queued.dy == r.dy)
        return true;
    }
    queued = r;
    pending = true;
    completeAt = now + 1000;
    return false;
  }
};
void asynchronousAndFairness() {
  auto p = std::make_unique<Profile>();
  p->count = 1;
  p->repeats = 100;
  p->points[0] = {0, 0, 1, 1, true};
  const Profile *profiles[16];
  for (auto &ptr : profiles)
    ptr = p.get();
  AsyncUSB usb;
  Engine e(usb);
  Calibration c{1000, 2000, 8000, 10, false};
  assert(e.start(profiles, 16, c, 0));
  for (uint64_t t = 0; t < 8000000; t += 100) {
    usb.now = t;
    e.tick(t);
  }
  assert(e.stats().clicks == 1600 && !e.stats().running);
  size_t presses = 0, homes = 0;
  bool held = false;
  for (auto r : usb.completed) {
    if (r.dx == -127)
      ++homes;
    if (r.buttons) {
      assert(!held);
      held = true;
      ++presses;
    } else
      held = false;
  }
  assert(presses == 1600 && homes == 255 &&
         !held); // single-position repeats do not rehome every 10 clicks
  assert(e.start(profiles, 1, c, 9000000));
  for (uint64_t t = 9000000; t < 10000000; t += 100) {
    usb.now = t;
    e.tick(t);
    if (usb.pending && usb.queued.buttons) {
      e.stop();
      break;
    }
  }
  for (unsigned i = 0; i < 30; ++i) {
    usb.now += 1000;
    e.tick(usb.now);
  }
  assert(!e.stats().releasing && usb.completed.back().buttons == 0);
  // Distinct positions identify each slot. Every finite schedule completes,
  // and the first round serves all 16 before any second click.
  std::vector<std::unique_ptr<Profile>> distinct;
  for (size_t i = 0; i < 16; ++i) {
    auto q = std::make_unique<Profile>();
    q->count = 1;
    q->repeats = 3;
    q->points[0] = {uint16_t(i * 500), 0, 1, 1, true};
    profiles[i] = q.get();
    distinct.push_back(std::move(q));
  }
  FakeUSB immediate;
  Engine fair(immediate);
  c.spanX = 10000;
  c.rehomeLoops = 0;
  assert(fair.start(profiles, 16, c, 0));
  uint64_t t = 0;
  drive(fair, t, 40000000);
  assert(fair.stats().clicks == 48 && !fair.stats().running);
  int x = 0;
  size_t clicked = 0;
  unsigned seen[16]{};
  for (auto r : immediate.reports) {
    x = std::max(0, x + int(r.dx));
    if (r.buttons) {
      assert(x % 500 == 0 && x <= 7500);
      ++seen[x / 500];
      if (++clicked == 16)
        for (auto n : seen)
          assert(n == 1);
    }
  }
  for (auto n : seen)
    assert(n == 3);
  std::strcpy(distinct[1]->device, "another-phone");
  assert(!fair.start(profiles, 16, c, t));
}
int main() {
  asynchronousAndFairness();
  auto p = std::make_unique<Profile>();
  p->count = 1;
  p->points[0] = {0, 0, 1, 1, true};
  Calibration cal{1000, 2000, 8000, 0, false};
  const Profile *profiles[16];
  for (auto &ptr : profiles)
    ptr = p.get();
  FakeUSB usb;
  Engine e(usb);
  uint64_t t = 0;
  assert(e.start(profiles, 16, cal, t));
  drive(e, t, 2500000);
  assert(e.stats().clicks > 900);
  assert(e.stats().late > 0);
  assert(e.stats().maxLateUs < 600000);
  e.stop();
  drive(e, t, 1000);
  assert(!e.stats().running && !e.stats().releasing);
  assert(usb.reports.back().buttons == 0);
  // Blocked completions never advance clicks; stop still retries release.
  assert(e.start(profiles, 1, cal, t));
  drive(e, t, 520000);
  usb.blocked = true;
  auto before = e.stats().clicks;
  drive(e, t, 500000);
  assert(e.stats().clicks == before);
  e.stop();
  e.tick(t);
  assert(e.stats().releasing);
  usb.blocked = false;
  e.tick(t);
  assert(!e.stats().releasing && usb.reports.back().buttons == 0);
  // Disconnect while held halts, and emits release before accepting any new
  // run.
  assert(e.start(profiles, 1, cal, t));
  drive(e, t, 511000);
  usb.online = false;
  e.tick(t);
  assert(!e.stats().running && e.stats().releasing);
  usb.online = true;
  e.tick(t);
  assert(!e.stats().releasing);
  // 1000 point finite profile, disabled tail, all 16 schedules terminate
  // fairly.
  p->count = 1000;
  p->repeats = 1;
  for (auto &q : p->points)
    q = {0, 0, 1, 1, true};
  assert(e.start(profiles, 16, cal, t));
  drive(e, t, 34000000);
  assert(e.stats().clicks == 16000 && !e.stats().running);
  p->points[999].enabled = false;
  assert(e.start(profiles, 1, cal, t));
  drive(e, t, 3000000);
  assert(e.stats().clicks == 999 && !e.stats().running);
  // Bounds, orientation, empty/all-disabled and invalid timing rejected.
  p->count = 0;
  assert(!e.start(profiles, 1, cal, t));
  p->count = 1;
  p->points[0].pressUs = 0;
  assert(!e.start(profiles, 1, cal, t));
  p->points[0].pressUs = 1;
  p->landscape = true;
  assert(!e.start(profiles, 1, cal, t));
  Button b;
  assert(b.poll(true, false, 0) == ButtonAction::None);
  assert(b.poll(false, false, 1100) == ButtonAction::Start);
  b.poll(true, false, 2000);
  assert(b.poll(false, false, 6100) == ButtonAction::Setup);
  assert(b.poll(true, true, 7000) == ButtonAction::Stop);
  assert(b.poll(false, false, 9000) == ButtonAction::None);
  std::puts("clicker simulation: PASS (16 schedules, 1000 points, "
            "backpressure, disconnect, stop, bounds, button)");
}
