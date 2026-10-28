# MAIPA-G

An AI helper for your iPhone, with GitHub built in.

**[Download the newest build](https://github.com/2c2bhdhw9z-cell/MAIPA-G/releases/latest/download/MAIPA-G.ipa)**, then sign the .ipa with your sideloading app.

- Chat with any AI on OpenRouter, or let **Auto** pick: cheaper AIs for easy things, smarter ones for hard work. The free AIs cost nothing.
- Pick a repo and a branch, and MAIPA-G reads and searches the whole thing to answer.
- MAIPA-G gets its own app on your GitHub, so its work shows up under its own name.
- Your chats and settings are kept in a private repo on your GitHub, so deleting the app loses nothing.

## What's where

- `App/` – the iPhone app (SwiftUI). `App/project.yml` describes the Xcode project; `App/package-ipa.sh` builds the .ipa.
- `AgentCore/` – the brain: the AI loop, OpenRouter and GitHub, repo copies and search, and saving. It builds and tests on Linux too: `swift test --package-path AgentCore`.
- `docs/` – the GitHub Pages site the sign-ins come back through.
- `design/` – the icon and mascot artwork.
