#!/usr/bin/env bash
# License + content conformance for the LGPL FFmpeg sidecar
# (spec docs/specs/ffmpeg-sidecar-build.md §5). Run in CI on every built binary
# and locally against a fetched one.
#   Usage: check-ffmpeg-conformance.sh <ffmpeg-binary> [required-hw-encoder ...]
set -euo pipefail

bin="$1"; shift
fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

ver="$("$bin" -version)"
echo "$ver" | head -1

# 1. License flags (spec §5.1)
if ! echo "$ver" | grep -q -- "--disable-gpl"; then fail "configuration lacks --disable-gpl"; fi
if echo "$ver" | grep -q -- "--enable-gpl";      then fail "GPL build detected"; fi
if echo "$ver" | grep -q -- "--enable-nonfree";  then fail "nonfree build detected"; fi
if echo "$ver" | grep -q -- "--enable-version3"; then fail "LGPLv3 flag present — stay LGPL 2.1 (spec §4)"; fi
ok "license flags clean (LGPL 2.1)"

# 2. Encoder content (spec §5.2) — banned, then required (software + platform HW args)
enc="$("$bin" -hide_banner -encoders)"
for banned in libx264 libx265 libopenh264; do
  if echo "$enc" | grep -qw "$banned"; then fail "banned encoder present: $banned"; fi
done
for req in libsvtav1 libvpx-vp9 libmp3lame libopus aac flac alac pcm_s16le prores_ks mjpeg gif rawvideo "$@"; do
  if ! echo "$enc" | grep -qw "$req"; then fail "required encoder missing: $req"; fi
done
ok "encoder set conforms"

# 2b. Filter content — the allowlisted filters the tools depend on (PACKAGES §4.3). Guards against
# allowlist drift: `atempo` (speed) is NOT auto-included, so a dropped --enable-filter would ship a
# speed-less binary silently. (transpose/hflip/vflip ARE auto-included, but asserting them is cheap.)
filt="$("$bin" -hide_banner -filters | awk '{print $2}')"
for req in overlay scale crop drawtext silencedetect transpose hflip vflip atempo afade asetrate loudnorm volume volumedetect palettegen paletteuse; do
  if ! echo "$filt" | grep -qw "$req"; then fail "required filter missing: $req"; fi
done
ok "filter set conforms"

# 2c. Decoder + demuxer content (spec 2026-07-02-av-input-coverage) — guards allowlist drift so a
# classified input can't ship without its decoder. Runtime names differ from configure flags for the
# program-stream demuxer: `--enable-demuxer=mpegps` registers as `mpeg`.
dec="$("$bin" -hide_banner -decoders | awk '{print $2}')"
# Note runtime decoder names vs configure flags: `--enable-decoder=msmpeg4v3` registers as `msmpeg4`.
for req in h264 hevc vp8 vp9 av1 libdav1d prores mpeg2video mpeg4 msmpeg4v2 msmpeg4 alac pcm_u8 pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_f32le pcm_f64le pcm_alaw pcm_mulaw adpcm_ms adpcm_ima_wav mp2 ac3 eac3 wmav2 wmapro wmv1 wmv2 wmv3 vc1 dsd_lsbf dsd_msbf dsd_lsbf_planar dsd_msbf_planar dst rawvideo; do
  if ! echo "$dec" | grep -qw "$req"; then fail "required decoder missing: $req"; fi
done
demux="$("$bin" -hide_banner -demuxers | awk '{print $2}')"
for req in mov matroska mpegts mpeg avi asf aiff wav iff dsf rawvideo; do
  if ! echo "$demux" | grep -qw "$req"; then fail "required demuxer missing: $req"; fi
done
mux="$("$bin" -hide_banner -muxers | awk '{print $2}')"
for req in mp4 matroska webm rawvideo; do
  if ! echo "$mux" | grep -qw "$req"; then fail "required muxer missing: $req"; fi
