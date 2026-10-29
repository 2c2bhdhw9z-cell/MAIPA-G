#!/usr/bin/env bash
# Publishes the already-checked ready-PR artifact after proving the squash merge has the same tree.
set -euo pipefail

[ "$#" -eq 3 ] || { echo "usage: $0 <run-id> <pr-head-sha> <main-sha>" >&2; exit 2; }
RUN_ID="$1"; PR_HEAD="$2"; MAIN_SHA="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GH_REPO:-2c2bhdhw9z-cell/MAIPA-G}"

PR_TREE="$(gh api "repos/$REPO/git/commits/$PR_HEAD" --jq .tree.sha)"
MAIN_TREE="$(gh api "repos/$REPO/git/commits/$MAIN_SHA" --jq .tree.sha)"
[ "$PR_TREE" = "$MAIN_TREE" ] || { echo "error: PR and main trees differ" >&2; exit 1; }
[ "$(gh api "repos/$REPO/commits/$MAIN_SHA" --jq .sha)" = "$MAIN_SHA" ] || { echo "error: main commit was not found" >&2; exit 1; }

RUN="$(gh api "repos/$REPO/actions/runs/$RUN_ID")"
RUN_SHA="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["head_sha"])' <<<"$RUN")"
RUN_NUMBER="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["run_number"])' <<<"$RUN")"
[ "$RUN_SHA" = "$PR_HEAD" ] || { echo "error: run did not check the PR head" >&2; exit 1; }
[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("conclusion"))' <<<"$RUN")" = "success" ] || { echo "error: run is not green" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ARTIFACT_ID="$(gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[] | select(.name|startswith("MAIPA-G-ipa-")) | .id' | head -n1)"
[ -n "$ARTIFACT_ID" ] || { echo "error: no IPA artifact on run" >&2; exit 1; }
gh api "repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" -H 'Accept: application/octet-stream' >"$TMP/artifact.zip"
unzip -q "$TMP/artifact.zip" -d "$TMP/artifact"
IPA="$(find "$TMP/artifact" -name 'MAIPA-G.ipa' -type f -print -quit)"
[ -n "$IPA" ] || { echo "error: artifact contains no MAIPA-G.ipa" >&2; exit 1; }
python3 "$ROOT/scripts/check-ipa.py" "$IPA" --build "$RUN_NUMBER"
cp "$IPA" "$TMP/MAIPA-G.ipa"; cp "$IPA" "$TMP/MAIPA-G-$RUN_NUMBER.ipa"
TAG="build-$RUN_NUMBER-${MAIN_SHA:0:7}"
NOTES="$TMP/notes.md"
printf '**MAIPA-G** checked by iOS run %s and published from main commit `%s`.\n\nAlways newest: https://github.com/%s/releases/latest/download/MAIPA-G.ipa\n' "$RUN_ID" "$MAIN_SHA" "$REPO" >"$NOTES"
gh release create "$TAG" "$TMP/MAIPA-G.ipa" "$TMP/MAIPA-G-$RUN_NUMBER.ipa" --repo "$REPO" --target "$MAIN_SHA" --title "MAIPA-G build $RUN_NUMBER" --notes-file "$NOTES"
echo "published $TAG from verified tree $MAIN_TREE"
