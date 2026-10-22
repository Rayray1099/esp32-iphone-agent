idf_component_register(SRCS main.cpp ../../hid_bridge/src/qrcode/qrcodegen.c
  INCLUDE_DIRS ../../hid_bridge/src REQUIRES esp_timer esp_driver_gpio)
target_compile_options(${COMPONENT_LIB} PRIVATE -std=gnu++17)
