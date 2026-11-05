---
inclusion: always
---

# The owner's rules for MAIPA-G. Read these first, every session.

These come straight from the owner. His general rules are in Kiro's global memories and apply
here too: plain English, iPhone only, never assume, ask short numbered questions, do only what he
asks, one build per batch with the .ipa link and test steps, Eastern time.

## Branches and pull requests: straight to main
Owner, 5 November 2026: "Everyone should only ever push the main ... There should not be branches or
PRs ... It's just fucking shit up." This replaces the 27 October exception entirely.
- Commit straight to `main`. Never open a branch or a pull request, and never ask the owner about
  them. If a stale branch or PR already exists, close/delete it rather than using it.
- The app's "saves directly" setting is the way to do this: turn off pull-request saving for this
  repository so every save lands on `main`.
- The build still has to be checked before it reaches him. `ios.yml` runs on `workflow_dispatch`
  as well as on pull requests, and it embeds `github.sha` when there is no pull request, so a
  checked build of `main` is still possible without a PR.
- Keep `.github/workflows/publish-verified-ipa.sh`'s "PR and main trees must match" proof intact:
  when there is no pull request, the tree of the published commit equals itself, so it still holds.

## "However you do it" means Kiro's factory defaults
Owner, 27 October 2026, correcting answer 11: "the way you normally are programmed, like the way
Amazon or whoever made you", not "the way I want you to do it".
- When he leaves a MAIPA-G choice to Kiro, MAIPA-G copies how Kiro works out of the box.
- Never copy his personal rules for Kiro (no branches, one build per batch, .ipa links, and so
  on) into MAIPA-G's own behaviour.
- A repo's own rules files still apply on top, the same as they do for Kiro.

## Plan first
Owner, 27 October 2026: "Obviously Plan First", and "Ask as many questions as you need. I want
this done right."
- The plan is `.kiro/notes/PLAN.md`. Read it at the start of every session and keep its status
  line true.
- Nothing gets built until he has answered every open question in it and has OK'd the final plan.
