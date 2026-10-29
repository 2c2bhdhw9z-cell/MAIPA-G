#!/usr/bin/env python3
"""Independently inspect a MAIPA-G IPA on macOS or Linux."""
import argparse
import io
import plistlib
import struct
import sys
import zipfile
from pathlib import PurePosixPath


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa")
    parser.add_argument("--build")
    parser.add_argument("--version")
    args = parser.parse_args()

    with zipfile.ZipFile(args.ipa) as archive:
        names = archive.namelist()
        unsafe = [name for name in names if name.startswith("/") or ".." in PurePosixPath(name).parts]
        if unsafe:
            fail("archive contains an unsafe path")
        apps = sorted({"/".join(name.split("/")[:2]) for name in names if name.startswith("Payload/") and name.count("/") >= 2 and name.split("/")[1].endswith(".app")})
        if apps != ["Payload/MAIPA-G.app"]:
            fail(f"expected one Payload/MAIPA-G.app, found {apps}")
        root = apps[0]
        required = [f"{root}/Info.plist", f"{root}/MAIPA-G", f"{root}/Assets.car", f"{root}/PrivacyInfo.xcprivacy"]
        for path in required:
            if path not in names:
                fail(f"missing {path}")
        info = plistlib.loads(archive.read(f"{root}/Info.plist"))
        expected = {"CFBundleIdentifier": "dev.maipag.app", "CFBundleExecutable": "MAIPA-G"}
        for key, value in expected.items():
            if info.get(key) != value:
                fail(f"{key} is {info.get(key)!r}, expected {value!r}")
        if args.build and str(info.get("CFBundleVersion")) != args.build:
            fail(f"build is {info.get('CFBundleVersion')!r}, expected {args.build!r}")
        if args.version and info.get("CFBundleShortVersionString") != args.version:
            fail(f"version is {info.get('CFBundleShortVersionString')!r}, expected {args.version!r}")
        if info.get("UIDeviceFamily") != [1]:
            fail(f"UIDeviceFamily is {info.get('UIDeviceFamily')!r}, expected [1]")
        schemes = [scheme for item in info.get("CFBundleURLTypes", []) for scheme in item.get("CFBundleURLSchemes", [])]
        if "maipag" not in schemes:
            fail("maipag URL scheme is missing")
        backgrounds = set(info.get("UIBackgroundModes", []))
        if not {"processing", "fetch"}.issubset(backgrounds):
            fail(f"background declarations are incomplete: {sorted(backgrounds)}")
        icon = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName")
        if icon != "AppIcon":
            fail(f"compiled app icon is not assigned: {icon!r}")
        privacy = plistlib.loads(archive.read(f"{root}/PrivacyInfo.xcprivacy"))
        if privacy.get("NSPrivacyTracking") is not False or "NSPrivacyAccessedAPITypes" not in privacy:
            fail("privacy manifest is incomplete")

        executable = archive.read(f"{root}/MAIPA-G")
        if len(executable) < 12:
            fail("executable is too small")
        magic = executable[:4]
        arm64 = 0x0100000C
        if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
            endian = "<" if magic == b"\xcf\xfa\xed\xfe" else ">"
            if struct.unpack(endian + "I", executable[4:8])[0] != arm64:
                fail("Mach-O executable is not arm64")
        elif magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xca\xfe"):
            endian = ">" if magic == b"\xca\xfe\xba\xbe" else "<"
            count = struct.unpack(endian + "I", executable[4:8])[0]
            cpus = [struct.unpack(endian + "I", executable[8 + index * 20:12 + index * 20])[0] for index in range(count)]
            if arm64 not in cpus:
                fail("fat Mach-O executable has no arm64 slice")
        else:
            fail(f"executable has unknown Mach-O magic {magic.hex()}")

        print(f"checked {args.ipa}: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), iPhone arm64, {len(names)} entries")


if __name__ == "__main__":
    main()
