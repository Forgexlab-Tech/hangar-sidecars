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
for req in libsvtav1 libvpx-vp9 libmp3lame libopus aac flac alac pcm_s16le mjpeg gif "$@"; do
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
for req in h264 hevc av1 libdav1d prores mpeg2video mpeg4 msmpeg4v2 msmpeg4 alac pcm_s16be pcm_s24be mp2 ac3 eac3 wmav2 wmapro wmv1 wmv2 wmv3 vc1; do
  if ! echo "$dec" | grep -qw "$req"; then fail "required decoder missing: $req"; fi
done
demux="$("$bin" -hide_banner -demuxers | awk '{print $2}')"
for req in mov matroska mpegts mpeg avi asf aiff wav; do
  if ! echo "$demux" | grep -qw "$req"; then fail "required demuxer missing: $req"; fi
done
ok "decoder + demuxer set conforms"

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
run -f lavfi -i testsrc=size=320x240:rate=30 -frames:v 1 -vf scale=320:-2 -c:v mjpeg -f image2pipe "$tmp/p.jpg"
ok "smoke encodes (VP9, AV1, AAC, Opus, MP3, FLAC, ALAC, poster JPEG)"

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
