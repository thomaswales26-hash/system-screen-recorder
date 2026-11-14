cmake_minimum_required(VERSION 3.20)
project(SystemScreenRecorder NONE)

find_program(SWIFT_EXECUTABLE swift REQUIRED)

add_custom_target(system-screen-recorder
    COMMAND "${SWIFT_EXECUTABLE}" build --package-path "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Building the macOS screen recorder"
    VERBATIM
)
