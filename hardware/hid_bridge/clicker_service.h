#pragma once
#include "src/clicker/engine.h"
#include "src/clicker/agent_progress.h"
#include <Arduino.h>
void clicker_begin();
String clicker_command(const String &line); // empty means legacy command
String clicker_api(const String &path, const String &method, const String &body,
                   int &code);
clicker::Stats clicker_stats();
bool clicker_busy();
bool clicker_healthy();
double clicker_requested_cps();
String clicker_last_error();
bool clicker_manual_begin();
void clicker_manual_end(bool held);
void clicker_link_lost();
bool clicker_update_begin();
void clicker_update_end();
bool display_healthy();
bool clicker_stop_wait();
String clicker_selected_name();
void clicker_setup();
bool clicker_radios_off();
bool clicker_wifi_off();
bool clicker_bluetooth_output();
const char *clicker_output();
void clicker_poll();
String controller_token();
void controller_begin();
void display_begin();
void display_poll();
bool agent_progress_update(const String &line);
clicker::AgentProgress agent_progress_snapshot();
bool display_bmp(void *req);
void remote_poll();
void remote_stop();
String remote_status();
String remote_configure(const String &json);
String ota_status();
bool ota_upload(void *req);
void diagnostic_event(const char* message);
String diagnostic_json(bool tasks);
