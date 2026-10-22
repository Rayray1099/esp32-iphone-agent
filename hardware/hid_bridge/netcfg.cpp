#include "netcfg.h"
#include <Preferences.h>
#include <WiFi.h>
#include <cJSON.h>
#include <esp_coexist.h>
#include <esp_eap_client.h>
#include <esp_mac.h>
#include <esp_netif.h>
#include <esp_random.h>
#include <esp_wifi.h>
#include <time.h>
static Preferences prefs;
static String apSsid, apPass, staSsid, staPass, mode, enterprise, pending,
    lastError;
static SemaphoreHandle_t pendingLock = xSemaphoreCreateMutex();
static uint32_t retryAt = 0, retryGap = 5000;
static uint16_t disconnectReason = 0;
static int coexPref = ESP_COEX_PREFER_BALANCE;
static String str(cJSON *j, const char *k) {
  auto *v = cJSON_GetObjectItemCaseSensitive(j, k);
  return cJSON_IsString(v) ? v->valuestring : "";
}
static String print(cJSON *j) {
  char *p = cJSON_PrintUnformatted(j);
  String s = p ? p : "{}";
  cJSON_free(p);
  return s;
}
String board_suffix() {
  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_BT);
  char s[5];
  snprintf(s, sizeof s, "%02X%02X", mac[4], mac[5]);
  return s;
}
static String randomPass() {
  const char *abc = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  String p;
  for (int i = 0; i < 12; i++)
    p += abc[esp_random() % strlen(abc)];
  return p;
}
static void noDefaultRoute() {
  auto *ap = WiFi.AP.netif();
  if (!ap)
    return;
  uint8_t off = 0;
  esp_netif_dhcps_stop(ap);
  esp_netif_dhcps_option(ap, ESP_NETIF_OP_SET,
                         ESP_NETIF_ROUTER_SOLICITATION_ADDRESS, &off,
                         sizeof off);
  esp_netif_dhcps_option(ap, ESP_NETIF_OP_SET, ESP_NETIF_DOMAIN_NAME_SERVER,
                         &off, sizeof off);
  esp_netif_dhcps_start(ap);
}
static bool check(esp_err_t e) {
  if (e == ESP_OK)
    return true;
  lastError = String("EAP: ") + esp_err_to_name(e);
  return false;
}
static bool configureEap() {
  auto *j = cJSON_Parse(enterprise.c_str());
  if (!j) {
    lastError = "Missing enterprise configuration";
    return false;
  }
  String method = str(j, "method"), identity = str(j, "identity"),
         user = str(j, "username"), pass = str(j, "password");
  String ca = str(j, "ca"), server = str(j, "server"),
         cert = str(j, "client_cert"), key = str(j, "client_key"),
         phase = str(j, "phase2");
  if (time(nullptr) < 1735689600) {
    lastError =
        "Set current time in setup before validating the eduroam certificate";
    cJSON_Delete(j);
    return false;
  }
  bool ok = check(esp_eap_client_set_ca_cert((const unsigned char *)ca.c_str(),
                                             ca.length() + 1)) &&
            check(esp_eap_client_set_domain_name(server.c_str())) &&
            check(esp_eap_client_set_disable_time_check(false)) &&
            check(esp_eap_client_set_identity(
                (const unsigned char *)identity.c_str(), identity.length()));
  if (method == "tls") {
    ok = ok && check(esp_eap_client_set_eap_methods(ESP_EAP_TYPE_TLS)) &&
         check(esp_eap_client_set_certificate_and_key(
             (const unsigned char *)cert.c_str(), cert.length() + 1,
             (const unsigned char *)key.c_str(), key.length() + 1, nullptr, 0));
  } else {
    ok = ok &&
         check(esp_eap_client_set_username((const unsigned char *)user.c_str(),
                                           user.length())) &&
         check(esp_eap_client_set_password((const unsigned char *)pass.c_str(),
                                           pass.length())) &&
         check(esp_eap_client_set_eap_methods(
             method == "ttls" ? ESP_EAP_TYPE_TTLS : ESP_EAP_TYPE_PEAP));
    if (method == "ttls") {
      auto p = phase == "pap"   ? ESP_EAP_TTLS_PHASE2_PAP
               : phase == "eap" ? ESP_EAP_TTLS_PHASE2_EAP
                                : ESP_EAP_TTLS_PHASE2_MSCHAPV2;
      ok = ok && check(esp_eap_client_set_ttls_phase2_method(p));
    }
  }
  cJSON_Delete(j);
  return ok && check(esp_wifi_sta_enterprise_enable());
}
static void joinSta() {
  if (enterprise.length()) {
    if (!configureEap())
      return;
    WiFi.begin(staSsid.c_str());
  } else {
    esp_wifi_sta_enterprise_disable();
    WiFi.setMinSecurity(staPass.isEmpty() ? WIFI_AUTH_OPEN
                                          : WIFI_AUTH_WPA2_PSK);
    WiFi.begin(staSsid.c_str(), staPass.c_str());
  }
}
static void startWifi() {
  lastError = "";
  WiFi.disconnect(true);
  WiFi.softAPdisconnect(true);
  WiFi.setHostname("s3-clicker");
  if (mode == "off") {
    WiFi.mode(WIFI_OFF);
    return;
  }
  bool station = mode == "sta" || mode == "apsta";
  WiFi.mode(station ? (mode == "apsta" ? WIFI_AP_STA : WIFI_STA) : WIFI_AP);
  WiFi.setAutoReconnect(false);
  if (mode != "sta") {
    WiFi.softAP(apSsid.c_str(), apPass.c_str(), 6, 0, 4);
    WiFi.setTxPower(WIFI_POWER_5dBm);
    noDefaultRoute();
  }
  if (station) {
    retryGap = 5000;
    retryAt = millis() + retryGap;
    joinSta();
  }
}
void net_begin(bool offline) {
  prefs.begin("agent", false);
  apSsid = prefs.getString("ap_ssid");
  apPass = prefs.getString("ap_pass");
  if (apSsid.isEmpty() || apPass.length() < 8) {
    apSsid = "ESP32Agent-" + board_suffix();
    apPass = randomPass();
    prefs.putString("ap_ssid", apSsid);
    prefs.putString("ap_pass", apPass);
  }
  mode = prefs.getString("mode", "ap");
  staSsid = prefs.getString("sta_ssid");
  staPass = prefs.getString("sta_pass");
  enterprise = prefs.getString("eap");
  WiFi.onEvent([](arduino_event_id_t event, arduino_event_info_t info) {
    if (event == ARDUINO_EVENT_WIFI_STA_DISCONNECTED)
      disconnectReason = info.wifi_sta_disconnected.reason;
    if (event == ARDUINO_EVENT_WIFI_STA_GOT_IP) {
      disconnectReason = 0;
      configTime(0, 0, "time.cloudflare.com", "pool.ntp.org");
    }
  });
  if ((mode == "sta" || mode == "apsta") && staSsid.isEmpty())
    mode = "ap";
  if (offline) {
    mode = "off";
  } else {
    startWifi();
    net_coex("balance");
  }
}
String net_configure(const String &json) {
  if (json.length() > 60000)
    return "err network configuration too large";
  auto *j = cJSON_ParseWithLength(json.c_str(), json.length());
  if (!j)
    return "err invalid network JSON";
  String m = str(j, "mode"), ssid = str(j, "ssid"), err;
  auto *e = cJSON_GetObjectItemCaseSensitive(j, "eap");
  if (m != "off" && m != "ap" && m != "sta" && m != "apsta")
    err = "mode must be off, ap, sta or apsta";
  else if ((m == "sta" || m == "apsta") &&
           (ssid.isEmpty() || ssid.length() > 32))
    err = "SSID required (1-32 bytes)";
  else if (e && !cJSON_IsNull(e)) {
    String method = str(e, "method"), ca = str(e, "ca"),
           server = str(e, "server"), id = str(e, "identity");
    if (!cJSON_IsObject(e) ||
        (method != "peap" && method != "ttls" && method != "tls"))
      err = "EAP method must be peap, ttls or tls";
    else if (ca.indexOf("-----BEGIN CERTIFICATE-----") < 0 ||
             server.isEmpty() || server.indexOf('/') >= 0 ||
             server.indexOf(' ') >= 0 || id.isEmpty())
      err = "EAP requires trusted CA, authentication server name and outer "
            "identity";
    else if (method == "tls" && (str(e, "client_cert").isEmpty() ||
                                 str(e, "client_key").isEmpty()))
      err = "EAP-TLS requires client certificate and private key";
    else if (method != "tls" &&
             (str(e, "username").isEmpty() || str(e, "password").isEmpty()))
      err = "EAP username and password required";
    else if (method == "ttls" && str(e, "phase2") != "mschapv2" &&
             str(e, "phase2") != "pap" && str(e, "phase2") != "eap")
      err = "TTLS phase2 must be mschapv2, pap or eap";
  }
  cJSON_Delete(j);
  if (err.length())
    return "err " + err;
  xSemaphoreTake(pendingLock, portMAX_DELAY);
  pending = json;
  xSemaphoreGive(pendingLock);
  return "ok";
}
void net_request(const String &json) { net_configure(json); }
void net_poll() {
  if ((mode == "sta" || mode == "apsta") && WiFi.status() != WL_CONNECTED &&
      (int32_t)(millis() - retryAt) >= 0) {
    WiFi.disconnect();
    joinSta();
    retryGap = std::min<uint32_t>(retryGap * 2, 60000);
    retryAt = millis() + retryGap;
    if (mode == "sta" && retryGap >= 60000) {
      mode = "apsta";
      startWifi();
    }
  }
  xSemaphoreTake(pendingLock, portMAX_DELAY);
  String p = pending;
  pending = "";
  xSemaphoreGive(pendingLock);
  if (p.isEmpty())
    return;
  auto *j = cJSON_Parse(p.c_str());
  if (!j)
    return;
  mode = str(j, "mode");
  auto *clock = cJSON_GetObjectItemCaseSensitive(j, "unix_time");
  if (cJSON_IsNumber(clock) && clock->valuedouble >= 1735689600 &&
      clock->valuedouble < 4102444800) {
    timeval tv{time_t(clock->valuedouble), 0};
    settimeofday(&tv, nullptr);
  }
  if (mode == "sta" || mode == "apsta") {
    staSsid = str(j, "ssid");
    staPass = str(j, "pass");
    auto *e = cJSON_GetObjectItemCaseSensitive(j, "eap");
    enterprise = cJSON_IsObject(e) ? print(e) : "";
    prefs.putString("sta_ssid", staSsid);
    prefs.putString("sta_pass", staPass);
    prefs.putString("eap", enterprise);
  }
  prefs.putString("mode", mode);
  cJSON_Delete(j);
  startWifi();
}
String net_status_json() {
  auto *j = cJSON_CreateObject();
  cJSON_AddStringToObject(j, "mode", mode.c_str());
  cJSON_AddStringToObject(j, "ssid", (mode == "ap" ? apSsid : staSsid).c_str());
  cJSON_AddStringToObject(j, "ip", net_ip().c_str());
  cJSON_AddStringToObject(
      j, "ap_ip", mode == "off" ? "" : WiFi.softAPIP().toString().c_str());
  cJSON_AddNumberToObject(j, "rssi",
                          WiFi.status() == WL_CONNECTED ? WiFi.RSSI() : 0);
  cJSON_AddNumberToObject(j, "disconnect_reason", disconnectReason);
  cJSON_AddBoolToObject(j, "enterprise", enterprise.length() > 0);
  cJSON_AddStringToObject(j, "error", lastError.c_str());
  cJSON_AddBoolToObject(j, "clock_valid", time(nullptr) >= 1735689600);
  String out = print(j);
  cJSON_Delete(j);
  return out;
}
String net_json() {
  auto *j = cJSON_Parse(net_status_json().c_str());
  if (mode == "ap" || mode == "apsta") {
    cJSON_DeleteItemFromObject(j, "ssid");
    cJSON_AddStringToObject(j, "ssid", apSsid.c_str());
    cJSON_AddStringToObject(j, "pass", apPass.c_str());
  }
  String out = print(j);
  cJSON_Delete(j);
  return out;
}
String net_ap_ssid() { return apSsid; }
String net_ap_password() { return apPass; }
const char *net_mode() {
  if (mode == "sta" && WiFi.status() != WL_CONNECTED)
    return "none";
  return mode.c_str();
}
String net_ip() {
  if (WiFi.status() == WL_CONNECTED)
    return WiFi.localIP().toString();
  return mode == "off" ? "" : WiFi.softAPIP().toString();
}
int net_peers() {
  return (mode == "off" ? 0 : WiFi.softAPgetStationNum()) +
         (WiFi.status() == WL_CONNECTED ? 1 : 0);
}
bool net_up() {
  return mode != "off" && (mode != "sta" || WiFi.status() == WL_CONNECTED);
}
static const char *coexNames[] = {"wifi", "bt", "balance"};
bool net_coex(const String &pref) {
  for (int i = 0; i < 3; i++)
    if (pref == coexNames[i] &&
        esp_coex_preference_set((esp_coex_prefer_t)i) == ESP_OK) {
      coexPref = i;
      return true;
    }
  return false;
}
const char *net_coex_mode() { return coexNames[coexPref]; }
uint16_t cfg_width() { return prefs.getUShort("w", 480); }
uint16_t cfg_height() { return prefs.getUShort("h", 1040); }
uint8_t cfg_fps() { return prefs.getUChar("fps", 5); }
void cfg_set_res(uint16_t w, uint16_t h) {
  prefs.putUShort("w", w);
  prefs.putUShort("h", h);
}
void cfg_set_fps(uint8_t fps) { prefs.putUChar("fps", fps); }
void cfg_ed25519_seed(uint8_t seed[32]) {
  if (prefs.getBytes("ed_seed", seed, 32) == 32)
    return;
  esp_fill_random(seed, 32);
  prefs.putBytes("ed_seed", seed, 32);
}
