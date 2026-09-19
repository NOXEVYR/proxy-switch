"""Native macOS build. Pinned downloads only; no signing credentials or user data."""
import argparse, gzip, hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys, urllib.request, zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = "0.1.0-preview.2"

def run(*args):
    print("RUN", pathlib.Path(args[0]).name, args[1] if len(args) > 1 else "", flush=True)
    timeout = 45 if "--system-selftest" in args or "--ui-smoke" in args else 180
    return subprocess.check_output(args, cwd=ROOT, text=True, timeout=timeout).strip()

def fetch(spec):
    data = urllib.request.urlopen(spec["url"], timeout=120).read()
    assert hashlib.sha256(data).hexdigest() == spec["sha256"], "Upstream checksum mismatch"
    return data

def main():
    p = argparse.ArgumentParser(); p.add_argument("--arch", required=True, choices=["arm64", "x86_64"]); p.add_argument("--output", required=True)
    args = p.parse_args()
    assert sys.platform == "darwin", "Native macOS build required"
    output = pathlib.Path(args.output).resolve(); output.mkdir(parents=True, exist_ok=True)
    bundle = output / "FlowSwitch.app"
    assert not bundle.exists(), "Use a new output directory"
    run("swift", "build", "-c", "release", "--arch", args.arch)
    bin_dir = pathlib.Path(run("swift", "build", "-c", "release", "--arch", args.arch, "--show-bin-path"))
    executable = bundle / "Contents/MacOS/FlowSwitch"; executable.parent.mkdir(parents=True)
    resources = bundle / "Contents/Resources"; resources.mkdir()
    shutil.copy2(bin_dir / "FlowSwitch", executable)
    lock = json.loads((ROOT / "runtime.lock.json").read_text())
    (resources / "mihomo").write_bytes(gzip.decompress(fetch(lock[args.arch])))
    (resources / "mihomo").chmod(0o755)
    (resources / "mihomo-source.zip").write_bytes(fetch(lock["source"]))
    with zipfile.ZipFile(resources / "mihomo-source.zip") as z:
        (resources / "mihomo-LICENSE").write_bytes(z.read("mihomo-1.19.29/LICENSE"))
    for file in ["README.md", "runtime.lock.json"]: shutil.copy2(ROOT / file, resources / file)
    shutil.copy2(ROOT.parent / "LICENSE", resources / "FlowSwitch-LICENSE")
    info = {"CFBundleExecutable":"FlowSwitch", "CFBundleIdentifier":"io.github.turnsolesama.FlowSwitch", "CFBundleName":"FlowSwitch", "CFBundleDisplayName":"流向 FlowSwitch", "CFBundlePackageType":"APPL", "CFBundleShortVersionString":"0.1.0", "CFBundleVersion":"2", "LSMinimumSystemVersion":"13.0", "NSHighResolutionCapable":True, "NSPrincipalClass":"NSApplication", "NSHumanReadableCopyright":"FlowSwitch contributors. Includes mihomo GPL-3.0."}
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    iconset = output / "FlowSwitch.iconset"; iconset.mkdir()
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
            run("sips", "-z", str(size*scale), str(size*scale), str(ROOT.parent / "assets/FlowSwitch.png"), "--out", str(iconset / name))
    run("iconutil", "-c", "icns", str(iconset), "-o", str(resources / "FlowSwitch.icns"))
    info["CFBundleIconFile"] = "FlowSwitch.icns"; (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    # Ad-hoc integrity signatures are NOT Developer ID signing or notarization.
    run("codesign", "--force", "--sign", "-", str(resources / "mihomo"))
    run("codesign", "--force", "--sign", "-", str(bundle))
    run("codesign", "--verify", "--deep", "--strict", str(bundle))
    assert args.arch in run("lipo", "-archs", str(executable))
    assert args.arch in run("lipo", "-archs", str(resources / "mihomo"))
    print(run(str(executable), "--version")); print(run(str(resources / "mihomo"), "-v"))
    # SystemConfiguration requires privileged commit even for an isolated temporary plist.
    # This mode uses no default preferences and never calls SCPreferencesApplyChanges.
    print(run("sudo", "-n", str(executable), "--system-selftest"))
    print(run("python3", str(ROOT / "scripts/integration.py"), "--app", str(bundle)))
    run(str(executable), "--ui-smoke", "--screenshot", str(output / "ui-smoke.png"))
    with zipfile.ZipFile(output / "UI-review.zip", "w", zipfile.ZIP_DEFLATED) as review:
        for image in sorted(output.glob("ui-*.png")): review.write(image, "FlowSwitch-UI/" + image.name)
    provenance = ROOT.parent / "SOURCE_COMMIT.txt"
    source_commit = provenance.read_text().strip() if provenance.exists() else run("git", "rev-parse", "HEAD")
    manifest = {"version":VERSION, "arch":args.arch, "sourceCommit":source_commit, "signature":"ad-hoc; not notarized", "files":{str(f.relative_to(bundle)):hashlib.sha256(f.read_bytes()).hexdigest() for f in bundle.rglob("*") if f.is_file()}}
    (output / "verification.json").write_text(json.dumps(manifest, indent=2))
    archive = output / f"FlowSwitch-macOS-{VERSION}-{args.arch}.zip"
    run("ditto", "-c", "-k", "--keepParent", str(bundle), str(archive))
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert all(n.startswith("FlowSwitch.app/") and ".." not in pathlib.PurePosixPath(n).parts for n in z.namelist())
    # Execute the actual archive after relocation, not only the staging directory.
    check = output / "archive-check"; run("ditto", "-x", "-k", str(archive), str(check))
    run("codesign", "--verify", "--deep", "--strict", str(check / "FlowSwitch.app"))
    print(run("python3", str(ROOT / "scripts/integration.py"), "--app", str(check / "FlowSwitch.app")))
    (output / f"SHA256-{args.arch}.txt").write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+"  "+archive.name+"\n")
    print(json.dumps({"archive":archive.name,"bytes":archive.stat().st_size,"sha256":hashlib.sha256(archive.read_bytes()).hexdigest()}))

if __name__ == "__main__": main()
