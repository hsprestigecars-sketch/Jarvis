# What iPadOS allows, and what JARVIS does instead

| Request | iPadOS reality | What JARVIS does |
|---|---|---|
| "What's on my calendar?" | EventKit, full access with permission | Reads events directly |
| "Schedule karting Saturday at 3" | EventKit can write | Shows a confirmation card, then saves the event |
| "Remind me at 8 PM…" | EventKit Reminders, including location alarms | Creates the reminder directly (you can turn on confirmation in Settings) |
| "Take a note" | Apple Notes has no public API | Saves a JARVIS Markdown note, which you can share to Apple Notes |
| "Find the racing video I saved" | Apps can only see their own sandbox and files you pick | Searches the JARVIS folder. Imports go through the system document or photo picker |
| "Send Dad a message" | Apps can't send messages silently | Shows a confirmation card, then opens Apple's Messages composer. You tap Send |
| "Call Dad" | Calls go through the system prompt (on iPad, through iPhone Continuity or FaceTime) | Shows a confirmation card, then opens `tel:` or `facetime:`. iPadOS asks again before dialling |
| "Prepare this for TikTok / Instagram" | Publishing needs the official APIs, OAuth and an approved developer app | Builds a post package, checks it against platform limits, then uses the Share Sheet and copies the caption |
| "Publish it" | Only possible through the official APIs | Asks for confirmation, but only if an account is connected. Otherwise JARVIS says plainly that nothing was posted |
| "Help me with this code" | No code execution on iPad | Explains, reviews and writes code into the JARVIS folder. It never claims to have run anything |
| "Night mode: silence notifications" | Apps can't change Focus or system settings | Suggests your own Focus or Sleep Focus, and can run a Shortcut you made (with confirmation) |
| "Hey JARVIS" (screen off) | No always-on microphone for third-party apps | Siri: "Ask JARVIS…" or "Talk to JARVIS" through App Shortcuts |
| Controlling other apps | Not allowed | Opens apps through their public URL schemes, or runs your own Shortcuts |
| Battery or device info | `UIDevice` and `ProcessInfo` | Reports battery level and state, Low Power Mode, storage and OS version |
| Weather and news | WeatherKit needs a paid entitlement | Uses web search with citations |
