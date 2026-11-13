#!/usr/bin/env python3
"""Build pinned tools locally; never installs into system paths or the app bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import urllib.request

HERE = Path(__file__).resolve().parent

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("component", choices=("ffmpeg", "dvrescue"))
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--archives", type=Path, required=True)
    p.add_argument("--jobs", type=int, default=4)
    a = p.parse_args()
    if not 1 <= a.jobs <= 8:
        p.error("jobs must be between 1 and 8")
    work, archives = a.work.resolve(), a.archives.resolve()
    work.mkdir(parents=True, exist_ok=True)
    archives.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin", LC_ALL="C",
               MACOSX_DEPLOYMENT_TARGET="12.0", SOURCE_DATE_EPOCH="1759276800",
               ZERO_AR_DATE="1", CFLAGS="-O2 -mmacosx-version-min=12.0",
               CXXFLAGS="-O2 -mmacosx-version-min=12.0", LDFLAGS="-mmacosx-version-min=12.0")
    # The caller selects Xcode explicitly; no xcode-select changes.
    # Apple's shims honor DEVELOPER_DIR and avoid spaces in make/configure CC values.
    env.update(CC="/usr/bin/clang", CXX="/usr/bin/clang++", OBJCXX="/usr/bin/clang++",
               OBJCXXFLAGS=env["CXXFLAGS"], MAKE="/usr/bin/make")
    prefix = work / "prefix"
    env.update(PKG_CONFIG_PATH="", PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"))
    lock = json.loads((HERE / "sources.lock.json").read_text())
    roots = {}
    inputs = []
    for item in lock["archives"]:
        if (item["file"].startswith("dvrescue")) != (a.component == "dvrescue"):
            continue
        delivered = item.get("delivery", item)
        selected = delivered if (archives / delivered["file"]).exists() else item
        archive = archives / selected["file"]
        if not archive.exists():
            urllib.request.urlretrieve(item["url"], archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != selected["sha256"]:
            raise RuntimeError(f"SHA-256 mismatch: {archive}")
        inputs.append({"file": archive.name, "sha256": selected["sha256"]})
        root = work / item["root"]
        if root.exists():
            raise RuntimeError(f"Use a fresh work directory; already exists: {root}")
        with tarfile.open(archive) as t:
            t.extractall(work, filter="data")
        roots[item["file"].split("-")[0].split("_")[0]] = root
    receipt = {"component": a.component, "source_archives": inputs, "environment": {k: env[k] for k in
               ("DEVELOPER_DIR", "CC", "CXX", "OBJCXX", "OBJCXXFLAGS", "CFLAGS", "CXXFLAGS", "LDFLAGS", "PATH",
                "MACOSX_DEPLOYMENT_TARGET", "SOURCE_DATE_EPOCH", "ZERO_AR_DATE", "PKG_CONFIG_LIBDIR") if k in env},
               "commands": []}
    def run(cmd, cwd):
        receipt["commands"].append({"cwd": str(cwd), "argv": list(map(str, cmd))})
        (work / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("RUN", cwd, cmd, flush=True)
        subprocess.run(list(map(str, cmd)), cwd=cwd, env=env, check=True)
    def make(cwd, install=False):
        run(["make", f"-j{a.jobs}"], cwd)
        if install:
            run(["make", "install"], cwd)
    if a.component == "ffmpeg":
        run(["./configure", f"--prefix={prefix}", "--disable-shared", "--enable-static",
             "--without-harfbuzz", "--without-zlib", "--without-bzip2", "--without-png", "--without-brotli"], roots["freetype"])
        make(roots["freetype"], True)
        hb = roots["harfbuzz"]
        run(["meson", "setup", "_build", f"--prefix={prefix}", "--libdir=lib", "--buildtype=release",
             "--default-library=static", "--wrap-mode=nodownload", "-Dfreetype=enabled",
             *[f"-D{x}=disabled" for x in ("glib", "gobject", "cairo", "chafa", "icu", "graphite2",
               "coretext", "tests", "utilities", "introspection", "docs", "benchmark")]], hb)
        run(["ninja", "-C", "_build", f"-j{a.jobs}"], hb)
        run(["ninja", "-C", "_build", "install"], hb)
        run(["./configure", f"--prefix={prefix}", "--enable-static", "--disable-cli", "--disable-opencl",
             "--enable-pic", "--bit-depth=8", "--chroma-format=all"], roots["x264"])
        make(roots["x264"], True)
        run(["./configure", f"--prefix={prefix}", "--disable-autodetect", "--disable-shared", "--enable-static",
             "--enable-gpl", "--enable-version3", "--enable-libx264", "--enable-libfreetype", "--enable-libharfbuzz",
             "--enable-zlib", "--disable-ffplay", "--disable-ffprobe", "--disable-doc", "--disable-debug",
             "--pkg-config-flags=--static", "--extra-ldflags=-lc++", "--extra-version=dvmetadata1"], roots["ffmpeg"])
        make(roots["ffmpeg"], True)
    else:
        root = roots["dvrescue"]
        run(["/usr/bin/patch", "-p1", "--batch", "--forward", "-i", HERE / "dvrescue-disable-capture.patch"], root)
        zen = root / "ZenLib/Project/GNU/Library"
        media = root / "MediaInfoLib/Project/GNU/Library"
        dv = root / "dvrescue/Project/GNU/CLI"
        for directory in (zen, media):
            run(["./configure", "--enable-static", "--disable-shared", f"--prefix={prefix}"], directory)
            make(directory)
        run(["./configure", f"--prefix={prefix}", "--enable-staticlibs", "--disable-capture",
             "--disable-avfctl", "--disable-decklink", "--disable-sony9pin", "--disable-simulator"], dv)
        make(dv, True)
    binary = prefix / "bin" / a.component
    receipt["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt["binary"] = str(binary)
    receipt["dynamic_libraries"] = subprocess.check_output(["otool", "-L", str(binary)], text=True, env=env)
    receipt["xcode"] = subprocess.check_output(["xcodebuild", "-version"], text=True, env=env)
    receipt["compiler"] = subprocess.check_output([env["CC"], "--version"], text=True, env=env)
    (work / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")

if __name__ == "__main__":
    main()
