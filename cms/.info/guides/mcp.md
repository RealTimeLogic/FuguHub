---
name: fuguhub-mcp-agent
description: Use when an AI agent connects to FuguHub over MCP to administer content, assets, taxonomy, navigation, redirects, settings, themes, diagnostics, runtime trace, or ZIP transfers.
---

# FuguHub MCP Skill

## Remote MCP Boundary

Every operation on the deployed CMS must use this server's HTTP MCP tools,
resources, or prompts. Never open or infer host filesystem paths, open SQLite
directly, or bypass MCP with another server-side access method. Paths returned
by tools are logical CMS paths. Read related guidance with `getGuide` and guide
IDs, never by attempting to open the packaged Markdown files. If
`getCapabilities` does not expose an operation, report it as unsupported
instead of creating a workaround.

Use this skill for a running FuguHub Streamable HTTP MCP server. For the content
data model, call `getGuide` with `id="database"`.

## API Milestone

MCP API `0.7.0` is the completed initial MCP design milestone. Its capability
identifier is `mcp-api-0.7.0`. `getCapabilities` reports the exact API version,
milestone status, and milestone date; use those fields instead of inferring MCP
compatibility from the CMS engine version.

The milestone covers the endpoint and authentication contract, discovery and
embedded guidance, content and site administration, assets, persistent theme
drafts and active-theme replacement, diagnostics, runtime trace, and
selected-content transfer. The deliberately unavailable section below is part
of the milestone contract, not an undocumented implementation gap.

Future additive operations must preserve this behavior. A breaking endpoint,
tool schema, authentication, transfer-format, or mutation-contract change
requires a new `mcpApiVersion`.

## Connect And Discover

An administrator saves a bearer token at `/admin/mcp/`. The server is disabled
until the token exists. The token is AES-GCM encrypted in the SQLite `options`
table with a key derived from `ba.tpm.uniquekey`; it is never returned by MCP.

The mount-aware endpoint is `<cms-base>/mcp/`:

```text
http://localhost/mcp/
http://localhost/mybase/mcp/
```

Use this directory endpoint exactly. There is no `mcp.lsp` alias. Send the token
only as `Authorization: Bearer <token>`, initialize Streamable HTTP, and retain
the returned `MCP-Session-Id`.

Call `getCapabilities` first when a task depends on available modules, limits,
operation classes, supported values, mount paths, or archive compatibility.
Do not infer an unavailable feature from generic tool schemas.

SMQ is reported under `realTimeMessaging.smq`, not as a standalone MCP
mutation tool. That block reports availability, current enablement, the
mount-aware endpoint, and the `smq` guide and reference IDs.

Guidance is available through:

- `listGuides`, `getGuide`, `searchHelp`, `getExample`, `listReferences`, and
  `getReference`;
- `fuguhub://instructions`, `fuguhub://capabilities`, and
  `fuguhub://guides/{id}`;
- `createCmsContent`, `importHtmlContent`, `buildCmsLspApp`,
  `buildCmsHtmxApp`, and `manageCmsTheme` prompts.

The authoritative operational guides, stable client policy, and workflow
prompts are embedded in `cms/.info/` and read through the CMS application IO.
They remain available when the CMS is packaged independently of the runtime
home directory. `searchHelp` also indexes reference titles, scopes,
applicability, and URLs; a match with `kind="reference"` should be followed
with `getReference`.

## Content Rules

Read before writing. Ask the user when create versus update or the target is
ambiguous.

- `createContent` and `copyContent` create drafts unless the user explicitly
  requests publication.
- `updateContent` preserves publication status. It does not accept a publish
  flag.
- `setContentStatus` is the explicit publish/unpublish operation.
- Send `expectedUpdatedAt` from the latest `getContent` result on updates,
  status changes, and permanent deletion. A stale value returns
  `contentConflict`.
- `listContent` supports stable cursors, search, path/date/taxonomy filters,
  sorting, optional totals, and optional bodies/terms.
- `getContentBatch` reads up to 100 known ids or paths.
- `validateContent` applies size, HTML safety, internal-link, and render-mode
  checks without saving. LSP is parsed and compiled but never executed.
- Content results expose `path` as the stored path and `publicPath` as the
  routed URL. They are identical for pages. For posts, `path` omits the
  configured blog base while `publicPath` includes it.
