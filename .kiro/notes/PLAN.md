# MAIPA-G plan

**Status (27 October 2026, Eastern): draft. Waiting for the owner's answers to the questions
below.** Nothing gets built until every question is answered and he has OK'd the final plan.
When the answers come in, write them under each question and update this line.

## What it is
An iPhone app (.ipa) for AI agents and workflows, with GitHub built in, like Kiro (app.kiro.dev)
and Arena (arena.ai). It's installed the same way as Continuum: download the .ipa, then sign and
install it with the owner's sideloading app and his own certificate.

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

## What the owner will see (proposed)
1. **Home:** a big greeting and the message box, with the AI picker, the Autonomous switch,
   Spec, Group, attach (photos and files), web search, a row of connections, and the repo and
   branch pickers.
2. **Side menu:** chats (in groups, searchable), Agents, Workflows, Memories, Settings.
3. **A chat:** each thing the AI does shows as a small line you can tap open. When it needs
   the owner, it asks numbered questions with buttons.
4. **Files:** look through the repo.
5. **Agents:** ready-made ones and his own (a name, its instructions, which AI, what it may do).
6. **Workflows:** agents chained into steps, with loops ("until the reviewer is happy, at most
   twice") and stop-and-ask points. Ready-made ones plus his own.
7. **Spec:** what it'll build, then how, then a task list. He OKs each, then it works down the list.
8. **Memories:** a ★ saves something for every agent. It also reads the rules already in his repos.
9. **Cost counter:** every chat shows what it cost, with limits he sets.
10. **Undo:** one tap takes back the last change an agent saved.
11. **Settings:** AI accounts, GitHub, Dark, Light, System and colours, how changes are saved,
    Technical details. It also says when a new MAIPA-G build is out.
- Chats, agents, workflows and memories are also kept in a private repo on his GitHub, so
  deleting the app before each install (he always does) loses nothing.
- Changes it makes show on GitHub under the name MAIPA-G, so they can be told apart from Kiro's.

## Facts checked on 27 October 2026
- The AI isn't free. GitHub Models (GitHub's free AI) was retired on 30 July 2026. Google's free
  Gemini allowance is about 20 requests a day on its good models. OpenRouter's free models allow
  50 requests a day, or 1,000 a day after a one-time $10 top-up. Claude per million tokens (in /
  out): Opus 5.5 is $4 / $20, Sonnet 5.5 is $2 / $10, and Haiku 5.5 is $0.10 / $0.50.
  OpenRouter charges the same per-token price plus a 5.5% fee on top-ups.
- GitHub Actions: standard runners are free with no limit for public repos. Private repos on
  GitHub Free get 2,000 minutes a month, and macOS minutes count ten times.
- Web search: Tavily gives 1,000 free searches a month. Brave gives $5 of free credit a month at
  $5 per 1,000 searches.
- A sideloaded app can't count on real push notifications, which need Apple's push setup and a
  server. The options are the ntfy app, a background check with local notifications, or none.

## Build order (proposed, one build each)
1. Home screen, Connect GitHub, repo and branch pickers, AI accounts and picker, a chat that can
   read and search a repo, the side menu.
2. Changing code and saving it, Undo, attachments, web search, Files, the cost counter.
3. Autonomous: jobs on GitHub's computers, live progress, starting and checking builds.
4. Agents and Workflows.
5. Spec, Memories, groups, connections.

## Questions asked on 27 October 2026 (answers go under each)
A. Big picture
1. What's it mostly for? a) his apps and games (code) b) everyday things too (writing,
   research, documents, planning) c) both
2. Just for him, or shared like Continuum?

B. The AI
3. Which AI accounts? (OpenRouter, Anthropic, OpenAI, Google Gemini, Apple's on-phone AI, others)
4. Does he already have an account with a key at any of them?
5. Which AI do new chats start on? (Opus 5.5, Sonnet 5.5, a free one, ask each time)
6. Thinking: always max, a switch per chat starting at max, or medium?
7. Money: a monthly limit, and pause a job to ask once it has cost a set amount.

C. GitHub
8. All repos, or only ones he picks?
9. How agents save changes: straight to main, a side copy with Keep / Throw away, or a switch
   per repo.
10. Continuum's rules say only Kiro may work on it. MAIPA-G on Continuum: allowed (update that
    rule), look only, or not at all?
11. May an agent start a build by itself (once at the end of a finished job), only when he says
    so, or never?
12. Should it ask before deleting files or changing a repo's build setup?
13. Can it create new repos for new projects?

