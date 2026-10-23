// Mirrored H.264 from AirPlay to BLE, see video_link.h.
#include "video_link.h"
#include <esp_heap_caps.h>
#include "ble_link.h"
#include "src/video/gop.h"

// GOP since the latest IDR; overflow drops it until the next IDR. A still screen gets an IDR only every
// few minutes, so room for ~27 min of AUs at 5 fps (P-frames of a still screen are tiny).
const size_t GOP_CAP = 4 * 1024 * 1024;
const int MAX_AUS = 8192;
const size_t SCRATCH_CAP = 512 * 1024;   // largest access unit we forward
const size_t MAX_CHUNK = 512;

struct Req {
  char id[16];
  uint32_t kb;
  bool bench;
};

static gop_buf gop;
static SemaphoreHandle_t lock;
static uint8_t *scratch;
static QueueHandle_t reqs;
static TaskHandle_t task;
static volatile bool streaming;
static uint16_t seq;
static uint8_t chunk[VCHUNK_HDR + MAX_CHUNK];
static uint32_t winStart, winBytes, winFrames, lastIdr;
static volatile uint32_t statKbps, statIdrMs, statAt;
static volatile float statFps;

// One access unit as notifies. A failed chunk still consumes its seq, so the app sees a gap.
static bool sendAu(const uint8_t *p, size_t n, uint8_t flags, uint32_t ts) {
  size_t room = min(ble_video_room(), MAX_CHUNK);
  if (room < 5) return false;
  vchunk c;
  vchunk_begin(&c, p, n, flags, ts);
  for (size_t len; (len = vchunk_next(&c, chunk, room, seq)) > 0;) {
    bool ok = ble_video_send(chunk, len);
    seq++;
    if (!ok) return false;
  }
  return true;
}

// Copies AU i of generation gen into scratch; false if the GOP moved on.
static bool copyAu(uint32_t gen, int i, gop_au *au) {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool ok = gop.gen == gen && i < gop.n && gop.aus[i].len <= SCRATCH_CAP;
  if (ok) {
    *au = gop.aus[i];
    memcpy(scratch, gop.arena + au->off, au->len);
  }
  xSemaphoreGive(lock);
  return ok;
}

// Snapshot of the GOP state: generation, AU count, SPS/PPS.
static bool snapshot(uint32_t *gen, int *n, uint8_t *cfg, size_t *cfg_len, uint32_t *cfg_ts) {
  xSemaphoreTake(lock, portMAX_DELAY);
  *gen = gop.gen;
  *n = gop.wait_idr ? 0 : gop.n;
  *cfg_len = gop.cfg_len;
  *cfg_ts = gop.cfg_ts;
  memcpy(cfg, gop.cfg, gop.cfg_len);
  xSemaphoreGive(lock);
  return *n > 0 && *cfg_len > 0;
}

static String doSnap() {
  static uint8_t cfg[GOP_CFG_MAX];
  if (!ble_video_room()) return "err video not subscribed";
  for (int attempt = 0; attempt < 3; attempt++) {
    uint32_t gen, cfg_ts;
    size_t cfg_len;
    int n;
    if (!snapshot(&gen, &n, cfg, &cfg_len, &cfg_ts)) return "err no video (start screen mirroring)";
    if (!sendAu(cfg, cfg_len, VF_CONFIG | VF_SNAP, cfg_ts)) return "err ble send failed";
    bool complete = true;
    for (int i = 0; i < n && complete; i++) {
      gop_au au;
      complete = copyAu(gen, i, &au);
      if (complete && !sendAu(scratch, au.len, VF_SNAP | (au.idr ? VF_IDR : 0), au.ts)) return "err ble send failed";
    }
    if (complete) return "ok";  // else a new IDR replaced the GOP mid-send: start over with it
  }
  return "err video changing too fast";
}

static String doBench(uint32_t kb) {
  size_t room = min(ble_video_room(), MAX_CHUNK);
  if (!room) return "err video not subscribed";
  uint32_t start = millis();
  memset(chunk + VCHUNK_HDR, 0xA5, room);
  for (size_t left = kb * 1024; left;) {
    size_t n = min(left, room);
    chunk[0] = (uint8_t)seq;
    chunk[1] = (uint8_t)(seq >> 8);
    chunk[2] = VF_BENCH;
    bool ok = ble_video_send(chunk, VCHUNK_HDR + n);
    seq++;
    if (!ok) return "err ble send failed";
    left -= n;
  }
  return "ok " + String(millis() - start);
}

