#!/usr/bin/env python3
"""Focused regression checks for the 29 October reports whose fixes live in the iPhone UI.

The Linux test job can't render SwiftUI, so these read the shipped sources and assets directly.
Each check names its report (OCT29-xx) in docs/regressions/2026-10-29.json.
"""
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
failures: list[str] = []


def body_of(source: str, struct_name: str) -> str:
    start = source.find(f"struct {struct_name}")
    if start < 0:
        failures.append(f"struct {struct_name} is missing")
        return ""
    following = source.find("\nstruct ", start + 1)
    return source[start: following if following > 0 else len(source)]


def check_oct29_01_real_connector_logos() -> None:
    """Report 1: every built-in connector shows the company's own full-colour logo on a plain tile."""
    assets = ROOT / "App/Resources/Assets.xcassets"
    sets = sorted(assets.glob("Integration*.imageset"))
    if len(sets) < 18:
        failures.append(f"OCT29-01: expected at least 18 connector logos, found {len(sets)}")
    for image_set in sets:
        contents = json.loads((image_set / "Contents.json").read_text())
        files = [image.get("filename") for image in contents.get("images", []) if image.get("filename")]
        if len(files) < 2:
            failures.append(f"OCT29-01: {image_set.name} has no 2x/3x artwork")
        if contents.get("properties", {}).get("template-rendering-intent") == "template":
            failures.append(f"OCT29-01: {image_set.name} is a one-colour template, not the real logo")
        for name in files:
            data = (image_set / name).read_bytes()
            if data[:8] != b"\x89PNG\r\n\x1a\n":
                failures.append(f"OCT29-01: {image_set.name}/{name} isn't a PNG")
                continue
            color_type = data[25]
            if color_type not in (2, 3, 6):
                failures.append(f"OCT29-01: {image_set.name}/{name} is greyscale, not full colour")
    screen = (ROOT / "App/Sources/Screens/ConnectorsScreen.swift").read_text()
    icon = body_of(screen, "IntegrationIcon")
    if ".renderingMode(.original)" not in icon:
        failures.append("OCT29-01: IntegrationIcon must draw logos in their original colours")
    if ".fill(Theme.raised)" not in icon or "service.colour.opacity" in icon:
        failures.append("OCT29-01: IntegrationIcon must use a plain tile, not a brand-tinted one")


def check_oct29_04_tool_bars_hug_their_content() -> None:
    """Report 4: tool bars end right after their arrow instead of stretching across the chat."""
    source = (ROOT / "App/Sources/Screens/MessageViews.swift").read_text()
    for name in ("ToolCallsFold", "ToolLine"):
        body = body_of(source, name)
        chevron = body.find('"chevron.')
        background = body.find(".background(Theme.surface")
        if chevron < 0 or background < 0:
            failures.append(f"OCT29-04: {name} lost its chevron or bar background")
            continue
        bar = body[body.rfind("HStack", 0, chevron): background]
        # Nothing inside the bar (from its HStack to its background) may stretch it.
        if "Spacer(" in bar or ".frame(maxWidth: .infinity" in bar:
            failures.append(f"OCT29-04: {name} has a Spacer or full-width frame inside its bar, which stretches it across the screen")
        if ".frame(maxWidth: .infinity, alignment: .leading)" not in body:
            failures.append(f"OCT29-04: {name} must leave the free width outside the bar, aligned to the leading edge")


check_oct29_01_real_connector_logos()
check_oct29_04_tool_bars_hug_their_content()
if failures:
    raise SystemExit("\n".join(failures))
print("29 October UI regression checks passed (OCT29-01, OCT29-04)")
