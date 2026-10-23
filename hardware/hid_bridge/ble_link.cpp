// BLE GATT link, see ble_link.h. Host: h2zero NimBLE-Arduino 2.5.x, buffer sizes in nimble_cfg.h.
//
// Send path: replies and status go through a queue drained by one TX task (callers never block on
// the radio); video is sent from the video task and always yields to them. NimBLE's NOTIFY_TX event
// fires when a notify is queued in the host, not when it is on air, so it cannot pace anything.
// Video is paced on the controller's ACL credits instead (the host's count, returned by HCI Number
// of Completed Packets): while commands flow, at most VIDEO_CTRL_PKTS packets in the controller, so a
// reply or an ATT write response never queues behind more than ~2 KB of video. It also leaves MBUF_RESERVE host
// blocks free, and never sends while a reply or status is waiting.
#include "ble_link.h"
#include <atomic>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>
#include <esp_timer.h>
#include <cJSON.h>
#include "tusb.h"
#include "nimble/nimble/host/include/host/ble_hs.h"
#include "netcfg.h"

static_assert(MYNEWT_VAL(MSYS_1_BLOCK_COUNT) == 64 && MYNEWT_VAL(MSYS_1_BLOCK_SIZE) == 320,
              "nimble_cfg.h not applied: build with hardware/flash.sh");
static_assert(MYNEWT_VAL(MSYS_2_BLOCK_COUNT) == 0 && MYNEWT_VAL(BLE_TRANSPORT_ACL_FROM_LL_COUNT) == 24, "nimble_cfg.h");
static_assert(MYNEWT_VAL(BLE_ATT_PREFERRED_MTU) == 517 && MYNEWT_VAL(BLE_HS_LOG_LVL) == 5, "nimble_cfg.h");
static_assert(MYNEWT_VAL(BLE_L2CAP_COC_MAX_NUM) == 1 && MYNEWT_VAL(BLE_L2CAP_COC_MPS) == 247, "nimble_cfg.h");

#define UUID(s) "6e400001-a9e8-4b1b-9c39-6d6f8a3c" s
const size_t CMD_MAX = 512;
const size_t TEXT_MAX = 514;               // MTU 517 - 3
const uint32_t VIDEO_TIMEOUT_MS = 1500;    // a full buffer waits; only a stalled link drops the chunk
const uint32_t REPLY_TIMEOUT_MS = 3000;    // replies retry this long (video is paused meanwhile)
const uint32_t STATUS_TIMEOUT_MS = 500;    // a newer status replaces it a second later anyway
const int MBUF_RESERVE = 16;               // of 64 msys blocks; video never takes these
const int VIDEO_CTRL_PKTS = 8;             // ACL packets video may have in the controller while commands flow
const uint32_t CMD_ACTIVE_MS = 1000;       // ... i.e. for this long after a `cmd` write; otherwise all of them
const int MBUF_DATA = MYNEWT_VAL(MSYS_1_BLOCK_SIZE) - 16;  // payload per block (16 B mbuf header)
// Up to MAX_PEERS centrals at once: the phone's app, plus a Mac as a debug harness.
const int MAX_PEERS = 2;

enum { CH_REPLY, CH_STATUS, CH_VIDEO, CH_COUNT };

struct Text {
  uint16_t len;
  char s[TEXT_MAX];
};

