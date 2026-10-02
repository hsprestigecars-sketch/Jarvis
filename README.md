# JARVIS — iPad-first personal AI assistant

<img src="docs/jarvis-concept.webp" width="200" align="right" alt="JARVIS">

JARVIS is a native SwiftUI iPad app. You talk to it by voice or text. Claude reasons about the request, and JARVIS runs it through a set of registered tools that use Apple's own frameworks. A safety layer sits between Claude and those tools. It decides in code what may run, what must be confirmed first, and what is permanently blocked.

```
USER ─▶ UI + VOICE ─▶ COMMAND PROCESSOR ─▶ CLAUDE ─▶ SAFETY ENGINE ─▶ CONFIRMATION ─▶ TOOLS ─▶ RESULT ─▶ CLAUDE ─▶ REPLY
          (on-device      (stop / cancel /      (reasoning,  (allow / confirm /   (frozen exact    (EventKit, Contacts,
           speech)         confirm / protected)  tool calls)  block, arg scan)     action)          Files, Messages UI…)
```

## Getting started

Requirements: a Mac with Xcode 16 or later, an iPad on iPadOS 17 or later, and a Claude API key.

```bash
brew install xcodegen
xcodegen generate          # creates JARVIS.xcodeproj from project.yml
open JARVIS.xcodeproj      # pick your team under Signing, then run on your iPad
swift test                 # runs the JarvisCore safety/agent tests
```

On first launch, JARVIS opens Settings so you can paste your Claude API key. The key is kept in the iPad Keychain and is only sent to `api.anthropic.com`.

## Layout

| Path | What it is |
|---|---|
| `Sources/JarvisCore/` | Platform-neutral core: tool registry, safety engine, blocked policy, confirmation engine, emergency stop, Claude client, agent loop, Mac companion bridge. This core will be shared with the future Mac companion. |
| `Tests/JarvisCoreTests/` | Unit tests for blocking, confirmation binding, cancel/stop, history repair, untrusted-content wrapping and the request format. |
| `App/` | The iPad app: SwiftUI UI, voice, App Intents (Siri/Shortcuts), and the iPadOS tool implementations. |
| `docs/ARCHITECTURE.md` | How the pipeline, safety levels and confirmations work. |
| `docs/IPADOS_CAPABILITIES.md` | What works natively, what uses a legitimate alternative, and what iPadOS doesn't allow. |

## What works in this version

| Area | Status |
|---|---|
| Voice | Push-to-talk with on-device speech recognition when the iPad supports it, auto-stop on silence, spoken replies, and interrupting by tapping the mic. "Hey Siri, ask JARVIS…" and "Talk to JARVIS" work through App Intents. |
| Chat | Markdown, code blocks with copy, tables, sources from research, tool status rows and confirmation cards. Voice and text share one conversation, which is saved across launches. |
| Calendar (EventKit) | List and search events and find free time without asking. Creating, editing and deleting events needs your confirmation. |
| Reminders (EventKit) | List, create, complete and repeat reminders, including location-based ones. Deleting needs your confirmation. |
| Notes | JARVIS notes are Markdown files: create, append, search, read, and share to Apple Notes. Deleting needs your confirmation. |
| Files | Covers JARVIS's own folder (visible in the Files app) plus files you import: list, search, read (including PDFs), create, copy and share. Overwriting, moving and deleting need your confirmation. |
| Photos and camera | You pick photos or videos with the system picker, or capture them with the visible camera. Images go to Claude; videos are saved to `Content/` and can be inspected. |
| Research | Claude's web search and web fetch, with citations. Page content is treated as untrusted data. |
| Daily assistant | "Plan my day", "Briefing" and "Night mode" use the calendar, reminders and web search, and never change the calendar unless you ask. |
| Messages, email, calls | Need your confirmation, then open Apple's composer or the call prompt. You send the message yourself. |
| Social | Builds Instagram and TikTok post packages: caption and hashtag checks against platform limits, plus copies of the media. These are handed to the official app through the Share Sheet. Publishing through the official APIs is built in but stays disabled until an OAuth app is registered (see below). |
| Device | Battery and storage, timers (through notifications), opening apps, opening links, and running your own Shortcuts (needs your confirmation). |
| Safety | Level 1 runs, Level 2 asks you first, Level 3 is blocked in code. There is an emergency stop button (⌘.) and a voice "JARVIS, stop". "Cancel" works by voice or button. |

## Not done yet (on purpose)

- **Wake word.** "Hey JARVIS" with the screen off would need the microphone running all the time. iPadOS doesn't allow that for third-party apps, and it would cost privacy and battery. Siri plus App Shortcuts is the supported hands-free route. A local wake word that only listens while the app is open could be added later. It would never upload audio.
- **Publishing to Instagram and TikTok.** This needs a registered Meta/TikTok developer app, which TikTok must audit before it allows public posting. Instagram also needs a Business or Creator account and a public URL to host the media. A `SocialConnector` implementation plugs into `SocialAndMediaTools.connectors`.
- **Mac companion.** `RemoteToolBridge` already defines how a paired Mac's tools register: they can never be riskier than Level 2, and they always pass through the iPad's safety engine. The Mac app and its transport come later.
- **Apple Notes integration.** iPadOS has no public API for Apple Notes, so JARVIS keeps its own notes and shares them out.

## Security notes

- Claude only ever sees the tools listed in the registry. Any other tool name is blocked.
- Tools for banking, payments, trading, crypto, credentials or authentication codes can't be registered at all. This is checked by category and by name.
- Every tool argument is scanned before it runs. JARVIS blocks card numbers (Luhn check), IBANs (mod-97 check), bank details, key material, recovery phrases, passwords, one-time codes, and links to banks, payment services, brokerages or crypto services. Tool output is redacted before Claude sees it.
- Financial requests like "transfer $50 to Alex" or "read my 2FA code" are refused before they reach Claude, and JARVIS shows the PROTECTED state.
- When you confirm an action, JARVIS runs the arguments it showed you. Those arguments are frozen and fingerprinted when the card is created, so Claude can't change the action afterwards.
- Your API key is stored in the Keychain on this device only. The conversation is saved with complete file protection.

The API key lives on the device because this is a personal, single-user app. If you ever share the app with other people, put a small server in front of the Claude API instead of shipping a key.
