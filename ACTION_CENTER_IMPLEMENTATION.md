# Action Center prototype

This branch adds the safe phone-side foundation for the proposed Even G1 Action Center.

Implemented:
- Android notification metadata now exposes `canReply` when a notification contains a free-form `RemoteInput` action.
- `replyNotification(key, text)` sends through the originating Android app's inline-reply action (no SMS permission / no replacement SMS client).
- Dart `ActionCenterCard` model retains the Android notification key, source, sender, body, type and reply capability.
- `ActionCenterReplyService` generates the requested three AI quick replies: affirmative, negative and contextual. Voice Reply remains a separate first UI option. Suggestions are short and have deterministic fallbacks.
- `ActionCenterService` filters notifications, excludes Calendar duplication, retains up to four cards, and owns reply dispatch.
- `Proto.setDashboardActionCard` implements the confirmed `0x1E` firmware QuickNote-slot packet shape for controlled device experiments.

Important safety gate:
- `ActionCenterService.experimentalQuickNoteSlotMirroring` is **false** by default.
- Firmware decompilation/source notes in this repo confirm that the known `0x1E` content records are QuickNotes, not arbitrary independent dashboard widgets. Enabling mirroring would repurpose/overwrite QuickNote slots. It must not be enabled on the user's daily glasses unless that tradeoff is explicitly desired.

Still required for the requested UX:
1. Reverse-engineer a non-destructive right-side dashboard content channel (likely one of the firmware-native `0x06` structured widget families) or prove a safe unused slot strategy.
2. Isolate/configure right long-press behavior. `LONG_PRESS_ACTION (0x07)` is known as a hardware subcommand, but its value mapping/host event behavior is not established in this repo.
3. Build the interactive Action Center menu state after a reliable silent select gesture is proven.
4. Wire Calendar reading/creation and native Translate/Transcribe/QuickNote launch after the interaction primitive is proven.

This keeps the prototype honest: notification actions/replies are real; the dedicated widget and long-hold navigation are not claimed solved before hardware validation.

## v0.2 hardware-proof changes

- Replaced the disabled QuickNote-slot mirror with a non-destructive native-dashboard proof using the documented `0x06 / 0x03` Calendar secondary pane record format.
- The firmware owns right-temple single-tap paging. Incoming `0x22` dashboard status is parsed to track the 1-based pane page and therefore the exact selected Action Center card.
- While the Action Center dashboard is visible, a right-temple long hold (`0x21` release) is consumed as **Select** and does **not** trigger QuickNote audio retrieval. Outside Action Center, the existing QuickNote flow is unchanged.
- Selecting a card opens its sender/body on the proven `0x4E` text surface. This is intentionally a hardware proof before wiring the full Reply/Back/menu state machine.
- Head-up is set to firmware Dashboard mode while Action Center is enabled; the existing Glance `F5 02/03` overlay handler is bypassed so it cannot steal the firmware carousel.
