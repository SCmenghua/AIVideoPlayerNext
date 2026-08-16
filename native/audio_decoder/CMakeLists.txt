cmake_minimum_required(VERSION 3.20)
project(ai_audio_decoder LANGUAGES CXX)

add_library(ai_audio_decoder SHARED src/audio_decoder.cpp)
target_compile_features(ai_audio_decoder PRIVATE cxx_std_17)
target_compile_definitions(ai_audio_decoder PRIVATE AI_AUDIO_DECODER_BUILD)
target_include_directories(ai_audio_decoder PUBLIC include)

if(MSVC)
  target_compile_options(ai_audio_decoder PRIVATE /W4 /WX /EHsc)
  target_link_libraries(ai_audio_decoder PRIVATE mfplat mfreadwrite mfuuid ole32 propsys)
else()
  target_compile_options(ai_audio_decoder PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

add_executable(audio_decode_smoke ../tools/audio_decode_smoke.cpp)
target_compile_features(audio_decode_smoke PRIVATE cxx_std_17)
target_link_libraries(audio_decode_smoke PRIVATE ai_audio_decoder)
target_include_directories(audio_decode_smoke PRIVATE include)

if(MSVC)
  target_compile_options(audio_decode_smoke PRIVATE /W4 /WX /EHsc)
endif()
