#include "../hid_bridge/src/clicker/engine.h"
#include "../hid_bridge/src/clicker/button.h"
#include <cassert>
#include <cstdio>
#include <memory>
#include <vector>
using namespace clicker;
struct FakeUSB: Transport {
  bool online = true, blocked = false; std::vector<Report> reports;
  bool connected() const override { return online; }
  bool send(Report r) override { if (blocked) return false; reports.push_back(r); return true; }
};
void drive(Engine& e, uint64_t& time, uint64_t duration) { uint64_t end=time+duration; for (;time<end;time+=1000) e.tick(time); }
int main() {
  auto p = std::make_unique<Profile>(); p->count=1; p->points[0]={0,0,1,1,true};
  Calibration cal{1000,2000,8000,0,false}; const Profile* profiles[16];
  for (auto& ptr:profiles) ptr=p.get();
  FakeUSB usb; Engine e(usb); uint64_t t=0;
  assert(e.start(profiles,16,cal,t)); drive(e,t,2500000);
  assert(e.stats().clicks>900); assert(e.stats().late>0);
  assert(e.stats().maxLateUs<600000);
  e.stop(); drive(e,t,1000); assert(!e.stats().running && !e.stats().releasing); assert(usb.reports.back().buttons==0);
  // Blocked completions never advance clicks; stop still retries release.
  assert(e.start(profiles,1,cal,t)); drive(e,t,520000); usb.blocked=true; auto before=e.stats().clicks;
  drive(e,t,500000); assert(e.stats().clicks==before); e.stop(); e.tick(t); assert(e.stats().releasing);
  usb.blocked=false; e.tick(t); assert(!e.stats().releasing && usb.reports.back().buttons==0);
  // Disconnect while held halts, and emits release before accepting any new run.
  assert(e.start(profiles,1,cal,t)); drive(e,t,511000); usb.online=false; e.tick(t);
  assert(!e.stats().running && e.stats().releasing); usb.online=true; e.tick(t); assert(!e.stats().releasing);
  // 1000 point finite profile, disabled tail, all 16 schedules terminate fairly.
  p->count=1000; p->repeats=1; for(auto& q:p->points) q={0,0,1,1,true};
  assert(e.start(profiles,16,cal,t)); drive(e,t,34000000); assert(e.stats().clicks==16000 && !e.stats().running);
  p->points[999].enabled=false;
  assert(e.start(profiles,1,cal,t)); drive(e,t,3000000); assert(e.stats().clicks==999 && !e.stats().running);
  // Bounds, orientation, empty/all-disabled and invalid timing rejected.
  p->count=0; assert(!e.start(profiles,1,cal,t)); p->count=1; p->points[0].pressUs=0; assert(!e.start(profiles,1,cal,t));
  p->points[0].pressUs=1; p->landscape=true; assert(!e.start(profiles,1,cal,t));
  Button b; assert(b.poll(true,false,0)==ButtonAction::None); assert(b.poll(false,false,1100)==ButtonAction::Start);
  b.poll(true,false,2000); assert(b.poll(false,false,6100)==ButtonAction::Setup);
  assert(b.poll(true,true,7000)==ButtonAction::Stop); assert(b.poll(false,false,9000)==ButtonAction::None);
  std::puts("clicker simulation: PASS (16 schedules, 1000 points, backpressure, disconnect, stop, bounds, button)");
}
