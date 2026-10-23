#include "clicker_service.h"
#include "src/clicker/agent_progress.h"
namespace {
clicker::AgentProgress progress;
portMUX_TYPE progressMux = portMUX_INITIALIZER_UNLOCKED;
}
bool agent_progress_update(const String &line) {
  auto next = agent_progress_snapshot();
  if (!next.update(line.c_str(), millis())) return false;
  portENTER_CRITICAL(&progressMux);
  bool ok = next.run >= progress.run && !(next.run == progress.run && !progress.active() && next.active());
  if (ok) progress = next;
  portEXIT_CRITICAL(&progressMux);
  return ok;
}
clicker::AgentProgress agent_progress_snapshot() {
  portENTER_CRITICAL(&progressMux);
  auto copy = progress;
  portEXIT_CRITICAL(&progressMux);
  return copy;
}
