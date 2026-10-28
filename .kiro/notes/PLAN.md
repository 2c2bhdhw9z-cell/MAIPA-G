# MAIPA-G plan

**Status (27 October 2026, 11:36 PM Eastern): the owner has answered. Questions 7 and 16 are still
open, asked again in plainer words (see "Still open").** Nothing gets built until those are
answered and he has OK'd the final plan. Then show him the final plan in short and start build 1
when he says go.

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
    notifications, the workflow choice (answer 15), how each repo saves changes, and Technical
    details. It also says when a new MAIPA-G build is out.
- Chats, memories, agents and workflows are kept in a private repo on his GitHub (answer 16,
  still open), so deleting the app before each install (he always does) loses nothing.
- Its changes show on GitHub under MAIPA-G's name, so they can be told apart from Kiro's.

## Decided (27 October 2026)
"Kiro's choice" marks the ones where he said "however you do it", "idk" or "do whatever". In
those cases, copy how Kiro does it.

A. Big picture
1. Mostly for his apps and games, but everyday things too (writing, research, documents).
2. Just him for now; shared one day ("if I ever actually finish a project"). Build it so anyone
   can use it with their own GitHub and OpenRouter accounts. Keep the app's text short and casual.

B. The AI
3. OpenRouter, plus Apple's free AI on the iPhone.
4. He has no AI account yet. The app gets a "Sign in with OpenRouter" button: he makes a free
   account there and taps Allow, with no key to copy. Free AIs work with $0 on it.
5. New chats start on **Auto**. With $0 on OpenRouter, or if paid use isn't allowed (7a), Auto
   uses only free AIs, plus Apple's AI for tiny jobs like chat titles.
6. Thinking starts on medium. Each chat can change it, but the control only shows when the
   chosen AI supports thinking levels.
7. Still open.

C. GitHub
8. All repos.
9. Kiro's choice: it saves to the branch picked in the chat (main unless he picks another),
   like Kiro does for him. A per-repo switch can make it use a side copy instead, with Keep or
   Throw away, tidied up automatically. Undo takes back the last saved change.
10. Kiro's choice ("do whatever"): MAIPA-G may work on Continuum. In the batch where MAIPA-G
    first changes code (build 2), update Continuum's "Only Kiro works on this repository" rule
    to allow MAIPA-G, his own app.
11. Kiro's choice: builds work the way Kiro does them. One build at the end of a finished batch,
    never in the middle. Then it checks the build and gives the download link and test steps.
    It follows each repo's own build rules.
12. It asks before deleting files and before changing a repo's build setup. The exceptions:
    he has told it to just get on with it, or a memory says otherwise.
13. It may create new repos.

D. Where the work runs
14. Autonomous starts off.
15. Workflows start when he asks, and also by themselves for big jobs. Settings has the same
    three choices as Kiro: When asked, Big jobs too (the default), and Everything.
16. Still open.
17. Kiro's choice, from his "never stop early" rule (he didn't follow the question): jobs keep
    going until they're done. GitHub stops a run after 6 hours, so MAIPA-G hands over to a fresh
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
    works), Builder (starts the build, checks the .ipa) and Workflow maker. Plus Side-copy sender
    and Feedback answerer, for repos set to side copies.
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

## Still open (asked again on 27 October 2026, in plainer words)
7. Money. OpenRouter is pay-first, like a prepaid card: it can't spend more than what's on it,
   and with $0 on it only free AIs work. Putting $10 on it once raises the free AIs from 50 to
   1,000 requests a day, and the $10 stays there to spend.
   - 7a. When there's money on it, may Auto spend some on harder jobs (a smarter AI, better web
     search)? a) yes b) no, free only unless he picks a paid AI himself
   - 7b. Should a job stop and ask once it has cost a set amount? a) yes, at $1 b) yes, at $__
     c) no
16. Two things on his GitHub: a private repo, "MAIPA-G-data", that only he can see and that keeps
    chats, memories, agents and workflows safe across reinstalls; and one small file added to a
    repo the first time he uses Autonomous on it. OK?

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
- **Builds:** GitHub Actions on macos-latest. Run xcodegen, then xcodebuild with signing off.
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
- **AI (Auto):** `openrouter/free` when there's no money or paid use isn't allowed;
  `openrouter/auto` or a smarter model when it is; Apple FoundationModels for tiny jobs. Reasoning
  effort starts on medium. Streaming, tool calls, prompt caching, and cost from the usage numbers.
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
- **Saving changes:** either straight to the chosen branch, or a side branch plus a PR that the
  app squash-merges and deletes on Keep, or deletes on Throw away.
