---
name: fuguhub-lsp-apps
description: Use when creating, porting, or debugging advanced FuguHub pages or asset apps that use LSP, database-stored LSP content, assets/.preload, assets/.lua modules, shared app state, page tables, CMS access events, or the CMS SQLite write thread.
---

# FuguHub LSP App Skill

## Remote MCP Boundary

When this guide is delivered by a remote FuguHub MCP server, every operation on
that deployed server must use its HTTP MCP tools, resources, or prompts. Never
open or infer host filesystem paths, open SQLite directly, or bypass MCP with
another server-side access method. Asset paths are logical paths supplied to
the MCP asset tools. Read the `site-builder` guide with
`getGuide { "id": "site-builder" }`. If the required operation is not exposed
by `getCapabilities`, report it as unsupported instead of creating a workaround.

Use this skill when a CMS page or an asset-side application needs Lua/LSP behavior beyond static HTML. The CMS supports two LSP surfaces:

- Database-stored CMS content with `content.render_mode='lsp'`.
- File-based LSP apps under the runtime `assets/` directory, including an optional `assets/.preload`.

The CMS engine remains separate from these public LSP app surfaces.

For content schema, page/post insertion, menus, redirects, taxonomy terms, and options, read:

```text
getGuide { "id": "database" }
```

## Runtime Layout

Typical runtime layout:

```text
work/
  cms/
    .preload
    .lua/
  assets/
    .preload        optional public app preload
    .lua/           optional modules for assets app
    *.lsp           optional file-based LSP pages
    images/
    css/
  themes/
  data/
```

The CMS `.preload` creates an internal engine `app` table. If `assets/.preload` exists, the CMS creates a separate asset app table and stores it as:

```lua
app.assetsApp
```

The asset app table inherits from the internal CMS app table, so public LSP code can read CMS APIs while keeping its own app-level values.

## Asset App Preload

If `assets/.preload` exists, the CMS loads it before mounting the admin and CMS fallback directories.

The preload environment contains:

```lua
app     -- the asset app table itself
io      -- app.assetsIo, rooted at assets/
dir     -- the assets resource reader/VFS directory
homeIo  -- writable Mako home IO
```

The asset app table is self-referential:

```lua
app == _ENV.app
```

Values assigned without `local` in `assets/.preload` become fields in the asset app environment:

```lua
trace("Setting mydata on", app)
mydata = "Hello World"
```

Database-stored CMS LSP pages and asset LSP files then see:

```lsp
<?lsp
print("app", app, "app data", app.mydata)
?>
```

Because the asset app table inherits from the internal CMS app table, public code can also access inherited fields such as:

```lua
app.db
app.db.thread
app.cms
app.homeIo
app.assetsIo
app.theme
```

## Asset Modules

The CMS engine itself loads modules under `cms/.lua/` with `appreq`. This gives
each CMS application a private module cache that is discarded and rebuilt by
`mako.reloadapp(app)`. CMS-private modules must not use global `require`;
database LSP and theme LSP use `app.appreq` when they need an engine module.

When `assets/.preload` exists, its environment receives an application-private
module loader:

```lua
local mod = assetsreq "mod"
```

The equivalent explicit form is:

```lua
local mod = app.assetsreq "mod"
```

Place these modules under:

```text
assets/.lua/
```

Dots map to subdirectories, so `assetsreq "service.mail"` loads
`assets/.lua/service/mail.lua`. The cache belongs to the active asset app and
is discarded whenever that app is restarted. Asset modules are not stored in
Lua's global `package.loaded`.

The CMS intentionally creates `assetsreq` only when `assets/.preload` exists.
Without a preload there is no asset application or private module cache.

## File-Based LSP Under Assets

The CMS resource reader for `assets/` uses:

```lua
assetsDir:lspfilter(app.assetsApp or app)
```

This means `.lsp` files stored directly under `assets/` execute as normal BAS LSP pages using the asset app table.

Use this for standalone LSP tools or small apps that should live outside the CMS database. Static files in `assets/` still take precedence over CMS dynamic routes.

