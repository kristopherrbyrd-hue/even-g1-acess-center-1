# Action Center v0.4

Adds glasses-microphone Voice Reply to the v0.3 interaction flow.

Flow: notification card -> right hold -> Reply -> Voice reply -> right hold to start -> speak -> right hold to finish -> transcribe -> Send/Back confirmation -> send through Android RemoteInput.

Safety behavior:
- Selected notification remains pinned by ID through the entire interaction.
- Voice transcripts never auto-send.
- Back while recording cancels capture.
- Empty/failed transcription returns to reply choices and sends nothing.
- Temporary voice WAV is deleted after transcription.
- Exiting Action Center always refreshes the native dashboard cards.
- Left long-hold handling is unchanged.

Build note: this environment does not contain the Flutter SDK, so this source pass has not been Flutter-compiled here. Hardware/protocol behavior still requires a real G1 test.
