# Action Center v0.5 — Virtual HUD

Adds an interactive phone-side HUD simulator that drives the same `ActionCenterService` state machine used by the BLE path.

## Open it
Home → Legacy / Debug → Open Action Center Virtual HUD.

## Controls
- Left Tap: previous card/menu item
- Right Tap: next card/menu item
- Left Hold: reserved for Even AI
- Right Hold: select
- Back: back one Action Center level

## Stress tests
- Inject a new notification while a reply is being composed; the active recipient remains pinned.
- Remove the selected notification while replying; Action Center must not retarget the reply.
- Voice Reply is simulated locally in Virtual HUD so UX can be judged without BLE/mic/transcription dependencies.

No BLE writes are made by the virtual controls.
