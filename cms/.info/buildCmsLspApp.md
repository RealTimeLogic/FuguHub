Build trusted FuguHub LSP application behavior for this goal:

{{userGoal}}

1. Call `getCapabilities`. Confirm `assetManagement` is enabled and the
   required asset operations are present. Treat asset paths as logical MCP
   paths, not host paths.
   Read the `assets` guide: logical path `example/status.lsp` is mounted at the
   returned `/example/status.lsp`, not `/assets/example/status.lsp`.
2. Confirm that the user explicitly requested executable LSP.
3. Call `getAssetCapabilities`. Keep site-specific modules and services in
   `assets/.lua/` and startup logic in `assets/.preload`; do not modify the
   generic engine for app behavior. Load modules with `assetsreq`, never global
   `require`; the loader exists only when `.preload` exists.
4. Use `app.url()` for mount-safe URLs and the shared `app.db` writer API for
   every SQLite mutation.
5. Store database LSP with `renderMode=lsp`; use the request environment and
   persistent `page` table according to the guide.
6. Use `writeTextAsset` with `confirmedExecutable=true` for file-based LSP,
   modules, and `.preload`. When a `.lua` or `.preload` write returns
   `restartRequired`, ask for confirmation and call `restartAssetsApplication`
   before claiming the change is active.
7. Pass each successful asset write's exact `publicUrl` to `testPublicPath`.
   Do not guess a URL or prepend `/assets`.
8. Create database content as a draft, validate through a real request, and publish only after
   the user explicitly requests it.
9. Inspect `readRuntimeTrace` after actions expected to execute Lua.
