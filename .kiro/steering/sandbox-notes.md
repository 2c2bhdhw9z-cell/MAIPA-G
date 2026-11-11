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
- Releases are automatic; never make or publish one by hand. The flow:
  - `ios.yml` runs on every push to `main` (no paths filter), on pull requests, and on
    `workflow_dispatch`. Runs on `main` are never cancelled (only superseded PR runs are), so
    two quick pushes both finish and the newest one is always released.
  - A push whose tree is identical to a merged PR head that already has a green iOS run with
    unexpired artifacts doesn't build again: its `reuse` job finds that run and the build jobs
    are skipped. A merged PR therefore builds once, on the PR.
  - `release.yml` follows every finished iOS run on `main` (`workflow_run`) and can be started
    by hand with an optional `sha`. One Release run per commit (concurrency group per sha), so
    a later commit's run never cancels an earlier one's publish. It publishes only from a green
    run on that exact tree: the commit's own run, or an identical-tree PR head's run
    (`scripts/publish-verified-ipa.sh` re-checks PR tree == main tree before uploading).
  - Started by hand for the head of `main` with no green run, Release dispatches `ios.yml` on
    `main` and waits. For an older commit it pushes a temporary tag `check-<sha12>-<run id>`,
    dispatches `ios.yml` on that tag, waits up to 85 minutes, then deletes the tag; a refusal
    or failure is reported with the run's link and result. An older build is published with
    `--latest=false`, so it never replaces the newest release.
  - A commit that is already published is skipped, so re-running Release never duplicates.
  - Never put the skip-CI marker text anywhere in a commit message: GitHub skips the push run
    when it appears anywhere, and that commit then gets no checked build.
- The three shell-command tests hang on GitHub's Mac, so they run on Linux only.
- To check the iPhone build before anything reaches `main` (no branches, no PRs): push a tag
  `check-<sha12>-kiro` for the commit and dispatch `ios.yml` on it
  (`gh api -X POST …/actions/workflows/ios.yml/dispatches -f ref=<tag>`). Release only publishes
  commits on `main`, so a tag run is a check only. Delete the tag afterwards.
- Scripts run by AgentCore tests also run on GitHub's Mac: no `stat -c` or `base64 -w0` there
  (use `wc -c < f` and `base64 | tr -d '\n'`).

## The sandbox itself
- `/tmp` doesn't last from one command to the next. Keep scratch files in `/projects/sandbox/`
  (outside the repo) and delete them afterwards.
- The Playwright tool's browser can't reach the sandbox's localhost. To test the Pages site,
  serve the files with `page.route`. Its code runs without `URL` and `URLSearchParams`, so parse
  addresses with plain string functions. It only loads script files from
  `/projects/sandbox/.kiro/artifacts/screenshots/`.
- AgentCore builds and tests here (`swift test --package-path AgentCore`). The app itself only
  builds on GitHub's Mac runners; the PR check also takes simulator screenshots of every screen.