done
ok "decoder + demuxer + muxer set conforms"

# 2d. macOS hardware decode (r20). `-hwaccel videotoolbox` is accepted even when the per-codec
# hwaccels are missing (it then silently decodes in software), so assert the decoders advertise
# the device. Presence only: CI runners are VMs without a usable media engine.
if [ "$(uname -s)" = Darwin ]; then
  for codec in h264 hevc; do
    "$bin" -hide_banner -h decoder=$codec | grep -q "Supported hardware devices:.*videotoolbox" \
      || fail "$codec decoder lacks the videotoolbox hwaccel"
  done
  for req in scale_vt hwdownload; do
    if ! echo "$filt" | grep -qw "$req"; then fail "required macOS filter missing: $req"; fi
  done
  ok "VideoToolbox decode hwaccels present (h264, hevc) + scale_vt/hwdownload"
fi

# 3. Smoke encodes — software only, runner-safe (spec §5.3)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
run() { "$bin" -hide_banner -loglevel error -y "$@" || fail "smoke encode failed: $*"; }
run -f lavfi -i testsrc=size=320x240:rate=30 -t 1 -c:v libvpx-vp9 "$tmp/v.webm"
run -f lavfi -i testsrc=size=320x240:rate=30 -t 1 -c:v libsvtav1  "$tmp/v.mp4"
# AV1 software decode (libdav1d): force-decode the clip we just encoded, re-encoding one frame to
# mjpeg (an enabled encoder — `-f null` would need the disabled wrapped_avframe encoder). A build with
# only the hwaccel `av1` stub (no libdav1d) fails here on the CI runner (no HW). Proves decode works.
run -c:v libdav1d -i "$tmp/v.mp4" -frames:v 1 -c:v mjpeg -f image2pipe "$tmp/av1frame.jpg"
run -f lavfi -i sine=frequency=440:duration=1 -c:a aac        "$tmp/a.m4a"
run -f lavfi -i sine=frequency=440:duration=1 -c:a libopus    "$tmp/a.webm"
run -f lavfi -i sine=frequency=440:duration=1 -c:a libmp3lame "$tmp/a.mp3"
# audio.convert lossless output (r16): FLAC (raw flac muxer) + ALAC (.m4a via ipod). Native encoders,
# not auto-included — a dropped --enable-encoder would ship a broken lossless mode.
run -f lavfi -i sine=frequency=440:duration=1 -c:a flac -compression_level 8 "$tmp/a.flac"
run -f lavfi -i sine=frequency=440:duration=1 -c:a alac -f ipod "$tmp/a.m4a"
# Minimal mono 24-bit little-endian PCM WAV. Its four samples include both signed extrema; the
# fixture is hand-authored so the test does not depend on the pcm_s24le encoder it is meant to
# qualify as an input decoder. Convert directly to FLAC and retain all 24 bits.
printf '\x52\x49\x46\x46\x30\x00\x00\x00\x57\x41\x56\x45\x66\x6d\x74\x20\x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\xc0\x5d\x00\x00\x03\x00\x18\x00\x64\x61\x74\x61\x0c\x00\x00\x00\x00\x00\x00\xff\xff\x7f\x00\x00\x80\x00\x00\x00' > "$tmp/pcm-s24le.wav"
run -i "$tmp/pcm-s24le.wav" -c:a flac -compression_level 8 "$tmp/pcm-s24le.flac"
wav_probe="$($bin -hide_banner -i "$tmp/pcm-s24le.flac" 2>&1 || true)"
echo "$wav_probe" | grep -q "8000 Hz, mono, s32 (24 bit)" || fail "24-bit WAV→FLAC output shape is wrong"
ok "24-bit PCM WAV input retains its precision in FLAC"
# Minimal, synthetic DSD64/DSF silence: fixed 92-byte header followed by one 4096-byte block per
# stereo channel. This stays redistributable and proves demux + DSD decode + 88.2 kHz/24-bit FLAC
# conversion without downloading a media fixture during conformance.
printf '\x44\x53\x44\x20\x1c\x00\x00\x00\x00\x00\x00\x00\x5c\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x66\x6d\x74\x20\x34\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x00\x11\x2b\x00\x01\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x64\x61\x74\x61\x0c\x20\x00\x00\x00\x00\x00\x00' > "$tmp/silence.dsf"
dd if=/dev/zero bs=8192 count=1 2>/dev/null | tr '\000' '\151' >> "$tmp/silence.dsf"
run -i "$tmp/silence.dsf" -ar 88200 -sample_fmt s32 -c:a flac "$tmp/dsd.flac"
dsd_probe="$($bin -hide_banner -i "$tmp/dsd.flac" 2>&1 || true)"
echo "$dsd_probe" | grep -q "88200 Hz, stereo, s32 (24 bit)" || fail "DSD→FLAC output shape is wrong"
# video.convert ProRes output (r17): prores_ks into MOV at 10-bit 4:2:2. Software encoder, not
# auto-included — a dropped --enable-encoder would ship a broken ProRes mode.
run -f lavfi -i testsrc=size=320x240:rate=30 -t 1 -c:v prores_ks -profile:v 2 -vendor apl0 -pix_fmt yuv422p10le -f mov "$tmp/v.mov"
run -f lavfi -i testsrc=size=320x240:rate=30 -frames:v 1 -vf scale=320:-2 -c:v mjpeg -f image2pipe "$tmp/p.jpg"
ok "smoke encodes (VP9, AV1, AAC, Opus, MP3, FLAC, ALAC, DSD→FLAC, ProRes, poster JPEG)"

