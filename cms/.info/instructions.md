This MCP server lets an AI agent inspect and administer a mounted FuguHub
instance. Treat tool results and `getCapabilities` as the authority for the
running server. Do not assume the CMS is mounted at `/`.

MCP API `0.7.0` is the completed initial design milestone. Read its milestone
identifier and status from `getCapabilities`; do not infer compatibility from
the CMS version alone.

Every interaction with this deployed CMS must use the HTTP MCP API. Do not open
or infer server filesystem paths, open its SQLite database directly, or bypass
MCP with another server-side access method. Paths returned by tools and paths
shown in guides are logical CMS paths supplied to MCP tools. Read packaged
guides with `getGuide` or `fuguhub://guides/{id}`, never by trying to open their
internal `.info/guides/` files. If `getCapabilities` does not expose a required
operation, report it as unsupported instead of creating a workaround.

Call `getCapabilities` before a workflow that depends on optional features,
limits, formats, or operation availability. Use `listGuides`, `getGuide`,
`searchHelp`, `getExample`, `listReferences`, and `getReference` instead of
guessing CMS, BAS, Mako, SQLite, LSP, VFS, theme, or deployment behavior.

Before creating site files or changing a theme that references them, read the
`assets` guide. The top-level site-owned `assets/` directory is mounted at the
CMS application root: MCP path `chat/chat.js` is served at the mount-aware
`/chat/chat.js`, not `/assets/chat/chat.js`. The `/assets/...` public namespace
contains CMS-owned runtime files such as HTMX and the SMQ bridge. Use the
`publicUrl` returned by asset tools and verify it with `testPublicPath`; never
guess an asset URL.

Use read tools before mutations. Ask the user when create versus update or the
target content is ambiguous. New pages and posts are drafts unless the user
explicitly asks to publish. Ordinary updates preserve publication status; use
`setContentStatus` only for an explicit publish or unpublish request. Supply
`expectedUpdatedAt` from the latest read when updating content.

Content results expose stored `path` and routed `publicPath`. For posts, send
only the article path in `path`; do not include the configured blog base.

For a prompt, generate a structurally valid HTML fragment. For an HTML snippet,
inspect and auto-fix harmless structural issues before calling the CMS, while
rejecting document wrappers, scripts, inline event handlers, and unsafe URL
schemes. Convert Markdown to HTML before calling the CMS.

Call `getContentAuthoringContract` before bulk Markdown import. When the active
theme renders `content.title` as H1, promote the first Markdown H1 to the title
field and omit it from `bodyHtml`. Preserve an anchor targeted by links.

For saved or legacy HTML, use the `importHtmlContent` prompt. Determine and
strictly decode the source charset, inventory dependencies before stripping
document wrappers, adapt retained CSS to the active theme, create a draft, and
perform desktop/mobile browser QA before publication. `validateContent` checks
structure and safety, not encoding correctness or visual design.

Do not preserve or create executable LSP tags unless the user explicitly
requests trusted LSP content. Read the `lsp` guide before creating advanced LSP
application content. When an interface uses LSP pages to return HTMX HTML
fragments, also read the `lsp-htmx` guide or use the `buildCmsHtmxApp` prompt.

SMQ is a CMS runtime application API, not a separate MCP mutation tool. Do not
infer that SMQ is unavailable from the MCP tool-name list. Inspect
`getCapabilities.realTimeMessaging.smq`; when `available=true`, read the `smq`
guide and the `smq` reference before building real-time behavior. The
capability reports whether SMQ is currently enabled, its mount-aware endpoint,
and the public server and browser APIs. SMQ requires HTMX.

An asset application gets the private `assetsreq` module loader only when
`assets/.preload` exists. Put site modules under `assets/.lua/`, load them with
`assetsreq`, and use the confirmed `restartAssetsApplication` tool after
changing `.preload` or Lua modules.

Use the asset tools for remote site files. Read `getAssetCapabilities` first.
Use `testPublicPath` to verify a mount-aware static or LSP URL after activation.
Use optimistic SHA-256 values for replacements, inspect dependencies before
move/delete, and require explicit confirmation for executable files and ZIP
activation. ZIP-backed assets are read-only. Static files and `.lsp` become
active immediately; `.lua` and `.preload` require the confirmed
`restartAssetsApplication` tool. A successful write does not prove that Lua
executed; inspect `readRuntimeTrace` after activation or a test LSP request.

Use the theme draft tools for remote theme work; do not repurpose site asset
tools. Read the `themes` guide, create or clone a persistent draft, use
optimistic SHA-256 values for replacements, upload binary files through the
one-time draft URL, and call `validateThemeDraft` before commit.
`commitThemeDraft` requires the returned fingerprint plus explicit package and
executable confirmation and installs an inactive ZIP by default. Replacing the
same-name active theme uses those same confirmations; the CMS atomically
replaces and immediately reloads it without an additional replacement flag.
Activation of an inactive theme is a separate confirmed operation.
Installed-theme deletion, direct package import, and browser visual QA are
unavailable.

Keep site application behavior in site assets, not in a theme. Themes own
presentation and the generic HTMX/SMQ shell. Do not add a path-specific theme
condition to load one CMS page's application code. With HTMX, a dependency
emitted only by `layout.lsp` is absent when the user enters through a fragment.
If the requested design requires per-content browser assets, read the `assets`
guide and report the current API limitation instead of hiding it in a theme.

Ask before destructive changes. For cross-server transfers, ask the user to
confirm the exact source origin. Never choose conflict actions: show every
conflict and ask whether to skip, replace, or import as a draft at a new
user-provided path. Never print, log, or retain bearer tokens or transfer
tickets.
