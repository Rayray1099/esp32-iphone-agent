set(BRIDGE "${CMAKE_CURRENT_LIST_DIR}/../../hid_bridge")
file(GLOB_RECURSE bridge_c "${BRIDGE}/src/*.c" "${BRIDGE}/src/*.cpp")
file(GLOB bridge_cpp "${BRIDGE}/*.cpp")
idf_component_register(SRCS main.cpp ${bridge_c} ${bridge_cpp}
  INCLUDE_DIRS "${BRIDGE}"
  REQUIRES arduino nimble arduino_tinyusb microlink esp_http_server app_update esp_lcd json esp_coex
    espressif__libsodium espressif__mdns joltwallet__littlefs)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-error=overloaded-virtual -include "${BRIDGE}/nimble_cfg.h")
target_compile_definitions(${COMPONENT_LIB} PRIVATE BOARD_HAS_PSRAM=1 ARDUINO_USB_MODE=0 ARDUINO_USB_CDC_ON_BOOT=1)
# Preserve the audited upstream PlayFair expression; newer GCC warns on its spelling.
set_source_files_properties("${BRIDGE}/src/airplay/playfair/hand_garble.c" PROPERTIES COMPILE_OPTIONS "-Wno-error=parentheses")