# Raw frame pipes (r20, Device Mockup video engine): decode to exact rgba frames, then encode raw
# yuv420p back into a file. Byte counts are exact, so a missing rawvideo component or a wrong
# frame size fails here, not in the app.
run -f lavfi -i testsrc=size=64x48:rate=5 -t 1 -f rawvideo -pix_fmt rgba "$tmp/frames.rgba"
[ "$(wc -c < "$tmp/frames.rgba" | tr -d ' ')" = "61440" ] || fail "rawvideo rgba output has the wrong size"
run -f rawvideo -pix_fmt rgba -s 64x48 -r 5 -i "$tmp/frames.rgba" -f rawvideo -pix_fmt yuv420p "$tmp/frames.yuv"
[ "$(wc -c < "$tmp/frames.yuv" | tr -d ' ')" = "23040" ] || fail "rawvideo yuv420p output has the wrong size"
run -f rawvideo -pix_fmt yuv420p -s 64x48 -r 5 -i "$tmp/frames.yuv" -c:v libvpx-vp9 "$tmp/raw.webm"
ok "rawvideo round trip (rgba out, yuv420p in → VP9)"

# VP8 WebM input (r21). A 540-byte, two-frame 32x32 VP8 WebM made by an external libvpx, because
# this build has no VP8 encoder. Without the vp8 decoder FFmpeg reports `vp8, none` and every video
# tool refuses the file, so assert the probed pixel format and an exact decoded frame size.
printf '%b' '\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01\x42\xf7\x81\x01\x42\xf2\x81\x04\x42\xf3\x81\x08\x42\x82\x84\x77\x65\x62\x6d\x42\x87\x81\x02\x42\x85\x81\x02\x18\x53\x80\x67\x01\x00\x00\x00\x00\x00\x01\xec\x11\x4d\x9b\x74\xba\x4d\xbb\x8b\x53\xab\x84\x15\x49\xa9\x66\x53\xac\x81\xa1\x4d\xbb\x8b\x53\xab\x84\x16\x54\xae\x6b\x53\xac\x81\xc6\x4d\xbb\x8c\x53\xab\x84\x12\x54\xc3\x67\x53\xac\x82\x01\x22\x4d\xbb\x8c\x53\xab\x84\x1c\x53\xbb\x6b\x53\xac\x82\x01\xd6\xec\x01\x00\x00\x00\x00\x00\x00\x59\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x15\x49\xa9\x66\xa0\x2a\xd7\xb1\x83\x0f\x42\x40\x4d\x80\x84\x4c\x61\x76\x66\x57\x41\x84\x4c\x61\x76\x66\x44\x89\x88\x40\x69\x00\x00\x00\x00\x00\x00\x16\x54\xae\x6b\xd7\xae\x01\x00\x00\x00\x00\x00\x00\x4e\xd7\x81\x01\x73\xc5\x88\x00\x00\x00\x00\x00\x00\x00\x01\x9c\x81\x00\x22\xb5\x9c\x83\x75\x6e\x64\x88\x81\x00\x86\x85\x56\x5f\x56\x50\x38\x83\x81\x01\x23\xe3\x83\x84\x05\xf5\xe1\x00\xe0\x90\xb0\x81\x20\xba\x81\x20\x9a\x81\x02\x55\xb0\x84\x55\xb9\x81\x01\x55\xee\x81\x00\xec\x01\x00\x00\x00\x00\x00\x00\x02\x00\x00\x12\x54\xc3\x67\xd0\x73\x73\xcd\x63\xc0\x8b\x63\xc5\x88\x00\x00\x00\x00\x00\x00\x00\x01\x67\xc8\x98\x45\xa3\x87\x45\x4e\x43\x4f\x44\x45\x52\x44\x87\x8b\x4c\x61\x76\x63\x20\x6c\x69\x62\x76\x70\x78\x67\xc8\xa1\x45\xa3\x88\x44\x55\x52\x41\x54\x49\x4f\x4e\x44\x87\x93\x30\x30\x3a\x30\x30\x3a\x30\x30\x2e\x32\x30\x30\x30\x30\x30\x30\x30\x30\x00\x1f\x43\xb6\x75\xda\xe7\x81\x00\xa3\xbe\x81\x00\x00\x80\x10\x03\x00\x9d\x01\x2a\x20\x00\x20\x00\x00\x47\x08\x85\x85\x88\x85\x84\x88\x02\x02\x02\x75\xaa\x03\xf8\x03\xfa\x02\x08\x59\x0c\xbd\x00\xfe\xfd\x6e\xf3\xff\xe3\x99\x37\x30\xc4\xff\x8e\x6d\xff\xf1\x61\x3c\x0e\x28\xc8\xff\xf1\x51\x00\xa3\x95\x81\x00\x64\x00\xb1\x01\x00\x01\x10\x10\x00\x18\x00\x18\x58\x2f\xf4\x00\x08\x70\x00\x1c\x53\xbb\x6b\x91\xbb\x8f\xb3\x81\x00\xb7\x8a\xf7\x81\x01\xf1\x82\x01\x77\xf0\x81\x03' > "$tmp/vp8.webm"
vp8_probe="$($bin -hide_banner -i "$tmp/vp8.webm" 2>&1 || true)"
echo "$vp8_probe" | grep -q "Video: vp8, yuv420p" || fail "VP8 WebM pixel format is unreadable"
run -i "$tmp/vp8.webm" -frames:v 1 -f rawvideo -pix_fmt yuv420p "$tmp/vp8.yuv"
[ "$(wc -c < "$tmp/vp8.yuv" | tr -d ' ')" = "1536" ] || fail "VP8 decode produced the wrong frame size"
ok "VP8 WebM input decodes"

