# Application, component, and sample rights

The root [LICENSE](../LICENSE) is a byte-for-byte copy of the existing [APP_LICENSE.txt](../Resources/licenses/APP_LICENSE.txt): MIT, **Copyright (c) 2025 Zach Zarzycki**. Adding it makes the existing terms discoverable; it does not change ownership or grant different terms. The bundled notice remains intact.

## Bundled components inspected on November 13, 2026

| Component | Observed version and notice | Scope and remaining evidence |
| --- | --- | --- |
| FFmpeg | Bundled x86_64 `8.0.1-tessus`; `-buildconf` includes `--enable-gpl --enable-version3`; `-L` states GPL version 3 or later. [GPLv3 text](../Resources/licenses/COPYING.GPLv3), [existing FFmpeg notice](../Resources/licenses/LICENSE.md). | This specific binary reports GPL-3.0-or-later. Other FFmpeg configurations can have different terms. Exact corresponding source/build provenance and the complete inventory for enabled external libraries remain to be established. |
| DVRescue | Bundled x86_64 24.07, reporting MediaInfoLib 24.06. [BSD-3-Clause notice](../Resources/licenses/dvrescue_LICENSE.txt), copyright 2019–2025 MIPoPS. | Preserve its notice. The bundled notice does not fully inventory dependency licensing; this is not a complete distribution audit. |
| UAV OSD fonts | UAV-OSD-Mono and UAV-OSD-Sans-Mono; attribution to Nicholas Kruse. | Existing notice references free personal/commercial use and author pages; a standalone preserved permission text was not found. |
| VCR OSD Mono | Attribution to Riciery Leal (mrmanet). | Existing notice relies on author comments for permission; a standalone preserved permission text was not found. |

All existing third-party texts and [attributions](../Resources/licenses/NOTICE.txt) are retained, including the LGPL and GPL copies. Verify tool evidence locally without changing the binaries:

```sh
Resources/bin/ffmpeg -version
Resources/bin/ffmpeg -buildconf
Resources/bin/ffmpeg -L
Resources/bin/dvrescue --version
```

The application's MIT license does not replace component terms. These observations do not establish blanket distribution compliance. Resolving the source/build and font-notice gaps is follow-up work; this documentation change does not replace bundled binaries or rewrite third-party terms.

## Train footage and extracted frames

Attribution: **Zach Zarzycki (ThePolish / shardsofaperture)**. The owner authorized publication of the identified train demonstration and directly related outputs. No existing explicit media license was found alongside the supplied files. No new MIT or Creative Commons license is applied to the videos or extracted frames. Public availability is not a new grant of reuse rights; contact the owner for permissions beyond the published demonstration.