- When creating or updating a post, send only its article path, for example
  `/release-notes/`. Do not prefix it with `blogBasePath`. The CMS derives the
  public URL and changing the setting does not rewrite post rows.
- Categories are taxonomy terms whose `type` is `category`. Use `listTerms`,
  `createTerm`, `updateTerm`, and `deleteTerm` to manage them. Supply their ids
  in a post's `termIds` to assign categories; do not create menu items or
  content rows for category archives.
- A category archive is generated automatically at
  `<blogBasePath>category/<slug>/`. Changing `blogBasePath` moves the archive
  without rewriting the term or its post assignments.

Generate a structurally valid HTML fragment from a prompt. Inspect an HTML
snippet and repair only harmless structural mistakes. Convert Markdown to HTML
before calling the CMS. Reject document wrappers, scripts, inline event
handlers, and unsafe URL schemes.

The validator examines actual element attributes rather than matching
`on...=` text globally. Code examples such as
`<pre><code>onerror=function()</code></pre>` are valid; a real
`<img onerror="...">` remains invalid.

Call `getContentAuthoringContract` before Markdown import. The default theme
renders `content.title` as the sole H1, so promote the first Markdown H1 to the
title field and omit it from `bodyHtml`. Preserve an anchor if links target the
removed heading. `validateContent` returns a theme-aware warning when the body
contains the heading element already owned by the theme.

Do not create, preserve, validate as LSP, or copy executable LSP unless the user
explicitly requests trusted LSP content. Copying LSP requires `allowLsp=true`.

## Legacy HTML Import And Visual QA

Use the `importHtmlContent` prompt when importing a saved page or legacy HTML
document. Do not treat this as ordinary fragment cleanup.

1. Determine the source charset from HTTP headers, a BOM, and HTML metadata.
   Decode strictly and stop on undecodable bytes or conflicting declarations.
   Do not silently insert replacement characters.
2. Check the decoded text for mojibake. Suspicious sequences such as `Ã`,
   `Â`, `â€™`, or `ðŸ` require rechecking the source decoding.
3. Parse the complete source and inventory stylesheets, scripts, images, fonts,
   media, and generated widget markup before removing document wrappers.
4. Classify dependencies. Import safe static files through the asset API.
   Never preserve scripts, inline handlers, or server-executable content
   without the corresponding explicit approval.
5. Replace script-dependent widgets with static accessible markup when
   practical. Scope retained CSS to a unique article wrapper or deliberately
   adapt the markup to the active theme. Do not copy global legacy styles into
   the theme without review.
6. Rewrite asset references using the mount-aware `publicUrl` returned by asset
   tools. Apply the active title/heading contract and preserve targeted
   anchors.
7. Call `validateContent`, then create or update a draft. Structural validation
   does not check character-encoding correctness, CSS contrast, responsive
   overflow, missing runtime dependencies, or visual quality.
8. Use the authenticated admin Preview action to render the draft through the
   active theme. Test desktop and mobile breakpoints, text contrast, horizontal
   overflow, headings, tables, code blocks, lazy-loaded media after scrolling,
   missing assets, and browser console/network errors.
9. Correct defects and repeat validation and browser QA. Publish only on an
   explicit user request.

Trash and revisions are not available. `deleteContent` is permanent:

1. Call `getContentDependencies`.
2. Show linked menu items, redirects, child paths, and required-page state.
3. Ask for explicit confirmation.
4. Ask whether menu items and related redirects should be preserved or deleted.
5. Never delete child content automatically.

The active editable 404 page cannot be deleted; change settings first.

## Administration Tools

Taxonomy:

- `listTerms`, `createTerm`, `updateTerm`, `deleteTerm`

Menus:

- `listMenus`, `getMenuLocations`, `createMenu`, `updateMenu`, `deleteMenu`
- `createMenuItem`, `updateMenuItem`, `deleteMenuItem`
- Set `topLevel=true` to force a new item to the menu root or promote an
  existing item by clearing its parent. Omit both `topLevel` and `parentId`
  when URL-prefix parent inference is desired. Supply a valid `parentId` to
  place or move an item below that parent.

Redirects:

