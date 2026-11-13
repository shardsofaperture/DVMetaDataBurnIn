# Application, component, and sample rights

The root [LICENSE](../LICENSE) is a byte-for-byte copy of the existing [APP_LICENSE.txt](../Resources/licenses/APP_LICENSE.txt): MIT, **Copyright (c) 2025 Zach Zarzycki**. Adding it makes the existing terms discoverable; it does not change ownership or grant different terms. The bundled notice remains intact.

See the [distribution audit](THIRD_PARTY_DISTRIBUTION_AUDIT.md) for all eight published application ZIPs, exact binary/font hashes, supplier matches, source-delivery findings and actionable issues. This page is the short rights overview.

## Bundled components inspected on November 13, 2026

| Component | Observed version and notice | Scope and remaining evidence |
| --- | --- | --- |
| FFmpeg | Bundled x86_64 `8.0.1-tessus`; `-buildconf` includes `--enable-gpl --enable-version3`; `-L` states GPL version 3 or later. [GPLv3 text](../Resources/licenses/COPYING.GPLv3), [existing FFmpeg notice](../Resources/licenses/LICENSE.md). | This specific binary reports GPL-3.0-or-later. Other FFmpeg configurations can have different terms. The executable now matches the supplier download by SHA-256. Exact corresponding source/build materials and complete external-library notices remain unresolved in issue #194. |
| DVRescue | Bundled x86_64 24.07, reporting MediaInfoLib 24.06. [BSD-3-Clause notice](../Resources/licenses/dvrescue_LICENSE.txt), copyright 2019–2025 MIPoPS. | Official 24.07 package matches the binary. Verified dependency notices are now appended to the bundled notice and supplied beside historical downloads; exact DeckLink SDK/build mapping remains open in #195. |
| UAV OSD fonts | UAV-OSD-Mono and UAV-OSD-Sans-Mono; attribution to Nicholas Kruse. | Existing notice references free personal/commercial use and author pages; author-linked font bytes and use permission are verified, while explicit redistribution/embedding terms remain unresolved in issue #196. |
| VCR OSD Mono | Attribution to Riciery Leal (mrmanet). | Existing notice relies on author comments for permission; author-linked font bytes and use permission are verified, while explicit redistribution/embedding terms remain unresolved in issue #196. |

All existing third-party texts and [attributions](../Resources/licenses/NOTICE.txt) are retained, including the LGPL and GPL copies. Verify tool evidence locally without changing the binaries:

```sh
Resources/bin/ffmpeg -version
Resources/bin/ffmpeg -buildconf
Resources/bin/ffmpeg -L
Resources/bin/dvrescue --version
```

The application's MIT license does not replace component terms. These observations do not establish blanket distribution compliance. Verified DVRescue notice gaps are partially repaired by the [supplement](audit/2026-11-13/DVRESCUE-NOTICES.txt). Exact remaining FFmpeg, DeckLink/build and font evidence is listed in the distribution audit. No bundled binary or third-party terms were replaced.

## Train footage and extracted frames

Attribution: **Zach Zarzycki (ThePolish / shardsofaperture)**. The owner authorized publication of the identified train demonstration and directly related outputs. No existing explicit media license was found alongside the supplied files. No new MIT or Creative Commons license is applied to the videos or extracted frames. Public availability is not a new grant of reuse rights; contact the owner for permissions beyond the published demonstration.
