cmake_minimum_required(VERSION 3.25)

project(yapper)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# The iPhone app builds on its own, on a Mac with the Xcode generator: cmake --preset ios-simulator (or ios-device)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    if(NOT CMAKE_HOST_APPLE OR NOT CMAKE_GENERATOR STREQUAL "Xcode")
        message(FATAL_ERROR "The iPhone app builds on a Mac with the Xcode generator. Use: cmake --preset ios-simulator")
    endif()

    enable_language(Swift)
    add_subdirectory(sources/ios)
    return()
endif()

enable_testing()

add_subdirectory(sources/common)
add_subdirectory(sources/server)

# The client and the tests are Windows only. The server also builds on Linux for Docker.
if(WIN32)
    add_subdirectory(third_party/imgui)
    add_subdirectory(sources/client)
    add_subdirectory(tests)
endif()
