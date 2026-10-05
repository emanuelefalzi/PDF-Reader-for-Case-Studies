// Chat module (SPEC §6.2). The UI (button, panel, scope, context §7.8.2)
// comes with M9. M4 already ships `MarkerParser.swift`, the pure parser for
// the `[p. N]`/`<fuori>…</fuori>` markers (SPEC §7.8), which consumes the
// `ChatEvent.textDelta` events from `Claude/ChatSession.swift`.
