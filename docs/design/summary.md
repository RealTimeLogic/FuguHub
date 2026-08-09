# FuguHub Maintenance Architecture

This is the maintainer entry point for the completed FuguHub CMS. It records
the boundaries and call chains that must remain stable when correcting bugs or
adding features. Operator workflows belong in
[FuguHub-User-Manual.md](../FuguHub-User-Manual.md), public Lua contracts in
[FuguHub-API.md](../FuguHub-API.md), and agent workflows in the embedded guides
under `cms/.info/guides/`.

## Maintenance References

- [application-layout.md](application-layout.md): package ownership, IO,
  loaders, VFS precedence, multi-domain startup, and unload order.
- [database-schema.md](database-schema.md): canonical core tables, indexes,
  settings, migrations, and runtime rules.
- [admin-ui.md](admin-ui.md): admin callback/LSP split, HTMX fragments,
  authentication markers, CSRF, and tests.
- [performance.md](performance.md): measured request costs, read caches,
  invalidation, and the deferred rendered-response cache.
- [enhancement-backlog.md](enhancement-backlog.md): deliberate limitations and
  enhancement candidates. It is not a release checklist.

The implementation is authoritative. Verify native APIs in the BAS/Mako
documentation and update these files when a contract changes.

## Runtime Boundaries

```text
cms/       Generic engine, admin UI, MCP, engine assets, and private modules
themes/    Public presentation packages, as directories or ZIP files
assets/    Site-owned files and optional public LSP application
plugins/   Optional trusted executable extensions
data/      Mutable CMS and plugin state
```

The engine must remain usable without `assets/` or `plugins/`. Site behavior
belongs in `assets/.preload`; presentation belongs in themes; optional platform
services belong in plugins. The engine must not acquire site-specific code.

The application may be mounted at `/` or below a named base. Code that emits
URLs uses `app.url()`, `app.pathFromUri()`, or `app.redirect()` and does not
hard-code root-relative application routes.

## Startup Chain

`cms/.preload` performs these stages:

1. Capture the original application directory and open engine and Mako home
   IOs. Create/open `themes`, `assets`, and `data` as needed.
2. Install application-private `appreq`, runtime URL helpers, event/page-state
   services, SQLite access, and runtime invalidation.
3. Acquire the SQLite writer connection and verify ownership.
4. Load `dbsetup` only when the database is absent or the known core schema
   requires additive repair or the supported content-path migration.
5. Ensure the core identity schema, start or inject the identity service, and
   apply the one-time command-line bootstrap when requested.
6. Load settings; activate a valid theme; configure SMQ; load the encrypted MCP
   token; and create the MCP runtime.
7. Discover trusted plugins, validate descriptors, resolve dependencies, and
   start them in dependency order.
8. Execute optional `assets/.preload`, install its private `assetsreq` loader,
   and select `app.assetsApp` as the public LSP environment.
9. Install the LSP filter and the admin, MCP, SMQ, CMS router, and editable 404
   VFS nodes.

Any stage executed through `startupStep` that fails installs the app-scoped
fatal `503` responder and writes the failure to trace. It does not terminate
Mako or damage other mounted applications.

On unload, the assets application receives `onunload`, plugins stop in reverse
dependency order, admin authentication and VFS nodes are unlinked, theme and
MCP runtime objects close, and the database writer/connection closes.

## Public Request Chain

For a normal public request:

1. BAS enters the application VFS at the root or named mount.
2. The assets resource reader gets first opportunity. Static files and asset
   LSP therefore override database-backed routes.
3. Named plugin VFS nodes, `/admin/`, `/mcp/`, and `/SMQ/` handle only their
   namespaces. A callback returns `false` only when it did not handle and did
   not commit the response.
4. The unnamed CMS router normalizes the mount-relative path and checks draft
   preview, redirects, the blog archive, category archives, and published
   content.
5. The router emits `app.cms:emit("access", env, context)`. A listener may
   observe the request or mark it handled.
6. The router selects the cache policy, ETag variant, page state, active menu,
   and theme model.
7. The theme renders `page.lsp`, `post.lsp`, `archive.lsp`, `fragment.lsp`, or
   `not-found.lsp` as appropriate.
8. `renderer.renderBody()` writes trusted HTML directly or compiles and runs
   database LSP with `ba.parselsp()` in the active request environment.
9. `response:setresponse()` supplies negotiated compression when the client
   supports deflate. Headers and validators distinguish full and HTMX fragment
   variants.
10. If every higher-priority node declines the request and editable 404 is
    enabled, the priority `-127` directory renders the configured CMS content
    with HTTP status 404.

