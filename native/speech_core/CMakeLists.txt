cmake_minimum_required(VERSION 3.20)
project(speech_core LANGUAGES C CXX)

include(CTest)

option(SPEECH_CORE_WITH_WHISPER "Build the whisper.cpp backend" OFF)
option(GGML_VULKAN "Build whisper.cpp with the Vulkan backend" OFF)
option(GGML_METAL "Build whisper.cpp with the Metal backend" OFF)
option(SPEECH_CORE_BUILD_SHARED "Build speech_core as a shared library" ON)
option(SPEECH_CORE_BUILD_TOOLS "Build the regression CLI and CTest targets" ON)
set(WHISPER_CPP_SOURCE_DIR "" CACHE PATH
  "Path to the pinned whisper.cpp source tree")

if(SPEECH_CORE_BUILD_SHARED)
  set(SPEECH_CORE_LIBRARY_TYPE SHARED)
else()
  set(SPEECH_CORE_LIBRARY_TYPE STATIC)
endif()

add_library(speech_core ${SPEECH_CORE_LIBRARY_TYPE}
  src/pcm.cpp
  src/speech_core.cpp
)

target_compile_features(speech_core PRIVATE cxx_std_17)
target_compile_definitions(speech_core PRIVATE SPEECH_CORE_BUILD)
target_include_directories(speech_core
  PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

if(MSVC)
  target_compile_options(speech_core PRIVATE /W4 /WX)
else()
  target_compile_options(speech_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

if(SPEECH_CORE_WITH_WHISPER)
  if(NOT IS_DIRECTORY "${WHISPER_CPP_SOURCE_DIR}")
    message(FATAL_ERROR
      "SPEECH_CORE_WITH_WHISPER requires WHISPER_CPP_SOURCE_DIR")
  endif()
  if(NOT EXISTS "${WHISPER_CPP_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "WHISPER_CPP_SOURCE_DIR is not a whisper.cpp source tree")
  endif()

  set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
  set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
  # Windows Phase 6.5 deliberately ships Vulkan/CPU only. Keep CUDA out of
  # this target even if a parent build or developer environment enables it.
  set(GGML_CUDA OFF CACHE BOOL "" FORCE)
  set(GGML_VULKAN ${GGML_VULKAN} CACHE BOOL "" FORCE)
  set(GGML_METAL ${GGML_METAL} CACHE BOOL "" FORCE)
  if(GGML_METAL)
    target_compile_definitions(speech_core PRIVATE SPEECH_CORE_GGML_METAL)
  endif()
  if(APPLE AND NOT IOS)
    # Desktop Apple builds are useful for local smoke tests, but the product
    # Metal target is the iOS build below.
    set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
  elseif(IOS)
    set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
  endif()
  add_subdirectory("${WHISPER_CPP_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/whisper.cpp")
  target_compile_definitions(speech_core PRIVATE SPEECH_CORE_WITH_WHISPER)
  target_link_libraries(speech_core PRIVATE whisper)
  target_include_directories(speech_core PRIVATE "${WHISPER_CPP_SOURCE_DIR}/include")
endif()

if(APPLE AND GGML_METAL)
  target_link_libraries(speech_core PUBLIC
    "-framework Foundation"
    "-framework Metal"
    "-framework Accelerate"
  )
endif()

if(SPEECH_CORE_BUILD_TOOLS)
  add_executable(speech_regression
    ../tools/speech_regression.cpp
  )
  target_compile_features(speech_regression PRIVATE cxx_std_17)
  target_link_libraries(speech_regression PRIVATE speech_core)
  target_include_directories(speech_regression PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  )

  if(MSVC)
    target_compile_options(speech_regression PRIVATE /W4 /WX)
  else()
    target_compile_options(speech_regression PRIVATE -Wall -Wextra -Wpedantic -Werror)
  endif()
endif()

if(SPEECH_CORE_BUILD_TOOLS AND BUILD_TESTING)
  add_executable(speech_core_tests
    tests/speech_core_tests.cpp
  )
  target_compile_features(speech_core_tests PRIVATE cxx_std_17)
  target_link_libraries(speech_core_tests PRIVATE speech_core)
  target_include_directories(speech_core_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  )
  if(MSVC)
    target_compile_options(speech_core_tests PRIVATE /W4 /WX)
  else()
    target_compile_options(speech_core_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
  endif()
  add_test(NAME speech_core_tests COMMAND speech_core_tests)
endif()

install(TARGETS speech_core
  RUNTIME DESTINATION bin
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib
)
if(SPEECH_CORE_BUILD_TOOLS)
  install(TARGETS speech_regression RUNTIME DESTINATION bin)
endif()
install(DIRECTORY include/ DESTINATION include)
