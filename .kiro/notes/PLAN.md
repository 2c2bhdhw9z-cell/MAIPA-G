# MAIPA-G plan

**Status (29 October 2026, 1:40 PM Eastern): the whole plan is built and on main. Build 25
(`build-25-480fa98`, 4.6 MB, PR #8) is the one to install. It fixes all four build 24 reports
below: the companies' own full-colour logos on plain tiles, search that finds Hugging Face and
well-known services, a real computer for every chat (Sprites through its connector, switchable in
Settings, set up and used by the AI on its own), and tool-call bars that end at their arrows.
Linux checks and the iPhone build passed; downloaded and checked: 0.1.0 (25), iPhone arm64, 19
entries. Next: he tests build 25.**

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
    Sprites instead.

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
