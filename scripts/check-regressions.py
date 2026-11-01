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
    if len(sets) < 107:
        failures.append(f"OCT29-01: expected at least 107 connector logos, found {len(sets)}")
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

    # Every single entry in IntegrationCatalog.all must specify a real bundled assetName on disk.
    catalog_src = (ROOT / "AgentCore/Sources/AgentCore/MCP/BuiltinIntegrationTools.swift").read_text()
    entries = re.findall(r'\.init\(id:\s*"([^"]+)"[^\n]+', catalog_src)
    if len(entries) != 81:
        failures.append(f"OCT29-01: expected exactly 81 working IntegrationCatalog entries, found {len(entries)}")
    for line_match in re.finditer(r'\.init\(id:\s*"([^"]+)"([^\n]+)', catalog_src):
        cid, rest = line_match.group(1), line_match.group(2)
        m_asset = re.search(r'assetName:\s*"([^"]+)"', rest)
        if not m_asset:
            failures.append(f"OCT29-01: IntegrationCatalog '{cid}' is missing assetName (no SF Symbol stand-ins allowed)")
            continue
        asset_dir = assets / f"{m_asset.group(1)}.imageset"
        if not asset_dir.is_dir():
            failures.append(f"OCT29-01: IntegrationCatalog '{cid}' references missing {asset_dir.name}")

    screen = (ROOT / "App/Sources/Screens/ConnectorsScreen.swift").read_text()
    icon = body_of(screen, "IntegrationIcon")
    if ".renderingMode(.original)" not in icon:
        failures.append("OCT29-01: IntegrationIcon must draw logos in their original colours")
    if "Image(systemName:" in icon:
        failures.append("OCT29-01: IntegrationIcon must never draw generic SF Symbol stand-ins")
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


def check_oct31_build67_workstation_photos_sources_and_models() -> None:
    """Build 67: Workstation Canvas+Files+Changes, Grok photo stack, Arena chips, Sources pill, 81 connectors, all-model search."""
    connectors = (ROOT / "App/Sources/Screens/ConnectorsScreen.swift").read_text()
    if 'case all = "All"' in connectors or "Open MCP Registry" in connectors:
        failures.append("OCT31-01: ConnectorsScreen still shows the uncurated All / Open MCP Registry tab")

    composer = (ROOT / "App/Sources/Screens/Composer.swift").read_text()
    if "ArenaComposerAttachmentChip" not in composer:
        failures.append("OCT31-02: Composer is missing ArenaComposerAttachmentChip")

    media = (ROOT / "App/Sources/Screens/ChatMediaAndSources.swift").read_text()
    for required in ("struct GrokPhotoStackView", "struct TurnSourcesPill", "struct TurnSourcesSheet", "enum MessageTimestampFormatter"):
        if required not in media:
            failures.append(f"OCT31-03: ChatMediaAndSources is missing {required}")

    workstation = (ROOT / "App/Sources/Screens/WorkstationScreen.swift").read_text()
    for required in ('case canvas = "Canvas"', 'case files = "Files"', 'case changes = "Changes"', "CanvasDotGrid", "WorkstationCanvasCard"):
        if required not in workstation:
            failures.append(f"OCT31-04: WorkstationScreen is missing {required}")

    pickers = (ROOT / "App/Sources/Screens/Pickers.swift").read_text()
    if "guard !model.isRouter else { return false }" in pickers:
        failures.append("OCT31-05: ModelPicker still hides openrouter/* models from search")
    if "allSelectableModels" not in pickers:
        failures.append("OCT31-05: ModelPicker is not searching allSelectableModels")

    chat = (ROOT / "App/Sources/Screens/ChatScreen.swift").read_text()
    if "jumpToBottom(proxy)" not in chat or "BottomScrollTrackingModifier" not in chat:
        failures.append("OCT31-06: ChatScreen is missing reliable jumpToBottom scroll wiring")


