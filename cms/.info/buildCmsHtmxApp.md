Build a FuguHub LSP and HTMX interface for this goal:

{{userGoal}}

1. Call `getCapabilities`. Confirm `assetManagement` and `lspHtmxPattern` are
   enabled and the required asset operations are present.
2. MCP asset tools can build a site-owned interface under logical `assets/`
   paths but cannot modify `cms/admin/`. If the request requires an
   engine-source change, report it as unsupported.
3. For site-owned code, call `getAssetCapabilities`; use `assets/.preload`,
   `assets/.lua/`, and `assetsreq` for reusable services and application state.
   Read the `assets` guide. MCP path `chat/chat.js` is public at the returned
   mount-aware `/chat/chat.js`, not `/assets/chat/chat.js`.
4. Separate directly navigable LSP shells from fragment-only LSP endpoints.
   Reject direct fragment requests and implement application-specific session
   authorization and CSRF protection.
5. Generate every URL with `app.url()`. Preserve a working ordinary form action
   where practical and use multipart requests for large editor content.
6. Return HTML fragments whose root matches `hx-target` and `hx-swap`. Use
   `HX-Redirect` when an HTMX request must perform a full login navigation.
7. Route every SQLite mutation through the CMS writer API. Keep slow work and
   rendering outside the serialized write callback.
8. If the goal requires real-time messaging and
   `getCapabilities.realTimeMessaging.smq.available=true`, read the `smq`
   guide and reference. Use the shell-owned `window.cmsSmq` page scopes and
   register server behavior through `app.smq`; do not create page-local SMQ
   clients.
9. Keep application JavaScript, CSS, and SMQ behavior in site assets. Themes
   provide only generic rendering and the HTMX/SMQ shell. Do not add a
   path-specific condition to `layout.lsp`; HTMX fragment entry will bypass it.
   If the design requires automatic per-content browser dependencies, report
   that MCP API `0.7.0` does not expose them.
10. Use `writeTextAsset` with `confirmedExecutable=true` for LSP, Lua modules,
   and `.preload`. Ask before calling `restartAssetsApplication`.
11. Use the `publicUrl` returned by each asset write and call `testPublicPath`
    with that exact value. Do not guess or prepend `/assets`.
12. Test direct-fragment rejection, authorization, CSRF, committed fragment
   state, browser history, network-failure UI, and both root and named mounts.
    For SMQ, also test page-scope cleanup, reconnect, events, direct messages,
    RPC, and entry through both a full request and HTMX navigation.
13. Inspect `readRuntimeTrace` after activation and real LSP requests.
