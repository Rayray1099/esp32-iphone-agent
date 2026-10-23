cmake_minimum_required(VERSION 3.16)
set(EXTRA_COMPONENT_DIRS
  "${CMAKE_CURRENT_LIST_DIR}/deps/arduino"
  "${CMAKE_CURRENT_LIST_DIR}/deps/nimble"
  "${CMAKE_CURRENT_LIST_DIR}/deps/lib-builder/components/arduino_tinyusb"
  "${CMAKE_CURRENT_LIST_DIR}/deps/microlink-source/components/microlink"
  "${CMAKE_CURRENT_LIST_DIR}/deps/microlink-source/components/microlink/components/wireguard_lwip")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(s3_clicker VERSION 0.3.1)
idf_component_get_property(arduino_lib arduino COMPONENT_LIB)
target_compile_definitions(${arduino_lib} PUBLIC BOARD_HAS_PSRAM=1 ARDUINO_USB_MODE=0 ARDUINO_USB_CDC_ON_BOOT=1)
idf_build_set_property(LINK_OPTIONS "-Wl,--wrap=tud_hid_report_complete_cb" APPEND)
idf_build_set_property(LINK_OPTIONS "-Wl,--wrap=cJSON_InitHooks" APPEND)
