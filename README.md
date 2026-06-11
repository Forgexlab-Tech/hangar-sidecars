# hangar-sidecars

Native sidecar binary builds for [Hangar](https://github.com/Forgexlab-Tech/hangar-app).

This repo exists so the expensive **macOS** build jobs run on **public-repo GitHub Actions
(free, unlimited minutes)** instead of consuming the private app repo's paid quota. It contains
**no Hangar application code** — only the generic, reproducible build recipes for the
statically-linked native tools the app ships alongside its binary.

## What it builds

- **`build-ffmpeg.yml`** — a static, **LGPL-only** FFmpeg (no GPL/nonfree components; HW-only
  H.264/HEVC via VideoToolbox / NVENC / QSV / AMF). Manually dispatched (`workflow_dispatch`);
  publishes `ffmpeg-<version>-rN` releases (mac arm64/x64 + Windows x64). License conformance is
  CI-enforced by `scripts/check-ffmpeg-conformance.sh` (license flags, banned/required encoders,
  smoke encodes, system-libs-only link, size guard).

## How it's consumed

`hangar-app/scripts/fetch-native-libs.sh` downloads the published binaries by release tag. The
normative build spec + allowlist live in the app repo
(`docs/specs/ffmpeg-sidecar-build.md`, `docs/PACKAGES.md §4.3`).

## Releasing a new build

```
gh workflow run build-ffmpeg.yml -R Forgexlab-Tech/hangar-sidecars \
  -f ffmpeg_version=7.1.1 -f release_tag=ffmpeg-7.1.1-rN
```
Then bump `FFMPEG_TAG` in the app's `fetch-native-libs.sh` and re-run it.
