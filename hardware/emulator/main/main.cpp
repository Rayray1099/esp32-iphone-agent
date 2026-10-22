// ESP32-S3 CPU/FreeRTOS adapter firmware. USB, BLE, Wi-Fi and panel are
// simulated. This runs the SAME scheduler, button state machine and framebuffer
// renderer.
#include "clicker/button.h"
#include "clicker/engine.h"
#include "clicker/screen.h"
#include <cassert>
#include <cstdio>
#include <esp_ota_ops.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
namespace {
uint16_t pixels[320 * 240];
clicker::Profile profile;
class SimulatedUSB : public clicker::Transport {
public:
  bool online = true, blocked = false;
  unsigned presses = 0, releases = 0;
  bool connected() const override { return online; }
  bool send(clicker::Report report) override {
    if (blocked)
      return false;
    if (report.buttons)
      ++presses;
    else
      ++releases;
    return true;
  }
};
} // namespace
// Host stages two valid images and OTA metadata. QEMU S3 does not emulate
// every flash-MMU path needed by esp_image_verify in an application task.
static void otaLifecycle() {
  const auto *fixture = esp_partition_find_first(
      ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, "profiles");
  uint8_t scenario = 0xff;
  ESP_ERROR_CHECK(esp_partition_read(fixture, 0, &scenario, 1));
  const auto *running = esp_ota_get_running_partition();
  esp_ota_img_states_t state = ESP_OTA_IMG_UNDEFINED;
  ESP_ERROR_CHECK(esp_ota_get_state_partition(running, &state));
  if (scenario == 1) {
    assert(running->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_1);
    assert(state == ESP_OTA_IMG_PENDING_VERIFY);
    ESP_ERROR_CHECK(esp_ota_mark_app_valid_cancel_rollback());
    ESP_ERROR_CHECK(esp_ota_get_state_partition(running, &state));
    assert(state == ESP_OTA_IMG_VALID);
    printf("EMULATOR OTA: startup confirmation PASS\n");
  } else if (scenario == 2) {
    if (running->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_1) {
      assert(state == ESP_OTA_IMG_PENDING_VERIFY);
      printf("EMULATOR OTA: deliberately restarting without confirmation\n");
      fflush(stdout);
      esp_restart();
    }
    assert(running->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_0 &&
           state == ESP_OTA_IMG_VALID);
    printf("EMULATOR OTA: failed-boot rollback PASS\n");
  } else {
    assert(false && "Missing host OTA fixture");
  }
}
extern "C" void app_main() {
  otaLifecycle();
  printf("EMULATOR: S3 CPU, actual FreeRTOS and shared core; simulated "
         "USB/BLE/Wi-Fi/TFT adapters\n");
  auto before = esp_timer_get_time();
  vTaskDelay(pdMS_TO_TICKS(12));
  assert(esp_timer_get_time() > before);
  profile.count = 1000;
  profile.repeats = 1;
  for (auto &point : profile.points)
    point = {0, 0, 1, 1, true};
  const clicker::Profile *schedules[16];
  for (auto &p : schedules)
    p = &profile;
  SimulatedUSB usb;
  clicker::Engine engine(usb);
  clicker::Calibration calibration{1000, 2000, 8000, 0, false};
  assert(engine.start(schedules, 16, calibration, 0));
  for (uint64_t time = 0; time < 34000000; time += 1000) {
    engine.tick(time);
    if (time % 100000 == 0)
      vTaskDelay(1);
  }
  assert(engine.stats().clicks == 16000 && !engine.stats().running);
  assert(usb.presses == 16000);
  printf("EMULATOR: 16 schedules x 1000 targets PASS; ordered releases=%u\n",
         usb.releases);
  assert(engine.start(schedules, 1, calibration, 35000000));
  usb.online = false;
  engine.tick(35000001);
  assert(engine.stats().releasing);
  usb.online = true;
  engine.tick(35000002);
  assert(!engine.stats().releasing);
  clicker::Button button;
  button.poll(true, false, 0);
  assert(button.poll(false, false, 1100) == clicker::ButtonAction::Start);
  assert(button.poll(true, true, 1200) == clicker::ButtonAction::Stop);
  button.poll(false, false, 1300);
  button.poll(true, false, 1400);
  assert(button.poll(false, false, 5500) == clicker::ButtonAction::Setup);
  clicker::ScreenData data;
  data.qr = "WIFI:T:WPA;S:EMULATOR;P:demo-only;;";
  for (int page = 0; page < 4; ++page) {
    clicker::Screen(pixels).render(page, data);
    unsigned colored = 0;
    for (auto pixel : pixels)
      if (pixel != 0x0862)
        ++colored;
    assert(colored > 10000);
    printf("EMULATOR: framebuffer page %d PASS (%u changed pixels)\n", page,
           colored);
  }
  printf("CLICKER_S3_EMULATOR_PASS\n");
  fflush(stdout);
  for (;;)
    vTaskDelay(pdMS_TO_TICKS(1000));
}
