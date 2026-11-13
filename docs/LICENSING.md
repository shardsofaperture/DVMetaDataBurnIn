# Application, component, and sample rights

The root [LICENSE](../LICENSE) retains the application's original MIT license,
**Copyright (c) 2025 Zach Zarzycki**, byte-for-byte identical to
[APP_LICENSE.txt](../Resources/licenses/APP_LICENSE.txt). Component licenses do
not change that authorship or license.

## Maintenance preview 2 replacements

These statements apply to `maintenance/1.0.7` and
[preview 2](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.2),
not stable 1.0.6 or preview 1. Stable source remains on
[main](https://github.com/shardsofaperture/DVMetaDataBurnIn/tree/main).

| Bundled component | Terms and source relationship |
| --- | --- |
| FFmpeg 8.0.1-dvmetadata1 | GPL-3.0-or-later; built from the pinned official FFmpeg release with static x264, FreeType and HarfBuzz. Autodetection of other third-party libraries is disabled. Full corresponding sources and the controlling build script are delivered in `dependency-sources.tar` beside the app ZIP. |
| x264 | GPL-2.0-or-later, pinned VideoLAN commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`. |
| FreeType 2.13.3 | GPL-2.0-or-later alternative selected; included BDF/PCF and HarfBuzz notices retained. |
| HarfBuzz 10.4.0 | Permissive licenses reproduced from upstream COPYING. |
| DVRescue 24.07-dvmetadata1 | BSD-3-Clause; built from MediaArea's official all-in-one source with MediaInfoLib 24.06 (BSD-2-Clause) and ZenLib 0.4.41 (zlib). DeckLink and other capture/control integrations are disabled; no SDK is used. |
| VT323, Share Tech Mono, IBM Plex Mono | Unmodified font bytes from a pinned Google Fonts revision. Full author/copyright/reserved-name terms and SIL OFL 1.1 texts accompany the app. MKV attachments include the corresponding OFL text. |

[Build recipe and locks](../scripts/dependencies/README.md),
[actual build receipts](audit/2026-11-13/dependency-builds/) and
[complete bundled notices](../Resources/licenses/NOTICE.txt) identify the actual
inputs and configuration. The source asset includes the FFmpeg/library archives, the byte-preserving
DVRescue CLI source subset and its documented capture-disable patch. The
selection script omits unrelated GUI media and precompiled Windows DLLs; its
upstream/delivery hashes and exact exclusions are published. The native
macOS runtime, zlib and system frameworks are supplied by the operating system;
no MacPorts libraries are dynamically required by the distributed tools.

The replacement is a pinned source build with recorded commands and hashes.
Bit-for-bit reproducibility across build paths/toolchain versions is not claimed.
The application invokes the executables as separate tools. Optional supplier
codecs/filters outside the documented application pipeline may differ.

## Historical distributions

The [dated distribution audit](THIRD_PARTY_DISTRIBUTION_AUDIT.md) remains the
record for the eight original application ZIPs, including stable 1.0.6 and
preview 1. Their assets and tags have not been silently overwritten. The old
[bundled notice](audit/2026-11-13/HISTORICAL-BUNDLED-NOTICE.txt) preserves authorship
and the earlier attribution work, including Nicholas Kruse's UAV OSD fonts and
Riciery Leal's VCR OSD Mono.

The verified DVRescue notice supplement remains available beside historical
releases. Historical distribution findings remain distinct from the new build:

- **#194:** exact corresponding sources/build materials for the old Evermeet
  executable `430d60f…` have not been obtained. These new sources cannot be
  substituted for them.
- **#195 resolved:** official binary identity and supplemental notice delivery
  are verified. DeckLink Include-file permissions exempt machine-generated
  object code from notice reproduction. Exact historical SDK/build mapping
  remains optional provenance, not a redistribution blocker. See the
  [non-font review](THIRD_PARTY_DISTRIBUTION_AUDIT.md#non-font-readiness-review--november-13-2026).
- **#196:** the UAV redistribution concern is resolved by Nicholas Kruse’s
  express written permission dated November 13, 2026 (see below). Only VCR OSD
  Mono still lacks explicit app redistribution and font-attachment permission evidence.
  OFL licenses for the new fonts do not license the old ones or old sample MKVs.

The maintainer privately retains the UAV author permission described below.
Historical obligations are not closed by replacing future maintenance downloads.
System/custom fonts selected by users retain
their own terms; the application does not grant redistribution rights for them.

## UAV font permission update — November 13, 2026

On November 13, 2026, Nicholas Kruse, the original author of UAV OSD Mono and UAV OSD Sans Mono, granted DVMetaDataBurnIn express written permission to use and redistribute both fonts. The correspondence is privately retained by the maintainer. This project-specific permission resolves the UAV redistribution concern in [#196](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/196); it is not an OFL license, a public-domain dedication, or blanket permission for unrelated projects. Existing copyright attribution and source links are retained.

Issue #196 remains open only for Riciery Leal’s VCR OSD Mono: explicit app
redistribution and font-attachment/embedding permission evidence, including
applicable attribution requirements. The dated font-origin records and original
distribution bytes remain unchanged.

## Train footage and extracted frames

Attribution: **Zach Zarzycki (ThePolish / shardsofaperture)**. The owner authorized publication of the identified train demonstration and directly related outputs. No existing explicit media license was found alongside the supplied files. No new MIT or Creative Commons license is applied to the videos or extracted frames. Public availability is not a new grant of reuse rights; contact the owner for permissions beyond the published demonstration.