An MCP-only agent can manage these files without physical filesystem access:

- call `getAssetCapabilities` and require a directory-backed active source;
- use `validateAssetCode` before executable changes;
- use `writeTextAsset` with `confirmedExecutable=true` for `.lsp`, `.lua/`
  modules, and `.preload`;
- treat `.lsp` as immediately visible after a successful write;
- when a `.lua` or `.preload` write returns `restartRequired=true`, ask for
  confirmation and call `restartAssetsApplication`;
- call `readRuntimeTrace` after activation or a test request.

`restartAssetsApplication` calls the current asset app's global `onunload`,
discards its module cache, reruns `assets/.preload`, updates the LSP
environment, and invalidates CMS runtime caches. It requires `confirmed=true`.

Define cleanup as a global function in `assets/.preload`:

```lua
function onunload()
   -- Stop threads/timers and unlink VFS nodes owned by this asset app.
end
```

The CMS calls the same function when the CMS itself unloads.

When an assets application registers SMQ RPC methods or broker-start callbacks
through `app.smq`, those registrations are also owned by the active assets
application and removed during restart. Read the `smq` guide for the public
server and browser APIs.

Restart unloads the old asset app before executing the replacement. If the new
preload fails, the MCP tool returns `assetsPreloadFailed` and public LSP falls
back to the internal CMS app. There is no automatic rollback; fix the reported
error and call `restartAssetsApplication` again.

## Database-Stored CMS LSP Pages

CMS database content can be LSP-enabled by setting:

```sql
render_mode = 'lsp'
```

For these pages, the CMS engine:

1. Reads the content row from SQLite.
2. Parses `body_html` with `ba.parselsp()`.
3. Compiles the generated Lua with `load(...)`.
4. Executes it inside the current request `_ENV`.
5. Passes the active public app table as the `app` argument.

The LSP call shape is:

```lua
fn(_ENV, pathname, io, page, app)
```

Where:

- `_ENV` is the BAS request/response command environment.
- `pathname` is the CMS content path.
- `io` is the active app IO, usually the asset IO when an asset app exists.
- `page` is the persistent page table for this virtual CMS page.
- `app` is `app.assetsApp` when present, otherwise the internal CMS app table.

Inside the database LSP code, use normal LSP globals:

```lsp
<?lsp
response:write("<p>", app.mydata or "", "</p>")
?>
```

Do not call `ba.parselsp()` from the database content itself. The renderer does that.

## Theme Template Call Chain

Theme templates are also LSP files. The CMS calls them with the same active public app table used for database LSP:

```lua
template(_ENV, pathname, io, page, app, model)
```

Theme templates should render `model.renderBody()` where the database content belongs. This keeps database LSP, theme layout, and HTMX fragments in one request/response chain.

## Page Tables

BAS gives physical LSP files a persistent page table. Database-stored LSP pages do not have a physical file, so the CMS emulates this with a stable table per virtual content item.

Use the `page` argument for per-page persistent state:

```lsp
<?lsp
page.count = (page.count or 0) + 1
print("render count", page.count)
?>
```

Use `_ENV` for per-request values. Use `app` for application-level state.

## Category Queries

Public database and asset LSP pages can query blog categories without opening
SQLite directly:

```lua
local posts, err = app.cms:postsByCategory("security", {
   limit = 20,
   offset = 0
})
local categories = app.cms:categories { includeEmpty = false }
local assigned = app.cms:categoriesForContent(contentId)
```

`postsByCategory` returns only published posts and derives each public post
path from the current blog base. Category archive paths are available as
`category.path`; pass CMS-relative paths through `app.url()` when emitting
links.

## CMS Access Events

The CMS exposes an EventEmitter-backed public event surface:

```lua
app.cms:on("access", function(_ENV, ctx)
   if ctx:isAdmin() or ctx:isStatic() then
      return
   end

   if ctx.route == "content" and app.coach then
      app.coach.triggerTodayNewsAsync()
   end
end)
```

Register access listeners from `assets/.preload` or another app initialization step. The CMS emits `access` only after it has confirmed a CMS route:

