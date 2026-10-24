#include "clicker_service.h"
#include <cJSON.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>
namespace {
struct Entry {
  uint32_t id;
  uint64_t us;
  char text[96];
};
Entry events[64]{};
uint32_t sequence = 0;
portMUX_TYPE logMux = portMUX_INITIALIZER_UNLOCKED;
} // namespace
void diagnostic_event(const char *message) {
  // Only fixed service events enter this ring. Never record commands, request
  // bodies, credentials, certificates, tokens or MicroLink control payloads.
  portENTER_CRITICAL(&logMux);
  auto &entry = events[sequence % 64];
  entry.id = ++sequence;
  entry.us = esp_timer_get_time();
  strlcpy(entry.text, message, sizeof entry.text);
  portEXIT_CRITICAL(&logMux);
}
String diagnostic_json(bool tasks) {
  auto *root = cJSON_CreateObject();
  cJSON_AddNumberToObject(root, "heap_internal",
                          heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
  cJSON_AddNumberToObject(
      root, "largest_internal",
      heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
  cJSON_AddNumberToObject(root, "minimum_heap",
                          esp_get_minimum_free_heap_size());
  cJSON_AddNumberToObject(root, "psram",
                          heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
  if (tasks) {
    auto *list = cJSON_AddArrayToObject(root, "tasks");
    constexpr unsigned cap = 64;
    auto *state = (TaskStatus_t *)heap_caps_calloc(cap, sizeof(TaskStatus_t),
                                                   MALLOC_CAP_SPIRAM);
    if (state) {
      auto count = uxTaskGetSystemState(state, cap, nullptr);
      for (unsigned i = 0; i < count; ++i) {
        auto *item = cJSON_CreateObject();
        cJSON_AddStringToObject(item, "name", state[i].pcTaskName);
        cJSON_AddNumberToObject(item, "priority", state[i].uxCurrentPriority);
        cJSON_AddNumberToObject(item, "state", state[i].eCurrentState);
        cJSON_AddNumberToObject(item, "stack_high_water_bytes",
                                state[i].usStackHighWaterMark);
        cJSON_AddItemToArray(list, item);
      }
      free(state);
      cJSON_AddBoolToObject(root, "task_list_truncated", count == 0);
    }
  } else {
    auto *list = cJSON_AddArrayToObject(root, "events");
    uint32_t latest;
    portENTER_CRITICAL(&logMux);
    latest = sequence;
    portEXIT_CRITICAL(&logMux);
    for (uint32_t id = latest > 64 ? latest - 63 : 1; id <= latest; ++id) {
      Entry entry;
      portENTER_CRITICAL(&logMux);
      entry = events[(id - 1) % 64];
      portEXIT_CRITICAL(&logMux);
      if (entry.id != id)
        continue;
      auto *item = cJSON_CreateObject();
      cJSON_AddNumberToObject(item, "id", entry.id);
      cJSON_AddNumberToObject(item, "time_us", double(entry.us));
      cJSON_AddStringToObject(item, "message", entry.text);
      cJSON_AddItemToArray(list, item);
    }
    cJSON_AddNumberToObject(root, "cursor", latest);
  }
  char *raw = cJSON_PrintUnformatted(root);
  String out = raw ? raw : "{}";
  cJSON_free(raw);
  cJSON_Delete(root);
  return out;
}
