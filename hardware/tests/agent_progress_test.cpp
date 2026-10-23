#include "../hid_bridge/src/clicker/agent_progress.h"
#include <cassert>
#include <cstdio>
int main() {
  clicker::AgentProgress p;
  assert(!p.visible(0));
  assert(p.update("100 acting 3 40 420 2000 120 12 Tap", 100));
  assert(p.active() && p.visible(100) && !p.stale(200));
  assert(p.stale(8100));
  assert(!p.update("99 thinking 2 40 0 0 0 1 Wait", 200));
  assert(!p.update("101 bogus 3 40 0 0 0 1 Tap", 200));
  assert(!p.update("101 acting 41 40 0 0 0 1 Tap", 200));
  assert(!p.update("101 acting 3 40 0 0 0 1 Tap unexpected", 200));
  assert(!p.update("101 acting 3 40 0 0 0 1 password=secret", 200));
  assert(p.update("100 done 3 40 420 2000 120 14 Completed", 300));
  assert(!p.active() && p.visible(300) && !p.visible(15300));
  assert(!p.update("100 acting 4 40 0 0 0 15 Tap", 400));
  assert(p.update("101 preparing 0 40 0 0 0 0 Checking", 500));
  puts("agent progress bounds, stale link, terminal ordering: PASS");
}
