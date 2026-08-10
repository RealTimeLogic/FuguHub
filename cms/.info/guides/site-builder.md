---
name: fuguhub-site-builder
description: Use when creating, extending, debugging, or deploying advanced database-driven websites on FuguHub, including CMS content rows, LSP-enabled pages, assets/.preload services, assets/.lua modules, CMS SQLite writes, themes, HTMX behavior, and runtime packaging.
---

# FuguHub Site Builder Skill

## Remote MCP Boundary

When this guide is delivered by a remote FuguHub MCP server, every operation on
that deployed server must use its HTTP MCP tools, resources, or prompts. Never
open or infer host filesystem paths, open SQLite directly, or bypass MCP with
another server-side access method. Paths such as `assets/.preload` are logical
CMS paths supplied to MCP tools. Read another guide with `getGuide` and its
guide ID. If the required operation is not exposed by `getCapabilities`, report
it as unsupported instead of creating a workaround.

Use this skill to build database-driven FuguHub websites, including sites with
server-side Lua, persistent SQLite data, forms, admin/setup pages, background
jobs, themes, and HTMX navigation.

This skill is written for agents that do not already understand BAS, Mako
Server, LSP, or the CMS internals. Follow the patterns below and do not invent
CMS or BAS APIs. If an API is unclear, inspect the CMS source or the local
embedded guides, and use `getReference` for authoritative BAS API sources.

## Terms Used Here

- BAS: Barracuda App Server, the Lua-capable web application server library used by Mako Server.
- Mako Server: the executable that runs this CMS application.
- LSP: Lua Server Pages. LSP files or database content can mix HTML with `<?lsp ... ?>` Lua blocks.
- CMS content row: one row in the `content` SQLite table.
- Runtime root: the directory that contains `cms/`, `assets/`, `themes/`, and `data/`. Run Mako from this directory.
- VFS: BAS virtual file system. It is the chain of resource readers and directory callbacks that decides what handles a URL.
- Resource reader: a BAS object that serves files from a directory, ZIP, or other IO source.
- IO: a BAS file interface rooted at a directory or ZIP.
- `_ENV`: the current request environment. It contains request-specific objects such as `request` and `response`.
- `app`: shared application state for the active public app.
- `page`: persistent state for one virtual page.
- HTMX: the optional browser library used by some themes for fragment navigation.

## Mental Model

FuguHub is a Mako/BAS application with four separate responsibilities:

```text
work/
  cms/       CMS engine code
  assets/    site-owned static files, LSP files, .preload, and .lua modules
  themes/    public themes, outside the CMS engine
  data/      mutable SQLite database and runtime data
```

Keep these separate:

- `cms/`: engine only. Modify only when the CMS itself needs a feature or bug
  fix.
- `assets/`: site/application code and public files.
- `themes/`: visual rendering, templates, CSS, and JS.
- `data/`: mutable runtime data such as `cms.sqlite.db`.

The CMS engine loads content from SQLite, selects a theme, and renders the
current page. Site-specific behavior should normally live in database-stored LSP
pages, `assets/.preload`, and modules under `assets/.lua/`.

The directory name `assets/` is not a public URL prefix. Its contents are
mounted at the CMS root. MCP asset `chat/chat.js` is served at
`app.url("/chat/chat.js")`, while `/assets/...` is reserved for CMS-owned
runtime files. Read the `assets` guide before creating browser files or making
a theme reference site assets.

## First Steps For Any Site Task

1. Identify the runtime root, usually the directory containing `cms/`, `assets/`,
   `themes/`, and `data/`. In command examples, replace `path\to\work` with this directory.
2. Identify whether the site uses `assets/` or `assets.zip`. If `assets.zip`
   exists, it takes precedence over `assets/`.
3. Call `getCmsInfo` and `getSchemaInfo` to inspect the active CMS and schema;
   do not locate or open its SQLite file.
4. Identify the active theme from the CMS options table or admin UI.
5. Decide whether the change belongs in:
   - CMS content row
   - LSP-enabled CMS page
   - `assets/.preload`
   - `assets/.lua` module
   - theme template/CSS/JS
   - CMS engine
6. If a CMS engine feature appears missing or broken, stop and report it. Do not
   build a fragile workaround in site code.

Application behavior must remain independent of the selected theme. A theme
may provide a generic browser shell, but it must not contain a special case for
one application page such as `/chat/`.