// Continuous mode: send every AU once, catching up from the GOP's IDR when streaming starts (P-frames
// can't be skipped: each needs the one before, and the next IDR may be minutes away). After a failed
// send, start over from the GOP's IDR.
static void streamStep() {
  static uint32_t txGen = UINT32_MAX;
  static int next;
  static uint8_t cfg[GOP_CFG_MAX];
  if (!streaming || !ble_video_room()) {
    txGen = UINT32_MAX;  // resend config + whole GOP when streaming resumes
    return;
  }
  uint32_t gen, cfg_ts;
  size_t cfg_len;
  int n;
  if (!snapshot(&gen, &n, cfg, &cfg_len, &cfg_ts)) return;
  if (gen != txGen) {
    txGen = gen;
    next = 0;
    if (!sendAu(cfg, cfg_len, VF_CONFIG, cfg_ts)) { txGen = UINT32_MAX; return; }
  }
  for (gop_au au; next < n && copyAu(gen, next, &au); next++)
    if (!sendAu(scratch, au.len, au.idr ? VF_IDR : 0, au.ts)) { txGen = UINT32_MAX; return; }
}

static void videoTask(void *) {
  for (;;) {
    Req r;
    if (xQueueReceive(reqs, &r, 0) == pdTRUE) {
      String reply = String(r.id) + " " + (r.bench ? doBench(r.kb) : doSnap());
#if DEBUG_SERIAL
      Serial.println("video: " + reply);  // the reply only goes over BLE; mirror it for serial-driven tests
#endif
      ble_reply(reply);
    }
    streamStep();
    ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(20));
  }
}

bool video_begin() {
  uint8_t *arena = (uint8_t *)heap_caps_malloc(GOP_CAP, MALLOC_CAP_SPIRAM);
  gop_au *aus = (gop_au *)heap_caps_malloc(MAX_AUS * sizeof(gop_au), MALLOC_CAP_SPIRAM);
  scratch = (uint8_t *)heap_caps_malloc(SCRATCH_CAP, MALLOC_CAP_SPIRAM);
  if (!arena || !aus || !scratch) return false;
  gop_init(&gop, arena, GOP_CAP, aus, MAX_AUS);
  lock = xSemaphoreCreateMutex();
  reqs = xQueueCreate(4, sizeof(Req));
  return xTaskCreatePinnedToCore(videoTask, "video", 6 * 1024, NULL, 2, &task, 1) == pdPASS;
}

void video_on_config(const uint8_t *sps_pps, size_t len) {
  xSemaphoreTake(lock, portMAX_DELAY);
  gop_set_config(&gop, sps_pps, len, millis());
  xSemaphoreGive(lock);
}

void video_on_au(const uint8_t *au, size_t len, bool idr) {
  uint32_t now = millis();
  winBytes += len;
  winFrames++;
  if (idr) {
    if (lastIdr) statIdrMs = now - lastIdr;
    lastIdr = now;
  }
  if (now - winStart >= 1000) {
    statKbps = winBytes * 8 / (now - winStart);
    statFps = winFrames * 1000.0f / (now - winStart);
    statAt = now;
    winBytes = winFrames = 0;
    winStart = now;
  }
  xSemaphoreTake(lock, portMAX_DELAY);
  gop_push(&gop, au, len, idr, now);
  xSemaphoreGive(lock);
  xTaskNotifyGive(task);
}

void video_stream(bool on) { streaming = on; }

static void request(const String &id, bool bench, uint32_t kb) {
  Req r = {{0}, kb, bench};
  strncpy(r.id, id.c_str(), sizeof r.id - 1);
  if (xQueueSend(reqs, &r, 0) != pdTRUE) ble_reply(id + " err busy");
}

void video_snap(const String &id) { request(id, false, 0); }
void video_bench(const String &id, uint32_t kb) { request(id, true, kb); }

VideoStats video_stats() {
  bool fresh = millis() - statAt < 3000;  // mirroring stopped: report zeros, not stale numbers
  xSemaphoreTake(lock, portMAX_DELAY);
  uint32_t gopBytes = gop.used;
  uint32_t latestMs = !gop.wait_idr && gop.n ? gop.aus[gop.n - 1].ts : 0;
  xSemaphoreGive(lock);
  return {fresh ? statKbps : 0, statIdrMs, gopBytes, latestMs, fresh ? statFps : 0};
}