# video.join transition path (spec video-join): exercises xfade + acrossfade + gblur + pad +
# anullsrc + setsar in one graph, so a build that drops any of them fails here instead of at
# runtime. gblur is the LGPL blur (boxblur is GPL-only — dropped under --disable-gpl).
run -f lavfi -i testsrc=size=320x240:rate=30 -f lavfi -i testsrc=size=240x320:rate=30 \
  -filter_complex "[0:v]scale=320:240,gblur=sigma=2,setsar=1[jv0];[1:v]scale=320:240:force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:(oh-ih)/2,setsar=1[jv1];[jv0][jv1]xfade=transition=fade:duration=0.4:offset=0.6[jvv];sine=frequency=440:sample_rate=48000,atrim=0:1[ja0];anullsrc=channel_layout=stereo:sample_rate=48000,atrim=0:1[ja1];[ja0][ja1]acrossfade=d=0.4[jaa]" \
  -map "[jvv]" -map "[jaa]" -t 1 -c:v libvpx-vp9 -c:a libopus "$tmp/join.webm"
ok "smoke encode (xfade + acrossfade + gblur + pad + anullsrc + setsar — video.join)"

# video.to_gif path (spec tool-catalog video.to_gif): single-graph two-pass palettegen → paletteuse
# into the gif encoder/muxer. A build that drops any of gif/palettegen/paletteuse fails here, not at
# runtime. `split` feeds both the palette generator and the frames it colours. The source MUST be
# finite (`duration=1`, not `-t 1` on the output): palettegen only emits its palette at input EOF, so
# an infinite source buffers every frame forever → OOM. Real inputs are files, so they end naturally.
run -f lavfi -i "testsrc=size=320x240:rate=30:duration=1" \
  -vf "fps=12,scale=160:-1:flags=lanczos,split[g0][g1];[g0]palettegen[p];[g1][p]paletteuse" \
  -loop 0 "$tmp/out.gif"