- `route = "content"` for published content rows.
- `route = "archive"` for the configured post archive path, defaulting to `/blog/`.
- `route = "category"` for a category archive below the configured blog path.
- `route = "preview"` for admin preview.
- `route = "not-found"` when the low-priority editable 404 handler renders its
  configured CMS page.

The event does not run for static assets, admin pages, or redirects.

The context table includes:

```lua
ctx.event     -- "access"
ctx.path      -- request path, such as "/products/"
ctx.method    -- request method
ctx.route     -- content, archive, preview, or not-found
ctx.content   -- content row for content/preview routes
ctx.isHtmx    -- true when HX-Request is present
```

It also provides:

```lua
ctx:handle()       -- mark the response as fully handled
ctx:isHandled()
ctx:isAdmin()      -- false for CMS access events
ctx:isStatic()     -- false for CMS access events
ctx:isCmsRoute()   -- true for CMS access events
```

If a listener writes or redirects the response, call:

```lua
ctx:handle()
```

The router stops normal rendering when `ctx:handle()` was called or the response is already committed.

`app.cms:on(...)` returns an unsubscribe function:

```lua
local off = app.cms:on("access", cb)
off()
```

`app.cms:off(event, cb)` is also available.

Access listeners run in the request path. Keep them fast. Use them for lightweight checks, counters, and starting idempotent background work. Do not perform slow HTTP calls, sleeps, or long database writes directly in the listener. Runtime DB writes must still use `app.db.writeSync` or `app.db.writeAsync`.

## SQLite Write Thread

The CMS creates one dedicated SQLite writer thread:

```lua
app.db.thread
```

This thread exists because SQLite allows many readers but only one writer. All CMS writes must use the CMS DB helper:

```lua
app.db.writeSync(function(conn)
   local ok, err = conn:execute("UPDATE options SET value='1' WHERE key='x'")
   if not ok then
      error(err)
   end
end)
```

Advanced asset apps may queue their own work on the same thread when they need to coordinate with CMS writes:

```lua
app.db.thread:run(function()
   -- Only use resources that are safe in this thread.
   -- Prefer app.db.writeAsync for SQLite writes.
end)
```

Preferred public APIs:

```lua
app.db.writeAsync(function(conn)
   return conn:execute("INSERT INTO log(message) VALUES('done')")
end)

local id = app.db.writeSync(function(conn)
   local ok, err = conn:execute("INSERT INTO log(message) VALUES('done')")
   if not ok then
      error(err)
   end
   local cur, selectErr = conn:execute("SELECT last_insert_rowid() AS id")
   if not cur then
      error(selectErr)
   end
   local row = cur:fetch({}, "a")
   cur:close()
   return row and row.id
end)
```

Use a result callback when an async write needs to complete a deferred HTTP response:

```lua
local dresp = response:deferred()

app.db.writeAsync(function(conn)
   return conn:execute("INSERT INTO log(message) VALUES('done')")
end, function(ok, res, err)
   if ok and res then
      dresp:setstatus(204)
      dresp:setcontentlength(0)
   else
      dresp:setstatus(500)
      dresp:write(tostring(ok and err or res))
   end
   dresp:close()
end)

return
```

If no result callback is provided, `writeAsync` logs failures with `mako.log(message, "cms-db")` and continues.

Rules:

- The `writeAsync` result callback runs on `app.db.thread`. Keep it short, do
  not call `writeSync` from it, and do not queue work to the same
  DB thread and wait for that work; doing so deadlocks the writer.
- Do not open independent SQLite write connections in LSP pages.
- Do not use the persistent write connection outside the DB thread.
- Use short-lived read connections for reads.
- Keep write callbacks short and DB-only.
- Do not call outbound HTTP services, OpenAI, `ba.sleep`, slow filesystem work, or heavy computation from inside `app.db.writeSync` or `app.db.writeAsync` write callbacks.
- Do not use the normal request `response` object from code running on `app.db.thread`; use `response:deferred()` if the thread must complete the HTTP response.
- Run schema changes through the write helper too.