static NimBLEServer *server;
static NimBLECharacteristic *mouseReport;
static NimBLECharacteristic *keyboardReport, *consumerReport;
static std::atomic<int> mousePeer{-1};
static int64_t lastMouseReportUs = 0;
static uint8_t mouseMap[] = {
  TUD_HID_REPORT_DESC_MOUSE(HID_REPORT_ID(1)),
  TUD_HID_REPORT_DESC_KEYBOARD(HID_REPORT_ID(2)),
  TUD_HID_REPORT_DESC_CONSUMER(HID_REPORT_ID(3))
};
static NimBLECharacteristic *chars[CH_COUNT], *netChar;
static QueueHandle_t cmdQueue, replyQueue;
static SemaphoreHandle_t statusLock;
static Text statusText;
static bool statusDirty;
static std::atomic<int> ctrlPending;  // replies queued or sending + a status waiting; video yields to them
static volatile int peers[MAX_PEERS] = {-1, -1};
static volatile bool subscribed[MAX_PEERS][CH_COUNT];
static bool mouseSubscribed[MAX_PEERS]{};
static bool keyboardSubscribed[MAX_PEERS]{}, consumerSubscribed[MAX_PEERS]{};
static portMUX_TYPE labelLock = portMUX_INITIALIZER_UNLOCKED;
static char peerLabels[MAX_PEERS][25]{};
static char peerSuffixes[MAX_PEERS][6]{};
static int slotFor(int h);
static void rememberPeer(NimBLEConnInfo &ci) {
  int slot = slotFor(ci.getConnHandle());
  if (slot < 0) return;
  std::string address = ci.getIdAddress().toString();
  portENTER_CRITICAL(&labelLock);
  if (address.size() >= 5)
    strlcpy(peerSuffixes[slot], address.c_str() + address.size() - 5, sizeof peerSuffixes[slot]);
  portEXIT_CRITICAL(&labelLock);
}
static uint32_t winStart, winBytes;  // touched by the video task only
static volatile uint32_t kbps;
static std::atomic<uint32_t> drops, replyDrops;
static volatile uint32_t lastCmdMs;  // last `cmd` write: replies are expected, keep video's share small

#if DEBUG_SERIAL
#define BLE_LOG(...) Serial.printf("ble: " __VA_ARGS__)
#else
#define BLE_LOG(...) ((void)0)
#endif

static int slotOf(int h) {
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] == h) return i;
  return -1;
}

// The peer's slot, claimed on first sight: a bonded central's restored subscriptions (and its
// encryption) can be reported before onConnect, and must not be lost.
static int slotFor(int h) {
  int i = slotOf(h);
  if (i < 0 && (i = slotOf(-1)) >= 0) {
    for (int c = 0; c < CH_COUNT; c++) subscribed[i][c] = false;
    peers[i] = h;
  }
  return i;
}

static int peerCount() {
  int n = 0;
  for (int i = 0; i < MAX_PEERS; i++) n += peers[i] >= 0;
  return n;
}

static int indexOf(NimBLECharacteristic *c) {
  for (int i = 0; i < CH_COUNT; i++)
    if (chars[i] == c) return i;
  return -1;
}

static bool anySubscribed(int ch) {
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] >= 0 && subscribed[i][ch]) return true;
  return false;
}

static void logConn(const char *what, NimBLEConnInfo &ci) {
  BLE_LOG("%s conn %u: interval %.2f ms, latency %u, timeout %u ms, mtu %u, %s\n", what, ci.getConnHandle(),
          ci.getConnInterval() * 1.25f, ci.getConnLatency(), ci.getConnTimeout() * 10u, ci.getMTU(),
          ci.isEncrypted() ? (ci.isBonded() ? "encrypted+bonded" : "encrypted") : "plain");
}

// 15 ms interval, no latency, 4 s supervision; reliable 1M PHY; DLE 251.
static void tuneLink(uint16_t h) {
  // Keep the connection on 1M: forcing 2M makes weak links repeatedly time out.
  server->setDataLen(h, 251);
  server->updateConnParams(h, 12, 12, 0, 400);
}

class ServerCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *s, NimBLEConnInfo &ci) override {
    if (slotFor(ci.getConnHandle()) < 0) { s->disconnect(ci.getConnHandle()); return; }
    rememberPeer(ci);
    logConn("connect", ci);
    tuneLink(ci.getConnHandle());
    if (peerCount() < MAX_PEERS) NimBLEDevice::startAdvertising();  // room for the debug harness
  }
  void onDisconnect(NimBLEServer *s, NimBLEConnInfo &ci, int reason) override {
    if (mousePeer == ci.getConnHandle()) mousePeer = -1;
    int i = slotOf(ci.getConnHandle());
    if (i >= 0) {
      portENTER_CRITICAL(&labelLock);
      peerLabels[i][0] = peerSuffixes[i][0] = 0;
      portEXIT_CRITICAL(&labelLock);
      mouseSubscribed[i] = false;
      keyboardSubscribed[i] = consumerSubscribed[i] = false;
      for (int c = 0; c < CH_COUNT; c++) subscribed[i][c] = false;
      peers[i] = -1;
    }
    BLE_LOG("disconnect conn %u, reason 0x%x\n", ci.getConnHandle(), reason);
    NimBLEDevice::startAdvertising();
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo &ci) override { BLE_LOG("conn %u: mtu %u\n", ci.getConnHandle(), mtu); }
  void onConnParamsUpdate(NimBLEConnInfo &ci) override { logConn("params", ci); }
  void onPhyUpdate(NimBLEConnInfo &ci, uint8_t tx, uint8_t rx) override {
    BLE_LOG("conn %u: phy tx %uM rx %uM\n", ci.getConnHandle(), tx, rx);
  }
  void onAuthenticationComplete(NimBLEConnInfo &ci) override {
    rememberPeer(ci);
    logConn("security", ci);
    int slot = slotOf(ci.getConnHandle());
    if (slot >= 0 && mouseSubscribed[slot] && ci.isEncrypted() && ci.isBonded()) {
      int expected = -1;
      mousePeer.compare_exchange_strong(expected, ci.getConnHandle());
    }
  }
};

class CharCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &ci) override {
    const NimBLEAttValue &raw = c->getValue();
    String v(raw.c_str(), raw.length());
    if (c == netChar) { net_request(v); return; }
    // Versioned commands can carry credentials and certificates. Require the same
    // encrypted, bonded channel as the existing network characteristic.
    if (v.indexOf(" v1 ") >= 0 && (!ci.isEncrypted() || !ci.isBonded())) {
      String requestId = v.substring(0, v.indexOf(' '));
      ble_reply(requestId + " err Pair and encrypt the BLE connection first");
      NimBLEDevice::startSecurity(ci.getConnHandle());
      return;
    }
    // Bind the friendly label to the authenticated sender, never to another
    // connected phone. A controller and the HID target may be different peers.
    int labelAt = v.indexOf(" v1 PUT device/label ");
    if (labelAt >= 0) {
      auto *j = cJSON_Parse(v.substring(labelAt + 21).c_str());
      auto *name = cJSON_GetObjectItemCaseSensitive(j, "name");
      int slot = slotFor(ci.getConnHandle());
      bool ok = slot >= 0 && cJSON_IsString(name) && name->valuestring[0];
      if (ok) {
        char label[25]{}; size_t n = 0;
        for (const unsigned char *p = (const unsigned char *)name->valuestring; *p && n < sizeof label - 1; ++p)
          if (*p >= 32 && *p < 127) label[n++] = *p;
        portENTER_CRITICAL(&labelLock);
        strlcpy(peerLabels[slot], n ? label : "PHONE", sizeof peerLabels[slot]);
        portEXIT_CRITICAL(&labelLock);
      }
      cJSON_Delete(j);
      ble_reply(v.substring(0, labelAt) + (ok ? " ok {\"ok\":true}" : " err invalid device label"));
      return;
    }
    char line[CMD_MAX] = {0};
    v.trim();
    strncpy(line, v.c_str(), CMD_MAX - 1);
    lastCmdMs = millis();
    if (line[0]) xQueueSend(cmdQueue, line, 0);  // full queue: the app times out and retries
  }
  void onRead(NimBLECharacteristic *c, NimBLEConnInfo &ci) override {
    if (c != netChar) return;
    String j = net_json();
    c->setValue((const uint8_t *)j.c_str(), j.length());
  }
  void onSubscribe(NimBLECharacteristic *c, NimBLEConnInfo &ci, uint16_t sub) override {
    if (c == keyboardReport || c == consumerReport) {
      int slot = slotFor(ci.getConnHandle());
      if (slot >= 0) (c == keyboardReport ? keyboardSubscribed : consumerSubscribed)[slot] = sub & 1;
      return;
    }
    if (c == mouseReport) {
      int slot = slotFor(ci.getConnHandle());
      if (slot >= 0) mouseSubscribed[slot] = sub & 1;
      if ((sub & 1) && ci.isEncrypted() && ci.isBonded()) {
        int expected = -1;
        mousePeer.compare_exchange_strong(expected, ci.getConnHandle());
      } else if (mousePeer == ci.getConnHandle()) mousePeer = -1;
      return;
    }
    int i = indexOf(c), p = sub & 1 ? slotFor(ci.getConnHandle()) : slotOf(ci.getConnHandle());
    if (i >= 0 && p >= 0) subscribed[p][i] = sub & 1;
    BLE_LOG("conn %u: %s %s\n", ci.getConnHandle(), sub & 1 ? "subscribed" : "unsubscribed",
            i == CH_REPLY ? "reply" : i == CH_STATUS ? "status" : "video");
  }
};