If `data/cms.sqlite.db` is absent, normal CMS startup creates the schema and
seeds default options, a primary menu, and an editable LSP 404 page. Do not ship
or invent a prebuilt database merely to satisfy startup.

## Admin Authentication

The admin UI is open by default when no admin users exist. Use
`/admin/users/` to create the first admin user. Profiles, role assignments,
audit rows, and the device-unique TPM-encrypted BAS user database are stored
together in `data/cms.sqlite.db`. The credential blob cannot be decrypted after
copying the database to another computer. After an enabled user has `cms-admin`,
the admin directory uses a BAS form authenticator and an authorizer requiring
that role.

The optional Identity Access plugin adds the Users & Access interface for the
same core identity service. It does not select or mirror another provider. The
final enabled `cms-admin` cannot be accidentally deleted, disabled, or demoted;
use the explicit reset action to remove every user and return to bootstrap mode.
In a multi-domain deployment, only the control CMS owns the Identity UI and
File Services. Consumer CMS instances use its injected core identity service
and retain separate browser sessions and CMS databases.

## File Services Access

CMS administration and file-data access are separate. A `cms-admin` needs a
matching enabled File Services role/path ACL before using the WFM or WebDAV.
Fresh installations include a `file-admin` ACL with write access to `/*`.
Direct WFM navigation without access returns a readable HTML 403 page and, for
CMS administrators, a link to File Services configuration. WFS JSON commands
and WebDAV requests continue to return their protocol-specific errors.

## Server-Side Code Preference

Prefer server-side code embedded in CMS pages when the behavior belongs to a
page or form. The CMS database row must use:

```text
content.render_mode = 'lsp'
```

The page body then contains LSP:

```lsp
<?lsp
response:write("<p>Hello from the server</p>")
?>
```

Use CMS LSP pages for:

- forms
- dashboards
- search pages
- authenticated views
- small admin/setup screens
- database-backed pages
- pages that call application services and render the result

Use `assets/.preload` and `assets/.lua` modules for shared services, state, and
code that is used by multiple CMS pages.

## Mount-Safe URLs

CMS apps can run at `/` or under a named base URL such as `/skillvault/`. Do not
hard-code root-relative URLs in app code or themes. Use the CMS helpers:

```lua
app.url("/library/")                 -- link or asset URL for the current base
app.pathFromUri(request:uri())       -- request path relative to the CMS base
app.redirect(_ENV, "/login/")        -- base-aware redirect
app.urlEncode(value)                 -- query/path component encoding
```

Ordinary CMS apps should use these helpers instead of calling `dir:baseuri()`
directly. The engine owns the VFS mount details.

## Runtime LSP Surfaces

FuguHub supports two public LSP surfaces:

1. Database-stored content with `render_mode='lsp'`.
2. File-based `.lsp` pages under `assets/`.

Database-stored CMS LSP pages are executed by the CMS renderer. The call shape is
effectively:

```lua
fn(_ENV, pathname, io, page, app)
```

Use:

- `_ENV`: current request environment, including `request` and `response`.
- `pathname`: current CMS path.
- `io`: active app IO.
- `page`: persistent page table for this virtual CMS page.
- `app`: public app table, usually `app.assetsApp` if `assets/.preload` exists.

Inside LSP pages, write output with `response:write(...)` or LSP expression
syntax:

```lsp
<p><?lsp= app.siteName or "Site" ?></p>
```

Do not call `ba.parselsp()` from a CMS page. The CMS renderer does that.

## Shared App Code

If `assets/.preload` exists, the CMS loads it before public CMS routes. The
preload receives:

```lua
app     -- public asset app table
io      -- app.assetsIo, rooted at assets/ or assets.zip
dir     -- public assets resource reader
homeIo  -- writable runtime root IO
```

The public app inherits CMS engine fields such as:

```lua
app.db
app.cms
app.homeIo
app.assetsIo
app.theme
```

Put shared setup in `assets/.preload`:

```lua
local service = assetsreq "myservice"
app.myservice = service.install(app)
```

Put reusable modules in:

```text
assets/.lua/
```

Load them from `.preload` or LSP pages:

```lua
local mod = app.assetsreq "mod"
```

The module cache belongs to the active asset application and does not use
Lua's global `package.loaded`. `assetsreq` exists only when
`assets/.preload` exists.

## App State

Use the right state scope:

- `_ENV`: one request only.
- `page`: persistent state for one virtual CMS page.
- `app`: shared application/service state.
- SQLite: durable state.

Example page state:

