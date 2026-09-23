cmake_minimum_required(VERSION 3.5.0)
project(softplayer)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 目标库名必须是 lib<modname>.so，且 modname 与 napi_module.nm_modname 一致
add_library(softplayer SHARED
    native_init.cpp
    SoftPlayerBinding.cpp
    player/StubEngine.cpp
    player/FfmpegEngine.cpp
    player/FfmpegCodecApi.cpp
    player/AudioOutput.cpp
)

# 头文件搜索路径：cpp/ 与 cpp/player/
target_include_directories(softplayer PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/player
)

# ---------------------------------------------------------------------------
# FFmpeg 软解
#
# 为什么头文件和库都放在【工程内部】而不是引用外部 SDK 目录：
#   FFmpeg 的产物在 C:\ffmpeg-build\，而 SDK 在
#   "F:\devecostudio\DevEco Studio\..."，两者都含空格或跨盘。
#   CMake + Ninja + MSYS 混在一起时，带空格的路径极易被参数分裂
#   （实测 configure 阶段就因此失败过）。所以：
#     entry/libs/arm64-v8a/libav*.so       ← 会被自动打包进 HAP
#     cpp/third_party/ffmpeg/include/      ← 只用于编译期
#   这样 CMake 里全是相对路径，不再依赖任何外部变量。
#
# 重新编译 FFmpeg 后同步产物：
#   Copy-Item C:\ffmpeg-build\out\lib\libav*.so.* → entry\libs\arm64-v8a\（按 SONAME 命名）
#   Copy-Item C:\ffmpeg-build\out\include\*       → cpp\third_party\ffmpeg\include\
# ---------------------------------------------------------------------------
set(FFMPEG_INC "${CMAKE_CURRENT_SOURCE_DIR}/third_party/ffmpeg/include")

if(EXISTS "${FFMPEG_INC}/libavcodec/avcodec.h")
    message(STATUS "启用 FFmpeg 软解（头文件目录存在）")

    target_compile_definitions(softplayer PRIVATE SOFT_PLAYER_WITH_FFMPEG=1)
    target_include_directories(softplayer PRIVATE "${FFMPEG_INC}")

    # 运行时库由 entry/libs/<abi>/ 提供（hvigor 自动打进 HAP 的 libs 目录）。
    # 这里只需要链接期的路径。
    #
    # 为什么不用 ${OHOS_ARCH}：hvigor 的 CMake 工具链里这个变量并不总是定义，
    # 实测取到空值会导致 glob 匹配失败 —— 表现为一堆 undefined symbol（avcodec_open2 等），
    # 看起来像"没链接 FFmpeg"，实际是路径拼接成了 .../libs//libavcodec.so.*。
    # 所以这里直接列出候选 ABI 目录，不依赖任何工具链变量。
    set(FF_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a")

    # 不使用 foreach + 变量插值的 glob：
    # 实测同样的通配在 foreach 里匹配不到、在循环外却正常匹配（原因未查明），
    # 所以这里直接逐条写死。库名固定、数量固定，可读性反而更好。
    file(GLOB FF_AVCODEC    "${FF_LIB_DIR}/libavcodec.so.*")
    file(GLOB FF_AVFORMAT   "${FF_LIB_DIR}/libavformat.so.*")
    file(GLOB FF_AVUTIL     "${FF_LIB_DIR}/libavutil.so.*")
    file(GLOB FF_SWSCALE    "${FF_LIB_DIR}/libswscale.so.*")
    file(GLOB FF_SWRESAMPLE "${FF_LIB_DIR}/libswresample.so.*")

    if(FF_AVCODEC)
        list(GET FF_AVCODEC 0 p)
        add_library(ff_avcodec SHARED IMPORTED)
        set_target_properties(ff_avcodec PROPERTIES IMPORTED_LOCATION "${p}")
        target_link_libraries(softplayer PUBLIC ff_avcodec)
        message(STATUS "  链接 avcodec: ${p}")
    endif()
    if(FF_AVFORMAT)
        list(GET FF_AVFORMAT 0 p)
        add_library(ff_avformat SHARED IMPORTED)
        set_target_properties(ff_avformat PROPERTIES IMPORTED_LOCATION "${p}")
        target_link_libraries(softplayer PUBLIC ff_avformat)
        message(STATUS "  链接 avformat: ${p}")
    endif()
    if(FF_AVUTIL)
        list(GET FF_AVUTIL 0 p)
        add_library(ff_avutil SHARED IMPORTED)
        set_target_properties(ff_avutil PROPERTIES IMPORTED_LOCATION "${p}")
        target_link_libraries(softplayer PUBLIC ff_avutil)
        message(STATUS "  链接 avutil: ${p}")
    endif()
    if(FF_SWSCALE)
        list(GET FF_SWSCALE 0 p)
        add_library(ff_swscale SHARED IMPORTED)
        set_target_properties(ff_swscale PROPERTIES IMPORTED_LOCATION "${p}")
        target_link_libraries(softplayer PUBLIC ff_swscale)
        message(STATUS "  链接 swscale: ${p}")
    endif()
    if(FF_SWRESAMPLE)
        list(GET FF_SWRESAMPLE 0 p)
        add_library(ff_swresample SHARED IMPORTED)
        set_target_properties(ff_swresample PROPERTIES IMPORTED_LOCATION "${p}")
        target_link_libraries(softplayer PUBLIC ff_swresample)
        message(STATUS "  链接 swresample: ${p}")
    endif()

    if(NOT FF_AVCODEC)
        message(WARNING "  未找到 libavcodec.so.*，请在 entry/libs/arm64-v8a/ 部署 FFmpeg 产物")
    endif()
else()
    message(STATUS "未启用 FFmpeg 软解：${FFMPEG_INC}/libavcodec/avcodec.h 不存在")
endif()

# NAPI 与日志库由系统提供；native_window 用于把解码帧送上 XComponent 的 surface；
# ohaudio 用于播放软解出的 PCM
target_link_libraries(softplayer PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_window.so
    libohaudio.so
)

# pthread：解码线程需要
target_link_libraries(softplayer PUBLIC pthread)
