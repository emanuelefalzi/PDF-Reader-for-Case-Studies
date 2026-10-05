// Claude module (SPEC §6.2): the access layer to the `claude` CLI.
//
// - `ClaudeCLILocator`: path lookup, `--version`/`--help`, caching.
// - `ClaudeAuth` / `ClaudeStatusModel`: `claude auth status` and the
//   app-level observable state (SPEC §5.11).
// - `ClaudeEnvironment` / `ClaudeProcessSupport`: working directory,
//   environment, running a one-shot process (SPEC §7.5).
// - `ClaudeError` / `ClaudeErrorMapper`: errors and user-facing messages
//   (SPEC §5.5), recognized from the text returned by the CLI.
// - `ClaudeResources`: loading prompts and schemas from the bundle
//   (`Resources/Prompts`, `Resources/Schemas`: prompts live in Resources,
//   not in code).
// - `BatchRunner`: queue and single process for one-shot calls (analysis,
//   generated contents; SPEC §6.3, §7.5).
// - `ChatProcessIO` / `ChatSession` / `ChatProcessOwner`: persistent
//   `stream-json` process for the chat (SPEC §7.8); the UI arrives with M9,
//   this file only covers the process lifecycle.
// - `TocGenerator`: generated contents (SPEC §7.4), the first real use of
//   `BatchRunner`.