static CharCb charCb;

#if DEBUG_SERIAL
static int onGap(ble_gap_event *e, void *) {  // NimBLEServerCallbacks has no data-length event
  if (e->type == BLE_GAP_EVENT_DATA_LEN_CHG)
    BLE_LOG("data length tx %u B / %u us, rx %u B / %u us\n", e->data_len_chg.max_tx_octets,
            e->data_len_chg.max_tx_time, e->data_len_chg.max_rx_octets, e->data_len_chg.max_rx_time);
  return 0;
}
#endif

extern "C" uint16_t ble_hs_hci_avail_pkts;  // free controller ACL buffers (NimBLE host, ble_hs_hci.c)
static uint16_t ctrlMax;                     // the controller's total, read at boot with no links up
static std::atomic<bool> hidPriority{false};
void ble_hid_priority(bool active) { hidPriority = active; }

// Room for a video notify of n bytes in the controller: its ACL fragments plus those already in flight.
static bool ctrlRoom(size_t n) {
  if (hidPriority.load()) return false;
  if (ble_hs_hci_avail_pkts > ctrlMax) ctrlMax = ble_hs_hci_avail_pkts;
  bool cmds = millis() - lastCmdMs < CMD_ACTIVE_MS;
  int frags = (int)((n + 3 + 4 + 250) / 251), limit = cmds && VIDEO_CTRL_PKTS < ctrlMax ? VIDEO_CTRL_PKTS : ctrlMax;
  return ctrlMax - ble_hs_hci_avail_pkts + frags <= (frags > limit ? frags : limit);
}

// msys blocks one queued notify of n bytes holds: ATT/L2CAP/HCI headers + packet header in the first
// block, plus one for the ACL fragment the host splits off.
static int blocksFor(size_t n) { return (int)((n + 3 + 4 + 4 + 8 + MBUF_DATA - 1) / MBUF_DATA) + 1; }

// One notify through the NimBLE host directly: unlike NimBLECharacteristic::notify() it reports
// "out of buffers", so we can wait instead of silently losing the packet.
static bool notifyOne(int slot, int ch, const uint8_t *p, size_t n, uint32_t start, uint32_t timeout_ms) {
  bool video = ch == CH_VIDEO;
  int need = blocksFor(n) + (video ? MBUF_RESERVE : 0);
  for (;;) {
    int h = peers[slot];
    if (h < 0 || !subscribed[slot][ch]) return false;
    if (!(video && (ctrlPending > 0 || !ctrlRoom(n))) && os_msys_num_free() >= need) {
      os_mbuf *om = ble_hs_mbuf_from_flat(p, n);
      int rc = om ? ble_gatts_notify_custom(h, chars[ch]->getHandle(), om) : BLE_HS_ENOMEM;  // om consumed
      if (rc == 0) return true;
      if (rc != BLE_HS_ENOMEM) {
        BLE_LOG("notify ch %d conn %d failed rc=%d\n", ch, h, rc);
        return false;
      }
    }
    if (millis() - start > timeout_ms) {
      BLE_LOG("notify ch %d conn %d gave up after %lu ms (free %d)\n", ch, h, millis() - start, os_msys_num_free());
      return false;
    }
    vTaskDelay(1);
  }
}

