# Licenses and source materials

The application is **MIT licensed, Copyright (c) 2025 Zach Zarzycki**.
See [LICENSE](../LICENSE) and [APP_LICENSE.txt](../Resources/licenses/APP_LICENSE.txt).
Bundled components retain their own licenses and attribution in
[Resources/licenses/NOTICE.txt](../Resources/licenses/NOTICE.txt).

## Maintenance 1.0.7

This page covers [experimental preview 2](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.2).
[Main remains stable 1.0.6](https://github.com/shardsofaperture/DVMetaDataBurnIn/tree/main),
with [its own bundled-component terms](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/main/docs/LICENSING.md).

| Bundled component | Terms and source relationship |
| --- | --- |
| FFmpeg 8.0.1-dvmetadata1 | GPL-3.0-or-later; built from the pinned official FFmpeg release with static x264, FreeType and HarfBuzz. Autodetection of other third-party libraries is disabled. Full corresponding sources and the controlling build script are delivered in `dependency-sources.tar` beside the app ZIP. |
| x264 | GPL-2.0-or-later, pinned VideoLAN commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`. |
| FreeType 2.13.3 | GPL-2.0-or-later alternative selected; included BDF/PCF and HarfBuzz notices retained. |
| HarfBuzz 10.4.0 | Permissive licenses reproduced from upstream COPYING. |
| DVRescue 24.07-dvmetadata1 | BSD-3-Clause; built from MediaArea's official all-in-one source with MediaInfoLib 24.06 (BSD-2-Clause) and ZenLib 0.4.41 (zlib). DeckLink and other capture/control integrations are disabled; no SDK is used. |
| VT323, Share Tech Mono, IBM Plex Mono | Unmodified font bytes from a pinned Google Fonts revision. Full author/copyright/reserved-name terms and SIL OFL 1.1 texts accompany the app. MKV attachments include the corresponding OFL text. |

## Corresponding source

Download `dependency-sources.tar` beside the matching app on the
[preview release](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.2).
It contains the pinned FFmpeg/library archives, DVRescue CLI sources and patch,
license texts, and controlling build scripts. [Build instructions and source
locks](../scripts/dependencies/README.md) describe how to use them.
Keep matching source materials available alongside each binary distribution.

The tools use macOS-provided system libraries. System/custom fonts selected by
users retain their own terms; the application grants no redistribution rights
for them.

## Stable and earlier distributions

Stable 1.0.6 and preview 1 retain their original tools and assets. The preview 2
source bundle corresponds only to preview 2, not their Evermeet FFmpeg binary.
Corresponding-source/build materials and the complete dependency notice set for
that historical binary remain unavailable. The DVRescue notice supplement is
provided beside the historical downloads.

## UAV OSD fonts in stable and earlier releases

UAV OSD Mono and UAV OSD Sans Mono are by Nicholas Kruse. He granted
DVMetaDataBurnIn express written permission to use and redistribute both fonts
on November 13, 2026. The correspondence is privately retained by the maintainer.
This permission applies to this project; it is not an OFL license, a public-domain
dedication, or blanket permission for unrelated projects. Copyright attribution
and source links are retained in the notices.

VCR OSD Mono by Riciery Leal has documented use permission; explicit app
redistribution and attachment/embedding terms, including attribution requirements,
remain unconfirmed. Its terms are managed separately by the owner.

## Train footage and extracted frames

Attribution: **Zach Zarzycki (ThePolish / shardsofaperture)**. The owner authorized publication of the identified train demonstration and directly related outputs. No existing explicit media license was found alongside the supplied files. No new MIT or Creative Commons license is applied to the videos or extracted frames. Public availability is not a new grant of reuse rights; contact the owner for permissions beyond the published demonstration.

[Historical distribution records](THIRD_PARTY_DISTRIBUTION_AUDIT.md) retain the supporting package and source verification.
