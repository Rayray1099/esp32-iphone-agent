#include "clicker_service.h"
#include "ota_public_key.h"
#include <atomic>
#include <esp_http_server.h>
#include <esp_ota_ops.h>
#include <mbedtls/sha256.h>
#include <sodium.h>
static std::atomic<const char *> state{"idle"};
static std::atomic<size_t> written{0}, total{0};
static std::atomic<bool> updating{false};
String ota_status() {
  return String("{\"state\":\"") + state.load() +
         "\",\"written\":" + String(written.load()) +
         ",\"total\":" + String(total.load()) + "}";
}
static bool readExact(httpd_req_t *r, uint8_t *p, size_t n) {
  int timeouts = 0;
  while (n) {
    int got = httpd_req_recv(r, (char *)p, n);
    if (got == HTTPD_SOCK_ERR_TIMEOUT && ++timeouts < 4)
      continue;
    if (got <= 0)
      return false;
    p += got;
    n -= got;
  }
  return true;
}
bool ota_upload(void *request) {
  auto *r = (httpd_req_t *)request;
  if (updating.exchange(true)) {
    httpd_resp_set_status(r, "409 Conflict");
    httpd_resp_sendstr(r, "Update already in progress");
    return false;
  }
  state = "checking";
  written = 0;
  uint8_t header[172];
  esp_ota_handle_t handle = 0;
  bool begun = false;
  bool ownsInput = false;
  auto fail = [&](const char *reason) {
    if (begun)
      esp_ota_abort(handle);
    state = reason;
    diagnostic_event(reason);
    updating = false;
    if (ownsInput)
      clicker_update_end();
    httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, reason);
    return false;
  };
  if (r->content_len < int(sizeof header) ||
      !readExact(r, header, sizeof header))
    return fail("truncated-header");
  uint32_t size;
  memcpy(&size, header + 72, 4);
  total = size;
  const auto *target = esp_ota_get_next_update_partition(nullptr);
  if (memcmp(header, "S3OTA1\0\0", 8) ||
      strncmp((char *)header + 8, "s3-n8r8-st7789", 32))
    return fail("wrong-board");
  if (!target || size < 256 || size > target->size ||
      r->content_len != int(sizeof header + size))
    return fail("invalid-size");
  if (sodium_init() < 0 ||
      crypto_sign_verify_detached(header + 108, header, 108, OTA_PUBLIC_KEY))
    return fail("invalid-signature");
  if (!clicker_update_begin())
    return fail("input-release-pending");
  ownsInput = true;
  if (esp_ota_begin(target, size, &handle) != ESP_OK)
    return fail("flash-begin-failed");
  begun = true;
  diagnostic_event(
      "Signed OTA accepted; input released; writing inactive slot");
  state = "writing";
  mbedtls_sha256_context hash;
  mbedtls_sha256_init(&hash);
  mbedtls_sha256_starts(&hash, 0);
  uint8_t data[2048];
  bool ok = true;
  while (written < size) {
    size_t n = std::min<size_t>(sizeof data, size - written.load());
    if (!readExact(r, data, n) || esp_ota_write(handle, data, n) != ESP_OK) {
      ok = false;
      break;
    }
    mbedtls_sha256_update(&hash, data, n);
    written += n;
  }
  uint8_t digest[32];
  mbedtls_sha256_finish(&hash, digest);
  mbedtls_sha256_free(&hash);
  if (!ok)
    return fail("interrupted-write");
  if (sodium_memcmp(digest, header + 76, 32))
    return fail("hash-mismatch");
  state = "verifying";
  esp_err_t err = esp_ota_end(handle);
  begun = false;
  if (err != ESP_OK)
    return fail("invalid-esp-image");
  esp_app_desc_t description{};
  if (esp_ota_get_partition_description(target, &description) != ESP_OK ||
      strcmp(description.project_name, "s3_clicker"))
    return fail("wrong-project");
  if (esp_ota_set_boot_partition(target) != ESP_OK)
    return fail("boot-slot-failed");
  state = "restart-pending";
  diagnostic_event("OTA image verified; restart pending");
  httpd_resp_set_type(r, "application/json");
  httpd_resp_sendstr(r, "{\"ok\":true,\"restart\":true}");
  xTaskCreate(
      [](void *) {
        vTaskDelay(pdMS_TO_TICKS(1200));
        esp_restart();
      },
      "ota-reboot", 2048, nullptr, 1, nullptr);
  return true;
}
