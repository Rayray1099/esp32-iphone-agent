// Legacy AirPlay event channel: the sender connects to eventPort; commands travel
// back over that socket as bounded RTSP binary plists. Owned by the RTSP task.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lwip/sockets.h"
#include "esp_timer.h"
#include "../bplist/bplist.h"
#include "ap_internal.h"

static int listener = -1, client = -1;
static uint32_t peer_ip;
static bool pending;
static bool connected;
static int64_t last_request;

void ap_events_stop(void) {
  __atomic_store_n(&connected, false, __ATOMIC_RELAXED);
  __atomic_store_n(&pending, false, __ATOMIC_RELAXED);
  if (client >= 0) close(client);
  if (listener >= 0) close(listener);
  client = listener = -1;
}

bool ap_events_setup(uint32_t peer) {
  ap_events_stop();
  peer_ip = peer; last_request = 0;
  listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0) return false;
  int one = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(AP_EVENT_PORT), .sin_addr.s_addr = htonl(INADDR_ANY)};
  if (bind(listener, (struct sockaddr *)&addr, sizeof addr) || listen(listener, 1)) {
    ap_events_stop(); return false;
  }
  return true;
}

bool airplay_request_keyframe(void) {
  if (!__atomic_load_n(&connected, __ATOMIC_RELAXED)) return false;
  __atomic_store_n(&pending, true, __ATOMIC_RELAXED);
  return true;
}

int ap_events_socket(void) { return client >= 0 ? client : listener; }

void ap_events_poll(bool readable) {
  if (readable && client < 0 && listener >= 0) {
    struct sockaddr_in addr; socklen_t size = sizeof addr;
    int fd = accept(listener, (struct sockaddr *)&addr, &size);
    if (fd >= 0 && addr.sin_addr.s_addr != peer_ip) { close(fd); return; }
    if (fd >= 0) {
      client = fd;
      struct timeval timeout = {0, 250000};
      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
      __atomic_store_n(&connected, true, __ATOMIC_RELAXED);
      ap_log("mirror: event channel connected");
    }
  } else if (readable && client >= 0) {
    char reply[1024];
    int n = recv(client, reply, sizeof reply - 1, 0);
    if (n <= 0) { ap_events_stop(); ap_log("mirror: event channel closed"); return; }
    reply[n] = 0;
    // Never log response bodies (or pairing data). Record only the response status.
    if (n >= 12 && (!memcmp(reply, "HTTP/1.1 ", 9) || !memcmp(reply, "RTSP/1.0 ", 9)))
      ap_log("mirror: event response %.3s", reply + 9);
  }
  int64_t now = esp_timer_get_time();
  if (client < 0 || !__atomic_load_n(&pending, __ATOMIC_RELAXED) || now - last_request < 2000000) return;
  __atomic_store_n(&pending, false, __ATOMIC_RELAXED);
  last_request = now;
  bp_writer writer; bp_writer_init(&writer);
  int root = bp_w_dict(&writer);
  bp_w_set(&writer, root, "type", bp_w_string(&writer, "forceKeyFrame"));
  size_t len = 0;
  uint8_t *body = bp_w_finish(&writer, &len);
  bp_writer_free(&writer);
  if (!body) return;
  char request[512];
  int header = snprintf(request, sizeof request, "POST /command RTSP/1.0\r\nCSeq: 1\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: %u\r\n\r\n", (unsigned)len);
  bool ok = header > 0 && (size_t)header + len <= sizeof request;
  if (ok) {
    memcpy(request + header, body, len);
    size_t total = header + len, sent = 0;
    while (sent < total) {
      int n = send(client, request + sent, total - sent, 0);
      if (n <= 0) { ok = false; break; }
      sent += n;
    }
  }
  free(body);
  ap_log("mirror: event keyframe request %s", ok ? "sent" : "failed");
  if (!ok) ap_events_stop();
}
