# FuguHub Agent Guide

This repository contains the generic FuguHub runtime. Read this file first, then
open only the documentation needed for the task.

## Repository Map

```text
cms/       Generic CMS engine
assets/    Site-owned files and optional public LSP application
themes/    Installed themes, outside the engine
plugins/   Optional trusted plugin directories or ZIP packages
data/      Mutable CMS SQLite database and optional plugin data
stress/    Reproducible seeded deployment and concurrent GET benchmark
docs/      Agent skills and design references
```

Run development instances from this directory so Mako's `home` IO resolves to
the runtime root:

```powershell
mako -l::cms
```

The engine can also be mounted below a named base URI. Site code and themes must
therefore use `app.url()`, `app.pathFromUri()`, and `app.redirect()` instead of
assuming the application is mounted at `/`.

## Start Here

The links in this file are for an agent working in this local source checkout.
An agent connected to a deployed `cms.zip` cannot open these paths. It must use
the CMS HTTP MCP API: call `listGuides`/`getGuide`, read
`fuguhub://guides/{id}`, and perform all deployed-server reads and mutations
through MCP tools. It must never infer remote filesystem or SQLite access.

Read [FuguHub Site Builder](cms/.info/guides/site-builder.md) before creating,
extending, debugging, or deploying a site. It defines the shared BAS, Mako, LSP,
VFS, `_ENV`, `app`, and `page` model.

Then select the task-specific skill:

- [FuguHub Benefits](docs/FuguHub-benefits.md): human-facing overview of
  measured performance, the indicative WordPress comparison, HTTP MCP,
  LSP/HTMX/SMQ application development, deployment, and runtime benefits.
- [FuguHub Lua API](docs/FuguHub-API.md): human-facing reference for the public
  `app`, database, event, page-state, assets preload, module-loader, restart,
  LSP, theme, and optional plugin APIs.
- [FuguHub User Manual](docs/FuguHub-User-Manual.md): operator-facing setup and
  workflows for installation, CMS administration, MCP, Identity and Access,
  File Services, the SMTP/Large File Mailer, and multi-domain deployment.
- [CMS DB Content](cms/.info/guides/database.md): content data modeling and MCP
  operations for posts, menus, taxonomy, redirects, options, drafts, and cache
  policy.
- [CMS LSP Apps](cms/.info/guides/lsp.md): database LSP, `assets/.preload`,
  asset modules, public app state, events, page tables, and serialized writes.
- [CMS Site Assets](cms/.info/guides/assets.md): site files and applications,
  public URL namespaces, MCP asset workflow, theme boundaries, and runtime
  verification.
- [CMS LSP and HTMX](cms/.info/guides/lsp-htmx.md): full-page LSP shells,
  guarded fragments, CSRF, multipart forms, swaps, history, and HTMX testing.
- [CMS SMQ Apps](cms/.info/guides/smq.md): CMS-owned broker, HTMX page scopes,
  events, direct messaging, RPC, assets registration, security, and testing.
- [CMS Theme Authoring](cms/.info/guides/themes.md): staged theme creation,
  modification, validation, ZIP packaging, activation, and runtime contracts.
- [CMS Deployment](cms/.info/guides/deployment.md): runtime layout,
  startup, ZIP packaging, writable data, and deployment troubleshooting.
- [CMS MCP](cms/.info/guides/mcp.md): AI-agent content operations,
  encrypted bearer configuration, draft/publish rules, and selected-content
  ZIP transfer between CMS servers.

Use the design references when changing or reviewing the engine:

- [Maintenance Architecture](docs/design/summary.md): current boundaries,
  startup/unload flow, public request chain, invariants, and validation.
- [Application Layout](docs/design/application-layout.md): IO ownership, VFS
  chain, mount behavior, and startup layout.
- [Database Schema](docs/design/database-schema.md): canonical tables, fields,
  options, indexes, seed behavior, and runtime rules.
- [Performance](docs/design/performance.md): measured request-path costs,
  read-cache design, invalidation contract, benchmark results, and deferred
  response-cache tradeoffs.
- [Admin UI Architecture](docs/design/admin-ui.md): callback/LSP ownership,
  authenticated fragment guards, CSRF, HTMX behavior, and required tests.
- [Enhancement Backlog](docs/design/enhancement-backlog.md): deliberate
  limitations and candidates for future maintenance releases.

Operational guides are embedded under `cms/.info/guides/` so the packaged MCP
server can expose them. Maintainer-only architecture references remain under
`docs/design/`. Do not add release milestones, completed-work snapshots, or a
second copy of embedded guidance to that directory.

