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
FONT = REPO / "Resources/fonts/VT323-Regular.ttf"
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
subtitle_font_name="VT323"
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
    def test_bundled_font_license_matches_bytes_and_fails_if_missing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for folder in ('scripts', 'fonts', 'licenses'):
                (root / folder).mkdir()
            shutil.copyfile(FONT, root / 'fonts' / FONT.name)
            renamed = root / 'renamed.ttf'
            shutil.copyfile(FONT, renamed)
            code = 'script_root=$1; bundled_font_license "$2"'
            result = zsh(code, root / 'scripts', renamed, check=False)
            self.assertEqual(result.returncode, 2)
            license = root / 'licenses/VT323-Regular-OFL.txt'
            license.write_bytes((REPO / 'Resources/licenses' / license.name).read_bytes())
            self.assertEqual(Path(zsh(code, root / 'scripts', renamed).strip()).resolve(), license.resolve())
            renamed.write_bytes(b'unrelated font with a misleading name')
            self.assertEqual(zsh(code, root / 'scripts', renamed, check=False).returncode, 1)
            (root / 'fonts' / FONT.name).rename(root / FONT.name)
            found = zsh('script_root=$1; find_font', root / 'scripts').strip()
            self.assertEqual(Path(found).resolve(), (root / FONT.name).resolve())

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

    def test_each_bundled_font_renders_and_mkv_carries_original_license(self):
        import hashlib
        lock = json.loads((REPO / "scripts/dependencies/fonts.lock.json").read_text())
        for item in lock["files"]:
            self.assertEqual(hashlib.sha256((REPO / item["file"]).read_bytes()).hexdigest(), item["sha256"])
        for font in sorted((REPO / "Resources/fonts").glob("*.ttf")):
            with self.subTest(font=font.name):
                self.cli("--format=mp4", "--burn-mode=burnin", "--fontfile="+str(font))
                out = self.output("_dateburn.mp4")
                pixels = subprocess.check_output([str(FFMPEG), "-v", "error", "-i", str(out),
                         "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "-"], timeout=20)
                self.assertGreater(max(pixels), 180)
                out.unlink()
                self.cli("--format=mkv", "--burn-mode=subtitleTrack", "--fontfile="+str(font))
                out = self.output("_dvsub.mkv")
                attachments = self.probe(out, "-select_streams", "t", "-show_streams")["streams"]
                license_name = font.stem + "-OFL.txt"
                family = {"VT323-Regular": "VT323", "ShareTechMono-Regular": "Share Tech Mono",
                          "IBMPlexMono-Regular": "IBM Plex Mono"}[font.stem]
                ass = run([FFMPEG, "-v", "error", "-i", out, "-map", "0:s:0", "-c", "copy", "-f", "ass", "-"])
                self.assertTrue(any(line.startswith("Style:") and line.split(",")[1] == family
                                    for line in ass.splitlines()), ass)
                self.assertEqual([s["tags"]["filename"] for s in attachments], [font.name, license_name])
                extracted = self.work / license_name
                run([FFMPEG, "-v", "error", "-dump_attachment:t:1", extracted,
                     "-i", out, "-map", "0:v", "-frames:v", "1", "-f", "null", "-"])
                self.assertEqual(extracted.read_bytes(), (REPO / "Resources/licenses" / license_name).read_bytes())
                out.unlink()

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
                frames = self.probe(out, "-select_streams", "v", "-show_frames")["frames"]
                self.assertTrue(all(f["interlaced_frame"] == (1 if mode == "off" else 0) for f in frames))
                if mode == "off":
                    self.assertTrue(all(f["top_field_first"] == 0 for f in frames))
                out.unlink()

    def test_switchable_ass_covers_final_frame(self):
        self.cli("--format=mkv", "--burn-mode=subtitleTrack", "--deinterlace=off")
        out = self.output("_dvsub.mkv")
        streams = self.probe(out, "-show_streams")["streams"]
        self.assertIn("ass", [s.get("codec_name") for s in streams])
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
                out.unlink()
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


    def test_subtitle_bitstream_is_bottom_field_first(self):
        self.cli("--format=mkv", "--burn-mode=subtitleTrack", "--deinterlace=off")
        elementary = self.work / "elementary.h264"
        run([FFMPEG, "-v", "error", "-i", self.output("_dvsub.mkv"), "-map", "0:v", "-c", "copy", elementary])
        frames = self.probe(elementary, "-show_frames")["frames"]
        self.assertEqual(len(frames), 37)
        self.assertTrue(all(f["interlaced_frame"] == 1 and f["top_field_first"] == 0 for f in frames))

    def safety_modes(self):
        return [("mov", "off", "off", False), ("mp4", "off", "off", False),
                ("mp4", "burnin", "off", False), ("mp4", "burnin", "60p", False),
                ("mkv", "subtitleTrack", "off", False),
                ("mkv", "subtitleTrack", "off", True),
                ("mp4", "burnin", "off", True), ("mp4", "off", "off", "audio")]

    def safety_wrapper(self, behavior):
        wrapper = self.work / "encoder.zsh"
        wrapper.write_text('#!/bin/zsh\n' +
            'if [[ "${@[-1]}" == */.dvmeta-output.*/output.* ]]; then\n' +
            '  print -r -- partial > "${@[-1]}"\n' + behavior + '\nfi\n' +
            'exec ' + __import__('shlex').quote(str(FFMPEG)) + ' "$@"\n')
        wrapper.chmod(0o755)
        return wrapper

    def test_all_encode_routes_reject_partial_or_invalid_success(self):
        for behavior in ("exit 42", "exit 0"):
            wrapper = self.safety_wrapper(behavior)
            for index, (fmt, burn, deint, fallback) in enumerate(self.safety_modes()):
                with self.subTest(behavior=behavior, mode=index):
                    flags = ["--format="+fmt, "--burn-mode="+burn, "--deinterlace="+deint,
                             "--output-base=case"+str(index), "--ffmpeg="+str(wrapper),
                             "--missing-meta=skip_burnin_convert"]
                    if fallback == "audio": flags.append("--output-mode=audio")
                    result = self.cli(*flags, metadata=DVRESCUE if fallback is True else None, check=False)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(list((self.work / "output").iterdir()), [])

    def test_all_encode_routes_cancel_without_final_or_stage(self):
        wrapper = self.safety_wrapper('print -r -- ready > "$DVMETA_CANCEL_READY"; while true; do sleep 0.1; done')
        for index, (fmt, burn, deint, fallback) in enumerate(self.safety_modes()):
            with self.subTest(mode=index):
                marker = self.work / "ready"
                marker.unlink(missing_ok=True)
                args = ["/bin/zsh", str(ENTRY), "--ffmpeg="+str(wrapper),
                        "--dvrescue="+str(DVRESCUE if fallback is True else self.metadata),
                        "--fontfile="+str(FONT), "--scratch-dir="+str(self.work / "scratch"),
                        "--dest-dir="+str(self.work / "output"), "--output-base=case"+str(index),
                        "--format="+fmt, "--burn-mode="+burn, "--deinterlace="+deint,
                        "--missing-meta=skip_burnin_convert"]
                if fallback == "audio": args.append("--output-mode=audio")
                args.append(str(self.source))
                with (self.work / "cancel.log").open("w") as log:
                    proc = subprocess.Popen(args, stdout=log, stderr=log,
                                            env=dict(os.environ, DVMETA_CANCEL_READY=str(marker)))
                    try:
                        deadline = time.monotonic()+15
                        while not marker.exists() and proc.poll() is None and time.monotonic()<deadline:
                            time.sleep(.05)
                        self.assertTrue(marker.exists(), (self.work / "cancel.log").read_text())
                        proc.terminate()
                        self.assertNotEqual(proc.wait(timeout=10), 0)
                    finally:
                        if proc.poll() is None: proc.terminate(); proc.wait(timeout=10)
                self.assertEqual(list((self.work / "output").iterdir()), [])

    def test_existing_file_directory_and_symlink_are_preserved(self):
        output = self.work / "output"
        output.mkdir()
        target = self.output("_conv.mov")
        owner = self.work / "owner.mov"
        owner.write_bytes(b"owner export")
        for kind in ("file", "directory", "symlink"):
            with self.subTest(kind=kind):
                if kind == "file": target.write_bytes(b"existing export")
                elif kind == "directory": target.mkdir()
                else: target.symlink_to(owner)
                result = self.cli("--format=mov", "--burn-mode=off", check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(owner.read_bytes(), b"owner export")
                if kind == "directory": self.assertEqual(list(target.iterdir()), []); target.rmdir()
                else:
                    self.assertEqual(target.read_bytes(), b"existing export" if kind == "file" else b"owner export")
                    target.unlink()

    def test_atomic_publish_race_and_distinct_destinations(self):
        # Real simultaneous writers of valid media: exactly one wins a collision.
        output = self.work / "output"
        output.mkdir()
        for distinct in (False, True):
            targets = [output / (str(i if distinct else 0)+".mov") for i in range(2)]
            code = '''source "$1/cleanup.zsh"
warn() { print -r -- "$*" >&2; }
owned_workspace_token=test; output_stage_dirs=(); active_child_pid=""; ffmpeg_bin=$2
run_output_command /bin/cp "$3" "$4"
'''
            procs = [subprocess.Popen(["zsh", "-c", code, "test", str(LIB), str(FFMPEG), str(self.source), str(t)],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT) for t in targets]
            results = [p.communicate(timeout=20) for p in procs]
            self.assertEqual(sum(p.returncode == 0 for p in procs), 2 if distinct else 1, results)
            for t in set(targets):
                self.assertEqual(t.read_bytes(), self.source.read_bytes()); t.unlink()
            self.assertEqual(list(output.iterdir()), [])


    def test_progressive_and_top_field_first_are_not_forced_to_bottom(self):
        for label, options, expected in [("progressive", [], (0, 0)),
                ("top", ["-flags", "+ilme+ildct", "-top", "1", "-x264-params", "tff=1"], (1, 1))]:
            with self.subTest(source=label):
                source = self.work / (label+".avi")
                run([FFMPEG, "-v", "error", "-i", self.source, "-c:v", "libx264", *options,
                     "-c:a", "copy", source])
                self.cli("--format=mp4", "--burn-mode=off", "--output-base="+label, source=source)
                out = self.work / "output" / (label+"_conv.mp4")
                frames = self.probe(out, "-select_streams", "v", "-show_frames")["frames"]
                self.assertTrue(all((f["interlaced_frame"], f["top_field_first"]) == expected for f in frames))

    def test_cancel_final_concat_preserves_existing_export(self):
        batch = self.work / "batch"
        batch.mkdir()
        for i in range(2): shutil.copyfile(self.source, batch/(str(i)+".avi"))
        output = self.work / "output"
        output.mkdir()
        final = output/"batch_stitched_conv.mov"
        final.write_bytes(b"owner export")
        marker = self.work/"ready"
        wrapper = self.work/"concat-cancel.zsh"
        import shlex
        wrapper.write_text('#!/bin/zsh\nfor arg in "$@"; do\nif [[ "$arg" == concat ]]; then\n' +
                           'print partial > "${@[-1]}"\nprint ready > '+shlex.quote(str(marker))+'\n' +
                           'while true; do sleep 0.1; done\nfi\ndone\nexec '+shlex.quote(str(FFMPEG))+' "$@"\n')
        wrapper.chmod(0o755)
        args = ["zsh", str(ENTRY), "--mode=batch", "--stitch-batch", "--format=mov", "--burn-mode=off",
                "--ffmpeg="+str(wrapper), "--dvrescue="+str(self.metadata), "--scratch-dir="+str(self.work/"scratch"),
                "--dest-dir="+str(output), str(batch)]
        with (self.work/"cancel.log").open('w') as log:
            proc = subprocess.Popen(args, stdout=log, stderr=log)
            try:
                deadline = time.monotonic()+15
                while not marker.exists() and proc.poll() is None and time.monotonic()<deadline: time.sleep(.05)
                self.assertTrue(marker.exists(), (self.work/"cancel.log").read_text())
                proc.terminate()
                self.assertNotEqual(proc.wait(timeout=10), 0)
            finally:
                if proc.poll() is None: proc.terminate(); proc.wait(timeout=10)
        self.assertEqual(final.read_bytes(), b"owner export")
        self.assertEqual(list(output.iterdir()), [final])


if __name__ == "__main__":
    unittest.main()