```lsp
<?lsp
page.views = (page.views or 0) + 1
response:write("<p>Views: ", page.views, "</p>")
?>
```

Use `app` for shared services:

```lsp
<?lsp
local user = app.accounts.currentUser(_ENV)
?>
```

## CMS Database

Core tables include:

- `content`: pages and posts.
- `menus`: menu definitions.
- `menu_items`: menu links and hierarchy.
- `terms`: tags/categories.
- `content_terms`: content-to-term relation.
- `options`: persistent key/value settings.
- `redirects`: redirects.

Common `content` fields:

- `type`: `page` or `post`.
- `path`: stored clean path. Pages store their public path. Posts store the
  article path without `blog_base_path`; the CMS derives their public URL.
- `title`: page title.
- `body_html`: HTML or LSP source.
- `render_mode`: `html` or `lsp`.
- `status`: `published` or `draft`.
- `meta_description`: optional.
- `head_html`: trusted head HTML.
- `cache_policy`: `default`, `revalidate`, `no-cache`, or `no-store`.

For LSP pages, set:

```text
render_mode = 'lsp'
cache_policy = 'no-store' or 'no-cache' when output is user-specific
```

## SQLite Writes

Runtime writes must use the CMS DB helper and writer thread. Do not open an
independent SQLite write connection from LSP, `.preload`, request handlers,
theme templates, access hooks, timers, or app modules.

Use:

```lua
app.db.writeSync(function(conn)
   local ok, err = conn:execute("UPDATE options SET value='1' WHERE key='x'")
   if not ok then error(err) end
end)
```

or:

```lua
app.db.writeAsync(function(conn)
   return conn:execute("INSERT INTO log(message) VALUES('done')")
end)
```

Rules:

- All writes go through the CMS writer thread.
- `writeAsync` result callbacks also execute on the writer thread. They must not
  call `writeSync` or wait for work queued to that same thread.
- Keep write callbacks short and DB-only.
- Do not call outbound HTTP services, AI APIs, `ba.sleep`, slow filesystem work,
  or heavy computation inside a write callback.
- Use short-lived read connections for reads.
- Run schema changes through the write helper too.
- Batch related writes so one logical operation does not perform unnecessary
  commits. Call `getGuide` with `id="lsp"` for CMS write-thread details.

If a request needs slow work:

```lua
-- 1. Optional short write, then commit.
app.db.writeSync(function(conn)
   local ok, err = conn:execute("INSERT INTO jobs(status) VALUES('pending')")
   if not ok then error(err) end
end)

-- 2. Slow work outside the DB write callback.
local result = timeConsumingCall()

-- 3. Short write to store result.
app.db.writeSync(function(conn)
   local ok, err = conn:execute("UPDATE jobs SET status='done' WHERE id=1")
   if not ok then error(err) end
end)
```

Never keep a SQLite transaction open while waiting for slow work.

## Reads

Use CMS read helpers or short-lived read connections. For direct runtime reads
from trusted LSP code, close both the connection and its environment:

```lua
local env, conn = app.db.openRead()
local cur, err = conn:execute(
   "SELECT id,title FROM content ORDER BY updated_at DESC"
)
if not cur then
   conn:close()
   env:close()
   error(err)
end

for row in cur:rows("a") do
   -- Use row.id and row.title.
end

cur:close()
conn:close()
env:close()
```

Close cursors if you use raw `conn:execute(...)` reads in a callback.

## Forms And Request Handling

In an LSP page:

```lsp
<?lsp
if request:method() == "POST" then
   local data = request:data() or {}
   app.myservice.save(_ENV, data)
   app.redirect(_ENV, "/done/")
   return
end
?>
<form method="post">
   <input name="title">
   <button type="submit">Save</button>
</form>
```

Use normal request threads for normal request/response work. Do not create a
worker thread just because a page performs an outbound HTTP call and the user is
waiting for the result.

Use `ba.thread.run(...)` when work should continue in the background after the
request returns. Use `response:deferred()` only when a response will be completed
outside the original request flow.

## CMS Access Events

The CMS exposes access events:

```lua
app.cms:on("access", function(_ENV, ctx)
   if ctx:isAdmin() or ctx:isStatic() then return end
   if ctx.route == "content" then
      app.analytics.noteAccessAsync(ctx.path)
   end
end)
```

Use access events for lightweight checks and for starting idempotent background
work. Do not do slow network work or long writes directly in the hook.

The context includes:

