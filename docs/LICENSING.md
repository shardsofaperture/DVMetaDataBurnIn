# Application, component, and sample rights

> Scope: this page describes the stable 1.0.6 bundle and the historical distributions through preview 1. Experimental [preview 2](https://github.com/shardsofaperture/DVMetaDataBurnIn/releases/tag/v1.0.7-maintenance.2) replaces its tools and fonts independently; see its [source-build and license evidence](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/maintenance/1.0.7/docs/LICENSING.md). Those replacements do not retroactively resolve the historical questions below.

The root [LICENSE](../LICENSE) is a byte-for-byte copy of the existing [APP_LICENSE.txt](../Resources/licenses/APP_LICENSE.txt): MIT, **Copyright (c) 2025 Zach Zarzycki**. Adding it makes the existing terms discoverable; it does not change ownership or grant different terms. The bundled notice remains intact.

See the [distribution audit](THIRD_PARTY_DISTRIBUTION_AUDIT.md) for the eight historical application ZIPs through preview 1, exact binary/font hashes, supplier matches, source-delivery findings and actionable issues. This page is the short rights overview.

## Bundled components inspected on November 13, 2026

| Component | Observed version and notice | Scope and remaining evidence |
| --- | --- | --- |
| FFmpeg | Bundled x86_64 `8.0.1-tessus`; `-buildconf` includes `--enable-gpl --enable-version3`; `-L` states GPL version 3 or later. [GPLv3 text](../Resources/licenses/COPYING.GPLv3), [existing FFmpeg notice](../Resources/licenses/LICENSE.md). | This specific binary reports GPL-3.0-or-later. Other FFmpeg configurations can have different terms. The executable now matches the supplier download by SHA-256. Exact corresponding source/build materials and complete external-library notices remain unresolved in issue #194. |
| DVRescue | Bundled x86_64 24.07, reporting MediaInfoLib 24.06. [BSD-3-Clause notice](../Resources/licenses/dvrescue_LICENSE.txt), copyright 2019–2025 MIPoPS. | Official 24.07 package matches the binary. Verified dependency notices are appended to the bundled notice and supplied beside historical downloads. #195 is resolved: the DeckLink Include-file permissions exempt compiled object code from notice reproduction. Exact SDK/build mapping remains optional provenance; see the [non-font review](THIRD_PARTY_DISTRIBUTION_AUDIT.md#non-font-readiness-review--november-13-2026). |
| UAV OSD fonts | UAV-OSD-Mono and UAV-OSD-Sans-Mono; attribution to Nicholas Kruse. | Author-linked font bytes are verified. Express written permission from Nicholas Kruse to use and redistribute both fonts in this project was granted November 13, 2026 and is privately retained by the maintainer. The UAV redistribution concern in #196 is resolved; see the permission update below. |
| VCR OSD Mono | Attribution to Riciery Leal (mrmanet). | Existing notice relies on author comments for permission; author-linked font bytes and use permission are verified, while explicit redistribution/embedding terms remain unresolved in issue #196. |

All existing third-party texts and [attributions](../Resources/licenses/NOTICE.txt) are retained, including the LGPL and GPL copies. Verify tool evidence locally without changing the binaries:

```sh
Resources/bin/ffmpeg -version
Resources/bin/ffmpeg -buildconf
Resources/bin/ffmpeg -L
Resources/bin/dvrescue --version
```

The application's MIT license does not replace component terms. These observations do not establish blanket distribution compliance. Verified DVRescue notice gaps are repaired by the [supplement](audit/2026-11-13/DVRESCUE-NOTICES.txt). Exact remaining FFmpeg and VCR OSD Mono permission evidence is listed in the distribution audit. No stable-branch binary or font is replaced.

## UAV font permission update — November 13, 2026

On November 13, 2026, Nicholas Kruse, the original author of UAV OSD Mono and UAV OSD Sans Mono, granted DVMetaDataBurnIn express written permission to use and redistribute both fonts. The correspondence is privately retained by the maintainer. This project-specific permission resolves the UAV redistribution concern in [#196](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/196); it is not an OFL license, a public-domain dedication, or blanket permission for unrelated projects. Existing copyright attribution and source links are retained.

Issue #196 remains open only for Riciery Leal’s VCR OSD Mono: explicit app
redistribution and font-attachment/embedding permission evidence, including
applicable attribution requirements. The dated font-origin records and original
distribution bytes remain unchanged.

## Train footage and extracted frames

Attribution: **Zach Zarzycki (ThePolish / shardsofaperture)**. The owner authorized publication of the identified train demonstration and directly related outputs. No existing explicit media license was found alongside the supplied files. No new MIT or Creative Commons license is applied to the videos or extracted frames. Public availability is not a new grant of reuse rights; contact the owner for permissions beyond the published demonstration.
