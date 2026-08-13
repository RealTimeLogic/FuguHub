# FuguHub Application Project

This file guides an AI agent that develops a site or web application on a
running FuguHub CMS. It is intended to be copied into the local project
directory before work begins.

This is not the FuguHub engine-maintenance guide. The deployed CMS is managed
through its authenticated HTTP MCP API.

## Project Contract

- Treat the connected FuguHub server as the source of truth for content,
  settings, themes, site assets, and runtime behavior.
- Use only the FuguHub HTTP MCP server to inspect or modify the deployed CMS.
- Local files may be used to draft or version application code, but they do not
  prove what is installed on the server.
- Never open or modify the server's SQLite database, deployment directories, or
  ZIP packages directly.
- Never put an MCP token in this file, another tracked file, a URL, page
  content, source code, logs, or a prompt.
- Ask before publishing content, activating a theme, installing executable
  code, restarting the assets application, deleting data, or replacing an
  active resource.
- Stop and report a BAS, Mako, FuguHub, or MCP API defect. Do not conceal it
  with an application workaround.

## Required Startup Sequence

Do not make changes until this sequence succeeds.

1. Find the connected FuguHub MCP server and its tools.
2. Call `getCapabilities`.
3. Call `listGuides`.
4. Read these guides with `getGuide`:
   - `site-builder`
   - `mcp`
   - `lsp`
   - `assets`
5. Call `getCmsInfo`, `getHealth`, and `getAssetCapabilities`.
6. Report the CMS base URL, active theme, asset source and writability, and
   whether HTMX and SMQ are enabled.
7. Load the additional guide required by the task before changing anything:
   - Content and SQLite model: `database`
   - HTMX fragments: `lsp-htmx`
   - Real-time messaging and RPC: `smq`
   - Theme work: `themes`
   - Packaging or transfer: `deployment`

Use `getCapabilities` and the embedded guides as the current contract. Do not
infer support from this file when the running server reports otherwise.

## Additional Source Documentation

The running server's MCP capabilities and embedded guides are authoritative for
remote operations. The following source documents provide deeper Lua API and
implementation context. Read only what the task requires; do not delay ordinary
content work by loading all maintenance documents.

When a FuguHub source checkout is available, look for:

- `docs/FuguHub-API.md`: public Lua APIs, the assets application, LSP and HTMX,
  SMQ, database access, events, themes, plugins, and execution environments.
- `docs/design/summary.md`: maintenance architecture and complete startup and
  request chains.
- `docs/design/application-layout.md`: application ownership, IO, VFS, module
  loading, mounting, lifecycle, plugins, and multi-domain behavior.
- `docs/design/database-schema.md`: core SQLite tables, indexes, and runtime
  rules.
- `docs/design/admin-ui.md`: admin authentication, HTMX/LSP rendering, and UI
  validation rules.
- `docs/design/performance.md`: current caching and performance design.
- `docs/design/enhancement-backlog.md`: unresolved future enhancements only;
  entries are not implemented capabilities.

The same documents are available in the public repository:

