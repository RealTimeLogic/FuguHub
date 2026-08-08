Manage a FuguHub theme for this goal:

{{userGoal}}

1. Call `getCapabilities`, then `listThemes` and `listThemeDrafts`.
2. Read the `themes` guide with `getGuide`. If the theme references site-owned
   files, also read the `assets` guide. Site asset MCP path `chat/chat.js` is
   referenced as `model.url('/chat/chat.js')`, not
   `model.url('/assets/chat/chat.js')`.
3. For a new theme, call `createThemeDraft` with a new `name` and optionally
   clone an installed `fromTheme`. For an existing theme, use the same exact
   value for `name` and `fromTheme`.
4. Inspect installed or staged files with `listThemeFiles`, `getThemeFile`,
   `listThemeDraftFiles`, and `getThemeDraftFile`.
5. Use `writeThemeDraftText` for text files. Supply the latest
   `expectedSha256` when replacing a file. LSP requires the user's explicit
   approval and `confirmedExecutable=true`.
6. Use `prepareThemeDraftUpload` and its one-time URL for binary files. Send
   the exact declared bytes, content type, SHA-256 digest, and bearer token.
7. Call `validateThemeDraft` after all edits and retain its fingerprint.
   Keep page-specific application behavior in site assets. Do not add a
   content-path condition to `layout.lsp`; HTMX fragment entry bypasses the
   full document layout.
8. Show the validation result and ask the user to confirm packaging executable
   LSP. Call `commitThemeDraft` with that fingerprint, `confirmed=true`, and
   `confirmedExecutable=true`. By default, commit validates again and installs
   an inactive ZIP theme atomically.
9. If the draft has the same name as the active theme, the normally confirmed
   commit automatically performs the controlled in-place replacement and
   reload. A successful result has `active=true`, `reloaded=true`, and
   `activationRequired=false`; no additional replacement flag is required.
10. To activate an inactive committed theme, call `validateTheme`, show the result, ask
    for confirmation, call `activateTheme` with `confirmed=true`, and verify
    the result with `getCmsInfo`.
11. Use `prepareThemeFileDownload` for a binary installed file and
    `prepareThemeExport` for a validated, correctly rooted theme ZIP.
12. Installed-theme deletion, direct theme-ZIP import, and browser visual QA
    are not available. Do not substitute site asset tools for theme operations.
13. When a committed theme references a site asset, verify the exact
    `publicUrl` with `testPublicPath` and test a representative page at root and
    named mounts. Test application pages through both full-page and HTMX entry.
