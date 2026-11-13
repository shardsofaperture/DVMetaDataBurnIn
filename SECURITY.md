# Security reporting

Report vulnerabilities privately through GitHub’s
[Report a vulnerability](https://github.com/shardsofaperture/DVMetaDataBurnIn/security/advisories/new)
form. Include affected versions, macOS/architecture, reproduction steps, impact
and a minimal non-sensitive sample if needed. Do not post exploit details,
private recordings or credentials in a public issue. If the private form is
unavailable, open an issue requesting a private contact without sensitive details.

`main` retains 1.0.6; `maintenance/1.0.7` is experimental. Reports affecting either
are welcome. Older packages are historical and do not receive independent fixes.
This volunteer project has no guaranteed response or patch schedule. A published
release is not a security certification; bundled FFmpeg/DVRescue versions and
source status are documented in [LICENSING.md](docs/LICENSING.md).

The application processes media using bundled native executables and runs with
the user's filesystem permissions. Keep original captures and backups separate
from output destinations. When reporting a dependency vulnerability, identify
the bundled version/hash rather than assuming the system installation is used.
