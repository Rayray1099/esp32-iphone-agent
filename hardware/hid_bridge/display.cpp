#include "ble_link.h"
#include "clicker_service.h"
#include "netcfg.h"
#include "src/clicker/screen.h"
#include <SPI.h>
#include <WiFi.h>
#include <atomic>
#include <cJSON.h>
#include <esp_heap_caps.h>
#include <esp_http_server.h>
#include <esp_timer.h>
#include <tusb.h>
extern const char *resetReason();
static uint16_t *framebuffer;
static uint32_t sentRows[240]{};
static bool firstFrame = true;
static std::atomic<bool> renderStarted{false};
static SemaphoreHandle_t frameLock;
static SPIClass lcd(FSPI);
static void command(uint8_t c, const uint8_t *p = nullptr, size_t n = 0) {
  digitalWrite(15, LOW);
  digitalWrite(6, LOW);
  lcd.write(c);
  digitalWrite(6, HIGH);
  if (n)
    lcd.writeBytes(p, n);
  digitalWrite(15, HIGH);
}
static void pushFrame() {
  lcd.beginTransaction(SPISettings(40000000, MSBFIRST, SPI_MODE0));
  const uint8_t x[] = {0, 0, 1, 63};
  uint8_t line[640];
  for (int y = 0; y < 240; y++) {
    uint32_t hash = 2166136261u;
    for (int x = 0; x < 320; x++) {
      uint16_t v = framebuffer[y * 320 + x];
      hash = (hash ^ v) * 16777619u;
      line[2 * x] = v >> 8;
      line[2 * x + 1] = v;
    }
    if (!firstFrame && sentRows[y] == hash)
      continue;
    sentRows[y] = hash;
    uint8_t row[] = {0, uint8_t(y), 0, uint8_t(y)};
    command(0x2a, x, 4);
    command(0x2b, row, 4);
    command(0x2c);
    digitalWrite(15, LOW);
    digitalWrite(6, HIGH);
    lcd.writeBytes(line, sizeof line);
    digitalWrite(15, HIGH);
  }
  firstFrame = false;
  digitalWrite(15, HIGH);
  lcd.endTransaction();
}
static String field(const String &json, const char *key) {
  auto *j = cJSON_Parse(json.c_str());
  auto *v = cJSON_GetObjectItemCaseSensitive(j, key);
  String s = cJSON_IsString(v) ? v->valuestring : "";
  cJSON_Delete(j);
  return s;
}
static void renderTask(void *) {
  float history[24]{};
  uint32_t historyAt = 0;
  for (;;) {
    auto s = clicker_stats();
    String name = clicker_selected_name(), net = net_mode(), ip = net_ip(),
           ssid = net_ap_ssid(), pass = net_ap_password(),
           token = controller_token();
    String remote = remote_status(), vpn = field(remote, "ip"),
           ota = ota_status(), update = field(ota, "state");
    auto *otaJson = cJSON_Parse(ota.c_str());
    auto *written = cJSON_GetObjectItemCaseSensitive(otaJson, "written");
    auto *total = cJSON_GetObjectItemCaseSensitive(otaJson, "total");
    if (cJSON_IsNumber(written) && cJSON_IsNumber(total) &&
        total->valuedouble > 0)
      update += " " +
                String(int(100 * written->valuedouble / total->valuedouble)) +
                "%";
    cJSON_Delete(otaJson);
    String error = clicker_last_error(), networkStatus = net_status_json();
    String networkError = field(networkStatus, "error");
    if (networkError.length())
      error = networkError;
    String qr = "WIFI:T:WPA;S:" + ssid + ";P:" + pass + ";;";
    clicker::ScreenData d;
    d.profile = name.c_str();
    d.network = net.c_str();
    d.ip = ip.c_str();
    d.usb = tud_mounted() ? (tud_suspended() ? "ASLEEP" : "OK") : "OFF";
    d.ble = clicker_radios_off() ? "OFF"
            : ble_mouse_connected() ? "MOUSE CONNECTED"
            : ble_connected()    ? "CONNECTED"
                                 : "ADVERTISING";
    d.vpn = vpn.c_str();
    String connectedSsid = field(networkStatus, "ssid");
    d.ssid = connectedSsid.c_str();
    d.password = pass.c_str();
    d.token = token.c_str();
    d.ota = update.c_str();
    d.qr = qr.c_str();
    d.error = error.c_str();
    d.reset = resetReason();
    d.rssi = WiFi.status() == WL_CONNECTED ? WiFi.RSSI() : 0;
    d.requestedCps = clicker_requested_cps();
    d.output = clicker_bluetooth_output() ? "BT" : "USB";
    String target = clicker_bluetooth_output() ? ble_mouse_label() : tud_mounted() ? "USB HOST" : "NO TARGET";
    d.target = target.c_str();
    d.inputConnected = clicker_bluetooth_output() ? ble_mouse_connected() : tud_mounted() && !tud_suspended();
    d.controllers = ble_controller_peers();
    d.releasing = s.releasing;
    d.clicks = s.clicks;
    d.loops = s.loops;
    d.late = s.late;
    d.schedules = s.active;
    d.point = s.point;
    d.running = s.running;
    d.heap = ESP.getFreeHeap();
    d.psram = ESP.getFreePsram();
    d.uptime = millis() / 1000;
    double seconds = (s.lastClickUs - s.firstClickUs) / 1e6;
    d.cps = seconds > 0 ? (s.clicks - 1) / seconds : 0;
    d.animationMs = millis();
    if (millis() - historyAt >= 500) {
      memmove(history, history + 1, sizeof(history) - sizeof(history[0]));
      history[23] = s.running ? d.cps : 0;
      historyAt = millis();
    }
    memcpy(d.history, history, sizeof(history));
    int page = s.running || net == "off" ? 0 : (millis() / 7000) % 4;
    if (update != "idle")
      page = 3;
    if (page == 3)
      d.ssid = ssid.c_str();
    xSemaphoreTake(frameLock, portMAX_DELAY);
    clicker::Screen(framebuffer).render(page, d);
    pushFrame();
    xSemaphoreGive(frameLock);
    renderStarted = true;
    vTaskDelay(pdMS_TO_TICKS(s.running && d.requestedCps > 75 ? 1000 : s.running ? 500 : 250));
  }
}
void display_begin() {
  framebuffer = (uint16_t *)heap_caps_malloc(
      320 * 240 * 2, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!framebuffer)
    return;
  frameLock = xSemaphoreCreateMutex();
  if (!frameLock)
    return;
  pinMode(16, OUTPUT);
  digitalWrite(16, HIGH);
  pinMode(15, OUTPUT);
  pinMode(6, OUTPUT);
  pinMode(7, OUTPUT);
  digitalWrite(15, HIGH);
  digitalWrite(7, HIGH);
  delay(10);
  digitalWrite(7, LOW);
  delay(20);
  digitalWrite(7, HIGH);
  delay(120);
  lcd.begin(2, -1, 5, 15);
  lcd.beginTransaction(SPISettings(40000000, MSBFIRST, SPI_MODE0));
  command(0x01);
  delay(150);
  command(0x11);
  delay(120);
  uint8_t color = 0x55, madctl = 0xA0;
  command(0x3a, &color, 1);
  command(0x36, &madctl, 1);
  command(0x21);
  command(0x29);
  lcd.endTransaction();
  digitalWrite(16, LOW);
  xTaskCreatePinnedToCore(renderTask, "tft", 8192, nullptr, 1, nullptr, 0);
}
void display_poll() {}
bool display_healthy() { return framebuffer && frameLock && renderStarted; }
bool display_bmp(void *request) {
  auto *r = (httpd_req_t *)request;
  if (!framebuffer) {
    httpd_resp_set_status(r, "503 Service Unavailable");
    httpd_resp_sendstr(r, "No framebuffer");
    return false;
  }
  auto *snapshot = (uint16_t *)heap_caps_malloc(320 * 240 * 2, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!snapshot) {
    httpd_resp_set_status(r, "503 Service Unavailable");
    httpd_resp_sendstr(r, "Snapshot memory unavailable");
    return false;
  }
  struct FreeSnapshot { uint16_t *p; ~FreeSnapshot() { free(p); } } cleanup{snapshot};
  xSemaphoreTake(frameLock, portMAX_DELAY);
  memcpy(snapshot, framebuffer, 320 * 240 * 2);
  xSemaphoreGive(frameLock);
  uint8_t header[54] = {0x42, 0x4d};
  auto put = [&](int at, uint32_t v) { memcpy(header + at, &v, 4); };
  put(2, 54 + 320 * 240 * 3);
  put(10, 54);
  put(14, 40);
  put(18, 320);
  put(22, 240);
  header[26] = 1;
  header[28] = 24;
  put(34, 320 * 240 * 3);
  httpd_resp_set_type(r, "image/bmp");
  httpd_resp_set_hdr(r, "Cache-Control", "no-store");
  if (httpd_resp_send_chunk(r, (char *)header, sizeof header) != ESP_OK)
    return false;
  // Snapshot is coherent even if slow Wi-Fi crosses a rotating status page.
  uint8_t row[960];
  for (int y = 239; y >= 0; y--) {
    for (int x = 0; x < 320; x++) {
      uint16_t c = snapshot[y * 320 + x];
      row[x * 3] = (c & 31) * 255 / 31;
      row[x * 3 + 1] = ((c >> 5) & 63) * 255 / 63;
      row[x * 3 + 2] = ((c >> 11) & 31) * 255 / 31;
    }
    if (httpd_resp_send_chunk(r, (char *)row, sizeof row) != ESP_OK)
      return false;
  }
  return httpd_resp_send_chunk(r, nullptr, 0) == ESP_OK;
}