D. Where the work runs
14. Is the Autonomous switch off, on, or does the AI pick per job?
15. Does a chat start workflows only when asked, by itself for big jobs, or always?
16. Extra repos: two (a private one for chats and private jobs, and a public one for jobs on
    public projects, free and unlimited), or one private repo only (about 33 free hours a month)?
17. Long jobs: keep going within the money limit, or stop after a set number of hours?
18. When a job finishes or needs him: show it in the app, ping him through ntfy, or have the app
    check in the background?

E. Agents and workflows
19. Ready-made agents: Planner, Coder, Reviewer, Researcher, Builder, Spec writer. Keep, add or
    remove any?
20. Ready-made workflows: Look into something, Plan → Build → Review, Fix a bug, Build and check
    the .ipa, Spec → Build. Keep, add or remove any?
21. Making his own workflows: describe them in words, tap steps together, or both?
22. Two agents at once (two reviewers on different AIs)?
23. Start with his Kiro rules copied in as Memories, or start empty?
24. Memories: only with a ★, also saved on its own (it tells him), or ask each time?
25. Do specs live in MAIPA-G's private repo or inside the project repo?

F. Chat extras
26. Web search: free (Tavily, about 1,000 a month), paid per search, or free first then paid?
27. Voice: keyboard mic only, or a talk button with spoken replies?
28. Which connections? (Drive, Docs, Gmail, Calendar, Notion, Slack, others, none)
29. Making pictures (icons, game art)?
30. Live previews of web projects?

G. Look
31. Style: like Arena (warm grey, big serif heading), like Kiro (near-black, bright accent), or
    his own colours?
32. A mascot of its own?
33. Moving effects (swirling background, glow) with switches, or calm?
34. Name under the icon, and the icon itself?

H. Safety, code, order
35. Face ID lock?
36. MAIPA-G's own code: public (free unlimited builds) or private (about 30 builds a month)?
37. Is the build order OK, or should Agents and Workflows come sooner?
38. Anything in the list he doesn't want, or anything missing?

## Technical notes (for Kiro; the owner doesn't read these)
- **App:** native Swift and SwiftUI, with the project made by XcodeGen (`project.yml`), like
  Continuum's `native/ios`. Minimum iOS 17. iOS 26 extras (Apple's on-device model through
  FoundationModels, the glass look) sit behind availability checks.
- **Agent core:** one Swift package (`AgentCore`) with no Apple-only frameworks, shared by the
  app and a Linux command-line runner for cloud jobs. That way it can be built and tested on
  Linux in the Kiro sandbox.
- **Builds:** GitHub Actions on macos-latest. Run xcodegen, then xcodebuild with signing off.
  Zip `Payload/MAIPA-G.app` into `MAIPA-G-<run>.ipa` and `MAIPA-G.ipa`, and publish GitHub
  Release `build-<run>-<sha>` from main only. Pull requests build as a check only. Reuse the
  packaging, .ipa checks and release retry logic from Continuum's `.github/workflows/ios.yml`.
  Check every .ipa (version, executable, Info.plist) before handing it over.
- **GitHub connection:** a GitHub App that the app registers for the user through GitHub's
  manifest flow. ASWebAuthenticationSession opens a tiny GitHub Pages page in this repo's
  `docs/`, which posts the manifest and bounces the callback back to the app's URL scheme. Keys
  are kept in the Keychain, and installation tokens are signed on the phone (RS256 with the
  Security framework). If that fails, fall back to device-flow sign-in.
- **Where things live:** secrets in the Keychain. Chats, agents, workflows, memories and specs
  are JSON on the phone, synced to a private data repo that the app creates on the user's
  account. Nothing is added to project repos except the changes the user asks for.
- **AI:** OpenRouter (OpenAI-style API) and the Anthropic Messages API, with streaming, tool
  calls and prompt caching. Cost comes from the usage numbers and is checked against the limits.
- **Phone agent tools:** list, read and search files; edit, create and delete files; save
  (commit through the Git Data API); start and watch Actions runs and read their logs; check
  releases and .ipa contents; web search; read a web page; ask numbered questions; save a
  memory; undo (revert the last saved change).
- **Cloud jobs (Autonomous, workflows):** a workflow_dispatch job that runs the AgentCore runner
  on ubuntu-latest with a real shell. Jobs for public projects run in a public runner repo (free,
  no limit); private ones run in the private data repo. Logs never show chat text. Progress goes
  back to the app through the private data repo (issue comments or check runs; decide in build
  3). State is saved after every step, so a run can resume or hand over to a fresh run before
  GitHub's 6-hour job limit.
- **Saving changes:** either straight to the chosen branch, or a side branch plus a PR that the
  app squash-merges and deletes on Keep, or deletes on Throw away.