def check_oct31_build70_buttons_github_and_ai_providers() -> None:
    """Build 70: 44pt button hit shapes, fitted ZoomableImageCanvas, Arrange+Center, ScrollPosition ↓, working GitHub connector, and 5 real AI provider logos."""
    assets = ROOT / "App/Resources/Assets.xcassets"
    for provider_asset in ("ProviderOpenRouter", "ProviderOneProvider", "ProviderSayGM", "ProviderTeamoRouter", "ProviderOmniRoute"):
        iset = assets / f"{provider_asset}.imageset"
        if not iset.is_dir():
            failures.append(f"OCT31-07: missing bundled logo asset {provider_asset}.imageset")
            continue
        contents = json.loads((iset / "Contents.json").read_text())
        for img in contents.get("images", []):
            fn = img.get("filename")
            if fn and (iset / fn).read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                failures.append(f"OCT31-07: {provider_asset}/{fn} is not a valid PNG")

    media = (ROOT / "App/Sources/Screens/ChatMediaAndSources.swift").read_text()
    if "struct ZoomableImageCanvas" not in media or "ScrollView([.horizontal, .vertical])" in media:
        failures.append("OCT31-08: AttachmentDataPreviewBody must use fitted ZoomableImageCanvas instead of unbounded 2D ScrollView")

    workstation = (ROOT / "App/Sources/Screens/WorkstationScreen.swift").read_text()
    if "arrangeAllCards" not in workstation or "centerOnCards" not in workstation:
        failures.append("OCT31-09: WorkstationScreen must offer Arrange + Center canvas actions")

    home = (ROOT / "App/Sources/Screens/HomeScreen.swift").read_text()
    menu_btn = body_of(home, "MenuButton")
    if ".contentShape(Circle())" not in menu_btn:
        failures.append("OCT31-10: MenuButton must define a full Circle() hit target")

    chat = (ROOT / "App/Sources/Screens/ChatScreen.swift").read_text()
    if "scrollPosition.scrollTo(edge: .bottom)" not in chat:
        failures.append("OCT31-11: ChatScreen ↓ button must drive ScrollPosition(edge: .bottom)")

    builtin = (ROOT / "AgentCore/Sources/AgentCore/MCP/BuiltinIntegrationTools.swift").read_text()
    if "api.githubcopilot.com" in builtin:
        failures.append("OCT31-12: GitHub connector regressed to broken api.githubcopilot.com OAuth URL")


def check_oct31_build76_kiro_arena_all_providers() -> None:
    """Build 76: Global drawer closeDrag, uncapped context/Max thinking, structured AI compaction + undo, live steering, Mermaid cache, multi-col Arrange, clean Sources."""
    root_view = (ROOT / "App/Sources/Screens/RootView.swift").read_text()
    if "DragGesture(minimumDistance: 8, coordinateSpace: .global)" not in root_view:
        failures.append("OCT31-13: RootView.closeDrag must use .global coordinateSpace to prevent drawer feedback oscillation")

    router = (ROOT / "AgentCore/Sources/AgentCore/Agent/ModelRouter.swift").read_text()
    if "300_000" in router or "* 0.75" in router:
        failures.append("OCT31-14: ModelRouter still contains hardcoded 300K / 0.75x artificial context caps")

    chat_session = (ROOT / "App/Sources/Model/ChatSession.swift").read_text()
    for required in ("performStructuredCompaction", "restoreFullMemory", "queuedSteering", "LaunchHelpersTool("):
        if required not in chat_session:
            failures.append(f"OCT31-15: ChatSession is missing {required}")
    if "18_000" in chat_session:
        failures.append("OCT31-15: ChatSession still contains the old 18_000-character fake prefix chopper")

    composer = (ROOT / "App/Sources/Screens/Composer.swift").read_text()
    if "Restore full memory" not in composer or "Steer running reply" not in composer:
        failures.append("OCT31-16: Composer is missing Restore full memory undo or live mid-run steering send button")

    mermaid = (ROOT / "App/Sources/Screens/MermaidDiagramView.swift").read_text()
    if "MermaidSnapshotCache" not in mermaid or "takeSnapshot" not in mermaid:
        failures.append("OCT31-17: MermaidDiagramView must snapshot-cache rendered diagrams so scrolling never blanks them out")

    workstation = (ROOT / "App/Sources/Screens/WorkstationScreen.swift").read_text()
    if "idealGridColumns" not in workstation or "stagedWorkstationItems" not in workstation or "saveViewport" not in workstation:
        failures.append("OCT31-18: WorkstationScreen must support multi-column grid, persisted viewport, and live staged files")

    chat_screen = (ROOT / "App/Sources/Screens/ChatScreen.swift").read_text()
    if "geo.contentInsets.bottom" in chat_screen:
        failures.append("OCT31-19: ChatScreen BottomScrollTrackingModifier regressed to double-subtracting contentInsets.bottom")
    if "savedFollowsBottom" not in chat_screen:
        failures.append("OCT31-19: ChatScreen must preserve scroll position across chat switches")

    sources = (ROOT / "App/Sources/Screens/ChatMediaAndSources.swift").read_text()
    if 'lowerName.contains("search")' in sources:
        failures.append("OCT31-20: TurnSourceItem still matches search_code via substring 'search'")


