---
inclusion: always
---

# The owner's rules for MAIPA-G. Read these first, every session.

These come straight from the owner. His general rules are in Kiro's global memories and apply
here too: plain English, iPhone only, never assume, ask short numbered questions, do only what he
asks, one build per batch with the .ipa link and test steps, Eastern time.

No pull requests.

## Branches and pull requests: straight to main
Owner, 5 November 2026: "Everyone should only ever push the main ... There should not be branches or
PRs ... It's just fucking shit up." This replaces the 27 October exception entirely.
- Never open a branch or a pull request, and never ask the owner about them. If a stale branch or
  PR already exists, close or delete it rather than using it.
- The line above (`No pull requests.`) is deliberately worded that way: the app only turns on
  direct saves for a repository whose rules contain one of a fixed set of exact sentences, and
  `no pull requests` is one of them. Paraphrases such as "commit straight to main" are NOT
  recognised and leave the default side-branch-and-PR behaviour in place. Do not reword it.
- Do not rely on the app's "Save straight to branch" switch. It is off by default, off means
  pull request, and the owner has never turned it on.
- The build still has to be checked before it reaches him, and nothing is published by hand.
  `ios.yml` runs on every push to `main` (and on pull requests and `workflow_dispatch`);
  `release.yml` follows each finished `main` run and publishes only from a green run on that
  exact tree. A push identical to an already-checked PR head reuses that PR run instead of
  building twice. Release can also be started by hand with an older commit's `sha`: it checks
  that commit first (on a temporary tag) or explains clearly why it can't.
- Keep `scripts/publish-verified-ipa.sh`'s "PR and main trees must match" proof intact: when
  there is no pull request, the tree of the published commit equals itself, so it still holds.

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
