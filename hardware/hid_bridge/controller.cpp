#include "clicker_service.h"
#include "web_assets.h"
#include "video_link.h"
#include <esp_http_server.h>
#include <sodium.h>
static httpd_handle_t http = nullptr;
static bool authorized(httpd_req_t *r) {
  char auth[80];
  size_t len = httpd_req_get_hdr_value_len(r, "Authorization");
  if (len >= sizeof auth ||
      httpd_req_get_hdr_value_str(r, "Authorization", auth, sizeof auth) !=
          ESP_OK)
    return false;
  String expected = "Bearer " + controller_token();
  return len == expected.length() &&
         !sodium_memcmp(auth, expected.c_str(), len);
}
static esp_err_t route(httpd_req_t *r) {
  httpd_resp_set_hdr(r, "Cache-Control", "no-store");
  httpd_resp_set_hdr(r, "X-Content-Type-Options", "nosniff");
  String path = r->uri;
  int q = path.indexOf('?');
  if (q >= 0)
    path = path.substring(0, q);
  if (path == "/") {
    httpd_resp_set_type(r, "text/html");
    return httpd_resp_send(r, WEB_INDEX, sizeof WEB_INDEX - 1);
  }
  if (path == "/app.js") {
    httpd_resp_set_type(r, "text/javascript");
    return httpd_resp_send(r, WEB_APP, sizeof WEB_APP - 1);
  }
  if (path == "/style.css") {
    httpd_resp_set_type(r, "text/css");
    return httpd_resp_send(r, WEB_STYLE, sizeof WEB_STYLE - 1);
  }
  if (!authorized(r)) {
    httpd_resp_set_status(r, "401 Unauthorized");
    return httpd_resp_sendstr(r, "Authentication required. Use the controller "
                                 "token shown on the board.");
  }
  if (path == "/api/v1/screen")
    return display_bmp(r) ? ESP_OK : ESP_FAIL;
  if (path == "/api/v1/video/gop" && r->method == HTTP_GET)
    return video_http_gop(r);
  if (path == "/api/v1/video/frames" && r->method == HTTP_GET)
    return video_http_frames(r);
  if (path == "/api/v1/ota" && r->method == HTTP_POST)
    return ota_upload(r) ? ESP_OK : ESP_FAIL;
  if (!path.startsWith("/api/v1/"))
    return httpd_resp_send_err(r, HTTPD_404_NOT_FOUND, "Unknown route");
  if (r->content_len > 196608)
    return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "Body too large");
  String body;
  body.reserve(r->content_len + 1);
  char chunk[1025];
  int left = r->content_len;
  int timeouts = 0;
  while (left > 0) {
    int n = httpd_req_recv(r, chunk, std::min<int>(sizeof(chunk) - 1, left));
    if (n == HTTPD_SOCK_ERR_TIMEOUT && ++timeouts < 4)
      continue;
    if (n <= 0)
      return ESP_FAIL;
    body.concat(chunk, n);
    left -= n;
  }
  const char *method = r->method == HTTP_POST     ? "POST"
                       : r->method == HTTP_PUT    ? "PUT"
                       : r->method == HTTP_DELETE ? "DELETE"
                                                  : "GET";
  int code;
  String result = clicker_api(path.substring(8), method, body, code);
  httpd_resp_set_type(r, "application/json");
  if (code == 400)
    httpd_resp_set_status(r, "400 Bad Request");
  else if (code == 409)
    httpd_resp_set_status(r, "409 Conflict");
  else if (code == 404)
    httpd_resp_set_status(r, "404 Not Found");
  else if (code >= 500)
    httpd_resp_set_status(r, "503 Service Unavailable");
  return httpd_resp_send(r, result.c_str(), result.length());
}
void controller_begin() {
  httpd_config_t c = HTTPD_DEFAULT_CONFIG();
  c.stack_size = 8192;
  c.max_uri_handlers = 8;
  c.uri_match_fn = httpd_uri_match_wildcard;
  c.lru_purge_enable = true;
  if (httpd_start(&http, &c) != ESP_OK)
    return;
  for (auto method : {HTTP_GET, HTTP_POST, HTTP_PUT, HTTP_DELETE}) {
    httpd_uri_t u{};
    u.uri = "/*";
    u.method = method;
    u.handler = route;
    httpd_register_uri_handler(http, &u);
  }
}