- `listRedirects`, `setRedirect`, `deleteRedirect`
- `setRedirect` rejects self-loops and redirect chains that form loops.

Site and themes:

- `getSettings`, `updateSettings`
- `smqEnabled` is an HTMX-dependent setting. Enabling it without
  `htmxEnabled=true` produces an effective value of `false`. For application
  integration, call `getGuide` with `id="smq"`.
- Installed theme reads: `listThemes`, `listThemeFiles`, `getThemeFile`,
  `prepareThemeFileDownload`, `prepareThemeExport`
- Theme drafts: `listThemeDrafts`, `createThemeDraft`,
  `listThemeDraftFiles`, `getThemeDraftFile`, `writeThemeDraftText`,
  `prepareThemeDraftUpload`, `prepareThemeDraftDownload`,
  `deleteThemeDraftFile`, `validateThemeDraft`, `discardThemeDraft`
- Theme installation: `commitThemeDraft`, `validateTheme`, `activateTheme`
- Use `dryRun=true` before a complex settings change.
- Read the `themes` guide before authoring. Draft replacements use optimistic
  SHA-256 checks. Commit requires a current validation fingerprint and explicit
  package and executable confirmation and installs an inactive ZIP by default.
  A commit whose draft has the same-name active target atomically replaces and
  immediately reloads that theme using the normal commit confirmations.
- Theme activation is a separate confirmed operation and takes effect without
  a Mako restart.

Operations:

- `getHealth`, `getSchemaInfo`, `runIntegrityCheck`, `clearCache`
- Diagnostics do not return secret options, database files, or unrestricted
  SQL access.

## Asset Tools

Call `getAssetCapabilities` before changing assets. It reports the active
source, writability, shadowed directory, package presence, limits, public base
URL, executable policy, and activation/restart behavior.

Read the `assets` guide before creating files or referencing them from content
or a theme. The top-level site source directory name is not public:

```text
MCP path:       chat/chat.js
publicUrl:      /mybase/chat/chat.js
theme LSP:      model.url('/chat/chat.js')
incorrect URL:  /mybase/assets/chat/chat.js
```

`/assets/...` is reserved for CMS-owned files such as HTMX and the SMQ bridge.

Read and discovery:

- `listAssets`, `getAsset`, `getAssetDependencies`
- `testPublicPath` for a bounded same-origin `GET` or `HEAD`
- `prepareAssetDownload`

Directory-backed mutations:

- `writeTextAsset`, `prepareAssetUpload`, `createAssetDirectory`
- `moveAsset`, `deleteAsset`
- `validateAssetCode`

Rules:

- Paths are relative to the active assets root. Never send absolute paths,
  drive letters, backslashes, `..`, or physical server paths.
- `assets.zip` is read-only while active.
- Directory-backed capabilities omit `readOnlyReason`; ZIP-backed capabilities
  include the reason.
- Missing files return `assetNotFound` with the normalized relative path.
- Empty `warnings` and `validationWarnings` values are JSON arrays.
- Validation failures include `kind`, `path`, a safe native parser/compiler
  message, and source coordinates when the native API reports them.
  `ba.json.decode` may identify only `parse`, `data`, `interface`, or `memory`
  because it does not return a source offset.
- Replacing, moving, or deleting a file requires the latest SHA-256 value.
- Inspect `getAssetDependencies` and ask before move/delete. Dependency results
  are bounded and always `complete=false`.
- `createAssetDirectory` is idempotent. An existing directory returns
  `created=false`, `exists=true`, and `directory=true`; a file at that path is
  still a conflict.
- Binary uploads use the one-time URL returned by `prepareAssetUpload`; upload
  exact bytes with the declared content type, SHA-256, byte count, and the same
  bearer token. Follow the returned method, required headers, expiration,
  one-use, and redirect-policy metadata. Never print or log the token or ticket.
- Use `writeTextAsset` for `.lsp`, `.lua`, and `.preload`, with
  `confirmedExecutable=true` only after explicit user approval.
- `.lua` modules must be below `.lua/`; `.preload` is allowed only at the
  assets root.
- Static files and `.lsp` become visible immediately. `.lua` and `.preload`
  return `restartRequired=true`.
