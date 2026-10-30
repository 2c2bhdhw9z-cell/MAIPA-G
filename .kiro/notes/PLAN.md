# MAIPA-G plan

**Status (30 October 2026, 7:45 PM ET): Build 61 (`build-61-f874a6b`, 5.1 MB, PR #17) is the latest
installable build: 0.1.0 (61), iPhone arm64, built from commit `5d3a5c5`, checked by the AgentCore
tests on Linux and macOS and an independent IPA inspection.

Confirmed on the owner's phone with build 55 (4:04 PM), build 59 (6:42 PM), and build 60 (7:20 PM):
saving works (Settings and the side menu showed "Saved just now", and the 173 MB Continuum .ipa is
in MAIPA-G-data's files release), the chat computer ran a real command through Sprites' `exec` (with
all green checks on GitHub, OpenRouter, Saving, Hugging Face, Sprites MCP Server, and GitHub Actions),
the clean Home screen and `+` menu are live, huge pastes turn into `Pasted text.txt` attachments,
and keyboard dismissal works without the `Done` button. Stability 3 is done.

Built since then:
- Build 56 (PR #12): Check everything, Recently Deleted and Unreadable files open inside Settings;
  the Computer list shows only connectors that can run commands; tool setup starts by itself.
- Build 57 (PR #13): the Sprite is held awake with Sprites' Tasks API while tools install (a Sprite
  pauses 30 seconds after the last command, which froze build 56's setup); Check everything shows
  the setup step and any tools that failed; Hugging Face's sandbox tool doesn't make it a computer;
  Edit memories opens inside Settings.
- Build 58 (PR #14, confirmed working on phone): chats work again after capping OpenRouter `models`
  at 3 items.
- Build 59 (PR #15, confirmed on phone): upgraded chat and Autonomous system prompts; folded the
  Home shortcut strip and the row under the message box into the `+` menu, aligned the AI/Thinking
  pills, and moved OpenRouter balance to the side menu and context ring popover; capped long user
  bubbles with a chunked `Full message` sheet, auto-converted 20,000+ character pastes into text
  attachments with paginated `read_attachment` up to 25 MB, and stopped dropped server connections
  from falsely claiming `This iPhone is offline`.
- Build 60 (PR #16, confirmed on phone): moved memory stars off message text (beside user bubbles
  and into the bottom footer of AI replies); moved the unlabeled top-bar `Compact` icon into the
  `+` menu and Context ring popover with plain-English status; added live status and a direct
  download button under `Check for a new build` in Settings; removed the floating keyboard `Done`
  pill and added app-wide keyboard dismissal on downward swipe, outside tap, or screen/sheet
  switches.
- Build 61 (PR #17): kept the chat computer (`mcp-maipa-g`) awake until its one-time tool install
  finishes (added `POST /v1/tasks`, `sprite-env curl`, `sudo curl`, and `/.sprite/bin` to
  `setup.sh`, plus an automatic 20-second app-side keep-awake ping while setup runs, live 15-second
  step refresh in `Check everything`, and recursive JSON output parsing so `Now: …` always shows);
  enabled selecting multiple photos (up to 20, ordered) and multiple files at once in the `+` menu;
  changed Side Menu `Agents` and `Workflows` taps to open runnable detail screens with plain-English
  explanations instead of `… copy` editors (with swipe-to-delete on custom copies); and fixed
  swipe-to-delete buttons to be red (`Theme.danger`, `allowsFullSwipe: false`) and replaced broken
  iOS 26 floating speech-bubble confirmation popovers with centered alerts that always include a
  `Cancel` button.

Still not done: Stability 11 (about 250 silent `try?` failures remain), necessary item 4 (sandbox
for downloaded connectors blocks all network, so npx/uvx connectors can't install), and necessary
item 6's leak test (deleted on the owner's order). Waiting on the phone: Stability 10, 31, 33, 34
and 35 (chat-computer features) and 14 (the owner has to add the GitHub app's Plan permission).
Cancelled by the owner: Stability 40 and necessary item 8 (the screenshot job was deleted at 2:40
PM). The 37 items finished before noon were spot-checked, not re-audited sentence by sentence.**

## Tools MAIPA-G must have (owner, 29 October 2026, 4:30 PM)
He listed Arena's agent tools (bash, write_file, web_search, read_file, fetch_page, list_files,
ask_user, generate_image) and Kiro's (read_file, list_directory, file_search, grep_search, code,
fs_write, str_replace, fs_append, delete_file, execute_bash, remote_web_search, web_fetch,
invoke_sub_agent, disclose_context, introspect): **"Whatever tools it doesn't have I want."**
- Already in every chat: read_file (text), list_files (also finds files by name pattern, like
  file_search), search_code, create_file, edit_file, delete_file, save_changes, web_search,
  read_web_page, ask_user, generate_image, add_memory/edit_memory, read_attachment, connector
  tools. `launch_helpers` exists, but only for agents and workflows. `run_shell` exists, but only
  in Autonomous.
- To add to every chat:
  1. **run_command** (bash / execute_bash): a real shell on the chat computer (report 5's design).
  2. **append_file** (fs_append).
  3. **Images in read_file**: show repo pictures (PNG, JPG and so on) to AIs that can see them.
  4. **code**: symbol search, file outlines, structural (AST) search and rewrite across
     languages, plus language-server go-to-definition, references, rename and diagnostics. Runs
     on the chat computer (ast-grep/tree-sitter and language servers), with a simple on-phone
     outline when no computer is set.
  5. **Helpers in chats** (invoke_sub_agent): `launch_helpers` for normal chats, each helper with
     a fresh context.
  6. **load_context** (disclose_context): load `.kiro/steering` files and `.kiro/skills/*/SKILL.md`
     on demand, honouring always/auto/manual inclusion.
  7. **introspect**: answer questions about MAIPA-G itself. Owner picked option 1 (4:40 PM): help
     pages plus live app status. (a) Help pages built into the app, one per screen, button and
     setting, plus how saving, jobs, connectors and the computer work, updated in every build so
     they match the installed version; the tool searches and reads them. (b) A read-only
     live-status tool: what's connected (GitHub, OpenRouter credit, each connector's state), the
     chosen AI, the chat computer setting, saving status with its real error, and the jobs list
     (status, step, run link, failure reason). Never shows tokens or secrets. This also fixes
     report 12.
  8. **Regex search** (grep_search): check that search_code takes regular expressions; add them
     if not. List and search respect .gitignore and .kiroignore.

## Stability list (owner, 29 October 2026, 4:50 PM: "everything else ... that make it work and stable"; not built yet)
On top of reports 5-18 and the tools list. Kiro's suggested order: 1-11 first (no lost work, and
Kiro can read errors itself).
- Data: 1 the new-build check warns when anything isn't backed up (don't delete the app before
  installing); 2 one bad file can't abort the whole DataRepoSync commit (isolate per file, say
  which); 3 big media stored or compressed so it can't break sync, MAIPA-G-data kept small (prune
  old job logs); 4 Recently deleted (30 days) for chats, memories, agents and workflows; 5 Export
  everything to Files (zip); 6 the composer draft (text and attachments) persists; 7 unreadable
  stored files are quarantined, never overwritten.
- Diagnostics: 8 a redacted error log synced to MAIPA-G-data `diagnostics/` so Kiro can read real
  errors; 9 MetricKit crash and hang diagnostics saved the same way; 10 a Settings "Check
  everything" health check (GitHub, OpenRouter, saving, each connector, the computer, Actions)
  with fixes; 11 no catch-all error messages anywhere: always the real cause and the next step.
- Jobs: 12 a prebuilt, checksummed MAIPAGRunner release binary instead of `swift build` on every
  run (~95 s build, ~2.5 min to start); 13 no progress for 10 min → stuck, with Stop and Resume;
  14 show private-repo Actions minutes left (2,000 a month) and warn; 15 auto-update the
  `maipa-g.yml` added to target repos; 16 update `actions/create-github-app-token@v2` in
  `.github/workflows/agent.yml` (Node.js 20 deprecation warning in Built-Helion's run); 17 explain
  iOS's "Task failed" background banner in the app (which job, why).
- AI: 18 OpenRouter fallback models (`models` list) after repeated failures or a removed model,
  with a notice; 19 429 handling with Retry-After, and a clear free-daily-limit message; 20 loop
  guard: repeated identical failing tool calls → change approach or ask_user; 21 unknown tool
  name → reply with the real tool list; 22 cap connector (MCP) tool results (no cap today; repo
  tools have caps); 23 load repo rule documents on demand (today up to 20 × 20,000 characters go
  into every request, `SystemPrompt.swift`).
- Saving changes: 24 a diff view of staged changes (this turn or the whole branch), none today;
  25 a protected branch → side branch and PR automatically; 26 merge conflicts on Add it
  explained, with a fix offered; 27 show PR check status, ask before adding a failing one;
  28 keep line endings and encoding, refuse text edits to binary files; 29 big repos: large
  tarballs, Git LFS, submodules, snapshot cache size shown, low-storage warning, clear cache.
- Computer: 30 a per-command timeout, output cut to head and tail; 31 long commands in the
  background with the computer kept awake (Sprites Tasks API); 32 Stop also kills running
  commands; 33 staged changes synced onto the computer before tests run; 34 auto-recreate a
  missing or broken machine; 35 computer checkpoints (Sprites) and an approximate cost.
- Connectors: 36 refresh OAuth tokens before expiry and reconnect after a restart; 37 send only
  enabled tools, with per-connector tool switches (some connectors expose 50+).
- iPhone: 38 long chats render lazily, with downsampled images; 39 resume an interrupted turn
  when the app comes back; (40, the signing-expiry reminder, was removed by the owner on
  29 October: "No 40".)
- Safety: 41 deleting, direct saves to the default branch, risky commands and spending always ask,
  whatever the wording; 42 tool, web and connector text is data, never orders (prompt-injection
  guard); 43 redact tokens from saved chats (including build 25's clone URL).
- Tests: 44 a regression test for every bug found on 29 October, run in CI.
- From Kiro and Arena: 45 edit and resend an earlier message, retry any answer (rewind), and a
  Compact button; 46 hooks (actions on events, like running the tests after every save).

## Necessary things that were missing from both the app and this plan (30 October 2026)
The owner asked for everything MAIPA-G still needs that was not already planned. Kiro first read
"even in the plans" backwards and repeated the existing plan; this is the corrected, code-checked
list. These 13 requirements are additional to the tools, stability list and reports above.

1. **Clean old Autonomous secrets out of other repos.** Remember which repos received MAIPA-G's
   GitHub, OpenRouter and connector access. When an account or connector is removed or changed,
   Autonomous is disabled, or MAIPA-G is disconnected, delete or replace the affected Actions
   secrets in every repo. Say which cleanup failed and offer Retry. Today removing the last
   connector leaves its old secret behind, and no delete-secret operation exists.
2. **Lock each Autonomous workflow to a reviewed MAIPA-G version.** The small workflow in another
   repo calls an exact checked commit, not moving `main`, and passes only the named MAIPA-G secrets
   it needs, not every secret in that repo. The planned workflow updater advances that locked
   version after review. Today it uses `agent.yml@main` with `secrets: inherit`.
3. **Keep MAIPA-G's credentials away from Autonomous commands.** Model- or repo-chosen commands
   cannot see credential files or their locations. Test the exact environment commands inherit.
   Today the filter removes `OPENROUTER_API_KEY` but leaves `OPENROUTER_API_KEY_FILE`, so a command
   can read the key file.
4. **Put downloaded local connectors in a real sandbox.** Registry packages started through
   `npx` or `uvx` run in OS/container isolation. They cannot read the private checkout, runner or
   secrets unless the owner approves a narrow read-only folder. Limit writable folders, child
   programs, resources and network access. Keep the before/after repo check as an extra safeguard.
5. **Validate connector sign-in addresses before sending credentials.** Every discovered sign-in,
   token and registration address, including its final redirect, must be safe HTTPS with no
   embedded username/password or fragment and the expected relationship to the connector. Never
   follow HTTPS back to HTTP. Test hostile sign-in metadata.
6. **Keep private files out of website previews.** Give preview JavaScript only published website
   files, never the whole project or repo. Block outside network access by default; the owner can
   explicitly allow a host when a site needs it. Test that a preview cannot read a private repo
   file or send it off the phone.
7. **Lock and verify downloaded setup programs and build helpers.** Use reviewed exact versions
   and verify every installer by signature or hash before running it. Lock GitHub Actions to exact
   reviewed versions too. The planned checked MAIPAGRunner covers only that runner; today the
   computer setup also downloads and runs moving "latest" installers, some with full control.
8. **(Cancelled by the owner, 30 October 2026, 2:40 PM: the screenshot job was deleted.)
   Never publish a build unless its complete screen check passed.** Publishing waits for the
   exact build's Linux tests, iPhone build and complete Dark/Light screenshot job. Every expected
   job must exist and pass. Today a release can publish while the screen job failed, stopped or is
   still running.
9. **Make saving a generated picture safe and visible.** Add the iPhone Photos permission text;
   never force-open a missing picture; keep the screen open and show Saved or the real permission
   or write error, with Open Settings when denied. Today Save can terminate the app or look like
   it did nothing.
10. **Handle an empty picture result without crashing.** Check that at least one readable picture
    came back before opening it. If none did, stop loading, keep the prompt and settings, explain
    the failure and offer Retry. Today the screen opens item zero without checking.
11. **Make the side menu correct for VoiceOver.** VoiceOver is the iPhone feature that reads the
    screen aloud. When the menu is closed it must not select invisible menu buttons; when open it
    must not select the covered chat. Move reading focus into the menu and back to its button, and
    let VoiceOver's two-finger Back gesture close it. Ordinary taps and swipes stay unchanged.
12. **Do not announce dead tool rows as buttons.** A tool event with nothing to open is labelled
    information, not a button. A row with details announces Expanded or Collapsed. Today every
    tool row is called a button even when tapping it deliberately does nothing.
13. **Separate Files loading, an empty repo and no search matches.** Show “Opening repo…” only
    during the request, an empty-repo message after a successful empty result, and “No files
    match” when search finds nothing, while preserving Retry for a failed request. Today an empty
    repo spins forever and no search matches give a blank screen.

## Build 24 test reports (29 October 2026, all fixed in build 25)
1. **10:04 AM: the connector logos aren't the real ones.** "CAN I PLEASE JUST HAVE THE NORMAL
   ICONS/LOGOS". He circled the logo column in Discover and compared it with Grok, Claude and a
   third AI app. Build 24 drew one-colour Simple Icons shapes on brand-tinted tiles. The other apps
   show each company's real full-colour logo on a plain tile (Claude and the third app: plain dark
   tile; Grok: each app's own icon). Fix: all 18 get the company's own current official artwork
   (Google's 2026 gradient icons, which Grok shows too), on a plain tile instead of a tinted one.
2. **10:20 AM: Hugging Face is missing, and the list is full of connectors nobody has heard of.**
   Hugging Face's own connector IS in the Registry (`co.huggingface/hf-mcp-server`, "Hugging Face",
   `https://huggingface.co/mcp?login`, active). The Registry's search only matches server names,
   so "Hugging Face" with a space finds nothing, while "hugging" or "huggingface" finds it. It is
   also not in Discover. Fix: search must find well-known services however he types them, with the
   company's own connector first; Hugging Face (and the other well-known ones) belong in Discover
   with real logos; All shouldn't lead with obscure entries.
3. **By 10:43 AM: the chat AI can't count a repo's lines of code.** It answered "I cannot run a
   command like wc -l or build a line-counting tool." He said MAIPA-G must work like Kiro and
   Arena, which can. Cause: a normal phone chat only gets list_files, search_code, read_file,
   read_repo_file, the edit/save tools, web, connectors, memories, pictures and ask_user
   (`App/Sources/Model/ChatSession.swift` ~249-281). The only real shell is `run_shell`
   (`AgentCore/Sources/AgentCore/Jobs/ProcessTool.swift`), which exists only inside an Autonomous
   job on GitHub's Linux computer, and the phone chat's system prompt
   (`AgentCore/Sources/AgentCore/Agent/SystemPrompt.swift`) never tells the AI that computer
   exists. Kiro and Arena give every chat a real computer. Fix: every repo chat gets a real
   command tool on a GitHub Linux computer checked out at the chat's branch, kept running for the
   chat so later commands come back quickly, and the AI is told it has it. Also an instant on-phone
   script runner (JavaScriptCore) over the repo copy for quick jobs like counting lines, which
   also works in chats with no repo (GitHub's terms rule out runners for repo-less work). Works
   now in build 24: switch Autonomous on before asking (a few minutes' wait).
   For comparison (29 October): Arena's Agent Mode computer, measured by the owner in Arena, has
   2 cores, 1.9 GiB memory, no swap and 25 GB disk. It is an E2B Firecracker microVM that starts
   almost at once and pauses/resumes with files and running programs kept. Kiro's sandbox: 8 cores,
   30 GB, 125 GB. GitHub's free Linux computer: 4 cores, 16 GB, 14 GB (public repos) or 2 cores,
   8 GB, 14 GB (private). So power is not the gap; start-up time and keeping work between visits
   are.
   Owner, 29 October: "I don't mind paying". Option: E2B, the company Arena uses. Hobby plan: free
   plus a one-time $100 credit, billed per second only while a computer runs (paused ones are free
   and kept indefinitely), templates up to 8 vCPU / 8 GiB / 10 GiB, 1-hour continuous runs that
   pause/resume resets. About $0.10/h for 2 vCPU plus about $0.016/GiB/h of memory. Asked him:
   (a) E2B, (b) GitHub's free computer, or (c) both, E2B when set up and GitHub otherwise (Kiro's
   pick), and which size (2 cores/2 GB, 2 cores/4 GB or 4 cores/8 GB). He then asked about Kiro's
   own computer: Kiro's sandbox can't be borrowed by other apps, but MAIPA-G could rent the same
   Amazon EC2 m6a.2xlarge (8 vCPU, 32 GiB) for about $0.3456/h on demand while running, plus EBS
   storage (gp3 about $0.08/GB-month, billed even when stopped), with a slower start than E2B and
   an AWS account needed. Offered as choice (d). He then asked which other companies offer this.
   Shortlist given (prices from Fly.io's and Upstash's comparisons of published rates, October
   2026): E2B; Daytona (same rates as E2B, $200 credit, stopped = disk only); Fly.io Sprites
   (8 vCPU, managed memory, 100 GB disk kept forever, pauses ~30 s after idle, warm wake
   100-500 ms with processes kept, cold wake 1-2 s, bills only CPU/memory actually used, $30
   trial, REST `PUT /v1/sprites/<name>` and `POST /v1/sprites/<name>/exec` with a bearer token);
   Vercel Sandbox; Upstash Box; Modal; Amazon EC2. Kiro's pick: Fly.io Sprites, with GitHub's free
   computer as the fallback for people without an account. 11:40 AM: he made a Fly.io account
   to try Sprites. Sprites has its own hosted connector, `https://sprites.dev/mcp`, with OAuth
   (Fly.io sign-in, organization choice, a consent screen that limits it to `mcp-` names by
   default). Its sign-in server accepts Client ID Metadata Documents and dynamic registration, and
   MAIPA-G's `mcp/client.json` is live, so build 24's custom connector (+ in Connectors) should
   sign in. Gave him steps to test it on the public MAIPA-G repo (27,065 lines in 200 text files
   at `0f1160d`).
   **Requirement (owner, 29 October 2026): "I might change the docker/vm/sandbox at any time."**
   The chat computer must not be tied to one company. Build it as one computer interface with
   swappable providers (Sprites first, then E2B, Daytona, GitHub's free computer and others),
   chosen and changed in Settings at any time. The repo on GitHub stays the source of truth, so
   switching only means the new computer copies the repo again.
   11:51 AM: the Sprites test worked in build 24. Through the connector the AI created `mcp-test`,
   cloned MAIPA-G to `/home/MAIPA-G` (204 tracked files) and ran `git ls-files | xargs wc -l`:
   28,925 (that includes binary files; text files alone are about 27,065). Model: Nemotron 3.5
   Super VL (free), $0.00. He had to say "use Sprites". **Requirement (owner): once the computer
   is set, the AI must use it by itself whenever a task needs it, like Kiro, with no "do this on
   the computer" from him.** So the fix sets up the chat's computer automatically (private repos
   included, without exposing his GitHub token to the model) and tells the AI it has it.
   He asked how to pre-install everything Kiro's sandbox has, and more. A Sprite already boots
   Ubuntu 26.04 with Node, Python, Go, Ruby, Rust, Java, Elixir, Docker and coding CLIs. **The fix
   installs one standard tool set on every chat computer automatically, the same on every
   provider:** at least what Kiro's sandbox has (Python with uv/ruff/pytest, Node with
   npm/pnpm/yarn/TypeScript, Java with Gradle/Maven, Rust, Go, Ruby, PHP with Composer, Elixir,
   Swift 6, .NET, Bun, gcc/clang/cmake/make, Git, gh, ripgrep) plus Deno, cloc, sqlite3, jq,
   ImageMagick, ffmpeg and Playwright with Chromium. Install once per computer and keep it. Gave
   him a one-message version to try now on `mcp-test`. 12:20 PM: it worked through the connector
   on the free Nemotron model ($0.00); all 25 are on `mcp-test`. Already on the Sprite: Bun, Deno,
   gcc, clang, make, gh, uv, sqlite3, jq. Added: Swift 6.4.1 (download), .NET 10.0.113, PHP 8.5.4,
   Composer, cmake, cloc, ripgrep, ImageMagick, ffmpeg (apt-get), ruff and pytest (pip3), pnpm,
   yarn, TypeScript and Playwright 1.64.1 with Chromium (npm).
4. **12:06 PM: the tool-call bars are too wide.** He drew a line along the empty part of every
   "1 tool call >" bar and every "Using Sprites MCP Server · exec… ⌄" bar: "Shrink it to match
   wherever the drop thing goes." Cause: `ToolCallsFold` and `ToolLine` in
   `App/Sources/Screens/MessageViews.swift` put `Spacer(minLength: 4)` after the chevron, so the
   rounded `Theme.surface` background stretches across the whole width. Fix: each bar hugs its
   icon, text and arrow and ends right after the arrow (the running spinner sits just after the
   arrow, inside the bar). Long titles still shorten in the middle when they reach the screen
   edge.

## Build 25 test reports (29 October 2026, held until he says he's done testing)
5. **1:46-2:01 PM: the line count works but is slow and fumbles.** In two chats, the free
   Nemotron model answered 27,819 and 27,396 lines after a dozen-plus tool calls each. Cause
   (MAIPA-G's, not the computer's): Sprites' exec tool starts the program directly, not through a
   shell, so `cd`, pipes, redirects, `&&` and wildcards fail unless wrapped in `bash -c`. Our
   prompt never says so, and our own setup line `curl ... | bash` is itself a pipe, so the tool
   setup never ran; the AI then installed PyPI's `cloc` instead of the real one. The AI also has
   to create the machine and clone the repo itself. He showed Kiro's automatic "Session setup /
   Cloning repository" step for comparison. Fix: MAIPA-G's own `run_command` tool, like Kiro's,
   that takes a normal command and runs it as `bash -lc` in the repo folder on the chosen computer
   through a provider adapter (for Sprites, its exec tool, with the argument names read from the
   tool's schema). Before the first command MAIPA-G itself creates the machine, runs the setup
   script and clones or updates the repo. Private repos use the read-only token, which is then
   never shown to the model or saved in the chat. The raw Sprites tools are hidden from the model
   while Sprites is the chat computer.
6. **2:12 PM: he asked me to check the AI's list of nine "tool risks".** All nine are accurate,
   with the right line numbers. These are deliberate: search_code downloads a repo copy on first
   use; list_files stops at 400 lines; inspect_ipa needs the checker file. Two apply to Autonomous
   only: one workspace-changing command at a time, and no commands that move git HEAD. Swift
   missing on `mcp-maipa-g` is report 5 (setup never ran). Possible changes, asked him:
   (a) read_file's 600-line/60,000-character pages could match Kiro's 2,000 lines; (b) free web
   search depends on DuckDuckGo's page layout, so a second free source could back it up;
   (c) approvals for deleting files or changing build setup come from keywords in his message
   (delete, remove, change, edit, update, add, create, with "don't/never/without" handled), which
   unusual wording can fool.
   2:20 PM, its second list, checked: "GenerateImageTool doesn't exist" is wrong (it's at
   `AgentCore/Sources/AgentCore/OpenRouter/OpenRouterImages.swift:73`, and build 25 compiled).
   "Memory tools aren't offered" is wrong for chats (`ChatSession.swift:253-254` adds them to every
   chat; the list it read is the ready-made agents'). The `mcp-` prefix check is only a warning, by
   design. Force-unwrapped `URL(string:)!` calls use fixed literal addresses, so they're harmless.
   Web search fragility and missing Swift are true (Swift because of report 5). Its searches ran
   through the shell-less exec tool, and it's a free model.
7. **2:20 PM: "the chat is long" trimming kicks in with the context ring under a quarter.** The
   notice appeared on the message where he attached two screenshots. Cause:
   `Transcript.estimatedTokens` (`AgentCore/Sources/AgentCore/Agent/Transcript.swift:69`)
   counts the JSON text of every content part, so an attached picture's base64 data counts as
   hundreds of thousands of tokens. `Transcript.fit` then drops old tool results against
   `route.contextBudget`, here min(75% of context, 300,000) for a chosen model, or 60,000 for free
   AIs, and halved after a provider says the request is too long. Fix: count images at their real
   token cost (about 1-2 thousand each) instead of their data length, and base trimming on the
   same real usage numbers the context ring shows. Also `fit` returns `trimmed: true` even when it
   removed nothing (a first message alone over budget), so the notice can show with nothing left
   out; only report trimming when something was actually removed. Test he can run: a new chat
   whose first message has 2-3 screenshots (one phone screenshot's base64 estimates at roughly half
   a million tokens). **Confirmed 2:35 PM:** a new chat with 3 screenshots showed the notice under
   the first answer while the ring said 22,056 of 1,000,000 tokens (2%). "What was in the second
   picture?" then got "I don't see any images", because the first exchange was dropped. He expects
   nothing lost, like Kiro. So the fix also: when a chat really nears the model's limit, summarize
   the older part instead of silently dropping it, as Kiro does.
   Easy tests he ran (2:48-3:10 PM): stop, switching AI, Airplane mode and big text worked.
8. **The AI picker offers AIs MAIPA-G can't use.** "Inkling Small (free)" gave OpenRouter 403
   "only available on agentic harnesses ... listed on openrouter.ai/apps". "Lyria 3 Pro Preview" is
   a music model: it wrote a `music_gen` call, then 403 PROHIBITED_CONTENT. Fix: list only models
   with text output that MAIPA-G may use (tools for repo chats), drop app-restricted ones after
   such a 403, and explain errors in plain words.
9. **No way to make a repo from a chat.** "Make me a new private repo called maipa-g-test" got
   "I don't have a direct way". Plan answer 13 says it may create repos, and the GitHub App has
   `repository_creation: write`. Fix: a create-repository tool that asks first.
10. **A dropped connection leaves a cut-off answer with no note.** The answer stopped at "1" when
    Airplane mode went on. Fix: mark it interrupted and offer Try again.
11. **Saving to MAIPA-G-data stopped at 7:10 AM Eastern.** Its last commit is 11:10 UTC, and
    `jobs/` has only the morning job. So the two "Give me a plan." Autonomous runs in Built-Helion
    (40936883430 and 40937278405, 19:05 and 19:08 UTC) built the runner, found no job record and
    exited in 0.4 s ("the job stopped safely"). They couldn't save the failure either, so the app
    shows "Starting on GitHub" forever. Chats since 7:10 AM aren't backed up. Asked him for a
    screenshot of Settings → Saving after "Save now". Fix: find why saving stopped; never dispatch
    a job before its record is saved; have the phone check the run's own result and show
    failures; make save failures obvious.
    3:17 PM, his screenshot: "Chats and settings: Not saved yet" and "Couldn't save to GitHub just
    now. It'll try again." That's the catch-all in `SyncCoordinator.describe`
    (`App/Sources/Model/SyncCoordinator.swift:104-118`), so it isn't a GitHub API refusal, being
    offline or a sign-in problem. It's another error inside `DataRepoSync.sync()` on the phone,
    such as a transport timeout, a decode error or a file error, and the message hides it. I
    couldn't run the sync here: the sandbox's gh token only works through its proxy (401 from
    URLSession). Fix: show the real error text, then fix its cause. Told him to install the next
    build over the top, without deleting the app first, so today's chats stay on the phone.
12. **The chat AI can't see Autonomous jobs.** Asked about "active ongoing jobs", it listed
    Sprites instead. Fix: the live-status tool in "Tools MAIPA-G must have", item 7.
    Worked (3:26-3:37 PM): web search (current answer with Apple and MacRumors sources), and the
    Spec requirements step.
13. **A sentence about notes made the whole MAIPA-G repo save straight to main.** "Add a line
    saying Hello to README" committed `62518fc` (maipa-g[bot]) to main instead of opening a side
    branch and PR. Cause: `RepoWriteRules.resolve`
    (`AgentCore/Sources/AgentCore/GitHub/GitHubChangeService.swift:40-52`) sets `directSave` for
    the whole repo when any rules line contains phrases like "straight to main". Our
    owner-rules.md says "Notes and rules files ... can go straight to main", which only covers
    those files. Fix: only an unconditional repo-wide rule (like Continuum's "no branches") or
    his per-repo setting turns on direct save. Scoped or conditional sentences don't, and the AI
    gets the rules text to apply per change, with a side branch and PR as the default. Told him to
    tap Undo, which also tests Undo.
14. **Preview can't find a website inside a folder.** Powder-Element-and-Particle-Sim has a Vite
    project in `web/` (package.json, vite.config.ts), plus `native/`. Preview said "No website
    entry point was found". Fix: detect web projects in subfolders, build them (npm install,
    npm run build) on the chat computer, and show the built site.
15. **A finished Spec step doesn't lead to its OK button.** The Requirements job page only offers
    "Delete job". "Approve requirements" is on the spec's own page (Specs → the spec,
    `SpecReviewScreen.swift:87`). Fix: when a spec step finishes, link or open the spec page from
    the job and the chat. (Owner, 3:41 PM: this isn't how he wants specs at all. He meant "Build
    with spec" in the chat, like Kiro. Then: "Just forget about it." Leave Spec alone unless he
    brings it up again.)
16. **Undo refuses whenever anything newer is on the branch.** His Undo of `62518fc` said "The
    branch moved after MAIPA-G's save (expected 62518fc, now 93e49d1)", because Kiro pushed a plan
    note to main in between. Safe, but too strict: Undo should make a commit that reverses only
    its own change when the newer commits don't touch the same files. Kiro reverted `62518fc`
    by hand at 3:45 PM. While he tests saving on the MAIPA-G repo, Kiro must not push to its main.
    Tool tests (4:14 PM, one six-part message, run twice): the last line of CloudRunner.swift (`}`,
    line 854, read in two parts) was right; 66 asset files was right; `\(` gave "80+ lines across
    87 files" (really 90 files, but it said the results were cut short); 🤗 none was right; canva.com
    honestly reported Canva's "Unsupported client" page; the nonsense search honestly found nothing;
    Continuum-'s README was right in run 1.
17. **An OpenRouter 500 isn't retried, and Try again starts over.** Run 1 ended in "OpenRouter
    500: Internal Server Error". `Networking/Retry.swift:56` retries only 502/503/504. Fix: retry
    500 too (a few times, with backoff), and make Try again continue from the saved tool results
    instead of redoing the whole turn.
18. **Reading his other repos is luck.** Run 2 said "I couldn't find a repository named
    'Continuum-'". `read_repo_file` (`Agent/RepoReferenceTool.swift`) is meant for attached repo
    file references at an exact commit, and the AI isn't told his repo names (the trailing dash
    trips it). Fix: put his repo list in the prompt and add a tool that reads a file from any of
    his repos by name (default branch), offering close matches when a name is slightly off.

Technical notes for the logo fix (for Kiro):
- iOS's asset-catalog SVG renderer can't draw Google's new icons (masks written as
  `style="mask-type:alpha"`, plus Gaussian-blur filters). Pre-render every logo to exact-size @2x
  and @3x PNGs with resvg (`npm i @resvg/resvg-js`; rewrite the style as a `mask-type="alpha"`
  attribute first, or Drive, Docs and Sheets come out see-through). Check each render by eye.
- Official sources found: Google `https://www.gstatic.com/images/branding/productlogos/<app>_2026/v2/web/192px.svg`
  (gmail, calendar, drive, docs, sheets, slides); GitHub `https://brand.github.com/GitHub_Logos.zip`
  (Invertocat White/Black, for Dark/Light); Figma's brand-page zip ("Figma Icon (Full-color)") or
  `https://static.figma.com/app/icon/2/favicon.svg`; Linear's own MCP icon
  `https://static.linear.app/integrations/mcp/icon.svg`; Microsoft
  `https://learn.microsoft.com/en-us/entra/identity-platform/media/howto-add-branding-in-apps/ms-symbollockup_mssymbol_19.svg`;
  Slack `https://a.slack-edge.com/1f40066/marketing/img/nav/logo.svg` (brand.slackhq.com is 404);
  Notion: the first inline SVG on notion.com (its `--tatami-color-black` is `#000`); Dropbox glyph
  in `https://fjord.dropboxstatic.com/warp/conversion/dropbox/warp/icons/Dropbox-logo-nav.svg`
  (`#0061FE`); Atlassian `https://atlassian.design/assets/37b166ae7510/logos/atlassian_logo.zip`
  ("Atlassian mark brand RGB"); Box: box.com's inline `svg.logo-box` in `#0061D5`; Asana: the
  three-dot path in asana.com's header logo (`#F06A6A`); Canva
  `https://static.canva.com/static/images/android-192x192-2.png` (no official SVG found; canva.com
  blocks scripts); YouTube: the red button in
  `https://www.gstatic.com/youtube/img/branding/youtubelogo/svg/youtubelogo.svg`. Hugging Face: not
  fetched yet.

## What it is
An iPhone app (.ipa) for AI agents and workflows, with GitHub built in, like Kiro (app.kiro.dev)
and Arena (arena.ai). It's installed the same way as Continuum: download the .ipa, then sign and
install it with his sideloading app and his own certificate.

## The owner's two screenshots (27 October 2026)
- **Arena:** warm dark grey, with a big serif heading, "What would you like to do?". Above the
  message box is a row of connection chips: GitHub ✓, Drive, Docs, Notion, and more. The message
  box says "Ask anything..." and has a few tool buttons and a send arrow. Under it are a repo
  picker ("2c2bhdhw9z...") and a branch picker ("master"), then a gear and an X. There's a
  side-menu button at the top left and a files button at the top right.
- **Kiro:** near-black with purple, a small ghost mascot, and "What can I help you with?". The
  message box has "Build with spec", "Add to group", the AI picker ("Claude Opus 5.5") and an
  "Autonomous" switch. Below that are web, attach and branch buttons and the repo chip
  ("2c2bhdhw9z-cell/Contin...") with an X. There's a side-menu button at the top left.
- "The github thing like in both" means: connect GitHub once, then pick a repo and a branch for
  each chat.

## What he'll see
1. **Home:** a big greeting and the message box, with the AI picker, the Autonomous switch,
   Spec, Group, attach (photos and files), web search, the connections row, and the repo and
   branch pickers.
2. **Side menu:** chats (in groups, searchable), Agents, Workflows, Memories, Settings.
3. **A chat:** each thing the AI does shows as a small line he can tap open. When it needs him,
   it asks numbered questions with buttons.
4. **Files:** look through the repo.
5. **Agents and Workflows:** ready-made ones plus his own (see E below).
6. **Spec:** what it'll build, then how, then a task list. He OKs each one, then it works down
   the list.
7. **Memories:** see answer 24.
8. **Cost counter:** every chat shows what it cost.
9. **Undo:** one tap takes back the last change an agent saved.
10. **Settings:** OpenRouter, GitHub, Dark, Light, System and colours, every effect's switch,
    notifications, the workflow choice (answer 15), how each repo saves changes, "Stop and ask
    when a job has cost $__" (answer 7b), and Technical details. It also says when a new MAIPA-G
    build is out.
- Chats, memories, agents and workflows are kept in a private repo on his GitHub (answer 16), so
  deleting the app before each install (he always does) loses nothing.
- Its changes show on GitHub under MAIPA-G's name, so they can be told apart from Kiro's.

## Decided (27 October 2026)
"Kiro's choice" marks the ones where he said "however you do it", "idk" or "do whatever". In
those cases, copy how Kiro works **out of the box, as Amazon made it**. That is NOT the same as
his personal rules for Kiro (no branches, one build per batch and so on); he corrected this on
27 October 2026 for answer 11. See `.kiro/steering/owner-rules.md`.

A. Big picture
1. Mostly for his apps and games, but everyday things too (writing, research, documents).
2. Just him for now; shared one day ("if I ever actually finish a project"). Build it so anyone
   can use it with their own GitHub and OpenRouter accounts. Keep the app's text short and casual.

B. The AI
3. OpenRouter, plus Apple's free AI on the iPhone.
4. He first said no AI account. Later the same day he said he has an account with about $5 on
   it, taken to be OpenRouter. The app gets a "Sign in with OpenRouter" button: he signs in and
   taps Allow, with no key to copy. With under $10 bought in total, the free AIs stay at 50
   requests a day.
5. New chats start on **Auto**, which picks the AI for each task, like Kiro's Auto: cheap ones
   for easy things, smarter ones for hard work. With $0 on OpenRouter, Auto and free models use
   only the free AIs. Apple's AI handles tiny jobs like chat titles. If he has picked a paid AI
   himself and the balance runs out, the chat asks him (switch to free AIs, or stop).
6. Thinking starts on medium. Each chat can change it, but the control only shows when the
   chosen AI supports thinking levels.
7. Money (answered 27 October 2026):
   - 7a. Yes, Auto may spend on harder jobs, and how much should depend on the task.
   - 7b. "Put a switch in the settings": Settings has "Stop and ask when a job has cost $__". It
     starts off, because Kiro has no such stop out of the box, and the amount is $1 when turned on.

C. GitHub
8. All repos.
9. Kiro's choice, fixed on 27 October 2026 to Kiro's factory default, which is also how Arena
   works (Arena's agent commits, pushes and opens a pull request):
   - If the chat's branch is main, it works on a new side branch. If he picked another branch,
     it works on that one.
   - When it's done, it opens a pull request into main. The chat shows "Add it" (merge, then
     delete the side branch) and "Throw away" (close it and delete the branch).
   - It tidies up after itself, so no branches or requests are left lying around.
   - A per-repo switch can make it save straight to the branch instead.
   - Undo takes back the last saved change.
   - A repo's own rules win. Continuum's say no branches, so there it saves straight to master.
10. Kiro's choice ("do whatever"): MAIPA-G may work on Continuum. In the batch where MAIPA-G
    first changes code (build 2), update Continuum's "Only Kiro works on this repository" rule
    to allow MAIPA-G, his own app.
11. Kiro's choice, fixed on 27 October 2026. He said: "not the way I want you to do it, the way
    you normally are programmed". Out of the box, Kiro:
    - checks its own work before saying it's done, building and testing where it has a computer
      (on GitHub's computers in Autonomous);
    - lets the repo's own automatic builds run when it saves, then checks their results and
      fixes failures;
    - starts a build by hand only when he asks.
    It does not copy his personal "one build per batch, .ipa link and test steps" rules. A
    repo's own rules files still apply.
12. It asks before deleting files and before changing a repo's build setup. The exceptions:
    he has told it to just get on with it, or a memory says otherwise.
13. It may create new repos.

D. Where the work runs
14. Autonomous starts off.
15. Workflows start when he asks, and also by themselves for big jobs. Settings has the same
    three choices as Kiro: When asked, Big jobs too (the default), and Everything.
16. Yes to both (27 October 2026): the private "MAIPA-G-data" repo, and the small job file
    added to a repo the first time Autonomous is used on it. He said storing data in a repo
    feels like "a stupid/crude way to save data". It's used because MAIPA-G has no server of
    its own (Kiro and Arena keep chats on theirs), and a private repo is his, free, and survives
    deleting the app. He never has to look at it. If a better place turns up that works on a
    sideloaded app, switch to it.
17. Kiro's choice (he didn't follow the question): jobs keep going until they're done, the same
    as Kiro out of the box. GitHub stops a run after 6 hours, so MAIPA-G hands over to a fresh
    run. The money rule (7) still applies.
18. He picked "show it in the app", and pointed out that sideloaded apps do get notifications.
    He's right: an app can post its own notifications. So it shows everything in the app, plus
    MAIPA-G's own notifications when a job finishes or needs him, with a switch in Settings (on).
    Jobs keep going for a while after he leaves the app (iOS 26 shows a progress bar). If the
    iPhone pauses the app, the notification comes when the iPhone next lets it check.

E. Agents and workflows
19. Kiro's choice: the ready-made agents are Kiro's set, in plain names: Planner, Designer,
    Design checker, Coder, Code checker, Second opinion (another checker on a different AI),
    Review combiner, Investigator (report only), Researcher (tries experiments, keeps what
    works), Builder (starts a build when asked, checks the .ipa) and Workflow maker. Plus Request
    sender and Feedback answerer, which open the pull request and answer comments on it.
20. Kiro's choice: the ready-made workflows are Kiro's set: Look into something, Keep going until
    a goal is met, Work through a checklist, and Full feature (requirements, design, checked
    design, plan, build with a two-AI review, final check). Also Two-AI review, Experiment until
    it's better, Send a side copy for review, and Build and check the .ipa.
21. Both: he can describe a workflow in words (the Workflow maker sets it up for his OK), or tap
    the steps together himself.
22. Kiro's choice: agents can run helpers side by side, like Kiro's sub-agents.
23. Memories start empty. His Kiro rules are not copied in.
24. Memories (owner's own words, 27 October 2026): "Memories start empty. If there are memories,
    they are used in every new chat. Memories can be added and edited by the AI and the user.
    Memories can be turned off and/or on." So:
    - a ★ in a message saves one;
    - the AI also saves on its own and says what it saved;
    - he can add, edit and delete them in Memories;
    - each memory has an on/off switch, and there's one switch for all of them.
25. He thought this meant MAIPA-G's own plan. It meant where the Spec button keeps the spec it
    writes for a project. Kiro's choice: inside that project's repo, where Kiro keeps its specs
    (`.kiro/specs/`), so Kiro and MAIPA-G can both read them.

F. Extras
26. Kiro's choice: web search and "read a web page", like Kiro has. It works free with no setup.
    When paid use is allowed (7a), it uses OpenRouter's better search, about 2 cents a search.
27. Keyboard mic only, for now.
28. Connections: ALL of them, not only the ones named; he uses none yet. The app has a searchable
    list of every connector in the official MCP Registry that AI apps share (over 40,000 in
    October 2026). The well-known ones come first: Google Drive, Docs, Sheets, Slides, Gmail,
    Calendar, Notion, Slack, Linear, Figma, Dropbox and so on. He taps one and signs in. A few
    need a one-time setup on their own website first.
29. Kiro's choice: pictures through OpenRouter's image AIs.
30. Live previews of web projects inside the app.

G. Look
31. Kiro designs MAIPA-G's own look, and he'll say if he doesn't like it. Colours can be changed.
32. Kiro designs a mascot. He expects it may get scrapped.
33. Kiro's choice: gentle moving effects, each with its own switch (on).
34. Name: MAIPA-G. Kiro makes the icon.

H. Safety, code, order
35. No Face ID lock.
36. MAIPA-G's code stays public.
37. The build order is fine.
38. Nothing to add or remove.

## Build order (agreed, one build each)
1. Home screen, Connect GitHub, the repo and branch pickers, Sign in with OpenRouter and the AI
   picker (Auto, thinking), a chat that can read and search a repo, the side menu.
2. Changing code and saving it, Undo, attachments, web search, Files, the cost counter,
   notifications.
3. Autonomous: jobs on GitHub's computers, live progress, starting and checking builds.
4. Agents and Workflows.
5. Spec, Memories, groups, connections, pictures, live previews.

## Facts checked on 27 October 2026
- GitHub Models (GitHub's free AI) was retired on 30 July 2026. Google's free Gemini allowance
  is about 20 requests a day on its good models.
- OpenRouter's free AIs allow 20 a minute and 50 a day, or 1,000 a day once $10 has been bought.
  Top-ups carry a 5.5% fee ($0.80 minimum). `openrouter/free` picks free models that support the
  features a request needs; `openrouter/auto` can pick paid models and bill. Web search costs $4
  per 1,000 results. Sign-in uses OAuth with PKCE, with https or localhost callbacks only.
- Claude per million tokens (in / out): Opus 5.5 is $4 / $20, Sonnet 5.5 is $2 / $10, and Haiku
  5.5 is $0.10 / $0.50.
- GitHub Actions: standard runners are free with no limit for public repos. Private repos on
  GitHub Free get 2,000 minutes a month, and macOS minutes count ten times. **GitHub's terms
  don't allow hosted runners to do anything unrelated to the project in the repo where they
  run.**
- The official MCP Registry lists over 40,000 servers, most new ones remote. MCP sign-in
  recommends Client ID Metadata Documents (an https URL as the client ID). Google has official
  remote MCP servers for Gmail, Drive, Docs, Sheets, Slides, Calendar and Chat (Developer
  Preview since September 2026).
- iOS 26 `BGContinuedProcessingTask` lets user-started work carry on in the background, with the
  system's progress UI. It's ended if progress stops being reported (about 30 seconds). Any app
  can post its own (local) notifications. Only instant pushes from a server need Apple's push
  setup.

## Technical notes (for Kiro; the owner doesn't read these)
- **App:** native Swift and SwiftUI, with the project made by XcodeGen (`project.yml`), like
  Continuum's `native/ios`. Minimum iOS 17. iOS 26 extras (FoundationModels, the glass look,
  `BGContinuedProcessingTask`) sit behind availability checks.
- **Agent core:** one Swift package (`AgentCore`) with no Apple-only frameworks, shared by the
  app and a Linux command-line runner for cloud jobs, so it can be built and tested on Linux in
  the Kiro sandbox.
- **Builds:** GitHub Actions on macos-26 (Xcode 26.6). Run xcodegen, then xcodebuild with signing off.
  Zip `Payload/MAIPA-G.app` into `MAIPA-G-<run>.ipa` and `MAIPA-G.ipa`, and publish GitHub
  Release `build-<run>-<sha>` from main only. Pull requests build as a check only. Reuse the
  packaging, .ipa checks and release retry logic from Continuum's `.github/workflows/ios.yml`.
  Check every .ipa (version, executable, Info.plist) before handing it over.
- **Sign-ins without copying keys:** all go through a GitHub Pages page in this repo's `docs/`
  that bounces https callbacks to the app's `maipag://` scheme, caught by
  ASWebAuthenticationSession.
  - GitHub: a GitHub App made for the user through the manifest flow. Its keys go in the
    Keychain, and installation tokens are signed on the phone (RS256 with the Security
    framework). Fall back to device flow if needed.
  - OpenRouter: OAuth with PKCE.
  - MCP connectors: OAuth 2.1 with PKCE, using a Client ID Metadata Document hosted on the same
    Pages site, or dynamic client registration where a server only supports that.
- **Where things live:** secrets in the Keychain. Chats, memories, agents, workflows and settings
  are JSON on the phone, synced to the private `MAIPA-G-data` repo (answer 16). That repo runs
  no Actions. Specs go in the project's `.kiro/specs/`.
- **AI (Auto):**
  - $0 balance: `openrouter/free`. Check the balance with OpenRouter's key and credits endpoints.
  - Money on it: `openrouter/auto`, with `cost_tier` chosen per task: low for chat and small
    jobs, medium for normal coding, high for planning, hard debugging and reviews. (Its default
    with no tier is low.) Use `session_id` so a chat stays on one model.
  - Apple FoundationModels for tiny jobs.
  - Reasoning effort starts on medium.
  - Streaming, tool calls, prompt caching, and cost from the usage numbers. The optional "stop
    and ask at $__" check runs on every step.
- **Phone agent tools:**
  - files: list, read and search; edit, create and delete; save (commit through the Git Data
    API); undo (revert the last save);
  - GitHub: start and watch Actions runs and read their logs; check releases and .ipa contents;
  - web: search (free with no key, e.g. DuckDuckGo's HTML results, plus OpenRouter's
    `openrouter:web_search` when allowed) and read a page;
  - asking numbered questions, memory add and edit, and MCP tools.
- **Cloud jobs:** because of GitHub's terms, there is no central runner. The first time
  Autonomous is used on a repo, add `.github/workflows/maipa-g.yml` there: a small caller of a
  reusable workflow in this repo. Set that repo's secrets (OpenRouter key, GitHub token) through
  the API, using a libsodium sealed box.
  - The job runs AgentCore's runner on ubuntu-latest with a real shell, in that repo. Local-only
    (stdio) MCP servers run there too.
  - Logs never show chat text. Progress goes back through MAIPA-G-data.
  - State is saved after every step, and a job hands over to a fresh run before the 6-hour
    limit.
  - Jobs that aren't about a repo run on the phone only.
  - Make sure adding the file doesn't start that repo's own build (check Continuum's ios.yml path
    filters; use `[skip ci]`).
- **Background:** `BGContinuedProcessingTask` for on-phone jobs and for watching cloud jobs, with
  progress reported often. Local notifications on finish or when a job needs him.
  `BGAppRefreshTask` as a fallback check. No remote push.
- **Memories:** each has text, on/off, source (★, AI or him) and dates. Every memory that's on
  goes into every new chat. There's a master switch, the AI has tools to add and edit them, and
  the app tells him when the AI saves one.
- **Workflows:** like Kiro's: steps with agents, repeat loops (a maximum, then pause), stop-and-ask
  steps, and parallel steps. The Workflow maker turns his words into a workflow for him to approve.
- **Saving changes:** follows Kiro's default branch policy.
  - If the chat's branch is the default branch, make a new branch. Otherwise use the picked
    branch.
  - Open a PR into the default branch. "Add it" squash-merges the PR and deletes the branch;
    "Throw away" closes it and deletes the branch.
  - If the PR from an earlier session was merged or closed, start a new branch.
  - The per-repo option saves straight to the branch. A repo's own rules files override the
    default.
- **What Build 1 settled (28 October 2026):**
  - GitHub: each person gets their own GitHub App, made with the manifest flow
    (`docs/github/new/`). `request_oauth_on_install: true` makes create, install and sign-in
    one trip. Its permissions cover the later builds too, because an app keeps what it was made
    with: contents, pull requests, issues, actions, workflows and secrets (write); checks and
    statuses (read); and `repository_creation: write`. That is the narrow permission GitHub
    added on 13 October 2026, used instead of `administration`, which could also delete repos.
    The app is called "MAIPA-G", or "MAIPA-G-xxxx" if that name is taken, and its commits show
    as `<app>[bot]`.
  - The app trusts GitHub's own list of installations (asked with the signed JWT), not the
    `installation_id` in the redirect.
  - Reading repos: the branch's tarball is unpacked into a snapshot per commit in Caches, and
    later commits are patched in from the compare API. Search runs on the phone.
  - Auto: `openrouter/auto` with the auto-router plugin's `cost_tier` (low, medium or high),
    chosen from how hard the task is (judged by Apple's on-phone AI, or by a word check without
    it). With no credit it uses `openrouter/free`. A 402 marks the account out of credit for an
    hour.
  - Chats sync to the private `MAIPA-G-data` repo from Build 1 on, because he deletes the app
    before every install.
  - Markdown: Apple's swift-markdown, drawn by MAIPA-G's own SwiftUI renderer and highlighter.
  - The PR check also opens every screen in the simulator, in Dark and Light, and keeps the
    screenshots.