// To every subscribed peer within one deadline; true if at least one got it.
static bool notifyRaw(int ch, const uint8_t *p, size_t n, uint32_t timeout_ms) {
  uint32_t start = millis();
  bool any = false;
  for (int i = 0; i < MAX_PEERS; i++) any |= notifyOne(i, ch, p, n, start, timeout_ms);
  return any;
}

static void sendText(int ch, const Text &t, uint32_t timeout_ms) {
  size_t room = ble_mtu() - 3;
  if (!notifyRaw(ch, (const uint8_t *)t.s, t.len < room ? t.len : room, timeout_ms) && ch == CH_REPLY &&
      anySubscribed(CH_REPLY)) {
    replyDrops++;
    BLE_LOG("reply dropped: %.*s\n", (int)t.len, t.s);
  }
}

static void txTask(void *) {
  static Text t;
  for (;;) {
    if (xQueueReceive(replyQueue, &t, pdMS_TO_TICKS(20)) == pdTRUE) {
      sendText(CH_REPLY, t, REPLY_TIMEOUT_MS);
      ctrlPending--;
    }
    xSemaphoreTake(statusLock, portMAX_DELAY);
    bool due = statusDirty;
    if (due) t = statusText;
    statusDirty = false;
    xSemaphoreGive(statusLock);
    if (due) {
      sendText(CH_STATUS, t, STATUS_TIMEOUT_MS);
      ctrlPending--;
    }
  }
}

static void toText(Text &t, const String &s) {
  t.len = s.length() < TEXT_MAX ? s.length() : TEXT_MAX;
  memcpy(t.s, s.c_str(), t.len);
}

void ble_begin(const String &name) {
  cmdQueue = xQueueCreate(6, CMD_MAX);
  replyQueue = xQueueCreate(8, sizeof(Text));
  statusLock = xSemaphoreCreateMutex();
  NimBLEDevice::init(name.c_str());
  NimBLEDevice::setMTU(517);
  NimBLEDevice::setPower(9);  // dBm: retain link margin during setup, including a board powered by a Mac.
  NimBLEDevice::setDefaultPhy(BLE_GAP_LE_PHY_1M_MASK, BLE_GAP_LE_PHY_1M_MASK);
  NimBLEDevice::setSecurityAuth(true, false, true);  // bonding, Just Works, LE Secure Connections
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
#if DEBUG_SERIAL
  NimBLEDevice::setCustomGapHandler(onGap);
#endif

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCb());
  NimBLEService *svc = server->createService(UUID("0000"));
  NimBLECharacteristic *cmd = svc->createCharacteristic(UUID("0001"), NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  chars[CH_REPLY] = svc->createCharacteristic(UUID("0002"), NIMBLE_PROPERTY::NOTIFY);
  chars[CH_STATUS] = svc->createCharacteristic(UUID("0003"), NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ);
  chars[CH_VIDEO] = svc->createCharacteristic(UUID("0004"), NIMBLE_PROPERTY::NOTIFY);
  netChar = svc->createCharacteristic(UUID("0005"), NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE |
                                                        NIMBLE_PROPERTY::READ_ENC | NIMBLE_PROPERTY::WRITE_ENC);
  cmd->setCallbacks(&charCb);
  netChar->setCallbacks(&charCb);
  for (auto *c : chars) c->setCallbacks(&charCb);
  auto *hid = new NimBLEHIDDevice(server);
  hid->setManufacturer("ESP32 Agent");
  hid->setPnp(0x02, 0x303A, 0x4001, 0x0200);
  hid->setHidInfo(0, 0x02);
  hid->setReportMap(mouseMap, sizeof mouseMap);
  mouseReport = hid->getInputReport(1);
  mouseReport->setCallbacks(&charCb);
  keyboardReport = hid->getInputReport(2);
  consumerReport = hid->getInputReport(3);
  keyboardReport->setCallbacks(&charCb);
  consumerReport->setCallbacks(&charCb);
  hid->setBatteryLevel(100);
  server->start();

  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  NimBLEAdvertisementData data, scan;
  data.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  data.setAppearance(HID_MOUSE);
  data.addServiceUUID(NimBLEUUID(uint16_t(0x1812)));
  data.setName(name.c_str());
  scan.addServiceUUID(NimBLEUUID(UUID("0000")));
  adv->setAdvertisementData(data);
  adv->setScanResponseData(scan);
  adv->enableScanResponse(true);
  NimBLEDevice::startAdvertising();
  xTaskCreatePinnedToCore(txTask, "ble_tx", 3072, NULL, 3, NULL, 1);
  ctrlMax = ble_hs_hci_avail_pkts;
  Serial.printf("ble: %s, msys %d x %d (%d free), acl rx %d, controller acl tx %u, mtu %d, coc %d x %d\n",
                NimBLEDevice::getVersion(), os_msys_count(), MYNEWT_VAL(MSYS_1_BLOCK_SIZE), os_msys_num_free(),
                MYNEWT_VAL(BLE_TRANSPORT_ACL_FROM_LL_COUNT), ctrlMax, ble_att_preferred_mtu(),
                MYNEWT_VAL(BLE_L2CAP_COC_MAX_NUM), MYNEWT_VAL(BLE_L2CAP_COC_MPS));
}

