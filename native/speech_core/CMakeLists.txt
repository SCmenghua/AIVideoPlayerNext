cmake_minimum_required(VERSION 3.20)
project(speech_core LANGUAGES C CXX)

include(CTest)

option(SPEECH_CORE_WITH_WHISPER "Build the whisper.cpp backend" OFF)
set(WHISPER_CPP_SOURCE_DIR "" CACHE PATH
  "Path to the pinned whisper.cpp source tree")

add_library(speech_core SHARED
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
  add_subdirectory("${WHISPER_CPP_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/whisper.cpp")
  target_compile_definitions(speech_core PRIVATE SPEECH_CORE_WITH_WHISPER)
  target_link_libraries(speech_core PRIVATE whisper)
  target_include_directories(speech_core PRIVATE "${WHISPER_CPP_SOURCE_DIR}/include")
endif()

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

if(BUILD_TESTING)
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

install(TARGETS speech_core speech_regression
  RUNTIME DESTINATION bin
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib
)
install(DIRECTORY include/ DESTINATION include)
