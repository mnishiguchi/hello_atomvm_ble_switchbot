cmake_minimum_required(VERSION 3.16)

idf_component_register(
  SRCS
    "ports/sample_app_port.c"
  INCLUDE_DIRS
    "ports/include"
  PRIV_INCLUDE_DIRS
    ${NIMBLE_PRIV_INCLUDES}
  PRIV_REQUIRES
    libatomvm
    avm_sys
    bt
    nvs_flash
  WHOLE_ARCHIVE
)
