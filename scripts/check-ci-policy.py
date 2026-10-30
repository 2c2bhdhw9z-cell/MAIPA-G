#!/usr/bin/env python3
"""Fail when workflow dependencies drift back to moving or incomplete release gates."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
errors: list[str] = []
for workflow in sorted((ROOT / ".github/workflows").glob("*.yml")):
    text = workflow.read_text()
    for line_number, line in enumerate(text.splitlines(), 1):
        match = re.search(r"\buses:\s*([^\s#]+)", line)
        if not match:
            continue
        value = match.group(1)
        if value.startswith("./"):
            continue
        ref = value.rsplit("@", 1)[-1]
        if not re.fullmatch(r"[0-9a-f]{40}", ref):
            errors.append(f"{workflow.relative_to(ROOT)}:{line_number}: external action is not pinned to a commit: {value}")

ios = (ROOT / ".github/workflows/ios.yml").read_text()
if "needs: [checks, screens]" not in ios:
    errors.append("ios.yml: IPA job must require checks and screens")
for expected in (
    "XcodeGen/releases/download/2.46.0/xcodegen.zip",
    "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
):
    if ios.count(expected) != 2:
        errors.append(f"ios.yml: both macOS jobs must use locked XcodeGen metadata: {expected}")
release = (ROOT / "scripts/publish-verified-ipa.sh").read_text()
for required in ("AgentCore tests (Linux)", "Complete Dark and Light screenshots", "iPhone release candidate"):
    if required not in release:
        errors.append(f"publish-verified-ipa.sh: missing release gate {required}")
if errors:
    raise SystemExit("\n".join(errors))
print("CI supply-chain pins and release gates are complete")