bool ble_connected() { return peerCount() > 0; }
bool ble_mouse_connected() { return mousePeer.load() >= 0; }
String ble_mouse_label() {
  int slot = slotOf(mousePeer.load());
  if (slot < 0 || !ble_mouse_connected()) return "NO TARGET";
  char name[25], suffix[6];
  portENTER_CRITICAL(&labelLock);
  strlcpy(name, peerLabels[slot], sizeof name);
  strlcpy(suffix, peerSuffixes[slot], sizeof suffix);
  portEXIT_CRITICAL(&labelLock);
  return String(name[0] ? name : "PHONE") + " / " + suffix;
}
int ble_controller_peers() {
  int count = 0;
  for (int i = 0; i < MAX_PEERS; ++i)
    if (peers[i] >= 0 && subscribed[i][CH_REPLY]) ++count;
  return count;
}
String ble_mouse_status_json() {
  auto *label = cJSON_CreateString(ble_mouse_label().c_str());
  char *encoded = cJSON_PrintUnformatted(label);
  String result = "{\"bonds\":" + String(NimBLEDevice::getNumBonds()) +
    ",\"report_handle\":" + String(mouseReport ? mouseReport->getHandle() : 0) +
    ",\"target\":" + String(encoded ? encoded : "\"\"") +
    ",\"controllers\":" + String(ble_controller_peers()) +
    ",\"peers\":[";
  cJSON_free(encoded); cJSON_Delete(label);
  bool comma = false;
  for (int i = 0; i < MAX_PEERS; ++i) {
    int h = peers[i];
    if (h < 0) continue;
    auto ci = server->getPeerInfoByHandle(h);
    if (comma) result += ',';
    comma = true;
    result += String("{\"encrypted\":") + (ci.isEncrypted() ? "true" : "false") +
      ",\"bonded\":" + (ci.isBonded() ? "true" : "false") +
      ",\"mouse_subscribed\":" + (mouseSubscribed[i] ? "true" : "false") +
      ",\"keyboard_subscribed\":" + (keyboardSubscribed[i] ? "true" : "false") +
      ",\"consumer_subscribed\":" + (consumerSubscribed[i] ? "true" : "false") +
      ",\"interval_us\":" + String(ci.getConnInterval() * 1250) + "}";
  }
  return result + "]}";
}
static bool hidSend(NimBLECharacteristic *characteristic, const uint8_t *report, size_t size) {
  int peer = mousePeer.load();
  int64_t now = esp_timer_get_time();
  // Notifications acknowledge host submission, not phone tap reception. Bound
  // controller backlog to two packets and pace retries outside the BLE task.
  if (peer < 0 || !characteristic || now - lastMouseReportUs < 1000 ||
      os_msys_num_free() < MBUF_RESERVE || ctrlMax - ble_hs_hci_avail_pkts >= 2)
    return false;
  if (!characteristic->notify(report, size, peer)) return false;
  lastMouseReportUs = now;
  return true;
}
bool ble_mouse_send(uint8_t buttons, int8_t dx, int8_t dy, int8_t wheel, int8_t pan) {
  const uint8_t report[] = {buttons, uint8_t(dx), uint8_t(dy), uint8_t(wheel), uint8_t(pan)};
  return hidSend(mouseReport, report, sizeof report);
}
bool ble_keyboard_send(uint8_t modifiers, const uint8_t keys[6]) {
  int slot = slotOf(mousePeer.load());
  if (slot < 0 || !keyboardSubscribed[slot]) return false;
  uint8_t report[8] = {modifiers, 0};
  memcpy(report + 2, keys, 6);
  return hidSend(keyboardReport, report, sizeof report);
}
bool ble_consumer_send(uint16_t usage) {
  int slot = slotOf(mousePeer.load());
  if (slot < 0 || !consumerSubscribed[slot]) return false;
  uint8_t report[] = {uint8_t(usage), uint8_t(usage >> 8)};
  return hidSend(consumerReport, report, sizeof report);
}

