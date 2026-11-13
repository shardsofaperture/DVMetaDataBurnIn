# Contributing

DVMetaDataBurnIn preserves recording context from existing DV/Digital8 captures.
Start with the [README](readme.md), [project status](docs/PROJECT_STATUS.md) and
[roadmap](docs/ROADMAP.md). Search existing issues before opening a new one.

## Branches and pull requests

- `main` retains application 1.0.6. Target shared documentation, licensing and
  release-verification corrections here; synchronize them narrowly to maintenance.
- `maintenance/1.0.7` contains experimental application work. Target runtime
  fixes and their regressions here. Do not merge maintenance into main or alter
  historical tags/assets as part of routine contributions.
- Describe the problem, resulting behavior, tests actually run and remaining
  limits. Keep changes focused and preserve unrelated work. Application contributions use the existing MIT license. Third-party materials
  retain their own terms; include provenance and required notices.

## Build and checks

Clone the repository and check out the intended branch. Use full Xcode with the
existing project/scheme, macOS 12 minimum; the verified toolchain is Intel macOS
14 and Xcode 15.4. Set `DEVELOPER_DIR` for the command rather than changing the
system toolchain. Bundled tools are Intel-only. See [DEV.md](DEV.md).

Both branches provide these standard-library Python checks:

```sh
python3 scripts/check_docs.py
python3 -m unittest discover -s scripts/tests -v
```

On maintenance, also run `zsh Resources/scripts/dev/test_all.zsh` and the native
build for application changes. The suite needs Python 3, Zsh and an existing
`ffprobe` for media inspection; report skips. [Developer tests](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/maintenance/1.0.7/docs/DEV_TESTS.md)
explain the synthetic fixtures and Swift checks. No package installation is
needed for a normal app build. For dependency rebuilds, use the pinned
[maintenance recipe](https://github.com/shardsofaperture/DVMetaDataBurnIn/blob/maintenance/1.0.7/scripts/dependencies/README.md)
and a separate work directory; never silently substitute system binaries.

## Reports and releases

For media problems, include the app version/commit, macOS/architecture, mode,
settings, expected/actual result and relevant logs. The [validation guide](docs/COMMUNITY_VALIDATION.md)
separates measured CLI results from human playback and GUI acceptance. Share
small samples only when you have permission; redact private paths and metadata.
Use [SECURITY.md](SECURITY.md) for vulnerabilities.

New packages must pass the [release integrity gate](scripts/verify_release.py),
include matching source/notices and receive download/hash verification after
publication. Automation does not establish manual acceptance. In particular,
[#197](https://github.com/shardsofaperture/DVMetaDataBurnIn/issues/197) is a player
acceptance requirement before stable 1.0.7 promotion, not an open code defect.
