#include "clicker_service.h"
#include "ble_link.h"
#include "netcfg.h"
#include "src/clicker/button.h"
#include <LittleFS.h>
#include <Preferences.h>
#include <USBHID.h>
#include <atomic>
#include <cJSON.h>
#include <cmath>
#include <esp_heap_caps.h>
#include <esp_partition.h>
#include <esp_timer.h>
#include <mbedtls/base64.h>
#include <memory>
#include <tusb.h>
extern String run(const String &);
using namespace clicker;
static std::atomic<bool> usbCompleted{false};
extern "C" void __real_tud_hid_report_complete_cb(uint8_t, const uint8_t*, uint16_t);
extern "C" void __wrap_tud_hid_report_complete_cb(uint8_t instance, const uint8_t* report, uint16_t len) {
  __real_tud_hid_report_complete_cb(instance, report, len);
  usbCompleted.store(true, std::memory_order_release);
}
namespace {
class USBTransport : public Transport {
  mutable bool pending = false;
  Report queued{};

public:
  bool connected() const override {
    bool online = tud_mounted() && !tud_suspended();
    if (!online) { pending = false; usbCompleted = false; }
    return online;
  }
  bool send(Report r) override {
    if (pending) {
      if (!usbCompleted.exchange(false, std::memory_order_acquire)) return false;
      pending = false;
      if (queued.buttons==r.buttons && queued.dx==r.dx && queued.dy==r.dy) return true;
      // A stop may replace an in-flight press. Drain it, then send release.
    }
    if (!tud_hid_ready()) return false;
    const int8_t report[5] = {int8_t(r.buttons), r.dx, r.dy, 0, 0};
    usbCompleted = false;
    if (tud_hid_report(HID_REPORT_ID_MOUSE, report, sizeof report)) { queued=r; pending=true; }
    return false;
  }
} transport;
Engine engine(transport);
Button button;
Preferences prefs;
SemaphoreHandle_t guard;
SemaphoreHandle_t apiGuard;
struct APILock {
  APILock() { xSemaphoreTakeRecursive(apiGuard, portMAX_DELAY); }
  ~APILock() { xSemaphoreGiveRecursive(apiGuard); }
};
bool manualBusy = false, manualHeld = false, aiLease = false,
     updateLock = false;
std::atomic<bool> stopRequested{false};
Profile *live[MaxSchedules]{};
uint8_t selection = 0;
String selectedGroup = "[0]", selectedName = "No saved profile";
String acceptedNonces[32];
size_t nonceCursor = 0;
String lastNonce, lastError;
bool ready = false;
std::atomic<uint32_t> restartAt{0};
struct Transfer {
  String id, kind;
  size_t size = 0, used = 0;
  uint32_t crc = 0;
  uint8_t *bytes = nullptr;
  uint32_t touched = 0;
} upload;
using JSON = std::unique_ptr<cJSON, decltype(&cJSON_Delete)>;
JSON parse(const String &s) {
  return JSON(cJSON_ParseWithLength(s.c_str(), s.length()), cJSON_Delete);
}
String jsonText(cJSON *j) {
  char *p = cJSON_PrintUnformatted(j);
  String s = p ? p : "{}";
  cJSON_free(p);
  return s;
}
String field(cJSON *j, const char *key, const char *fallback = "") {
  auto *v = cJSON_GetObjectItemCaseSensitive(j, key);
  return cJSON_IsString(v) ? v->valuestring : fallback;
}
bool jsonBool(cJSON *j, const char *key, bool fallback = false) {
  auto *v = cJSON_GetObjectItemCaseSensitive(j, key);
  return cJSON_IsBool(v) ? cJSON_IsTrue(v) : fallback;
}
bool number(cJSON *j, const char *key, uint32_t lo, uint32_t hi, uint32_t &out,
            uint32_t fallback) {
  auto *v = cJSON_GetObjectItemCaseSensitive(j, key);
  if (!v) {
    out = fallback;
    return true;
  }
  if (!cJSON_IsNumber(v) || !std::isfinite(v->valuedouble) ||
      v->valuedouble < lo || v->valuedouble > hi ||
      std::floor(v->valuedouble) != v->valuedouble)
    return false;
  out = uint32_t(v->valuedouble);
  return true;
}
uint32_t crc32(const void *data, size_t n) {
  uint32_t c = ~0u;
  auto *p = (const uint8_t *)data;
  while (n--) {
    c ^= *p++;
    for (int b = 0; b < 8; ++b)
      c = (c >> 1) ^ (0xedb88320u & uint32_t(-int32_t(c & 1)));
  }
  return ~c;
}
String filename(int id) { return "/p" + String(id) + ".bin"; }
// Versioned records with CRC; commit is one LittleFS rename, never a partially
// overwritten profile.
bool store(int id, const Profile &p) {
  String dst = filename(id), tmp = dst + ".tmp";
  auto f = LittleFS.open(tmp, "w");
  if (!f)
    return false;
  uint32_t header[] = {0x32504353, 1, sizeof(Profile), crc32(&p, sizeof p)};
  bool ok = f.write((uint8_t *)header, sizeof header) == sizeof header &&
            f.write((const uint8_t *)&p, sizeof p) == sizeof p;
  f.flush();
  f.close();
  if (!ok) {
    LittleFS.remove(tmp);
    return false;
  }
  return LittleFS.rename(tmp, dst);
}
bool load(int id, Profile &p) {
  auto f = LittleFS.open(filename(id), "r");
  if (!f)
    return false;
  uint32_t h[4];
  return f.size() == sizeof(h) + sizeof(p) &&
         f.read((uint8_t *)h, sizeof h) == sizeof h && h[0] == 0x32504353 &&
         h[1] == 1 && h[2] == sizeof p &&
         f.read((uint8_t *)&p, sizeof p) == sizeof p &&
         h[3] == crc32(&p, sizeof p) && valid(p);
}
Profile *allocProfile() {
  void *p =
      heap_caps_malloc(sizeof(Profile), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  return p ? new (p) Profile : nullptr;
}
bool decodeProfile(cJSON *j, Profile &p) {
  uint32_t schema;
  if (!cJSON_IsObject(j) || !number(j, "schema", 1, 1, schema, 1))
    return false;
  String name = field(j, "name");
  if (name.isEmpty() || name.length() > 48)
    return false;
  p = Profile{};
  strlcpy(p.name, name.c_str(), sizeof p.name);
  if (!number(j, "repeats", 0, 1000000000, p.repeats, 0))
    return false;
  p.landscape = jsonBool(j, "landscape");
  p.fast = jsonBool(j, "fast");
  auto *points = cJSON_GetObjectItemCaseSensitive(j, "points");
  if (!cJSON_IsArray(points))
    return false;
  int n = cJSON_GetArraySize(points);
  if (n < 1 || n > int(MaxPoints))
    return false;
  p.count = n;
  for (int i = 0; i < n; ++i) {
    auto *q = cJSON_GetArrayItem(points, i);
    uint32_t x, y;
    auto &v = p.points[i];
    if (!cJSON_IsObject(q) || !number(q, "x", 0, 10000, x, 5000) ||
        !number(q, "y", 0, 10000, y, 5000) ||
        !number(q, "press_us", 1, MaxIntervalUs, v.pressUs, 1000) ||
        !number(q, "delay_us", 1, MaxIntervalUs, v.delayUs, 5000))
      return false;
    v.x = x;
    v.y = y;
    v.enabled = jsonBool(q, "enabled", true);
  }
  return valid(p);
}
String encodeProfile(const Profile &p) {
  JSON j(cJSON_CreateObject(), cJSON_Delete);
  cJSON_AddStringToObject(j.get(), "name", p.name);
  cJSON_AddNumberToObject(j.get(), "schema", 1);
  cJSON_AddNumberToObject(j.get(), "repeats", p.repeats);
  cJSON_AddBoolToObject(j.get(), "landscape", p.landscape);
  cJSON_AddBoolToObject(j.get(), "fast", p.fast);
  auto *a = cJSON_AddArrayToObject(j.get(), "points");
  for (int i = 0; i < p.count; ++i) {
    auto *q = cJSON_CreateObject();
    const auto &v = p.points[i];
    cJSON_AddNumberToObject(q, "x", v.x);
    cJSON_AddNumberToObject(q, "y", v.y);
    cJSON_AddNumberToObject(q, "press_us", v.pressUs);
    cJSON_AddNumberToObject(q, "delay_us", v.delayUs);
    cJSON_AddBoolToObject(q, "enabled", v.enabled);
    cJSON_AddItemToArray(a, q);
  }
  return jsonText(j.get());
}
void releaseProfiles() {
  for (auto *&p : live) {
    free(p);
    p = nullptr;
  }
}
Calibration calibration(bool landscape) {
  Calibration c;
  const char *k = landscape ? "land" : "port";
  if (prefs.getBytesLength(k) == sizeof c)
    prefs.getBytes(k, &c, sizeof c);
  return c;
}
String start(cJSON *j) {
  APILock apiLock;
  String nonce = field(j, "nonce");
  if (nonce.length() < 8 || nonce.length() > 64)
    return "err nonce must have 8-64 characters";
  for (const auto &accepted : acceptedNonces)
    if (nonce == accepted)
      return "ok already accepted";
  xSemaphoreTake(guard, portMAX_DELAY);
  if (engine.stats().running || engine.stats().releasing || manualBusy ||
      manualHeld || aiLease || updateLock) {
    xSemaphoreGive(guard);
    return "err input busy";
  }
  releaseProfiles();
  auto *ids = cJSON_GetObjectItemCaseSensitive(j, "profiles");
  int n = cJSON_GetArraySize(ids);
  bool ok = cJSON_IsArray(ids) && n >= 1 && n <= 16;
  for (int i = 0; ok && i < n; ++i) {
    auto *id = cJSON_GetArrayItem(ids, i);
    ok = cJSON_IsNumber(id) && id->valuedouble == id->valueint &&
         id->valueint >= 0 && id->valueint < 32;
    if (ok) {
      live[i] = allocProfile();
      ok = live[i] && load(id->valueint, *live[i]);
    }
  }
  if (ok) {
    auto c = calibration(live[0]->landscape);
    ok = engine.start((const Profile *const *)live, n, c, esp_timer_get_time());
  }
  if (!ok)
    releaseProfiles();
  else {
    lastNonce = nonce;
    acceptedNonces[nonceCursor++ % 32] = nonce;
    selectedGroup = jsonText(ids);
    selection = cJSON_GetArrayItem(ids, 0)->valueint;
    selectedName = live[0]->name;
  }
  xSemaphoreGive(guard);
  if (ok) {
    prefs.putString("group", selectedGroup);
    prefs.putUChar("selected", selection);
  }
  if (!ok)
    return "err invalid profile, USB unavailable, or calibration missing";
  return "ok";
}
void worker(void *) {
  for (;;) {
    xSemaphoreTake(guard, portMAX_DELAY);
    if (stopRequested.exchange(false))
      engine.stop();
    auto action = button.poll(digitalRead(0) == LOW, engine.stats().running,
                              esp_timer_get_time() / 1000);
    if (action == ButtonAction::Stop)
      engine.stop();
    engine.tick(esp_timer_get_time());
    xSemaphoreGive(guard);
    if (action == ButtonAction::Cycle) {
      APILock apiLock;
      auto *profile = allocProfile();
      for (int n = 0; n < 32; ++n) {
        selection = (selection + 1) % 32;
        if (profile && load(selection, *profile)) {
          selectedName = profile->name;
          break;
        }
      }
      free(profile);
      selectedGroup = "[" + String(selection) + "]";
      prefs.putString("group", selectedGroup);
      prefs.putUChar("selected", selection);
    }
    if (action == ButtonAction::Start) {
      auto j = parse("{\"nonce\":\"button-" + String(millis()) +
                     "\",\"profiles\":" + selectedGroup + "}");
      lastError = start(j.get());
    }
    if (action == ButtonAction::Setup)
      clicker_setup();
    vTaskDelay(1);
  }
}
void clearUpload() {
  free(upload.bytes);
  upload = {};
}
} // namespace
void clicker_begin() {
  guard = xSemaphoreCreateMutex();
  apiGuard = xSemaphoreCreateRecursiveMutex();
  prefs.begin("clicker", false);
  selection = prefs.getUChar("selected", 0);
  selectedGroup = prefs.getString("group", "[" + String(selection) + "]");
  pinMode(0, INPUT_PULLUP);
  ready = LittleFS.begin(false, "/littlefs", 10, "profiles");
  if (!ready) { // Only a genuinely blank partition may be formatted; preserve a
                // damaged store for recovery.
    const esp_partition_t *p = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, "profiles");
    uint8_t sample[256]{};
    bool blank = p && esp_partition_read(p, 0, sample, sizeof sample) == ESP_OK;
    for (auto b : sample)
      blank = blank && b == 0xff;
    if (blank && LittleFS.format())
      ready = LittleFS.begin(false, "/littlefs", 10, "profiles");
  }
  if (!ready)
    lastError = "Profile storage unavailable";
  auto *selected = allocProfile();
  if (selected && load(selection, *selected))
    selectedName = selected->name;
  free(selected);
  controller_token();
  xTaskCreatePinnedToCore(worker, "clicker", 4096, nullptr, 4, nullptr, 1);
}
Stats clicker_stats() {
  if (!guard)
    return {};
  xSemaphoreTake(guard, portMAX_DELAY);
  auto s = engine.stats();
  xSemaphoreGive(guard);
  return s;
}
bool clicker_busy() {
  auto s = clicker_stats();
  return s.running || s.releasing;
}
bool clicker_healthy() { return ready && guard && apiGuard; }
bool clicker_manual_begin() {
  xSemaphoreTake(guard, portMAX_DELAY);
  bool ok = !engine.stats().running && !engine.stats().releasing &&
            !manualBusy && !updateLock;
  if (ok)
    manualBusy = true;
  xSemaphoreGive(guard);
  return ok;
}
void clicker_manual_end(bool held) {
  xSemaphoreTake(guard, portMAX_DELAY);
  manualBusy = false;
  manualHeld = held;
  xSemaphoreGive(guard);
}
bool clicker_update_begin() {
  xSemaphoreTake(guard, portMAX_DELAY);
  bool ok = !manualBusy && !aiLease && !updateLock;
  if (ok)
    updateLock = true;
  xSemaphoreGive(guard);
  if (ok && !clicker_stop_wait()) {
    clicker_update_end();
    return false;
  }
  return ok;
}
void clicker_update_end() {
  xSemaphoreTake(guard, portMAX_DELAY);
  updateLock = false;
  manualHeld = false;
  xSemaphoreGive(guard);
}
bool clicker_stop_wait() {
  stopRequested = true;
  for (int i = 0; i < 100; ++i) {
    if (!stopRequested.load() && !clicker_busy())
      return true;
    delay(2);
  }
  return false;
}
String clicker_selected_name() {
  APILock apiLock;
  return selectedName;
}
String controller_token() {
  String t = prefs.getString("token");
  if (t.length() != 32) {
    char b[33];
    for (int i = 0; i < 16; ++i)
      snprintf(b + i * 2, 3, "%02x", uint8_t(esp_random()));
    t = b;
    prefs.putString("token", t);
  }
  return t;
}
bool clicker_radios_off() { return prefs.getBool("offline", false); }
void clicker_poll() {
  uint32_t at = restartAt.load();
  if (at && (int32_t)(millis() - at) >= 0)
    ESP.restart();
}
void clicker_setup() {
  if (clicker_busy())
    return;
  prefs.putBool("offline", false);
  net_request("{\"mode\":\"ap\"}");
  restartAt = millis() + 800;
}
String clicker_api(const String &path, const String &method, const String &body,
                   int &code) {
  APILock apiLock;
  code = 200;
  if (upload.bytes && uint32_t(millis() - upload.touched) > 120000)
    clearUpload();
  if (updateLock && method != "GET" && path != "run/stop") {
    code = 409;
    return "{\"error\":\"OTA owns input and flash\"}";
  }
  auto j = parse(body);
  if (path == "capabilities")
    return "{\"api\":1,\"board\":\"s3-n8r8-st7789\",\"profiles\":32,\"points\":"
           "1000,\"schedules\":16,\"timing_us\":1,\"usb_poll_us\":1000,"
           "\"version\":\"0.2.0\"}";
  if (path == "status") {
    auto s = clicker_stats();
    JSON o(cJSON_CreateObject(), cJSON_Delete);
    cJSON_AddBoolToObject(o.get(), "running", s.running);
    cJSON_AddBoolToObject(o.get(), "releasing", s.releasing);
    cJSON_AddNumberToObject(o.get(), "clicks", double(s.clicks));
    cJSON_AddNumberToObject(o.get(), "reports", double(s.reports));
    cJSON_AddNumberToObject(o.get(), "late", double(s.late));
    cJSON_AddNumberToObject(o.get(), "max_late_us", double(s.maxLateUs));
    cJSON_AddNumberToObject(o.get(), "loops", s.loops);
    cJSON_AddNumberToObject(o.get(), "point", s.point);
    cJSON_AddNumberToObject(o.get(), "active", s.active);
    double seconds =
        s.startedUs ? (esp_timer_get_time() - s.startedUs) / 1e6 : 0;
    cJSON_AddNumberToObject(o.get(), "usb_cps",
                            seconds > 0 ? s.clicks / seconds : 0);
    cJSON_AddNumberToObject(o.get(), "heap", ESP.getFreeHeap());
    cJSON_AddNumberToObject(o.get(), "psram", ESP.getFreePsram());
    cJSON_AddNumberToObject(o.get(), "uptime_ms", millis());
    cJSON_AddStringToObject(o.get(), "error", lastError.c_str());
    cJSON_AddStringToObject(o.get(), "profile",
                            clicker_selected_name().c_str());
    cJSON_AddItemToObject(o.get(), "network",
                          cJSON_Parse(net_status_json().c_str()));
    cJSON_AddItemToObject(o.get(), "tailscale",
                          cJSON_Parse(remote_status().c_str()));
    cJSON_AddItemToObject(o.get(), "ota", cJSON_Parse(ota_status().c_str()));
    return jsonText(o.get());
  }
  String result;
  if (path == "input/claim" && method == "POST") {
    xSemaphoreTake(guard, portMAX_DELAY);
    bool ok = !engine.stats().running && !engine.stats().releasing &&
              !manualBusy && !manualHeld && !updateLock;
    if (ok)
      aiLease = true;
    xSemaphoreGive(guard);
    return ok ? "{\"ok\":true}"
              : (code = 409, "{\"error\":\"USB input busy\"}");
  }
  if (path == "input/release" && method == "POST") {
    if (!clicker_stop_wait()) {
      code = 409;
      return "{\"error\":\"USB release pending\"}";
    }
    xSemaphoreTake(guard, portMAX_DELAY);
    aiLease = false;
    manualHeld = false;
    xSemaphoreGive(guard);
    return "{\"ok\":true}";
  }
  if (path == "run/stop" && method == "POST") {
    stopRequested = true;
    return "{\"accepted\":true}";
  }
  if (path == "run/start" && method == "POST")
    result = j ? start(j.get()) : "err invalid JSON";
  else if (path == "pointer" && method == "POST") {
    String cmd = field(j.get(), "command");
    if (cmd != "home" && !cmd.startsWith("move "))
      result = "err only home and move allowed";
    else
      result = run(cmd);
  } else if (path == "system/reboot" && method == "POST") {
    if (!clicker_stop_wait())
      result = "err input release pending";
    else {
      restartAt = millis() + 800;
      result = "ok";
    }
  } else if (path == "network") {
    if (method == "GET")
      return net_status_json();
    if (clicker_busy())
      result = "err stop clicking before changing network";
    else
      result = net_configure(body);
  } else if (path == "tailscale") {
    if (method == "GET")
      return remote_status();
    result = remote_configure(body);
  } else if (path == "mode/offline" && method == "POST") {
    if (!clicker_stop_wait())
      result = "err USB release pending";
    else {
      prefs.putBool("offline", true);
      restartAt = millis() + 800;
      result = "ok restarting into offline mode";
    }
  } else if (path == "mode/setup" && method == "POST") {
    clicker_setup();
    result = "ok";
  } else if (path == "calibration") {
    bool land = j && jsonBool(j.get(), "landscape");
    Calibration c = calibration(land);
    if (method != "GET") {
      uint32_t x, y, interval, loops;
      if (clicker_busy() || !j || !number(j.get(), "span_x", 1, 32000, x, 0) ||
          !number(j.get(), "span_y", 1, 32000, y, 0) || !x || !y ||
          !number(j.get(), "move_interval_us", 1000, 100000, interval, 8000) ||
          !number(j.get(), "rehome_loops", 0, 65535, loops, 10))
        result = "err calibration requires measured spans and stopped input";
      else {
        c.spanX = x;
        c.spanY = y;
        c.moveIntervalUs = interval;
        c.rehomeLoops = loops;
        c.landscape = land;
        prefs.putBytes(land ? "land" : "port", &c, sizeof c);
        result = "ok";
      }
    } else
      return "{\"span_x\":" + String(c.spanX) +
             ",\"span_y\":" + String(c.spanY) +
             ",\"landscape\":" + (c.landscape ? "true" : "false") + "}";
  } else if (path == "profiles" && method == "GET") {
    JSON a(cJSON_CreateArray(), cJSON_Delete);
    auto *p = allocProfile();
    if (!p) {
      code = 503;
      return "{}";
    }
    for (int i = 0; i < 32; ++i)
      if (load(i, *p)) {
        auto *o = cJSON_CreateObject();
        cJSON_AddNumberToObject(o, "id", i);
        cJSON_AddStringToObject(o, "name", p->name);
        cJSON_AddNumberToObject(o, "points", p->count);
        cJSON_AddItemToArray(a.get(), o);
      }
    free(p);
    return jsonText(a.get());
  } else if (path.startsWith("profiles/")) {
    String idText = path.substring(9);
    int id = idText.toInt();
    if (String(id) != idText || id < 0 || id >= 32)
      result = "err profile id 0-31 required";
    else if (clicker_busy() && method != "GET")
      result = "err stop before changing profiles";
    else if (method == "DELETE")
      result = LittleFS.remove(filename(id)) ? "ok" : "err missing profile";
    else {
      auto *p = allocProfile();
      if (!p)
        result = "err out of memory";
      else {
        if (method == "GET") {
          if (load(id, *p)) {
            String out = encodeProfile(*p);
            free(p);
            return out;
          }
          result = "err missing profile";
        } else {
          bool saved = j && decodeProfile(j.get(), *p) && store(id, *p);
          result = saved ? "ok" : "err invalid profile or storage failure";
          if (saved) {
            selection = id;
            selectedName = p->name;
            selectedGroup = "[" + String(id) + "]";
            prefs.putUChar("selected", selection);
            prefs.putString("group", selectedGroup);
          }
        }
        free(p);
      }
    }
  } else if (path == "transfer/begin" && method == "POST") {
    uint32_t size, crc;
    String id = field(j.get(), "id"), kind = field(j.get(), "path");
    if (!j || id.length() < 8 || id.length() > 48 ||
        !number(j.get(), "size", 1, 196608, size, 0) || !size ||
        !number(j.get(), "crc32", 0, UINT32_MAX, crc, 0) ||
        !(kind.startsWith("profiles/") || kind == "network" ||
          kind == "calibration" || kind == "tailscale"))
      result = "err invalid transfer";
    else if (upload.id == id && upload.kind == kind && upload.size == size &&
             upload.crc == crc)
      return "{\"offset\":" + String(upload.used) + "}";
    else {
      clearUpload();
      upload.bytes = (uint8_t *)heap_caps_malloc(size + 1, MALLOC_CAP_SPIRAM);
      if (!upload.bytes)
        result = "err no memory";
      else {
        upload.id = id;
        upload.kind = kind;
        upload.size = size;
        upload.crc = crc;
        upload.touched = millis();
        return "{\"offset\":0}";
      }
    }
  } else if (path == "transfer/chunk" && method == "POST") {
    uint32_t off;
    String id = field(j.get(), "id"), b64 = field(j.get(), "data");
    size_t got = 0;
    uint8_t data[192];
    if (!upload.bytes || id != upload.id ||
        !number(j.get(), "offset", 0, 196608, off, UINT32_MAX) ||
        b64.length() > 256 ||
        mbedtls_base64_decode(data, sizeof data, &got,
                              (const uint8_t *)b64.c_str(), b64.length()) ||
        !got || off + got > upload.size)
      result = "err invalid chunk";
    else if (off == upload.used) {
      memcpy(upload.bytes + off, data, got);
      upload.used += got;
      upload.touched = millis();
      return "{\"offset\":" + String(upload.used) + "}";
    } else if (off + got <= upload.used &&
               !memcmp(upload.bytes + off, data, got))
      return "{\"offset\":" + String(upload.used) + "}";
    else
      result = "err out of order or conflicting retry";
  } else if (path == "transfer/commit" && method == "POST") {
    if (!upload.bytes || field(j.get(), "id") != upload.id ||
        upload.used != upload.size ||
        crc32(upload.bytes, upload.size) != upload.crc)
      result = "err incomplete transfer or CRC mismatch";
    else {
      upload.bytes[upload.size] = 0;
      String kind = upload.kind, contents((char *)upload.bytes, upload.size);
      clearUpload();
      return clicker_api(kind, "PUT", contents, code);
    }
  } else {
    code = 404;
    return "{\"error\":\"unknown API route\"}";
  }
  if (result.startsWith("ok"))
    return "{\"ok\":true}";
  code = 400;
  JSON e(cJSON_CreateObject(), cJSON_Delete);
  cJSON_AddStringToObject(e.get(), "error", result.c_str());
  return jsonText(e.get());
}
String clicker_command(const String &line) {
  if (line == "capabilities") {
    int c;
    return "ok " + clicker_api("capabilities", "GET", "", c);
  }
  if (!line.startsWith("v1 "))
    return "";
  int sp = line.indexOf(' ', 3), sp2 = line.indexOf(' ', sp + 1);
  if (sp < 0)
    return "err usage v1 METHOD path [json]";
  String method = line.substring(3, sp),
         path = sp2 < 0 ? line.substring(sp + 1) : line.substring(sp + 1, sp2);
  int c;
  String out =
      clicker_api(path, method, sp2 < 0 ? "" : line.substring(sp2 + 1), c);
  if (out.length() > 460)
    return "err response too large; use HTTP";
  return (c < 400 ? "ok " : "err ") + out;
}