The active public LSP app is `app.assetsApp or app`. Database LSP, asset LSP,
and theme templates participating in one request share the BAS command
environment. Persistent virtual-page state comes from `app.pageTable(scope,
key)`, not from the request environment.

## Rendering And Presentation

`content.render_mode` is `html` or `lsp`. HTML is trusted administrator markup.
LSP is trusted server-side Lua and executes on every request, including when
browser revalidation is enabled. Do not cache complete rendered LSP output
without an explicit deterministic-output contract.

Installed themes are external packages. A theme is opened from
`themes/<name>.zip` when present, otherwise `themes/<name>/`. When the external
theme store is empty, the packaged default is opened with
`pathio(app.engineIo, "fallback-theme")`. Activation compiles all required
templates before replacing the active VFS reader. Failure leaves the previous
valid theme active; startup searches installed fallbacks and becomes fatal only
when no theme can load.

Theme templates receive a render model and the active public app. They render
data but do not own durable mutations. The exact authoring contract is exposed
to agents by `cms/.info/guides/themes.md`.

## Data And Invalidation

Core data is in `data/cms.sqlite.db`. All runtime writes use
`app.db.writeSync`, `app.db.writeAsync`, or `db.withWrite`; the writer thread is
the exclusive write owner. Reads use short-lived connections and bounded
runtime caches.

`app.invalidateRuntime()` clears published-content, redirect, menu, taxonomy,
page-table, and parsed-LSP state and advances the presentation revision used by
ETags. Every mutation that changes public output must invoke this hook after a
successful commit. Direct external database changes while the CMS runs are
unsupported because they bypass invalidation.

Posts store only their article path. `blog_base_path` is prepended at routing
time, allowing the public blog base to change without rewriting post rows.
Menus and redirects whose URLs use the old base are rebased by the settings
mutation.

## Authentication And Multi-Domain Ownership

Core identity profiles, roles, assignments, audit rows, and the TPM-encrypted
JSON-user blob live in the CMS SQLite database. Authentication is disabled only
while no enabled user has `cms-admin`; otherwise the admin VFS uses the native
BAS form authenticator and authorizer. Admin LSP fragments also require the
session marker `session.isCmsAdmin` so authentication performed by another app
does not grant CMS administration.

`CmsDomains` starts exactly one control CMS first. The control owns identity
and the shared management plugins. Consumer domains receive the same identity
service but keep independent CMS databases, assets, themes, sessions, and
public content. Consumers stop before the control. Configuration and packaged
startup details are maintained in
[application-layout.md](application-layout.md) and the user manual.

## Admin And MCP Surfaces

Admin is a named VFS child. Callback routes handle the dashboard, forms, and
small actions; Content and Menus use physical LSP pages and server-rendered HTMX
fragments. All mutations require the CMS-admin check and session-backed CSRF.
See [admin-ui.md](admin-ui.md) before changing admin routing.

MCP is a separate mount-aware `/mcp/` child and remains disabled until an
encrypted bearer token is configured. `getCapabilities` and the embedded
instructions/guides are the compatibility source of truth for remote agents.
Content creation defaults to draft; publication, executable content,
destructive operations, theme activation, and conflicting transfers require
the explicit confirmations declared by the tools.

When changing MCP behavior:

1. Preserve the endpoint and bearer-token contract.
2. Update `getCapabilities` and affected embedded guides/prompts.
3. Keep direct binary transfers bounded, one-use, authenticated, and digest
   checked.
4. Test root and named mounts and any cross-server transfer path.

## Extension Boundaries

`assets/.preload` is the site application. It receives the active public `app`,
site IO, and `app.assetsreq`, whose module cache is private to that assets
application. `restartAssetsApplication` calls the old `onunload`, discards the
cache, reruns the preload, updates the LSP filter, and invalidates runtime state.

Plugins are trusted packages with a root `.preload`. They receive owner-scoped
registration helpers for native VFS mounts, admin entries, APIs, services, and
cleanup. Plugin modules use `pluginreq`; mutable state stays under
`data/plugins/<id>/`. Do not add a plugin wildcard to the CMS router or expose
plugin-private modules through global `require`.

## Validation

Run the complete harness from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File tests\run.ps1
```

For request-path or packaging changes, also build both deployment variants and
exercise the stress harness when performance can be affected. Tests must cover
root and named mounts, HTML and LSP, full and HTMX responses, authentication,
CSRF, SQLite restart/ownership, theme and asset ZIPs, plugins, MCP, compression,
and browser cache revalidation as applicable.
