#include "clicker_service.h"
#include <Preferences.h>
#include <WiFi.h>
#include <cJSON.h>
#include <microlink.h>
static microlink_t *vpn = nullptr;
static Preferences remotePrefs;
static bool initialized = false, enabled = false;
static String authKey, deviceName, lastError;
static uint32_t retryAfter = 0;
static SemaphoreHandle_t remoteLock = xSemaphoreCreateRecursiveMutex();
struct RemoteLock {
  RemoteLock() { xSemaphoreTakeRecursive(remoteLock, portMAX_DELAY); }
  ~RemoteLock() { xSemaphoreGiveRecursive(remoteLock); }
};
static void initRemote() {
  if (initialized)
    return;
  initialized = true;
  remotePrefs.begin("remote", false);
  enabled = remotePrefs.getBool("enabled", false);
  authKey = remotePrefs.getString("auth");
  deviceName = remotePrefs.getString("name", "s3-clicker");
}
void remote_poll() {
  RemoteLock lock;
  initRemote();
  if (!enabled || vpn || WiFi.status() != WL_CONNECTED ||
      (int32_t)(millis() - retryAfter) < 0)
    return;
  microlink_config_t c{};
  c.auth_key = authKey.c_str();
  c.device_name = deviceName.c_str();
  c.enable_derp = true;
  c.enable_stun = true;
  c.enable_disco = true;
  c.max_peers = 4;
  c.wifi_tx_power_dbm = 5;
  vpn = microlink_init(&c);
  if (!vpn) {
    lastError = "Tailscale initialization failed (memory/configuration)";
    retryAfter = millis() + 60000;
    return;
  }
  esp_err_t err = microlink_start(vpn);
  if (err != ESP_OK) {
    lastError = esp_err_to_name(err);
    microlink_destroy(vpn);
    vpn = nullptr;
    retryAfter = millis() + 60000;
  }
}
void remote_stop() {
  RemoteLock lock;
  if (vpn) {
    microlink_destroy(vpn);
    vpn = nullptr;
  }
}
String remote_status() {
  RemoteLock lock;
  initRemote();
  static const char *states[] = {"idle",        "wifi-wait", "connecting",
                                 "registering", "connected", "reconnecting",
                                 "error"};
  char ip[16] = "";
  int peers = 0, direct = 0;
  if (vpn) {
    microlink_ip_to_str(microlink_get_vpn_ip(vpn), ip);
    peers = microlink_get_peer_count(vpn);
    for (int i = 0; i < peers; ++i) {
      microlink_peer_info_t p{};
      if (microlink_get_peer_info(vpn, i, &p) == ESP_OK && p.direct_path)
        ++direct;
    }
  }
  auto *j = cJSON_CreateObject();
  cJSON_AddBoolToObject(j, "enabled", enabled);
  int state = vpn ? int(microlink_get_state(vpn)) : 0;
  cJSON_AddStringToObject(j, "state",
                          states[state >= 0 && state < 7 ? state : 6]);
  cJSON_AddStringToObject(j, "ip", ip);
  cJSON_AddNumberToObject(j, "peers", peers);
  cJSON_AddNumberToObject(j, "direct_peers", direct);
  cJSON_AddStringToObject(j, "error", lastError.c_str());
  char *out = cJSON_PrintUnformatted(j);
  String result = out;
  free(out);
  cJSON_Delete(j);
  return result;
}
String remote_configure(const String &json) {
  RemoteLock lock;
  initRemote();
  if (clicker_busy())
    return "err stop clicking before changing Tailscale";
  auto *j = cJSON_Parse(json.c_str());
  if (!j)
    return "err invalid Tailscale JSON";
  auto *e = cJSON_GetObjectItemCaseSensitive(j, "enabled");
  auto *k = cJSON_GetObjectItemCaseSensitive(j, "auth_key");
  auto *n = cJSON_GetObjectItemCaseSensitive(j, "name");
  if (cJSON_IsString(k)) {
    String s = k->valuestring;
    if (!s.startsWith("tskey-auth-") || s.length() > 250) {
      cJSON_Delete(j);
      return "err invalid enrollment key";
    }
    authKey = s;
  }
  if (cJSON_IsString(n)) {
    String s = n->valuestring;
    if (s.length() < 1 || s.length() > 63) {
      cJSON_Delete(j);
      return "err invalid hostname";
    }
    deviceName = s;
  }
  enabled = cJSON_IsTrue(e);
  if (enabled && authKey.isEmpty()) {
    cJSON_Delete(j);
    return "err enrollment key required";
  }
  remote_stop();
  remotePrefs.putBool("enabled", enabled);
  remotePrefs.putString("auth", authKey);
  remotePrefs.putString("name", deviceName);
  cJSON_Delete(j);
  return "ok";
}
