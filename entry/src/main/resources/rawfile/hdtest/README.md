# 高分辨率压力测试素材（hdtest）

本目录的样本用于回答一个此前**无法回答**的问题：**播放到底流畅不流畅？**

## 为什么需要这批素材

`rawfile/codec/` 里那 12 个格式样本全是 **320x240 以下的极低分辨率小文件**
（最大 156 KB）。它们足以证明「这个格式能不能解」，但**证明不了性能**：

- 分辨率太低 → 软解后要放大到 1084x610 上屏，画面必然发糊，
  糊会被眼睛读成「卡」；
- 码率太低 → 解码器几乎不费力，压不出真实负载。

2026-09-28 真机实测第一次量出真实数字（见下），这批样本就是为它造的。

## 文件清单

| 文件 | 规格 | 用途 |
|---|---|---|
| `HD_720p_h264_aac.mp4` | 1280x720 / 30fps / 4 Mbps / 15s | 系统（硬件）解码基线 |
| `HD_720p_rv20_ac3.rm` | 1280x720 / 25fps / 2 Mbps / 10s | **内置软解的真实负载** |
| `audio_24bit_pcm_s24le.wav` | 48kHz / mono / 5s | 验证新补的 `pcm_s24le` |
| `audio_32bitfloat_pcm_f32le.wav` | 48kHz / mono / 5s | 验证新补的 `pcm_f32le` |

> 另有 4 个更大的样本（1080p H.264、720p VP9、720p WMV2、多音轨 MKV）
> **没有**打进来，目的是控制 HAP 体积。需要时按下文命令生成，
> 放进本目录重新构建即可（`getRawFileList` 会自动发现新文件）。

## 生成命令（可复现）

需要带 `libx264` / `rv20` / `wmv2` 的桌面版 ffmpeg（实测 8.1 即可）。
`mandelbrot` 滤镜细节丰富、帧间变化大，比 `testsrc` 更接近真实视频的码率特征，
用来压解码器更公平。

```bash
# 720p H.264（系统解码基线）
ffmpeg -y -f lavfi -i "mandelbrot=size=1280x720:rate=30" \
       -f lavfi -i "sine=frequency=440:sample_rate=48000" \
       -t 15 -c:v libx264 -preset medium -b:v 4000k -maxrate 4500k -bufsize 8000k \
       -pix_fmt yuv420p -c:a aac -b:a 128k -ac 2 -shortest HD_720p_h264_aac.mp4

# 720p RV20 + AC3（内置软解压力）
ffmpeg -y -f lavfi -i "mandelbrot=size=1280x720:rate=25" \
       -f lavfi -i "sine=frequency=440:sample_rate=44100" \
       -t 10 -c:v rv20 -b:v 2000k -c:a ac3 -b:a 128k -ac 2 -shortest HD_720p_rv20_ac3.rm

# 24bit PCM WAV
ffmpeg -y -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 5 \
       -c:a pcm_s24le audio_24bit_pcm_s24le.wav

# 32bit 浮点 WAV
ffmpeg -y -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 5 \
       -c:a pcm_f32le audio_32bitfloat_pcm_f32le.wav

# ---- 以下 4 个未打包，需要时再生成 ----
ffmpeg -y -f lavfi -i "mandelbrot=size=1920x1080:rate=30" \
       -f lavfi -i "sine=frequency=440:sample_rate=48000" \
       -t 10 -c:v libx264 -preset medium -b:v 8000k -pix_fmt yuv420p \
       -c:a aac -b:a 128k -ac 2 -shortest FHD_1080p_h264_aac.mp4

ffmpeg -y -f lavfi -i "mandelbrot=size=1280x720:rate=25" \
       -f lavfi -i "sine=frequency=440:sample_rate=48000" \
       -t 8 -c:v libvpx-vp9 -b:v 1500k -deadline realtime -cpu-used 8 \
       -c:a libopus -b:a 96k -ac 2 -shortest HD_720p_vp9_opus.webm

ffmpeg -y -f lavfi -i "mandelbrot=size=1280x720:rate=25" \
       -f lavfi -i "sine=frequency=440:sample_rate=44100" \
       -t 12 -c:v wmv2 -b:v 3000k -c:a wmav2 -b:a 128k -ac 2 -shortest HD_720p_wmv2_wmav2.wmv

ffmpeg -y -f lavfi -i "testsrc2=size=640x480:rate=25" \
       -f lavfi -i "sine=frequency=440:sample_rate=48000" \
       -f lavfi -i "sine=frequency=880:sample_rate=48000" \
       -t 8 -map 0:v -map 1:a -map 2:a \
       -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p -c:a aac -b:a 96k \
       -metadata:s:a:0 language=chi -metadata:s:a:0 title="中文" \
       -metadata:s:a:1 language=eng -metadata:s:a:1 title="English" \
       multi_audio_2tracks.mkv
```

## 怎么用

装好应用 → 设置页 → **「拉高清」** → 去「文件搜索」页点「重新扫描」。

## 2026-09-28 真机实测结论（PSN-AL00）

```
720p RV20（内置软解）: perf: 解码均=79344 us  上屏均=3020 us  合计=82364 us
                            → 上限 12 fps（目标 25fps），丢帧 69
720p H.264（系统硬解）: 进度按真实时间推进，15 秒正常播完，流畅
```

**结论：瓶颈 100% 在软件解码本身（rv20 平均 79ms/帧），不在缩放
（3ms）、不在上屏、不在同步逻辑。** 软解路径能做的事有限 ——
RealVideo 这类编码在移动端 CPU 上就是重。