- [FuguHub Lua API](https://github.com/RealTimeLogic/FuguHub/blob/main/docs/FuguHub-API.md)
- [Maintenance architecture](https://github.com/RealTimeLogic/FuguHub/blob/main/docs/design/summary.md)
- [Application layout](https://github.com/RealTimeLogic/FuguHub/blob/main/docs/design/application-layout.md)
- [Database schema](https://github.com/RealTimeLogic/FuguHub/blob/main/docs/design/database-schema.md)
- [Admin UI architecture](https://github.com/RealTimeLogic/FuguHub/blob/main/docs/design/admin-ui.md)
- [Performance design](https://github.com/RealTimeLogic/FuguHub/blob/main/docs/design/performance.md)
- [Enhancement backlog](https://github.com/RealTimeLogic/FuguHub/blob/main/docs/design/enhancement-backlog.md)

Prefer documentation from the same FuguHub release as the running server. If a
needed document cannot be found locally or opened from the public repository,
ask the user to provide the matching source checkout or document. Do not guess
an API or reconstruct undocumented engine behavior. If source documentation
conflicts with `getCapabilities` or an embedded MCP guide, report the mismatch
and follow the running server contract for remote changes.

## If FuguHub MCP Is Missing

First check whether the AI product has an unconfigured or disabled FuguHub MCP
server or plugin. If no FuguHub tools are available, tell the user that the
remote CMS is not connected and help configure it using the product's official
MCP or plugin settings.

Ask the user for the public CMS base URL, but do not ask them to paste the
bearer token into this file or a tracked project file. The administrator enables
MCP and creates the token at `<cms-base>/admin/mcp/`. Configure the client with:

| Setting | Value |
| --- | --- |
| Name | `fuguhub` |
| Transport | Streamable HTTP |
| URL | `<cms-base>/mcp/` |
| Authentication | `Authorization: Bearer <token>` |

The URL must include the trailing slash. For example:

```text
http://localhost/mcp/
https://example.com/mcp/
https://example.com/mybase/mcp/
```

There is no `mcp.lsp` endpoint. Store the token using the AI product's secure
credential or header mechanism. If the product represents MCP connections as
plugins, add or install a remote Streamable HTTP MCP plugin with the settings
above; do not install an unrelated FuguHub code package.

If the agent can edit its own MCP configuration, explain the proposed change
and obtain permission before applying it. Otherwise, give product-appropriate
steps and wait for the user to reconnect or restart the agent. Afterward, run
the Required Startup Sequence. If the connection still fails, report the HTTP
status and transport error without printing the token.

## Choose The Correct Application Surface

Use the smallest surface that matches the behavior:

| Need | Location | Notes |
| --- | --- | --- |
| Article or page-specific server rendering | SQLite CMS content | Set `render_mode` to `lsp`; create as a draft first |
| Public LSP endpoint or HTMX fragment | Site assets, such as `device/status.lsp` | Available at the mount-aware public URL returned by MCP |
| Shared Lua service or application state | `assets/.lua/` plus `assets/.preload` | Load modules with `assetsreq`; restart the assets application after changes |
| Browser JavaScript, CSS, images, or downloads | Site assets | Use the exact `publicUrl` returned by the asset tools |
| Reusable visual structure and presentation | Theme | Keep application-specific services and behavior out of the theme |
| CMS engine behavior | FuguHub source repository | Do not patch the deployed site to imitate an engine change |

When the requested location is ambiguous and affects routing, lifecycle, or
reuse, ask whether the code belongs to a database page or the assets
application before writing it.

## Theme Development

Before creating or changing a theme, call `getCapabilities`, load the embedded
`themes` guide with `getGuide`, and use the `manageCmsTheme` prompt when it is
available. The running guide is the complete theme contract; do not infer the
package format or template model from another CMS.

Use the MCP theme-draft workflow:

1. Call `listThemes` and `listThemeDrafts`.
2. Prefer creating a new draft from the installed `default` theme so the full
   rendering, menu, HTMX, and SMQ contracts are preserved. Use an empty draft
   only when the user explicitly wants a theme built from scratch.
3. Inspect the source and draft files before editing. Theme files include the
   content contract, CSS and browser code, and LSP templates for the full
   layout, fragment, page, post, archive, and not-found views. Follow the exact
   required and optional file list reported by the current `themes` guide.
4. Use `writeThemeDraftText` for text and the one-time draft upload operation
   for binary images or fonts. Use the latest SHA-256 when replacing a file.
5. Keep reusable presentation, responsive layout, menus, typography, and the
   generic HTMX/SMQ shell in the theme. Keep site-specific Lua, LSP endpoints,
   JavaScript, data services, and application state in site assets.
6. Generate all theme and site URLs with `model.url(...)`. Use `/theme/...`
   for theme-owned files, the exact asset `publicUrl` for site-owned files, the
   CMS-owned `/assets/...` paths documented by the guide, and the server-root
   SMQ path exactly as documented.
7. Match `theme.json` title ownership to both the full and fragment templates.
   Render `model.content.title` and `model.renderBody()` according to that
   declared contract.
8. Render `model.menu` recursively and preserve hidden, selected, keyboard,
   touch, mobile, and multi-level submenu behavior. Do not create pointer gaps
   between a menu item and its submenu.
9. When HTMX is supported, keep the full-page and fragment roots structurally
   compatible, avoid duplicate IDs, preserve title and menu state during
   history restoration, and display fragment-request failures visibly.
10. When SMQ is supported, load its shell scripts only from the full layout and
    use the target and lifecycle contract from the built-in `smq` guide.
11. Call `validateThemeDraft` and retain its exact validation fingerprint.
12. Show the validation result and ask before `commitThemeDraft`, because theme
    LSP is executable. A normal commit installs an inactive theme unless it is
    the controlled replacement of the active same-name theme.
13. Validate the installed theme and ask separately before `activateTheme`.
14. Confirm the active theme with `getCmsInfo`, then perform browser QA on full
    pages, posts, archives, categories, 404 responses, menus with at least three
    levels, HTMX navigation and history, and desktop and mobile viewports.

There is no direct theme ZIP import in the current MCP contract. Reproduce a
theme by creating a draft and writing or uploading its files through the MCP
theme tools. Do not use site asset tools to modify themes or host theme-owned
files. If a required theme operation is absent from `getCapabilities`, report
it as unsupported instead of accessing the server filesystem.

## Lua And LSP Environment

FuguHub provides a public application environment shared by database LSP
content, asset LSP files, and theme rendering:

- `_ENV` is the request/response command environment.
- `app` is the public application table. When `assets/.preload` exists, it is
  the assets application table, which inherits the CMS public APIs.
- `page` is persistent for each database-backed virtual LSP page, just as BAS
  provides a persistent page table for a physical LSP file.
- Request variables belong in `_ENV`, page-specific persistent state belongs in
  `page`, and application-wide state belongs in `app`.
- Generate mount-safe URLs with `app.url(...)` or the theme model's
  `model.url(...)`.

Database content containing LSP tags must use the LSP render mode. A minimal
body is:

```html
<p>Rendered by LSP.</p>
<?lsp
page.requests = (page.requests or 0) + 1
?>
<p>Page requests: <?lsp=page.requests?></p>
```

Do not enable LSP merely to render static HTML. Executable LSP content requires
explicit user approval and the MCP executable-content confirmation.

## Assets Application

Use `assets/.preload` when the site needs shared Lua state, modules, background
services, CMS events, or SMQ registrations. Put private modules below
`assets/.lua/` and load them with the application-scoped loader:

```lua
local device = assetsreq "device"

app.device = device.start()

return function()
   if app.device then
      app.device:close()
      app.device = nil
   end
end
```

The returned function is the assets application's unload handler. It runs when
the application is restarted or the CMS unloads. Do not use global `require`
for site modules; `assetsreq` keeps module state scoped to this assets
application and supports restart.

Asset rules:

- Call `getAssetCapabilities` before every asset mutation workflow.
- Read before write and use the returned revision or hash when the tool
  supports optimistic concurrency.
- Use `writeTextAsset` for text, Lua, LSP, JavaScript, and CSS.
- `.lua` modules belong below `.lua/`; `.preload` is allowed only at the asset
  root.
- Static files and `.lsp` files become active immediately.
- Changes to `.preload` or `.lua` require confirmed
  `restartAssetsApplication` before execution can be verified.
- After restart, call `readRuntimeTrace` and test the exact public path.
- An active `assets.zip` is read-only. Report that limitation instead of
  bypassing it.

Logical asset paths do not include the physical assets directory name:

```text
MCP asset path:       chat/chat.js
Public path:          /chat/chat.js
Theme reference:      model.url('/chat/chat.js')
Incorrect site path:  /assets/chat/chat.js
```

The `/assets/` public namespace is reserved for CMS-owned runtime files.
Always use the `publicUrl` returned by MCP because the CMS may be mounted below
a base path.

## HTMX Applications

HTMX is disabled by default and must be enabled in FuguHub settings. Before
building an HTMX application, read the `lsp-htmx` guide and verify the current
capability.

Use a full page as the stable application shell and asset `.lsp` endpoints for
HTML fragments. Keep validation and durable mutations in Lua services rather
than presentation fragments. Fragment endpoints must enforce the request and
session rules documented by FuguHub, including HTMX-only access where
appropriate, CSRF protection for writes, and mount-safe redirects.

Test both paths:

1. A direct browser request renders a valid full page or is rejected as
   intended.
2. An `HX-Request` receives only the expected fragment.

Also test browser history, back/forward navigation, failed requests, form
errors, and behavior after the server is temporarily unavailable.

## SMQ Real-Time Applications

For FuguHub applications, the built-in `smq` guide and SMQ reference exposed by
the MCP server are authoritative. Load them through `getGuide` and
`getReference`. Do not start with a generic SMQ skill: it may omit FuguHub's
HTMX page scopes, lifecycle cleanup, RPC conventions, and reconnect behavior.

Use a generic SMQ reference only as supplemental protocol information when the
user asks about a non-CMS client. It must not override the FuguHub guide.

FuguHub SMQ rules:

- SMQ depends on HTMX; verify both settings with `getCapabilities`.
- Register server RPC methods, publications, and broker callbacks through
  `app.smq` in `assets/.preload` or an `assetsreq` module.
- Browser fragments use the shell-owned `window.cmsSmq` bridge and
  `window.cmsSmq.mountPage(...)`.
- Never create a second page-local `SMQ.Client` in an HTMX fragment.
- Ensure page subscriptions are removed when fragments are swapped.
- Test disconnect, automatic reconnect, subscription restoration, RPC after
  reconnect, and assets-application restart.

## SQLite Access

Remote administration uses MCP content and site tools, never direct SQL.
Application Lua may read through the documented CMS database APIs. Every
SQLite write must use the CMS-owned writer thread:

```lua
local id = app.db.writeSync(function(conn)
   local ok, err = conn:execute("INSERT INTO app_log(message) VALUES('ready')")
   if not ok then error(err) end
   return conn:lastinsertid()
end)
```

For asynchronous writes, use `app.db.writeAsync(writeFn, resultFn)`. Keep write
callbacks short and database-only. Do not open an independent SQLite writer,
perform network calls or slow work in a writer callback, use the request
response object from the DB thread, or call `writeSync` from a `writeAsync`
result callback. Read the `lsp` and `database` guides before adding tables or
write logic.

## MCP Editing Workflow

For each change:

1. Call `getCapabilities` if the connection is new or the task uses an optional
   feature.
2. Load the relevant embedded guide.
3. Inspect the current resource and its dependencies.
4. Ask the user when create versus update, page versus post, HTML versus LSP,
   or database page versus asset endpoint is ambiguous.
5. Validate before saving.
6. Create new content as a draft unless the user explicitly requests
   publication.
7. Preserve the latest revision timestamp or hash for updates.
8. Apply only the requested change.
9. Restart the assets application only when executable asset changes require
   it and the user confirms.
10. Test the exact mount-aware public URL returned by MCP.
11. Inspect `readRuntimeTrace` for Lua, LSP, preload, database, SMQ, or routing
    errors.
12. Report what changed, what was tested, and what remains unverified.

Use the task-specific MCP prompts when available, especially
`buildCmsLspApp`, `buildCmsHtmxApp`, `createCmsContent`, and
`importHtmlContent`. A prompt is workflow guidance, not permission to publish
or install executable code.

## Content Safety

- Read `getContentAuthoringContract` before creating content from Markdown or
  importing HTML.
- Generate HTML fragments, not complete HTML documents, unless a public asset
  LSP endpoint specifically owns a complete response.
- Do not add scripts, inline event handlers, unsafe URL schemes, or executable
  LSP without explicit approval.
- New pages and posts are drafts by default.
- Publishing uses the explicit status operation.
- Permanent deletion requires dependency inspection and user confirmation.
- Do not silently choose transfer conflicts, overwrite active themes, or
  replace executable resources.

## Completion Checklist

Before declaring the task complete:

- The required embedded guides were read through MCP.
- Validation succeeded.
- The resource exists at the expected logical and public paths.
- Root and base-path routing were respected.
- Database LSP and asset LSP execute with the intended public `app` table.
- Lua module or preload changes were restarted and trace-checked.
- HTMX returns correct full pages and fragments.
- SMQ reconnects and restores subscriptions when used.
- No secret was written to project files, content, logs, URLs, or the response.
- Publication, activation, executable installation, restart, replacement, and
  deletion occurred only with the required confirmation.

## Bootstrap Prompt

A developer can begin a new AI session with:

```text
Read AGENTS.md and follow it as the project contract. Verify the FuguHub MCP
connection without changing the site. If FuguHub MCP is not connected, help me
add its Streamable HTTP endpoint using my AI product's MCP or plugin settings;
do not ask me to store the bearer token in this project. Call getCapabilities,
load the required embedded guides, summarize the active CMS, asset, HTMX, and
SMQ environment, and then ask what Lua/LSP application I want to build.
```
