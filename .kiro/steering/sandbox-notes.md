---
inclusion: always
---

# Working notes for Kiro in the Kiro Web sandbox (for Kiro; the owner doesn't read these)

Things that cost time to find out. Keep them short and true.

## GitHub from the sandbox
- Open every pull request as ready, never as a draft. GraphQL is blocked here, and only GraphQL
  can turn a draft into a ready one. (Build 1's draft needed a throwaway workflow running
  `gh pr ready` with `contents: write` and `pull-requests: write`.)
- `gh pr`, `gh issue` and `gh api graphql` don't work. Use `gh api` REST calls.
- Start a workflow by hand with
  `gh api -X POST repos/2c2bhdhw9z-cell/MAIPA-G/actions/workflows/ios.yml/dispatches -f ref=<branch>`.
  `gh workflow run` fails, and a workflow GitHub has never run can't be started this way (404).
- Logs: `gh run view <id> -R 2c2bhdhw9z-cell/MAIPA-G --log` (without `-R` it can't find the repo).
- Artifacts: `gh api repos/2c2bhdhw9z-cell/MAIPA-G/actions/artifacts/<id>/zip > x.zip`
  (`gh run download` gives 401).
- The sandbox can't change repo settings that need admin rights (turning on GitHub Pages gave
  403). Neither can a workflow's own token. Only the owner can, in the repo's Settings.
- Releases: the sandbox can create a release but can't upload files to it (uploads.github.com
  gives 400). A workflow's token can upload files but gets 403 creating the release. So: make the
  release as a draft from the sandbox (`gh api -X POST .../releases`, tag `build-<run>-<sha7>`),
  dispatch release.yml with run_id, pr_head and main_sha (it attaches the checked .ipa), then
  publish the draft (`PATCH .../releases/<id> -F draft=false -f make_latest=true`).
- The three shell-command tests hang on GitHub's Mac, so they run on Linux only.

## The sandbox itself
- `/tmp` doesn't last from one command to the next. Keep scratch files in `/projects/sandbox/`
  (outside the repo) and delete them afterwards.
- The Playwright tool's browser can't reach the sandbox's localhost. To test the Pages site,
  serve the files with `page.route`. Its code runs without `URL` and `URLSearchParams`, so parse
  addresses with plain string functions. It only loads script files from
  `/projects/sandbox/.kiro/artifacts/screenshots/`.
- AgentCore builds and tests here (`swift test --package-path AgentCore`). The app itself only
  builds on GitHub's Mac runners; the PR check also takes simulator screenshots of every screen.