```lua
ctx.path
ctx.method
ctx.route      -- content, archive, preview, or not-found
ctx.content
ctx.isHtmx
ctx:handle()
ctx:isHandled()
ctx:isAdmin()
ctx:isStatic()
ctx:isCmsRoute()
```

If the hook writes or redirects the response, call `ctx:handle()`.

## Themes

Themes live under:

```text
themes/<theme-name>/
```

or:

```text
themes/<theme-name>.zip
```

If both a directory and ZIP exist for the same theme name, the ZIP wins.

Typical theme layout:

```text
themes/my-theme/
  style.css
  cms.js
  templates/
    layout.lsp
    fragment.lsp
    page.lsp
    post.lsp
    archive.lsp
    not-found.lsp
  images/
  fonts/
```

Theme assets are served from:

```text
/theme/...
```

That path is relative to the CMS mount. Templates must call `model.url()` when
emitting it; CSS should use stylesheet-relative asset URLs.

In templates, use the URL helper supplied by the CMS model:

```lsp
<?lsp
local url = model.url or function(path) return path end
?>
<link rel="stylesheet" href="<?lsp= attr(url('/theme/style.css')) ?>">
<script defer src="<?lsp= attr(url('/theme/cms.js')) ?>"></script>
<script defer src="<?lsp= attr(url('/assets/htmx/htmx.min.js')) ?>"></script>
<img src="<?lsp= attr(url('/theme/images/logo.png')) ?>" alt="">
```

Theme templates receive:

```lua
template(_ENV, pathname, io, page, app, model)
```

Important `model` fields:

- `model.content`
- `model.menu`
- `model.posts`
- `model.renderBody`
- `model.pageState`
- `model.htmxEnabled`
- `model.htmxFragment`
- `model.smqEnabled`
- `model.smqEndpoint`

The router renders editable 404 content through `not-found.lsp`. The default
template delegates to the normal layout, while a custom theme may give missing
pages a distinct presentation.

Themes should render. Do not mutate durable app data from theme templates unless
there is a very explicit reason.

Themes also should not own site application behavior. Put a chat client,
dashboard controller, or page-specific browser service in site assets. A
path-specific dependency emitted only by `layout.lsp` will not be loaded when
HTMX enters the page through `fragment.lsp`. MCP API `0.7.0` does not provide a
per-content browser-asset declaration; report that limitation rather than
coupling the application to one theme.

## HTMX

If HTMX is enabled, the theme must support full-page and fragment rendering.
The theme script must also surface HTMX network failures with a visible warning;
otherwise a lost server connection can make a fragment navigation appear to do
nothing. Load the shipped library from
`model.url('/assets/htmx/htmx.min.js')`; this file belongs to the CMS engine,
not the site-owned top-level `assets/` directory. Shipped themes must not depend
on a CDN.

Use a stable wrapper:

```html
<div id="cms-htmx-scope"
     hx-boost="true"
     hx-push-url="true"
     hx-target="#cms-main"
     hx-history-elt>
   <header>...</header>
   <main id="cms-main">...</main>
</div>
```

Place `hx-history-elt` on the stable wrapper that includes both page chrome and
the swap target. If it is only on the swap target, browser Back/Forward can
restore content while leaving stale menu state.

Fragment templates should not output:

- `<!doctype html>`
- `<html>`
- `<head>`
- global CSS links
- global script tags

Fragment templates should include stable metadata such as:

```html
<section data-cms-title="Page title" data-cms-path="/page/">
```

Theme JS should update document title and selected menu state after:

- `htmx:afterSwap`
- `htmx:pushedIntoHistory`
- `htmx:historyRestore`

Opt out of boosted navigation for:

- login/logout/register forms unless explicitly tested
- destructive actions
- downloads
- standalone app routes that return complete HTML documents
- routes that depend on normal browser navigation

Use:

```html
hx-boost="false"
```

or make the server return `HX-Redirect` for routes that require a full page
navigation.

## SMQ

SMQ is an optional real-time messaging layer that requires HTMX. The full
theme shell owns one browser connection while each HTMX fragment mounts a
temporary page scope for subscriptions, direct messages, and correlated RPC.
Application callbacks registered by `assets/.preload` are removed and rebuilt
when the assets application restarts.

Call `getGuide` with `id="smq"` before adding SMQ behavior. That guide defines
the browser `window.cmsSmq` API, the server-side `app.smq` API, the theme
contract, authorization requirements, and the required lifecycle tests.

## Setup And Admin Pages