## Source Of Truth

When documentation and implementation differ:

1. Verify the native API in the official
   [BAS API reference](https://realtimelogic.com/downloads/basapi.md).
2. Inspect the current code under `cms/.lua/` and `cms/.preload`.
3. Report the discrepancy and update the local documentation.

Do not invent BAS, Lua, LSP, VFS, SQLite, or Mako APIs.

Optional official guidance:

- [BAS VFS skill](https://realtimelogic.com/downloads/ai-skills/VFS-skill.md)
- [SQLite writer skill](https://realtimelogic.com/downloads/ai-skills/SQLite-Skill.md)
- [Authentication skill](https://realtimelogic.com/downloads/ai-skills/Authentication-Authorization-Skill.md)
- [Application security skill](https://realtimelogic.com/downloads/ai-skills/OWASP-General-Security-Skill.md)

## Non-Negotiable Rules

- Keep engine code, site assets, installed themes, and mutable data separate.
  The deployment builders deliberately embed the read-only default theme under
  `fallback-theme/` so `cms.zip` can start when no external theme is installed.
- Treat packages under optional `plugins/` as trusted executable code. Use a
  root `.preload`, private `pluginreq` modules, native BAS VFS mounts, and the
  owner-scoped plugin context; do not add plugin behavior to the CMS router.
- Put site services in `assets/.preload` and uniquely named modules under
  `assets/.lua/`; do not add site-specific behavior to the generic engine.
- Load application modules under `cms/.lua/` with the application-private
  `appreq`; LSP templates and pages access them through `app.appreq`. Stable,
  process-level libraries use `require`. FastMCP is the deliberate exception:
  it lives under `cms/lib/.lua/fastmcp/`, is exposed by a dedicated loader, and
  uses `require` internally while each CMS owns its FastMCP runtime objects.
- Mark database bodies containing LSP tags with `render_mode='lsp'`.
- Use `_ENV` for request state, `page` for persistent virtual-page state,
  `app` for shared application state, and SQLite for durable state.
- Route all runtime SQLite writes through `app.db.writeSync`,
  `app.db.writeAsync`, or `db.withWrite`. Keep write callbacks short and
  DB-only.
- Generate mount-safe links with `app.url()` or the theme's `model.url`.
- Treat `head_html` and LSP bodies as trusted administrator code, not
  untrusted user input.
- Theme templates render data; they should not own durable mutations.
- MCP content creation and copying default to drafts. Ordinary updates preserve
  status. Publishing, destructive actions, executable LSP, theme activation,
  and transfer-conflict actions require explicit user decisions.
- Use MCP asset tools rather than assuming direct filesystem access. ZIP-backed
  assets are read-only. Activate directory-backed `.preload` and `.lua/`
  changes with the confirmed `restartAssetsApplication` tool.
- Use persistent MCP theme drafts for remote theme changes. Validate the
  complete draft before confirmed commit. Keep inactive commit separate from
  confirmed activation. A normally confirmed commit to the same-name active
  target performs the controlled in-place replacement and reload automatically.
  Never use site asset tools for theme files.
- Directory callbacks return `false` only when they did not handle the
  resource and did not commit a response.
- If the CMS engine is missing a general capability or behaves incorrectly,
  report and fix the engine instead of hiding the problem in site code.

## Validation

Run the reusable integration suite from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File tests\run.ps1
```

The suite creates isolated runtimes under `.test-runtime/`, launches and stops
its own Mako processes, and removes the temporary data when complete.

Build the full archive deployment, including bundled plugins and the
multi-domain loader, or the standalone plugin-free deployment with:

```powershell
.\create-deploy.cmd
.\create-core-deploy.cmd
```

The full output is under `deploy/`; the core output is under `deploy-core/`.
The integration suite starts the standalone archive without external themes,
verifies the built-in fallback, and checks bundled plugin discovery and
multi-domain service ownership.

Build and run the separate hardware stress fixture as documented in
[Stress Harness](stress/README.md):

```powershell
.\create-stress-deploy.cmd
.\stress\stress-test.cmd --host localhost --concurrency 32 --requests 10000
```

`deploy-stress/` is benchmark-only. Its seeded database intentionally has no
admin users, so do not expose it to an untrusted network.

For relevant changes, test both root and named mounts, normal and LSP content,
HTML and HTMX navigation, editable 404 behavior, admin authentication, theme
assets, browser cache revalidation, compression, and SQLite restart behavior.
Never claim a BAS request path works solely from static code inspection.
