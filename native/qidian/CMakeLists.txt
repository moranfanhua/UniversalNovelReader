cmake_minimum_required(VERSION 3.16)
project(unr_qidian LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(qidian_sources
 protocol/qimei_protocol.cpp protocol/qimei_json.cpp protocol/qimei_response.cpp
 protocol/qimei_provider.cpp protocol/qimei_file_store.cpp protocol/qimei_profile.cpp
 protocol/qimei_register.cpp protocol/qimei_snapshot.cpp
 client/client.cpp client/snapshot_json.cpp headers/app_headers.cpp
 primitives/fock_digest.cpp primitives/default_signature.cpp primitives/registration_signature.cpp
 ibex/ibex_generator.cpp assembly/assembly.cpp assembly/utf8.cpp
 armor/string_armor.cpp hav/hav.cpp scripts/script_crypto.cpp scripts/script_runtime.cpp)
add_subdirectory(scripts)
if(WIN32)
  add_library(unr_qidian SHARED ${qidian_sources}
    protocol/windows_cng.cpp protocol/crypto_cng.cpp headers/crypto_cng.cpp
    ibex/lk_cng.cpp client/windows_context.cpp client/windows_store.cpp
    client/http_windows.cpp client/capi_windows.cpp)
  target_compile_definitions(unr_qidian PRIVATE QIMEI_USE_CNG=1)
  target_link_libraries(unr_qidian PRIVATE bcrypt crypt32 winhttp iphlpapi psapi advapi32 ws2_32 user32)
elseif(ANDROID)
  add_library(qimei_client_android SHARED ${qidian_sources}
    protocol/android/crypto_jce.cpp protocol/android/snapshot_jni.cpp client/android/bridge.cpp
    producer/android_collector.cpp producer/native_probes.cpp assembly/jvm_crypto.cpp
    assembly/portable_lk.cpp assembly/md4.cpp)
  target_link_libraries(qimei_client_android PRIVATE m)
  target_link_options(qimei_client_android PRIVATE -Wl,--exclude-libs,ALL)
else()
  message(FATAL_ERROR "Qidian provider requires Windows or Android")
endif()
if(WIN32)
  set(qidian_target unr_qidian)
else()
  set(qidian_target qimei_client_android)
endif()
target_include_directories(${qidian_target} PRIVATE protocol protocol/android client headers primitives ibex producer assembly lk armor hav)
target_include_directories(${qidian_target} PRIVATE scripts)
target_link_libraries(${qidian_target} PRIVATE qidian_script_engine qidian_script_crypto)
if(MSVC)
  target_compile_options(${qidian_target} PRIVATE /W4 /WX /utf-8 /EHsc)
else()
  target_compile_options(${qidian_target} PRIVATE -Wall -Wextra -Werror)
endif()
