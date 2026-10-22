#pragma once
#include <cstdint>
namespace clicker {
enum class ButtonAction { None, Stop, Cycle, Start, Setup };
class Button {
public:
  ButtonAction poll(bool down, bool running, uint64_t nowMs) {
    if (down && !pressed) {
      pressed = true;
      since = nowMs;
      stopped = running;
      if (running)
        return ButtonAction::Stop;
    }
    if (!down && pressed) {
      pressed = false;
      if (stopped)
        return ButtonAction::None;
      auto held = nowMs - since;
      if (held < 35)
        return ButtonAction::None;
      if (held >= 4000)
        return ButtonAction::Setup;
      if (held >= 1000)
        return ButtonAction::Start;
      return ButtonAction::Cycle;
    }
    return ButtonAction::None;
  }

private:
  bool pressed = false, stopped = false;
  uint64_t since = 0;
};
} // namespace clicker
