#pragma once
#include "src/clicker/engine.h"
#include <Arduino.h>
void clicker_begin();
String clicker_command(const String &line); // empty means legacy command
String clicker_api(const String &path, const String &method, const String &body,
                   int &code);
clicker::Stats clicker_stats();
bool clicker_busy();
bool clicker_healthy();
bool clicker_manual_begin();
void clicker_manual_end(bool held);
bool clicker_update_begin();
void clicker_update_end();
bool display_healthy();
bool clicker_stop_wait();
String clicker_selected_name();
void clicker_setup();
bool clicker_radios_off();
void clicker_poll();
String controller_token();
void controller_begin();
void display_begin();
void display_poll();
bool display_bmp(void *req);
void remote_poll();
void remote_stop();
String remote_status();
String remote_configure(const String &json);
String ota_status();
bool ota_upload(void *req);