- After a `.lua` or `.preload` write, ask for explicit confirmation and call
  `restartAssetsApplication`. It invokes the old asset app's `onunload`,
  discards the private `assetsreq` cache, reruns `.preload`, and refreshes the
  public LSP environment without restarting Mako.
- A runtime preload failure returns `assetsPreloadFailed` and leaves the asset
  app inactive. Fix the executable asset and call the tool again; automatic
  rollback is not implemented.
- Compile validation does not execute code. Verify static and LSP activation
  by passing the exact returned `publicUrl` to `testPublicPath`, then inspect
  `readRuntimeTrace` when runtime behavior matters. Do not construct or guess a
  second URL. `testPublicPath` accepts only a mount-aware path on this CMS origin,
  never forwards credentials, never follows redirects, excludes admin/MCP
  routes, limits reads to 256 KiB, and times out after five seconds.

`prepareAssetsExport` returns a one-time correctly rooted assets ZIP.
`prepareAssetsImport` validates and installs an uploaded `assets.zip` after
explicit confirmation. The package becomes active after Mako restart. Rollback
is not implemented.

## Runtime Trace

`readRuntimeTrace` follows the LSP-Claw behavior: it returns and clears a
bounded server-global BAS trace buffer. Live Streamable HTTP clients may also
receive `notifications/message` events with `logger="trace"`.

Trace output is not reliably attributable to one CMS app and is not filtered
or redacted by FuguHub. Do not print secrets from application code.

Every destructive tool requires `confirmed=true`. Ask the user immediately
before sending it. Theme activation, publication, executable code, and
dependency/conflict choices also require explicit user direction.

## ZIP Export And Transfer

`prepareContentExport` creates a one-time ZIP download for selected content ids
or paths. `prepareContentTransfer` creates an immutable one-time snapshot and
returns a direct-transfer descriptor. Archives contain selected pages/posts,
their metadata, and taxonomy assignments; menus and redirects are not included.

To transfer between CMS servers:

1. Call `prepareContentTransfer` on the source.
2. Relay the descriptor to `importContentTransfer` on the destination.
3. Show the exact `sourceOrigin` from `transferSourceRequiresConfirmation` and
   ask the user to confirm it.
4. Retry with that exact `confirmedSourceOrigin`.
5. If `contentConflictsRequireDecision` is returned, show every conflict and
   ask whether to `skip`, `replace`, or `importDraft`.
6. `importDraft` requires a new user-provided path.
7. Publish imported source content only on an explicit request.

Never choose a conflict action. Never forward either persistent bearer token.
Do not print, log, summarize, or retain the short-lived transfer ticket.

## Packaged Server Components

The engine packages FastMCP, stable instructions, guides, prompts, content and
site tools, archive transfer support, asset tools, configuration, and runtime
trace access. These components are internal to the deployed application and
are not client filesystem resources. Discover and use them only through the
HTTP MCP endpoint.

The API is a named BAS VFS child `mcp`, so it follows root and named mounts.
All SQLite mutations use the CMS writer thread.

MCP Inspector may use another loopback port. The CMS permits cross-port Origin
requests only when both sides are loopback. Non-loopback browser requests
require exact same origin.

## Deliberately Unavailable

The capability response reports features that need structural CMS work as
unavailable. Do not emulate them with unsafe workarounds:

- trash, revisions, scheduling, and editorial workflow;
- media-library metadata and image processing;
- full-site backup/restore;
- roles, audit history, and separate privilege scopes;
- plugin installation, localization, comments, forms, analytics, and webhooks;
- arbitrary SQL and schema migration;
- asset ZIP rollback;
- installed-theme deletion, direct theme-package import, and browser visual QA.

## Validation

Run:

```powershell
powershell -ExecutionPolicy Bypass -File tests\run.ps1
```

The suite validates root and named mounts, initialization instructions,
milestone capability metadata, guides/resources/prompts, content lifecycle and
concurrency, pagination/search/validation/copy/delete, taxonomy, menus,
redirects, settings,
theme draft creation/modification/validation/commit/export, automatic
same-name active-theme replacement, ZIP themes,
directory/ZIP assets, binary transfers, executable validation,
runtime trace, SMQ discovery/settings, diagnostics, authentication,
supplementary-plane Unicode
create/read/update/export, and live two-server transfer.