esp_err_t video_http_gop(httpd_req_t *request) {
  // Never hold the producer mutex while serving a slow client. Reserve only the bytes needed,
  // in PSRAM, then retry if an IDR replaced the GOP while the allocation was being made.
  for (int attempt = 0; attempt < 3; ++attempt) {
    xSemaphoreTake(lock, portMAX_DELAY);
    uint32_t gen = gop.gen;
    size_t bytes = gop.used, configBytes = gop.cfg_len;
    bool available = !gop.wait_idr && gop.n && configBytes;
    xSemaphoreGive(lock);
    if (!available) {
      httpd_resp_set_status(request, "503 Service Unavailable");
      return httpd_resp_sendstr(request, "No decodable video");
    }
    auto *copy = static_cast<uint8_t *>(heap_caps_malloc(configBytes + bytes, MALLOC_CAP_SPIRAM));
    if (!copy) {
      httpd_resp_set_status(request, "503 Service Unavailable");
      return httpd_resp_sendstr(request, "Not enough video snapshot memory");
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    bool same = gop.gen == gen && gop.used >= bytes && gop.cfg_len == configBytes && !gop.wait_idr;
    uint32_t latest = 0;
    if (same) {
      memcpy(copy, gop.cfg, configBytes);
      memcpy(copy + configBytes, gop.arena, bytes);
      for (int i = 0; i < gop.n && gop.aus[i].off + gop.aus[i].len <= bytes; ++i) latest = gop.aus[i].ts;
    }
    xSemaphoreGive(lock);
    if (!same) { heap_caps_free(copy); continue; }
    httpd_resp_set_type(request, "video/h264");
    char up[24], captured[24];
    snprintf(up, sizeof up, "%lu", static_cast<unsigned long>(millis()));
    snprintf(captured, sizeof captured, "%lu", static_cast<unsigned long>(latest));
    httpd_resp_set_hdr(request, "X-Board-Uptime-Ms", up);
    httpd_resp_set_hdr(request, "X-Video-Captured-Ms", captured);
    esp_err_t result = httpd_resp_send(request, reinterpret_cast<char *>(copy), configBytes + bytes);
    heap_caps_free(copy);
    return result;
  }
  httpd_resp_set_status(request, "503 Service Unavailable");
  return httpd_resp_sendstr(request, "Video changed during capture");
}

static void put32(uint8_t *p, uint32_t value) {
  for (int i = 0; i < 4; ++i) p[i] = value >> (8 * i);
}

esp_err_t video_http_frames(httpd_req_t *request) {
  char query[100]{}, value[24]{};
  uint32_t wantedGen = UINT32_MAX, after = 0;
  size_t budget = 0; // Older clients retain the complete-GOP response.
  if (httpd_req_get_url_query_str(request, query, sizeof query) == ESP_OK) {
    if (httpd_query_key_value(query, "generation", value, sizeof value) == ESP_OK) wantedGen = strtoul(value, nullptr, 10);
    if (httpd_query_key_value(query, "after", value, sizeof value) == ESP_OK) after = strtoul(value, nullptr, 10);
    if (httpd_query_key_value(query, "max_bytes", value, sizeof value) == ESP_OK)
      budget = std::max<size_t>(16384, std::min<size_t>(strtoul(value, nullptr, 10), 512 * 1024));
  }
  for (int attempt = 0; attempt < 3; ++attempt) {
    xSemaphoreTake(lock, portMAX_DELAY);
    uint32_t gen = gop.gen;
    int count = gop.n;
    bool available = !gop.wait_idr && count && gop.cfg_len;
    bool restart = wantedGen != gen || after > static_cast<uint32_t>(count);
    int first = restart ? 0 : static_cast<int>(after);
    size_t start = first < count ? gop.aus[first].off : gop.used;
    uint32_t latest = count ? gop.aus[count - 1].ts : 0;
    count = gop_window_end(&gop, first, budget);
    size_t end = count > first ? gop.aus[count - 1].off + gop.aus[count - 1].len : start;
    size_t config = restart ? gop.cfg_len : 0;
    size_t size = 16 + (count - first + (restart ? 1 : 0)) * 9 + config + end - start;
    uint32_t up = millis();
    xSemaphoreGive(lock);
    if (!available) break;
    auto *copy = static_cast<uint8_t *>(heap_caps_malloc(size, MALLOC_CAP_SPIRAM));
    if (!copy) break;
    xSemaphoreTake(lock, portMAX_DELAY);
    bool same = gop.gen == gen && !gop.wait_idr && gop.n >= count && (!restart || gop.cfg_len == config);
    if (same) {
      memcpy(copy, "S3VF", 4); put32(copy + 4, gen); put32(copy + 8, count);
      put32(copy + 12, count - first + (restart ? 1 : 0));
      size_t pos = 16;
      auto append = [&](const uint8_t *bytes, size_t len, uint32_t ts, uint8_t flags) {
        put32(copy + pos, ts); put32(copy + pos + 4, len); copy[pos + 8] = flags;
        memcpy(copy + pos + 9, bytes, len); pos += 9 + len;
      };
      if (restart) append(gop.cfg, config, gop.cfg_ts, VF_CONFIG);
      for (int i = first; i < count; ++i) {
        const auto &au = gop.aus[i];
        append(gop.arena + au.off, au.len, au.ts, au.idr ? VF_IDR : 0);
      }
    }
    xSemaphoreGive(lock);
    if (!same) { heap_caps_free(copy); continue; }
    httpd_resp_set_type(request, "application/octet-stream");
    char uptime[24], captured[24];
    snprintf(uptime, sizeof uptime, "%lu", static_cast<unsigned long>(up));
    snprintf(captured, sizeof captured, "%lu", static_cast<unsigned long>(latest));
    httpd_resp_set_hdr(request, "X-Board-Uptime-Ms", uptime);
    httpd_resp_set_hdr(request, "X-Video-Captured-Ms", captured);
    esp_err_t result = httpd_resp_send(request, reinterpret_cast<char *>(copy), size);
    heap_caps_free(copy); return result;
  }
  httpd_resp_set_status(request, "503 Service Unavailable");
  return httpd_resp_sendstr(request, "Video unavailable; reconnect mirroring");
}