For the CMS SQLite pattern, use the write-thread rules in this document.

## Long-Running Work And HTTP Calls

Database-stored LSP pages and asset `.lsp` files execute in the normal BAS request thread. That request thread can render output, read request data, call application services, and perform outbound HTTP calls when the page needs the result before responding.

Do not create a separate worker thread just because an LSP page calls HTTP. Use the request thread when the response naturally waits for the result.

Do not perform outbound HTTP, OpenAI calls, sleeps, or other long-running work inside the CMS DB write thread. The DB thread owns the exclusive SQLite write connection; blocking it can make unrelated requests fail with `BUSY`.

Preferred shape for LSP/request-driven long work:

```lua
-- Short DB write: reserve or create pending rows.
app.db.writeSync(function(conn)
   local ok, err = conn:execute("INSERT INTO jobs(status) VALUES('pending')")
   if not ok then error(err) end
end)

-- Slow work in the current LSP/request thread, outside the DB write callback.
local result = callHttpOrOpenAI()

-- Short DB write: persist the result.
app.db.writeSync(function(conn)
   local ok, err = conn:execute("UPDATE jobs SET status='done' WHERE id=1")
   if not ok then error(err) end
end)
```

Use `ba.thread.run(...)` when work should continue in the background or be decoupled from the current request. Use `response:deferred()` only when the response will be completed from outside the original request flow, such as from a DB-thread result callback or another worker callback.

## Public App vs Internal Engine App

The internal CMS app owns routing, content lookup, admin pages, theme loading, and DB configuration.

The public active app is:

```lua
app.assetsApp or app
```

Database LSP pages, asset `.lsp` files, and theme templates should use this public active app. This lets standalone LSP apps attach state in `assets/.preload` and see it from CMS pages.

Internal CMS modules should continue using the internal engine app passed to routers and DB modules.

## Recommended Workflow

When adding an advanced LSP app:

1. Add `assets/.preload`.
2. Put app state and setup in `assets/.preload`.
3. Put reusable modules in `assets/.lua/`.
4. Use `app.url(...)` for application links and assets so the app works at `/`
   and under a named mount.
5. Set CMS database pages that contain LSP tags to `render_mode='lsp'`.
6. Use `page` for per-page persistent state.
7. Use `app` for shared application state.
8. Use `app.db.writeSync(fn)` or `app.db.writeAsync(fn)` for writes.
9. Test a direct asset LSP page and a database-stored LSP page.
10. Call `restartAssetsApplication` after executable asset changes and confirm
    `assets/.preload` initializes without errors.
11. If a page performs slow HTTP/OpenAI work, confirm the slow call is outside all DB write callbacks.

## Debug Checklist

If app state is missing:

- Confirm `assets/.preload` exists under the runtime `assets/` directory.
- Confirm the preload assigns to the asset app environment, such as `mydata = "Hello World"`.
- Confirm the CMS page has `render_mode='lsp'`.
- Print `app` from both `assets/.preload` and the CMS page. They should match for public LSP execution.
- Check Mako trace output for `assets/.preload load failed` or `assets/.preload failed`.

If modules fail to load:

- Confirm modules are under `assets/.lua/`.
- Confirm `assets/.preload` exists and uses `assetsreq`, not global `require`.
- Inspect `readRuntimeTrace` for the module path and loader error.

If SQLite writes fail:

- Confirm the code uses `app.db.writeSync` or `app.db.writeAsync`.
- Search for request code that opens independent write connections.
- Confirm schema setup is not using a read helper.
- Search for slow work inside DB write callbacks, especially outbound HTTP, OpenAI calls, `ba.sleep`, or filesystem work.
- Check trace output for repeated `BUSY` messages.

If a page is slow or appears stuck:

- Confirm it is not holding `app.db.thread` while waiting for a network request.
- Confirm frequent page views are not doing unnecessary synchronous writes, such as updating a session timestamp on every GET.
- For fresh-user or first-day flows, test two overlapping requests and confirm `BUSY` does not reach the browser.
