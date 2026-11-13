# Developer Tests

## Mixed meta batch stitch

**Scenario**
- Batch stitch enabled.
- N folders with metadata + 1 folder without metadata.

**Expected outcome**
- The batch stitch completes successfully, including the folder without metadata.

## Sendcmd parse smoke test

**Scenario**
- Generate `timestamp.cmd`.
- Run ffmpeg to read it and reinitialize `drawtext@dvtime` (e.g., `-vf "sendcmd=f=timestamp.cmd,drawtext@dvtime=..."`).

**Expected outcome**
- ffmpeg parses `timestamp.cmd` without errors, and `drawtext@dvtime` reinitializes successfully.

## Duplicate stitched output

**Scenario**
- Perform a stitch operation that would previously risk producing duplicates.

**Expected outcome**
- Only one stitched output file is produced (no duplicates).