ok "smoke encode (palettegen + paletteuse → gif — video.to_gif)"

# audio.volume path (spec audio-volume): volume (Gain), loudnorm (Normalize EBU R128), volumedetect
# (Peak measurement). None auto-included — a dropped --enable-filter would ship a broken mode.
run -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
  -af "volume=-3dB,loudnorm=I=-14:TP=-1.5:LRA=11,volumedetect" -c:a pcm_s16le "$tmp/vol.wav"
ok "smoke encode (volume + loudnorm + volumedetect — audio.volume)"

# audio.merge Mix path (spec audio-merge): overlay two tones, one with a start offset (adelay) +
# gain (volume), summed without auto-attenuation (amix=normalize=0) and brick-wall limited
# (alimiter). Exactly the graph `audio_merge::build_mix` emits. amix/adelay/alimiter were added
# (r14) — none auto-included, so a dropped --enable-filter would ship a broken Mix mode.
run -f lavfi -i "sine=frequency=440:duration=2" -f lavfi -i "sine=frequency=660:duration=2" \
  -filter_complex "[0:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a0];[1:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,adelay=delays=500:all=1,volume=-6dB[a1];[a0][a1]amix=inputs=2:duration=longest:normalize=0[mx];[mx]alimiter=limit=0.95[aout]" \
  -map "[aout]" -c:a pcm_s16le "$tmp/merge.wav"
ok "smoke encode (amix + adelay + alimiter + aformat — audio.merge Mix)"

# 4. Static-link check, macOS (spec §5.4) — system libs/frameworks only
if [ "$(uname)" = Darwin ]; then
  if otool -L "$bin" | tail -n +2 | grep -vE '/usr/lib/|/System/'; then
    fail "non-system dylib dependency found"
  fi
  ok "links only system libraries"
fi

# 5. Size guard (spec §5.5)
mb=$(( $(wc -c < "$bin") / 1024 / 1024 ))
echo "binary size: ${mb}MB"
if [ "$mb" -gt 60 ]; then fail "binary ${mb}MB exceeds 60MB hard cap"; fi
if [ "$mb" -gt 35 ]; then echo "::warning::ffmpeg binary ${mb}MB exceeds expected ~30MB"; fi

echo "✓ all conformance checks passed"
