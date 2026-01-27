idf_component_register(
    SRCS "ports/sample_app_port.c"
    INCLUDE_DIRS "ports/include"
    PRIV_REQUIRES "libatomvm" "avm_sys"
)

# Ensure the driver registration object is not discarded by the linker.
# Without whole-archive, the REGISTER_PORT_DRIVER(...) symbol can be GC'd if
# nothing in the app directly references it.
idf_build_set_property(
    LINK_OPTIONS
        "-Wl,--whole-archive;${CMAKE_CURRENT_BINARY_DIR}/lib${COMPONENT_NAME}.a;-Wl,--no-whole-archive"
    APPEND
)

