# JARVIS architecture

## Pipeline

1. **Input.** Text from the chat, or speech from `VoiceInput` (Apple Speech, on-device when available). A request can also come from Siri or Shortcuts through `AskJarvisIntent`.
2. **CommandProcessor** (`JarvisCore/Agent/CommandProcessor.swift`) handles some inputs deterministically before any network call:
   - "Stop" and "JARVIS, stop" trigger the **emergency stop**.
   - "Cancel", "never mind" and "no" (only while a confirmation is waiting) cancel the most recent pending action, or the turn that is running.
   - "Confirm" approves the waiting action, but only when exactly one action is waiting.
   - Imperative financial or credential requests get **PROTECTED** and never reach Claude.
3. **JarvisAgent** (`JarvisCore/Agent/JarvisAgent.swift`) calls `POST /v1/messages` with the registered tools plus Anthropic's web search and web fetch. It uses adaptive thinking and server-side refusal fallback. Assistant turns are stored and sent back to Claude unchanged, thinking blocks included. The current date and time go in the user turn, so the system prompt stays cacheable.
4. **SafetyEngine** checks every `tool_use` before it runs. The possible outcomes are:
   - **Block**: the tool isn't registered, its category is blocked, its name looks financial, or an argument contains Level 3 material.
   - **Confirm**: the tool is Level 2, or you chose "always confirm" for it.
   - **Allow**: the tool runs.
   User overrides can only make a decision stricter, never looser.
5. **ConfirmationEngine** holds Level 2 actions:
   - Each `PendingAction` stores the tool name and a **frozen** copy of the arguments, plus a fingerprint (`tool|canonical-json`).
   - The card shows `ConfirmationDetails` (action, target, content, account, settings, risk). JARVIS builds these from the frozen arguments, not from text Claude wrote.
   - Confirming needs the matching fingerprint, and it runs the frozen arguments.
   - If Claude asks for something different, that is a new tool call, so it gets a new card.
   - Pending actions expire after 10 minutes.
6. **Tools** (`App/Integrations/*`) run on the main actor using EventKit, Contacts, UserNotifications, FileManager (inside the JARVIS folder only), MessageUI, UIActivityViewController, AVFoundation and PDFKit.
7. **Result.** Output is redacted (card numbers, key material). Output from untrusted sources (files, notes, calendar text, Mac tools) is wrapped in `<untrusted_content>` before Claude sees it. Claude then writes the reply. If the input was spoken, the reply is spoken too.

## Emergency stop

`EmergencyStop` is a list of handlers that run synchronously on the main actor:

- cancel pending confirmations
- cancel the agent task
- stop speech
- stop the microphone
- dismiss system sheets
- remove queued JARVIS timers

The agent then repairs the conversation history. Every `tool_use` gets a matching "cancelled" `tool_result`, so the next request is still valid. A stopped or replaced turn can't write to the history again, because each turn carries an `activeTurn` token. The stop only affects work JARVIS started. It never touches iPadOS settings or security.

## Safety levels

| Level | Behaviour | Examples |
|---|---|---|
| 1 SAFE | Runs immediately | read calendar/reminders, create reminder, notes, read/create files, timers, research, prepare social post |
| 2 CONFIRM | Shows a confirmation card, then runs the frozen action | create/edit/delete events, delete reminders/notes/files, move/overwrite files, send message/email, call, run Shortcut, publish post |
| 3 BLOCKED | Can't be registered; arguments and requests are scanned | banking, cards, payments, trading, crypto, passwords, OTP/2FA/recovery codes, business financial systems |

## Untrusted content

The system prompt says that tool output and web content are data, not instructions. The code backs this up:

- **Wrapping.** File, note and calendar output is wrapped in `<untrusted_content>`.
- **Same checks for every tool call.** Instructions injected into a web page or file can't skip the safety engine. Any tool call they cause still goes through the safety engine and, for Level 2, through your confirmation.

## Mac companion (future)

`RemoteCompanionChannel` and `RemoteToolBridge` define how a paired Mac plugs in:

- **Pairing.** The Mac and iPad pair explicitly, and you verify the Mac's key fingerprint.
- **Tool registration.** The Mac advertises its tools. The iPad registers them with a `mac_` prefix through the normal registry, so blocked categories and names are refused there too.
- **Risk level.** Mac tools default to at least Level 2.
- **Calls.** Every call passes the iPad's safety engine, and Level 2 calls also need your confirmation. The Mac then checks again with its own safety layer before running anything.
