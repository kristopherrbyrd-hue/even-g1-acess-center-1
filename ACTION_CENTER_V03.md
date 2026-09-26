# Action Center v0.3

Hardware-proof interaction layer on top of v0.2.

## Added
- Pins the selected notification for the entire interaction so a newly arriving notification cannot change the reply target.
- Right-hold on a selected actionable notification opens Reply.
- AI reply menu exposes affirmative / negative / contextual options.
- F5 01 left/right feature taps move through Action Center choices while its text surface owns the display.
- Right-hold selects the highlighted reply.
- Confirmation screen always appears before Android RemoteInput is invoked.
- F5 00 acts as Back through confirmation -> replies -> notification -> dashboard.
- Dashboard refreshes are deferred while an interaction is active.
- If the underlying notification disappears, Action Center consumes the hold and reports that it is unavailable rather than falling through into QuickNote capture.

## Deliberately not enabled yet
Voice Reply. The repository has multiple glasses-microphone pipelines with different lifecycle semantics. v0.3 does not bind Voice Reply until that flow is isolated and tested; silent replies remain usable.

## Safety invariant
No quick reply sends directly from the suggestion menu. Sending requires a second explicit hold on `Send` in the confirmation view.
