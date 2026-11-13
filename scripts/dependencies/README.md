# Maintenance dependency builds

This recipe builds the replacements introduced in maintenance preview 2. It does
not reproduce or establish provenance for the historical Evermeet FFmpeg or
MediaArea Mac binaries. It installs only into the specified work directory.

The published `dependency-sources.tar` contains the FFmpeg/library source archives
and the CLI-only DVRescue source delivery listed in `sources.lock.json`, plus
these build scripts. SHA-256 verification is
mandatory before extraction. FFmpeg 8.0.1, FreeType 2.13.3 and HarfBuzz 10.4.0 are
pinned release archives; x264 is pinned to commit
`b35605ace3ddf7c1a5d67a2eb553f034aef41d55`. DVRescue's official 24.07 all-in-one
archive includes MediaInfoLib 24.06 and ZenLib 0.4.41. FFmpeg and its libraries are unpatched. The included
`dvrescue-disable-capture.patch` guards device-control parser code that otherwise
references unavailable enums when both capture and simulation are disabled,
and makes XML output use its DV-file path without optional capture-only fields.
The simulator translation unit is also excluded when disabled. The binary
identifies itself as `24.07-dvmetadata1`. This project patch is dated November 13, 2026; upstream copyrights are retained.
The upstream all-in-one archive also contains unrelated GUI video fixtures and
precompiled Windows DLLs. `prepare_dvrescue_source.py` reproducibly excludes
`dvrescue/Source/GUI`, `dvrescue/docs` and `MediaInfoLib/Contrib`; all other members,
bytes and metadata are preserved. The lock records both upstream and delivery
hashes. The delivered CLI sources and their original licenses are retained;
no files compiled by this CLI build are excluded. The build script accepts the
verified CLI subset offline, or the verified original publisher archive.

Prerequisites used: Intel macOS, Xcode 15.4 (15F31d), its macOS SDK and Apple
Clang; Python 3.11.8 or newer 3.11 with tarfile extraction filters; existing
MacPorts meson, ninja, pkg-config and nasm. No package manager runs inside the
recipe. No Homebrew tools/libraries are used. Select Xcode for the process only:

```sh
export DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer"
/opt/local/bin/python3.11 scripts/dependencies/build.py ffmpeg \
  --work "$PWD/build-ffmpeg" --archives "$PWD/archives" --jobs 4
/opt/local/bin/python3.11 scripts/dependencies/build.py dvrescue \
  --work "$PWD/build-dvrescue" --archives "$PWD/archives" --jobs 4
```

Use fresh work directories without spaces. Existing archives enable an offline
build; missing archives are fetched from the locked URL and verified. Outputs
are `WORK/prefix/bin/ffmpeg` and `WORK/prefix/bin/dvrescue`. Review and test them
before copying into `Resources/bin`. The script records commands, toolchain,
environment, linked libraries and final hashes in `WORK/build-receipt.json`.
Release receipts are committed under `docs/audit/2026-11-13/dependency-builds/`.

FFmpeg disables dependency autodetection and statically links only x264,
FreeType and HarfBuzz. macOS provides zlib, C/C++ runtime and system frameworks.
GPLv3-or-later is selected; FreeType uses its GPLv2-or-later alternative. The
other native FFmpeg codecs/filters remain available. The app's supported DV,
H.264/AAC, drawtext, yadif, MOV/MP4/MKV/ASS workflows are regression-tested.
Supplier-only optional codecs/filters and arbitrary custom FFmpeg options are
not promised to match the old all-purpose binary.

DVRescue disables DeckLink, Sony9Pin, AVF control, Linux capture and simulator.
The application analyzes existing files; direct DV/Digital8 and HDV capture
remain future goals. No capture SDK is required by this recipe.

`SOURCE_DATE_EPOCH`, deployment target and static-archive timestamps are fixed.
This is a pinned, repeatable build procedure with recorded actual inputs, not a
claim of byte-for-byte reproducibility across SDKs, tool versions or build paths.
Native Apple Silicon builds have not been validated.

The original unmodified UAV/VCR font binaries are pinned separately in
`fonts.lock.json`, matching stable 1.0.6. Their attribution and permission notices
are in `Resources/licenses/NOTICE.txt`; MKV exports attach that notice with the
bundled font bytes. Published preview 2 retains its different OFL font set. Users must
check their own rights when choosing other system/custom fonts for attachment.

After replacing tools, run `zsh Resources/scripts/dev/test_all.zsh`, the native
Release build, the optional real-footage checks and `scripts/verify_release.py`.
Create the accompanying source delivery with:

```sh
/opt/local/bin/python3.11 scripts/dependencies/package_sources.py \
  --archives "$PWD/archives" --output dependency-sources.tar
```

Publish that asset beside the matching application ZIP. Never label it as the
corresponding source for older, differently hashed third-party binaries.
