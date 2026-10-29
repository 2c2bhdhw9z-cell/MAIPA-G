# MAIPA-G

An AI helper for your iPhone, with GitHub built in.

**[Download the newest build](https://github.com/2c2bhdhw9z-cell/MAIPA-G/releases/latest/download/MAIPA-G.ipa)**, then sign the IPA with your sideloading app.

- Chat through OpenRouter with Auto, a chosen AI, thinking levels, pictures, PDFs, current web results, generated pictures, and connected MCP tools.
- Read, search, edit, save, and undo work in a GitHub repo. Default-branch changes use a reviewable side branch unless that repo allows direct saves.
- Run restartable Autonomous jobs, built-in or custom agents and workflows, and ordered Specs with approval stops, progress, cost, logs, and build results.
- Organize chats into groups, save selected memories, browse repo files, and open static or built websites in an isolated live preview.
- Keep chats, attachments, generated media, settings, memories, groups, connectors, agents, workflows, jobs, and Specs in the private `MAIPA-G-data` repo.

The app keeps OpenRouter, GitHub, and connector credentials in the iPhone Keychain. It does not put secrets in the data repo.

## What's where

- `App/` contains the SwiftUI iPhone app. `App/project.yml` describes the generated Xcode project and `App/package-ipa.sh` packages the IPA.
- `AgentCore/` contains the cross-platform agent, GitHub, OpenRouter, MCP, workflow, preview, and persistence code. Run `swift test --package-path AgentCore` on Linux or macOS.
- `docs/` contains the GitHub Pages sign-in callbacks and MCP Client ID Metadata Document.
- `scripts/` contains the Dark/Light screenshot matrix and independent IPA release checks.

Hello
