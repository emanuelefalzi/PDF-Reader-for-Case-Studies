// Settings module (SPEC §6.2, §5.11, M10).
//
// - `SettingsScene`/`SettingsView`: the SwiftUI `Settings` scene (⌘,) with
//   data folder, CLI path, models, chat budget and Claude status.
// - `ClaudeStatusSection`: CLI/login, "Verify" (`ClaudeStatusModel`, M4).
// - `SettingsPanels`: small shared AppKit utilities (`NSOpenPanel`).
// - `Laboratorio/`: SPEC §5.14 "Summary Lab", a separate window (Window
//   menu, or from Settings), not part of the Settings scene proper but
//   reachable from it.
