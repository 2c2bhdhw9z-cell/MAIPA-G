#!/usr/bin/env python3
"""Fail when workflow dependencies drift back to moving or incomplete release gates."""
import json
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
# Every iOS job checks out the exact PR head, never GitHub's temporary merge commit, and the IPA
# must embed that revision: Autonomous callers download runner-<revision>.
head_ref = "ref: ${{ github.event.pull_request.head.sha || github.sha }}"
if ios.count("uses: actions/checkout@") != ios.count(head_ref):
    errors.append("ios.yml: every checkout must use the exact PR head")
for expected in ('MAIPAG_REVIEWED_REVISION: ${{ github.event.pull_request.head.sha || github.sha }}', '--revision "${{ github.event.pull_request.head.sha || github.sha }}"'):
    if expected not in ios:
        errors.append(f"ios.yml: must pin the reviewed revision: {expected}")
if '--revision "$PR_HEAD"' not in (ROOT / "scripts/publish-verified-ipa.sh").read_text():
    errors.append("publish-verified-ipa.sh: must check the IPA's reviewed revision")
for expected in (
    "XcodeGen/releases/download/2.46.0/xcodegen.zip",
    "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
):
    if ios.count(expected) != 1:
        errors.append(f"ios.yml: the macOS job must use locked XcodeGen metadata: {expected}")
agent = (ROOT / ".github/workflows/agent.yml").read_text()
for forbidden in ("swift run --package-path", "git clone --depth 1 --branch main"):
    if forbidden in agent:
        errors.append(f"agent.yml: checked runner regressed to {forbidden}")
for required in ("runner-$MAIPAG_REVISION", "sha256sum -c", "MAIPAGRunner-linux-x86_64.tar.gz"):
    if required not in agent:
        errors.append(f"agent.yml: missing checked prebuilt runner requirement {required}")
release = (ROOT / "scripts/publish-verified-ipa.sh").read_text()
for required in ("AgentCore tests (Linux)", "iPhone release candidate"):
    if required not in release:
        errors.append(f"publish-verified-ipa.sh: missing release gate {required}")
manifest = json.loads((ROOT / "docs/regressions/2026-10-29.json").read_text())
reports = manifest.get("reports", [])
expected_ids = {f"OCT29-{number:02d}" for number in range(1, 19)}
actual_ids = {item.get("id") for item in reports}
if actual_ids != expected_ids or len(reports) != 18:
    errors.append("29 October regression manifest must contain OCT29-01 through OCT29-18 exactly once")
evidence_text = "\n".join(
    path.read_text(errors="ignore")
    for folder in (ROOT / "AgentCore/Tests", ROOT / "scripts", ROOT / ".kiro/notes")
    for path in folder.rglob("*") if path.is_file()
)
for item in reports:
    status = item.get("status")
    evidence = item.get("evidence", "")
    if status not in {"covered", "owner-waived"}:
        errors.append(f"{item.get('id')}: invalid regression status {status}")
    if evidence not in evidence_text:
        errors.append(f"{item.get('id')}: evidence not found: {evidence}")

# The app only runs the computer setup script whose SHA-256 it was built with.
import hashlib
setup_sha = hashlib.sha256((ROOT / "docs/computer/setup.sh").read_bytes()).hexdigest()
prompt = (ROOT / "AgentCore/Sources/AgentCore/Agent/SystemPrompt.swift").read_text()
if f'computerSetupSHA256 = "{setup_sha}"' not in prompt:
    errors.append(f"SystemPrompt.computerSetupSHA256 must be {setup_sha}, the SHA-256 of docs/computer/setup.sh")
setup = (ROOT / "docs/computer/setup.sh").read_text()
for moving in ("setup_lts", "sh.rustup.rs", "dot.net/v1", "bun.sh/install", "deno.land/install", "astral.sh/uv/install", "install latest", "playwright install"):
    if moving in setup:
        errors.append(f"docs/computer/setup.sh: unpinned installer {moving}")
if "verified_fetch" not in setup:
    errors.append("docs/computer/setup.sh: downloads must go through verified_fetch")

if errors:
    raise SystemExit("\n".join(errors))
print("CI supply-chain pins and release gates are complete")
