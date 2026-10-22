#include <Arduino.h>
// Arduino's optional BLE component normally owns this link-time conflict flag.
// NimBLE-Arduino is the only BLE host in this selective component build.
bool _bleLibraryInUse = false;
#include "../../hid_bridge/hid_bridge.ino"
extern "C" void app_main() {
  initArduino();
  setup();
  for (;;) { loop(); delay(1); }
}
