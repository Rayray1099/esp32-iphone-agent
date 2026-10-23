#include "../hid_bridge/src/clicker/agent_progress.h"
#include <cassert>
#include <cstdio>
#include <string>
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
  assert(p.update("101 acting 2 40 800 2000 100 4 Tap |開啟計算機，輸入數字", 600));
  assert(std::strcmp(p.summary, "開啟計算機，輸入數字") == 0);
  assert(!p.update("101 acting 2 40 800 2000 100 4 Tap |bad\nline", 700));
  assert(!p.update("101 acting 2 40 800 2000 100 4 Tap |\xc0\xaf", 700));
  assert(!p.update("101 acting 2 40 800 2000 100 4 Tap |\xed\xa0\x80", 700));
  assert(!p.update("101 acting 2 40 800 2000 100 4 Tap |\xe9\x96", 700));
  char oversized[256];
  std::snprintf(oversized, sizeof oversized, "101 acting 2 40 0 0 0 4 Tap |%s", std::string(97, 'a').c_str());
  assert(!p.update(oversized, 700));
  assert(p.update("102 preparing 0 40 0 0 0 0 Checking", 800));
  assert(!p.summary[0]); // Legacy app cannot inherit another run's summary.
  const char *samples[] = {"鬧鐘時間確認完成", "繪製下一條線", "尋找相簿中的照片", "hello 😀"};
  for (auto text : samples) assert(clicker::validSummary(text));
  assert(!clicker::validSummary("\xe2\x80\xae"));
  puts("agent progress bounds, stale link, terminal ordering: PASS");
}
