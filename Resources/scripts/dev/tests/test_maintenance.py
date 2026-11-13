"""Synthetic maintenance regressions; no owner footage or third-party Python packages."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[4]
LIB = REPO / "Resources/scripts/lib"
ENTRY = REPO / "Resources/scripts/dvmetaburn.zsh"
FFMPEG = Path(os.environ.get("FFMPEG_BIN", REPO / "Resources/bin/ffmpeg"))
DVRESCUE = Path(os.environ.get("DVRESCUE_BIN", REPO / "Resources/bin/dvrescue"))
FFPROBE = shutil.which("ffprobe")
FONT = REPO / "Resources/fonts/UAV-OSD-Mono.ttf"
FPS = 30000 / 1001


def run(args, **kwargs):
    result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90, **kwargs)
    if result.returncode:
        raise AssertionError("Command failed ({}): {}\n{}".format(
            result.returncode, args, result.stdout.decode("utf-8", "replace")[-10000:]))
    return result.stdout.decode("utf-8", "replace")


def zsh(code, *args, check=True, env=None):
    script = '''set -euo pipefail
lib_root=$1; shift
for lib in env logging pathing dvrescue timeline cleanup artifacts filtergraph; do
  source "$lib_root/$lib.zsh"
done
debug_mode=0
fontfile=""
DVMETABURN_FONTFILE=""
burn_granularity=per_second
missing_meta=error
subtitle_font_name="UAV OSD Mono"
''' + code
    argv = ["/bin/zsh", "-c", script, "maintenance-test", str(LIB)] + list(map(str, args))
    if check:
        return run(argv, env=env)
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20, env=env)


def ass_seconds(value):
    h, m, s = value.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def events(ass):
    rows = []
    for line in ass.read_text().splitlines():
        if line.startswith("Dialogue:"):
            fields = line.split(",", 9)
            rows.append((ass_seconds(fields[1]), ass_seconds(fields[2]), fields[3], fields[9]))
    return rows


class TimelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dvmeta-timing-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def make_ass(self, rows, duration="N/A", fps="29.97", layout="stacked", granularity="per_second"):
        log = self.root / "metadata.log"
        log.write_text("\n".join(rows) + "\n")
        # A banner fixture controls duration without generating hours of video.
        probe = self.root / "probe.zsh"
        probe.write_text("#!/bin/zsh\nprint -r -- '  Duration: {}, start: 0.000000, bitrate: 1 kb/s'\nexit 1\n".format(duration))
        probe.chmod(0o755)
        source = self.root / "source.dv"
        source.touch()
        out = self.root / "timestamps.ass"
        zsh('''ffmpeg_bin=$1; burn_granularity=$8
make_ass_subs "$2" "$7" "$3" "unused" "$4" "$5" "$6"
''', probe, source, out, log, self.root / "timeline.tsv", fps, layout, granularity)
        result = events(out)
        self.assertTrue(result)
        for start, end, _, _ in result:
            self.assertGreaterEqual(start, 0)
            self.assertGreater(end, start)
        for style in {r[2] for r in result}:
            group = [r for r in result if r[2] == style]
            for before, after in zip(group, group[1:]):
                self.assertLessEqual(before[1], after[0])
        return result

    def test_final_event_uses_source_end_not_last_metadata_change(self):
        result = self.make_ass(["1 00:00:00;00 2024-01-01 12:00:00",
                                "31 00:00:01;00 2024-01-01 12:00:01"], "00:00:01.23")
        self.assertAlmostEqual(result[-1][0], 1.0)
        self.assertAlmostEqual(result[-1][1], 1.24)

    def test_one_frame_and_subsecond_clips(self):
        for duration, expected in [("00:00:00.03", .04), ("00:00:00.50", .51)]:
            with self.subTest(duration=duration):
                result = self.make_ass(["1 00:00:00;00 2024-01-01 12:00:00"], duration)
                self.assertEqual(result[-1][1], expected)

    def test_hour_long_ntsc_clip_does_not_accumulate_rounded_rate_drift(self):
        result = self.make_ass(["1 00:00:00;00 2024-01-01 12:00:00",
                                "107893 01:00:00;00 2024-01-01 13:00:00"], "01:00:00.03")
        self.assertAlmostEqual(result[-1][0], 3599.99)
        self.assertAlmostEqual(result[-1][1], 3600.03)

    def test_midnight_and_recording_interruptions_keep_recorded_values(self):
        result = self.make_ass(["1 00:00:00;00 2024-01-01 23:59:59",
                                "31 00:00:01;00 2024-01-02 00:00:00",
                                "61 00:00:02;00 2024-02-10 17:43:10"], "00:00:03.00")
        self.assertIn("2024-01-02\\N00:00:00", result[1][3])
        self.assertIn("2024-02-10\\N17:43:10", result[2][3])
        self.assertAlmostEqual(result[-1][1], 3.01)

    def test_missing_duration_uses_last_numbered_frame_without_metadata(self):
        result = self.make_ass(["1 00:00:00;00 2024-01-01 12:00:00",
                                "37 00:00:01;06 ---- ----"])
        self.assertAlmostEqual(result[-1][1], 1.24)

    def test_duplicate_and_backwards_rows_and_rows_after_clip_end(self):
        result = self.make_ass(["0 00:00:00;00 2024-01-01 00:00:00",
                                "1 00:00:00;00 2024-01-01 12:00:00",
                                "31 00:00:01;00 2024-01-01 12:00:01",
                                "31 00:00:01;00 2024-01-01 12:00:02",
                                "2 00:00:00;01 2024-01-01 12:00:03",
                                "301 00:00:10;00 2024-01-01 12:00:10"], "00:00:02.00")
        self.assertEqual(len(result), 2)
        self.assertAlmostEqual(result[-1][1], 2.01)

    def test_single_layout_and_per_frame_mode(self):
        result = self.make_ass(["1 00:00:00;00 2024-01-01 12:00:00",
                                "2 00:00:00;01 2024-01-01 12:00:00"],
                               "00:00:00.07", "30000/1001", "single", "per_frame")
        self.assertEqual(len(result), 4)
        self.assertEqual({r[2] for r in result}, {"DVLeft", "DVRight"})
        self.assertAlmostEqual(result[-1][1], .07)

    def test_ass_time_carries_minutes_and_hours(self):
        self.assertIn("1:00:00.00", zsh('seconds_to_ass_time 3599.999'))

    def test_invalid_fps_rejected(self):
        for value in ("0", "-25", "30000/0", "garbage"):
            self.assertNotEqual(zsh('normalize_fps "$1"', value, check=False).returncode, 0)


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dvmeta-workspace-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def workspace_script(self, body):
        return '''scratch_dir=$1; dest_dir=""; run_notes=(); run_scratch_root=""
scratch_cleanup_policy=$2; keep_on_failure=${3:-0}; primary_input_path=""
trap 'exit_run_workspace $?' EXIT
trap 'cancel_run_workspace 143' TERM
initialize_run_workspace
print -r -- "ROOT=$run_scratch_root"
''' + body

    def roots(self):
        return list(self.root.glob("**/run.*"))

    def test_concurrent_runs_with_special_paths_get_separate_workspaces(self):
        special = self.root / "Owner's 漢字 [DV], : ; $scratch"
        code = self.workspace_script('print -r -- marker > "$artifact_root/result"')
        # Run two shells concurrently, as two application instances would.
        argv = ["/bin/zsh", "-c", 'source "$1/env.zsh"; source "$1/logging.zsh"; source "$1/cleanup.zsh"; debug_mode=0; shift; ' + code,
                "test", str(LIB), str(special), "never"]
        children = [subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) for _ in range(2)]
        for child in children:
            output, _ = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, output)
        roots = self.roots()
        self.assertEqual(len(roots), 2)
        for root in roots:
            self.assertEqual((root / "artifacts/result").read_text().strip(), "marker")
            self.assertFalse((root / "tmp").exists())

    def test_cleanup_policies_and_failure_retention(self):
        for policy, rc, keep, retained in [("success", 0, 0, False), ("success", 7, 0, True),
                                           ("failure", 7, 0, False), ("failure", 0, 0, True),
                                           ("never", 0, 0, True), ("failure", 7, 1, True)]:
            with self.subTest(policy=policy, rc=rc, keep=keep):
                base = self.root / (policy + str(rc) + str(keep))
                result = zsh(self.workspace_script('exit ' + str(rc)), base, policy, keep, check=False)
                self.assertEqual(result.returncode, rc, result.stdout)
                self.assertEqual(bool(list(base.glob("**/run.*"))), retained)

    def test_cleanup_refuses_unowned_marker_and_protected_destination(self):
        for body in ['print -rn -- changed > "$run_scratch_root/.dvmeta-owner"',
                     'dest_dir="$run_scratch_root/artifacts"']:
            zsh(self.workspace_script(body), self.root, "success")
        self.assertEqual(len(self.roots()), 2)

    def test_cleanup_refuses_parent_directory_and_symlink(self):
        victim = self.root / "owner-input"
        victim.mkdir()
        (victim / "keep").write_text("owner data")
        code = self.workspace_script('''run_scratch_root=$4
cleanup_run_scratch_root success && exit 9
''')
        result = zsh(code, self.root, "success", 0, victim, check=False)
        self.assertNotEqual(result.returncode, 9)
        self.assertEqual((victim / "keep").read_text(), "owner data")

    def test_cleanup_refuses_replaced_root_symlink(self):
        victim = self.root / "outside"
        victim.mkdir()
        (victim / "keep").write_text("owner data")
        code = self.workspace_script('''saved="$run_scratch_root.saved"
mv "$run_scratch_root" "$saved"
ln -s "$4" "$run_scratch_root"
''')
        zsh(code, self.root, "success", 0, victim)
        self.assertEqual((victim / "keep").read_text(), "owner data")

    def test_adopt_swift_workspace_and_reject_wrong_owner(self):
        workspace = self.root / "run.from-swift"
        workspace.mkdir()
        (workspace / ".dvmeta-owner").write_text("unique-owner-token")
        env = dict(os.environ, DVMETA_WORKSPACE=str(workspace), DVMETA_WORKSPACE_TOKEN="wrong")
        result = zsh(self.workspace_script("true"), self.root, "success", check=False, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(workspace.exists())
        env["DVMETA_WORKSPACE_TOKEN"] = "unique-owner-token"
        zsh(self.workspace_script('print -r -- marker > "$artifact_root/kept"'), self.root, "never", env=env)
        self.assertTrue((workspace / "artifacts/kept").exists())
        self.assertFalse((workspace / "tmp").exists())

    def test_signal_stops_only_owned_child_before_cleanup(self):
        ready = self.root / "ready"
        code = self.workspace_script('''run_owned_command /bin/zsh -c 'print -r -- $$ > "$1"; exec /bin/sleep 30' child "$4"
''')
        script = 'source "$1/env.zsh"; source "$1/logging.zsh"; source "$1/cleanup.zsh"; debug_mode=0; shift; ' + code
        child = subprocess.Popen(["/bin/zsh", "-c", script, "test", str(LIB), str(self.root), "failure", "0", str(ready)],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(ready.exists())
        worker_pid = int(ready.read_text())
        child.terminate()
        output, _ = child.communicate(timeout=5)
        self.assertEqual(child.returncode, 143, output)
        with self.assertRaises(ProcessLookupError):
            os.kill(worker_pid, 0)
        self.assertEqual(self.roots(), [])


@unittest.skipUnless(FFMPEG.exists() and DVRESCUE.exists() and FFPROBE, "Media tests need bundled tools and developer ffprobe")
class MediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="dvmeta-media-")
        cls.root = Path(cls.temp.name)
        cls.source = cls.root / "input.avi"
        run([FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:size=720x480:rate=30000/1001",
             "-f", "lavfi", "-i", "sine=sample_rate=48000", "-t", "1.234567",
             "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-flags", "+ilme+ildct", "-top", "0",
             "-c:a", "pcm_s16le", "-ac", "2", cls.source])
        # Controlled recording metadata; the actual media always passes through
        # bundled FFmpeg. A separate test exercises actual DVRescue's no-RDT case.
        cls.metadata = cls.root / "metadata.zsh"
        cls.metadata.write_text('''#!/bin/zsh
if [[ "$1" == --version ]]; then print -r -- fixture; exit 0; fi
print -r -- '1 00:00:00;00 2024-01-01 23:59:59'
print -r -- '31 00:00:01;00 2024-01-02 00:00:00'
print -r -- '37 00:00:01;06 2024-01-02 00:00:00'
''')
        cls.metadata.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.work = self.root / self.id().split(".")[-1]
        self.work.mkdir()

    def cli(self, *flags, source=None, metadata=None, check=True):
        source = source or self.source
        args = ["/bin/zsh", ENTRY, "--ffmpeg=" + str(FFMPEG), "--dvrescue=" + str(metadata or self.metadata),
                "--scratch-dir=" + str(self.work / "scratch"), "--dest-dir=" + str(self.work / "output"),
                "--fontfile=" + str(FONT)] + list(flags) + ["--", str(source)]
        if check:
            return run(args)
        return subprocess.run(list(map(str, args)), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)

    def probe(self, path, *flags):
        return json.loads(run([FFPROBE, "-v", "error", "-of", "json", *flags, path]))

    def output(self, suffix):
        return self.work / "output" / ("input" + suffix)

    def test_dv_avi_to_mov_preserves_video_packets(self):
        self.cli("--format=mov", "--burn-mode=off", "--deinterlace=off")
        out = self.output("_conv.mov")
        hashes = []
        for path in (self.source, out):
            text = run([FFMPEG, "-v", "error", "-i", path, "-map", "0:v:0", "-c:v", "copy", "-f", "framemd5", "-"])
            hashes.append([line.split(",")[-1] for line in text.splitlines() if not line.startswith("#")])
        self.assertEqual(hashes[0], hashes[1])
        stream = self.probe(out, "-show_streams")["streams"][0]
        self.assertEqual(stream["codec_name"], "dvvideo")
        self.assertEqual((stream["width"], stream["height"]), (720, 480))

    def test_mp4_burnin_and_deinterlace_modes(self):
        for mode, count in [("off", 37), ("30p", 37), ("60p", 74)]:
            with self.subTest(mode=mode):
                self.cli("--format=mp4", "--burn-mode=burnin", "--deinterlace=" + mode)
                out = self.output("_dateburn.mp4")
                stream = self.probe(out, "-count_frames", "-show_streams")["streams"][0]
                self.assertEqual(int(stream["nb_read_frames"]), count)
                self.assertEqual((stream["width"], stream["height"]), (720, 480))
                # The final decoded frame contains white date/time text on black.
                data = subprocess.check_output([str(FFMPEG), "-v", "error", "-sseof", "-0.04", "-i", str(out),
                                                "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "-"], timeout=10)
                self.assertTrue(data and max(data) > 180)

    def test_switchable_ass_covers_final_frame(self):
        self.cli("--format=mkv", "--burn-mode=subtitleTrack", "--deinterlace=off")
        out = self.output("_dvsub.mkv")
        streams = self.probe(out, "-show_streams")["streams"]
        self.assertIn("ass", [s["codec_name"] for s in streams])
        packets = self.probe(out, "-select_streams", "s", "-show_packets")["packets"]
        last = packets[-1]
        end = float(last["pts_time"]) + float(last["duration_time"])
        self.assertGreaterEqual(end, 37 / FPS)
        self.assertLessEqual(end, 37 / FPS + .04)

    def test_special_paths_burnin(self):
        special = self.work / 'Owner\'s "漢字" [DV], : ; $clip \\clip'
        special.mkdir()
        source = special / "input.avi"
        shutil.copyfile(self.source, source)
        # Cover filtergraph escaping of the scratch and font paths as well.
        special_font = special / "Owner's [font], : ; \\font.ttf"
        shutil.copyfile(FONT, special_font)
        self.cli("--format=mp4", "--burn-mode=burnin", "--deinterlace=30p",
                 "--scratch-dir=" + str(special / "scratch"), "--fontfile=" + str(special_font), source=source)
        self.assertTrue(self.output("_dateburn.mp4").exists())
        manifests = list(special.glob("scratch/**/run_manifest.json"))
        self.assertEqual(len(manifests), 1)
        self.assertEqual(json.loads(manifests[0].read_text())["input"], str(source))

    def test_missing_metadata_modes_with_actual_dvrescue(self):
        for mode in ("skip_burnin_convert", "skip_file", "error"):
            with self.subTest(mode=mode):
                result = self.cli("--format=mkv", "--burn-mode=subtitleTrack", "--missing-meta=" + mode,
                                  metadata=DVRESCUE, check=False)
                if mode == "error":
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.output("_conv.mkv").exists())
        self.assertFalse(self.output("_dvsub.mkv").exists())

    def test_batch_cleanup_after_all_clips_and_stitch_boundaries(self):
        batch = self.work / "batch"
        batch.mkdir()
        for index in range(2):
            shutil.copyfile(self.source, batch / ("part{}.avi".format(index)))
        for mode in ("per-clip", "continuous"):
            with self.subTest(mode=mode):
                self.cli("--mode=batch", "--stitch-batch", "--format=mkv", "--burn-mode=subtitleTrack",
                         "--subtitle-mode=" + mode, "--scratch-cleanup=success", source=batch)
                out = self.work / "output/batch_dvsub_stitched.mkv"
                self.assertTrue(out.exists())
                packets = self.probe(out, "-select_streams", "s", "-show_packets")["packets"]
                starts = [float(p["pts_time"]) for p in packets]
                self.assertEqual(starts, sorted(starts))
                self.assertGreaterEqual(starts[2], 37 / FPS - .04)
                self.assertFalse(list((self.work / "scratch").glob("**/run.*")))
                self.assertEqual(len(list((self.work / "output").glob("*.mkv"))), 1)
        # No-stitch batch must also keep its workspace through the second clip.
        self.cli("--mode=batch", "--format=mov", "--burn-mode=off", "--scratch-cleanup=success", source=batch)
        self.assertTrue((self.work / "output/part0_conv.mov").exists())
        self.assertTrue((self.work / "output/part1_conv.mov").exists())

    def test_cli_stitch_input_manifest(self):
        manifest = self.work / "clips.txt"
        manifest.write_text(str(self.source) + "\n" + str(self.source) + "\n")
        self.cli("--stitch", "--stitch-inputs=" + str(manifest), "--format=mov", "--burn-mode=off")
        stream = self.probe(self.output("_conv.mov"), "-count_frames", "-show_streams")["streams"][0]
        self.assertEqual(int(stream["nb_read_frames"]), 74)

    def test_mixed_metadata_batch_stitch_and_stale_parts(self):
        batch = self.work / "batch"
        batch.mkdir()
        for name in ("good.avi", "missing.avi"):
            shutil.copyfile(self.source, batch / name)
        metadata = self.work / "mixed.zsh"
        metadata.write_text('#!/bin/zsh\n[[ "$1" == *missing.avi ]] && exit 0\nexec "$DVMETA_TEST_METADATA" "$@"\n')
        metadata.chmod(0o755)
        old_env = os.environ.get("DVMETA_TEST_METADATA")
        os.environ["DVMETA_TEST_METADATA"] = str(self.metadata)
        self.addCleanup(lambda: os.environ.pop("DVMETA_TEST_METADATA", None) if old_env is None else os.environ.update(DVMETA_TEST_METADATA=old_env))
        # A stale part in the final destination must never enter this run's concat.
        output_dir = self.work / "output"
        output_dir.mkdir()
        shutil.copyfile(self.source, output_dir / "stale_dvsub.mkv")
        self.cli("--mode=batch", "--stitch-batch", "--format=mp4", "--burn-mode=burnin",
                 "--missing-meta=skip_burnin_convert", source=batch, metadata=metadata)
        out = output_dir / "batch_stitched_dateburn.mp4"
        stream = self.probe(out, "-count_frames", "-show_streams")["streams"][0]
        self.assertEqual(int(stream["nb_read_frames"]), 74)
        self.assertEqual(len(list(output_dir.glob("*stitched*.mp4"))), 1)

    def test_failed_concat_does_not_publish_partial_output(self):
        batch = self.work / "batch"
        batch.mkdir()
        for index in range(2):
            shutil.copyfile(self.source, batch / ("part{}.avi".format(index)))
        failing_ffmpeg = self.work / "ffmpeg-failure.zsh"
        failing_ffmpeg.write_text('''#!/bin/zsh
for arg in "$@"; do
  if [[ "$arg" == concat ]]; then
    print -r -- partial > "${@[-1]}"
    exit 42
  fi
done
exec "$DVMETA_TEST_REAL_FFMPEG" "$@"
''')
        failing_ffmpeg.chmod(0o755)
        old_env = os.environ.get("DVMETA_TEST_REAL_FFMPEG")
        os.environ["DVMETA_TEST_REAL_FFMPEG"] = str(FFMPEG)
        self.addCleanup(lambda: os.environ.pop("DVMETA_TEST_REAL_FFMPEG", None) if old_env is None else os.environ.update(DVMETA_TEST_REAL_FFMPEG=old_env))
        result = self.cli("--mode=batch", "--stitch-batch", "--format=mov", "--burn-mode=off",
                          "--ffmpeg=" + str(failing_ffmpeg), source=batch, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "output/batch_stitched_conv.mov").exists())

    def test_encoder_failure_is_reported_and_workspace_retained(self):
        result = self.cli("--format=mp4", "--burn-mode=off", "--extra-args=-c:v nonexistent_encoder", check=False)
        self.assertNotEqual(result.returncode, 0)
        manifests = list((self.work / "scratch").glob("**/run_manifest.json"))
        self.assertTrue(manifests)
        self.assertEqual(json.loads(manifests[-1].read_text())["status"], "error")


if __name__ == "__main__":
    unittest.main()