bool ble_pop_cmd(String &line, uint32_t wait_ms) {
  char buf[CMD_MAX];
  if (xQueueReceive(cmdQueue, buf, pdMS_TO_TICKS(wait_ms)) != pdTRUE) return false;
  line = buf;
  return true;
}

void ble_reply(const String &line) {
  if (!anySubscribed(CH_REPLY)) return;
  Text t;
  toText(t, line);
  ctrlPending++;
  if (xQueueSend(replyQueue, &t, pdMS_TO_TICKS(200)) != pdTRUE) {  // 8 replies stuck: the link is gone
    ctrlPending--;
    replyDrops++;
  }
}

void ble_status(const String &json) {
  chars[CH_STATUS]->setValue((const uint8_t *)json.c_str(), json.length());  // also served on read
  if (!anySubscribed(CH_STATUS)) return;
  xSemaphoreTake(statusLock, portMAX_DELAY);
  toText(statusText, json);
  if (!statusDirty) ctrlPending++;
  statusDirty = true;
  xSemaphoreGive(statusLock);
}

size_t ble_video_room() { return anySubscribed(CH_VIDEO) ? ble_mtu() - 3 - 3 : 0; }

bool ble_video_send(const uint8_t *p, size_t n) {
  if (!notifyRaw(CH_VIDEO, p, n, VIDEO_TIMEOUT_MS)) {
    drops++;
    return false;
  }
  uint32_t now = millis();
  winBytes += n;
  if (now - winStart >= 1000) {
    kbps = winBytes * 8 / (now - winStart);
    winBytes = 0;
    winStart = now;
  }
  return true;
}

uint32_t ble_kbps() { return millis() - winStart > 2000 ? 0 : kbps; }
uint32_t ble_drops() { return drops; }
uint32_t ble_reply_drops() { return replyDrops; }
int ble_peers() { return peerCount(); }

uint16_t ble_mtu() {  // the smallest peer's, so one notify fits everyone
  uint16_t mtu = 0;
  for (int i = 0; i < MAX_PEERS; i++) {
    int h = peers[i];
    uint16_t m = h >= 0 ? server->getPeerMTU(h) : 0;
    if (m && (!mtu || m < mtu)) mtu = m;
  }
  return mtu ? mtu : 23;
}

uint8_t ble_phy() {
  uint8_t tx = 1, rx = 1;
  int h = peers[0] >= 0 ? peers[0] : peers[1];
  if (h >= 0) ble_gap_read_le_phy(h, &tx, &rx);
  return tx == BLE_GAP_LE_PHY_2M ? 2 : 1;
}

void ble_unpair() {
  for (int i = 0; i < 100 && ctrlPending > 0; i++) vTaskDelay(pdMS_TO_TICKS(10));  // let the `ok` go out
  NimBLEDevice::deleteAllBonds();  // unpairs each bond (also drops it from the controller's resolving list)
  ble_store_clear();               // and any CCCD/peer records left in NVS
  bool any = false;
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] >= 0) { server->disconnect(peers[i]); any = true; }  // onDisconnect restarts advertising
  if (!any) NimBLEDevice::startAdvertising();
}