def check_oct31_build81_subagent_cards_and_crash_safety() -> None:
    """Build 81: Kiro SubagentCardsGroupView in chat, zero values[index]! crash, cold-launch settle, nonisolated system callbacks."""
    message_views = (ROOT / "App/Sources/Screens/MessageViews.swift").read_text()
    for required in ("struct SubagentCardsGroupView", "case subagents(ToolCallRecord)", "SubagentRunItem.resolvedItems(for: call)"):
        if required not in message_views:
            failures.append(f"OCT31-21: MessageViews is missing {required}")

    agent_exec = (ROOT / "AgentCore/Sources/AgentCore/Agents/AgentExecutor.swift").read_text()
    if "values[index]!" in agent_exec:
        failures.append("OCT31-22: AgentExecutor still contains unsafe values[index]! force-unwrap")

    chat_lib = (ROOT / "App/Sources/Model/ChatLibrary.swift").read_text()
    load_start = chat_lib.find("func load()")
    reload_start = chat_lib.find("func reloadFromDisk()")
    load_body = chat_lib[load_start:reload_start] if load_start >= 0 and reload_start > load_start else ""
    if "settleInterruptedTurnOnLaunch()" not in load_body or "resumeInterruptedTurn()" in load_body:
        failures.append("OCT31-23: ChatLibrary.load() must settle cold-launch interrupted turns instead of auto-resuming crash loops")

    bg_jobs = (ROOT / "App/Sources/Support/BackgroundJobs.swift").read_text()
    if "nonisolated private static func registerSystemTasks" not in bg_jobs:
        failures.append("OCT31-24: BackgroundJobs must register BGTaskScheduler handlers from a nonisolated context")

    notifications = (ROOT / "App/Sources/Support/Notifications.swift").read_text()
    pic_viewer = (ROOT / "App/Sources/Screens/PictureViewer.swift").read_text()
    if "nonisolated private static func ignoreAuthorizationResult" not in notifications:
        failures.append("OCT31-25: Notifications must use a nonisolated authorization completion handler")
    if "nonisolated private static func addPhoto" not in pic_viewer:
        failures.append("OCT31-25: PictureViewer must run PhotoKit callbacks from nonisolated helpers")


check_oct29_01_real_connector_logos()
check_oct29_04_tool_bars_hug_their_content()
check_oct31_build67_workstation_photos_sources_and_models()
check_oct31_build70_buttons_github_and_ai_providers()
check_oct31_build76_kiro_arena_all_providers()
check_oct31_build81_subagent_cards_and_crash_safety()
if failures:
    raise SystemExit("\n".join(failures))
print("UI regression checks passed (OCT29-01, OCT29-04, OCT31-01..25)")