Setup/admin pages that are part of the public site can be normal CMS pages with
`render_mode='lsp'`. A guard installed from `assets/.preload` may redirect other
URLs to the setup page until configuration is complete.

Rules:

- Let static assets and theme assets pass through setup guards.
- Allow the setup page itself to render.
- Store app config in the database when practical.
- Keep secrets server-side only.
- If storing secrets, encrypt or protect them using a server-side module.
- Validate external credentials before marking config valid.
- Do slow validation outside DB write callbacks.

## Assets And Deployment

Development usually uses:

```text
assets/
```

Deployment may use:

```text
assets.zip
```

If `assets.zip` exists, the CMS uses it and ignores `assets/`.

Treat `app.assetsIo` as read-only when the site may be packaged. Write runtime
data through `app.homeIo` under `data/` or another explicit writable location.

When working through MCP, call `getAssetCapabilities` before assuming the
active source is writable. Use `listAssets`/`getAsset` for discovery,
`writeTextAsset` for text and executable files, and `prepareAssetUpload` for
binary bytes. Replacements use SHA-256 optimistic concurrency. Static and LSP
files become visible immediately. Activate `.lua` and `.preload` changes with
the confirmed `restartAssetsApplication` MCP tool.

Asset tool paths are relative to the active site assets root. Use each returned
`publicUrl` for runtime verification. Do not prepend the source directory name:
`images/logo.png` is public at `app.url("/images/logo.png")`, not
`app.url("/assets/images/logo.png")`. Read the `assets` guide for the complete
namespace table and verification workflow.

Package ZIPs from inside the directory so the ZIP root contains the files, not a
nested base directory:

```cmd
cd MyTheme
zip -D -q -u -r -9 ..\MyTheme.zip .
```

Keep mutable data outside ZIPs.

## When To Modify The CMS Engine

Modify `cms/` only when:

- the router, renderer, theme loader, admin UI, schema, or event system lacks a
  needed general feature
- the CMS behavior is wrong
- app code would otherwise need a brittle workaround

When in doubt, stop and report the suspected CMS issue with:

- exact URL or operation
- expected behavior
- actual behavior
- relevant trace/log output
- whether it happens on full page loads, HTMX loads, or both

## Validation Checklist

After creating or changing an advanced site:

- Start from the runtime root.
- Confirm the expected database under `data/` is used.
- Confirm the site base URL renders, for example `/` or `/MyApp/`.
- Confirm the admin URL still works, for example `/admin/` or `/MyApp/admin/`.
- Confirm the active theme stylesheet loads, for example `/theme/style.css` or `/MyApp/theme/style.css`.
- Confirm a normal HTML CMS page renders.
- Confirm an LSP-enabled CMS page renders.
- Confirm forms submit and redirect correctly.
- Confirm runtime writes use CMS DB helpers.
- Confirm no direct SQLite write connections exist in LSP/request code.
- Confirm slow HTTP/AI/filesystem work is outside DB write callbacks.
- Confirm theme selected menu state is correct on full page loads.
- If HTMX is enabled, test menu clicks, browser Back/Forward, forms, redirects,
  and standalone app routes.
- If SMQ is enabled, test events, direct messages, RPC, HTMX page cleanup,
  reconnect behavior, and root plus named CMS mounts.
- Restart Mako and confirm `assets/.preload` initializes without errors.
- If using `assets.zip`, confirm the ZIP is actually active.
- If using theme ZIPs, confirm the ZIP contains theme files at its root.

## Common Failure Patterns

### LSP tags show as text

The content row probably has `render_mode='html'`. Change it to `lsp`.

### Shared app state is missing

Check that `assets/.preload` exists in the active assets IO. If `assets.zip`
exists, it may be hiding the `assets/` directory.

### Module `assetsreq` fails

Check that the module is under `assets/.lua/`, that `assets/.preload` exists,
and that the preload or LSP page uses `assetsreq`/`app.assetsreq`.

### SQLite `BUSY`

Look for independent write connections, slow work inside write callbacks, or too
many commits in one logical operation. Use the CMS writer thread helpers.

### HTMX page looks unstyled

A standalone route may have returned a full HTML document into a fragment swap.
Opt out of HTMX for that route or return `HX-Redirect`.

### Menu state is stale after Back/Forward

Ensure `hx-history-elt` is on the stable wrapper and that the theme script
updates menu state on HTMX history restore events.

### Database looks empty after restart

Mako may have been started from the wrong directory. Confirm `home` points at
the runtime root containing `data/cms.sqlite.db`.
