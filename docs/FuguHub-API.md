# FuguHub Lua API

Use this reference to add application logic to a FuguHub site: create Lua
services, render Lua Server Pages (LSP), query content, store data, and build
live browser interfaces. It covers site applications, themes, and trusted
plugins. For installation and browser administration, use the
[README](../README.md#get-started) and [User Manual](FuguHub-User-Manual.md).

FuguHub runs on [Mako Server](https://makoserver.net/), which supplies the
Barracuda App Server (BAS) runtime. Standard objects such as `request`,
`response`, `ba.*`, LuaSQL connections, and virtual file system (VFS) objects
belong to BAS. This reference describes the helpers that FuguHub adds; use the
[BAS API reference](https://realtimelogic.com/ba/doc/) for the underlying APIs.
An **IO** below means a BAS `IoIntf` object for accessing a directory or archive.
**CMS** means content management system; **MCP** means Model Context Protocol,
the interface used by connected AI clients.

| What you want to do | Start here |
| --- | --- |
| Understand `app`, `page`, and request state | [Execution Environments](#execution-environments) and [State Selection](#state-selection) |
| Add a Lua service or LSP endpoint | [Assets Application](#assets-application) |
| Generate links that also work below a base path | [URL helpers](#mount-safe-url-api) |
| Read categories and published posts | [Category API](#category-api) |
| Read or write application data | [SQLite API](#sqlite-api) |
| Update part of a page or deliver live events | [LSP and HTMX](#cms-lsp-and-htmx) and [SMQ](#smq-real-time-api) |
| React to CMS requests | [CMS Event API](#cms-event-api) |
| Build a theme or plugin | [Theme API](#theme-api) and [Optional Plugins](#optional-plugins) |

Examples assume a configured FuguHub site. Paths such as `assets/` are relative
to its runtime directory. Keep your site code there and leave the CMS engine
separate. The manual explains the [runtime layout](FuguHub-User-Manual.md#runtime-directory)
and [AI client setup](FuguHub-User-Manual.md#mcp-setup).

## Public API Boundary

Use the APIs documented here for site code and integrations:


- the public `app` table and the helpers documented here, available to
  database LSP, asset LSP, site Lua, and theme templates;
- `app.db` for SQLite access;
- `app.cms` for application and CMS access events;
- `app.smq` for CMS-owned SMQ lifecycle, publishing, and assets-application
  registrations;
- the persistent `page` table passed to LSP and theme templates;
- `assets/.preload`, `assetsreq`, and the assets application lifecycle;
- the theme template `model` and `app.theme.getTemplate()` call used to
  compose templates;
- the `cmshttp` escaping utility loaded with `app.appreq`;
- the optional plugin descriptor and cleanup-managed `ctx` methods under
  [Optional Plugins](#optional-plugins).

Objects such as `app.adminAuth`, `app.mcp`, internal routers, MCP managers,
theme resource readers, and private modules under `cms/.lua/` are engine
implementation details unless this document explicitly describes them.

All these APIs execute trusted administrator code. CMS LSP, theme LSP, and
`assets/.preload` are not sandboxes.

## Execution Environments

FuguHub has one internal engine app table and, optionally, one public assets
app table:

```lua
local publicApp = internalApp.assetsApp or internalApp
```

When `assets/.preload` loads successfully, FuguHub creates `app.assetsApp`. Database-stored
LSP, file-based asset LSP, and theme templates receive this same public table
as `app`. Without a successfully loaded preload, they receive the internal
CMS app table.

### Database-stored LSP

Content with `render_mode='lsp'` is parsed by the engine with `ba.parselsp()`
and invoked as:

```lua
fn(_ENV, pathname, io, page, app)
```

- `_ENV` (table) is the BAS request/response command environment.
- `pathname` (string) is the clean CMS content path.
- `io` (IO object) is the active application IO.
- `page` (table) holds persistent state for this virtual CMS page.
- `app` (table) is the active public application environment.

Inside LSP tags, `request`, `response`, `page`, and `app` are available through
the request environment:

```lsp
<?lsp
page.views = (page.views or 0) + 1
?>
<p>Rendered <?lsp= page.views ?> times.</p>
```

Do not call `ba.parselsp()` from the page body. The CMS renderer owns parsing,
compilation, caching, and execution.

### File-based asset LSP

Files ending in `.lsp` under the active `assets/` or `assets.zip` IO execute
through the BAS resource reader. They receive the same public app table used
by database LSP.

### Theme templates

Theme templates are invoked as:

```lua
template(_ENV, pathname, io, page, app, model)
```

The first five arguments have the same meaning as database LSP. `model` is a
table containing the render data described under [Theme API](#theme-api).

## Application Table

### Common fields

The following fields are available to public application code:

| Field | Type | Meaning |
| --- | --- | --- |
| `app.baseUri` | string | CMS mount path, beginning and ending with `/`. |
| `app.db` | table | SQLite access methods. |
| `app.cms` | table | CMS events and category queries. |
| `app.identity` | table | Core user and role service, also used by the Identity and Access plugin. |
| `app.smq` | table | SMQ lifecycle, publishing, and registration methods. |
| `app.settings` | table | Current settings; treat as read-only. |
| `app.homeIo` | IO object | Mako's runtime directory. |
| `app.dataIo` | IO object | Writable `data/` directory. |
| `app.assetsIo` | IO object | Active site assets, from `assets.zip` or `assets/`. |
| `app.assetsSource` | string | `"zip"` or `"directory"`. |
| `app.assetsApp` | table or nil | Public assets environment after a successful preload; normally accessed as `app`. |
| `app.appreq` | function | Private CMS module loader; use only for documented helpers. |
| `app.theme` | table | Active theme; use the documented `getTemplate()` and `hasTemplate()` methods. |

The public assets app also has direct `io`, `dir`, and `homeIo` fields. See
[Assets Application](#assets-application).

Current settings fields are:

| Field | Type | Meaning and new-site default |
| --- | --- | --- |
| `htmxEnabled` | boolean | HTMX navigation; `false`. |
| `smqEnabled` | boolean | SMQ messaging; `false`. Also requires HTMX. |
| `blogBasePath` | string | Blog URL prefix; `"/blog/"`. |
| `notFoundEnabled` | boolean | Editable CMS 404 handling; `true`. |
| `notFoundPath` | string | Content path for that 404 page; `"/404/"`. |

Do not persist settings by assigning these fields. Use the CMS admin UI or MCP
settings API so validation, related public-link rebasing, and runtime
invalidation all occur. Post rows store only their article path; the CMS
prepends `app.settings.blogBasePath` when routing and rendering them.

## State Selection

Use the narrowest state scope:

| Need | Store it in |
| --- | --- |
| One request | `_ENV` or local variables |
| One virtual CMS page | `page` or `app.pageTable(scope, key)` |
| Current application lifetime | assets app fields or an `assetsreq` module |
| Durable application data | SQLite through `app.db` |
| Writable files | an explicit location below `app.dataIo` or `app.homeIo` |

Do not write runtime data into `app.assetsIo`; it may be ZIP-backed and
read-only.

## Assets Application

The top-level `assets/` directory is the main application directory for the
site using FuguHub. Despite its name, it is not limited to images, CSS, and
JavaScript. It may contain:

- static files such as images, style sheets, scripts, and downloads;
- directly addressable `.lsp` pages and HTMX fragment endpoints;
- private Lua modules below `.lua/`;
- an optional `.preload` that initializes the site application.

A source checkout keeps the CMS engine under `cms/`; a deployed site normally
uses `cms.zip`. The site application has the same layout in either case:

```text
assets/
  .preload
  .lua/
    status.lua
  api/
    status.lsp
  css/
    site.css
  js/
    site.js
  images/
themes/
data/
```

At startup FuguHub selects the assets source:

1. If `assets.zip` exists (deployed assets), it is used.
2. Otherwise the CMS uses `assets/`, creating the directory when needed.

The selected assets source takes precedence over database-backed CMS routes.
For example, `assets/api/status.lsp` is served at the mount-safe logical path
`/api/status.lsp`, not `/assets/api/status.lsp`. `assets.zip` is read-only
through the MCP asset API.

### `assets/.preload`

If the active assets IO contains `.preload`, FuguHub creates a separate assets
app table and executes the preload with that table as its Lua environment.
The preload runs after the database, settings, active theme, and MCP server
have been initialized, and before public CMS routes are mounted.

The preload environment contains:

| Name | Type | Purpose |
| --- | --- | --- |
| `app` | table | The assets application environment itself. |
| `io` | IO object | Active site assets, from a directory or ZIP. |
| `dir` | BAS resource-reader directory | Serves public asset files. |
| `homeIo` | IO object | Mako's runtime directory. |
| `assetsreq` | function | Loads private modules from `assets/.lua/`. |

The `app` table has the same identity in `assets/.preload`, LSP files under
`assets/`, LSP-enabled CMS pages, and theme templates. Printing `app` in each
environment therefore shows the same table reference.

In `assets/.preload`, the table is self-referential:

```lua
-- Preload globals belong to the public application table.
assert(_ENV == app)
assert(app == _ENV.app)
```

An LSP page instead receives a separate request/response environment containing
the shared app table:

```lua
-- In an LSP request, the request environment refers to the shared app.
assert(_ENV ~= app)
assert(_ENV.app == app)
```

#### `app` table inheritance

Lookups first check the assets app table, then the internal CMS app, then the
parent Mako preload environment. The assets app therefore inherits `app.url`,
`app.db`, `app.cms`, `app.settings`, IO fields, and other documented CMS
helpers without copying them.

In `assets/.preload`, assignments without `local` become public app fields:

```lua
siteName = "Example"
assert(siteName == app.siteName)
```

CMS LSP, asset LSP, and theme templates can then read:

```lua
-- Read the shared value from request or theme code.
trace(app.siteName)
```

Use locals for private preload state and modules. Use app fields only for
state and services intentionally shared with request code.

If loading or executing `.preload` fails, the CMS writes the failure to trace
and does not install the assets app table.

### `assetsreq(name)`

`assetsreq` loads a private site module. The required `name` is a string such
as `"service"` or `"services.mail"`, without a `.lua` extension. A missing file,
syntax error, or module execution error raises a Lua error:


```lua
local service = assetsreq "service"
local mail = assetsreq "services.mail"
```

Names map to:

```text
assetsreq "service"       -> assets/.lua/service.lua
assetsreq "services.mail" -> assets/.lua/services/mail.lua
```

The explicit form is:

```lua
local service = app.assetsreq "service"
```

Modules execute in the assets app environment. A module normally returns a
table or another service value; a module with no return value resolves to
`true`. Every result, including `false`, is cached for the current assets
application. The cache does not use global `package.loaded` and is discarded on
an assets application restart.

`assetsreq` exists only when `.preload` exists. Do not use global `require` for
site modules.

Example module:

```lua
-- assets/.lua/counter.lua
local M = {}
local value = 0

function M.next()
   value = value + 1
   return value
end

return M
```

Example preload, which exposes the counter to request code:

```lua
-- assets/.preload
local counter = assetsreq "counter"

siteName = "Example"
nextCounter = counter.next

local removeAccessListener = app.cms:on("access", function(_ENV, ctx)
   if ctx.route == "content" then
      trace("Access:", ctx.path)
   end
end)

function onunload()
   removeAccessListener()
end
```

Add an endpoint to call the service:

```lsp
<?lsp
-- assets/counter.lsp; requires the counter module and preload above.
?>
<p>Request count: <?lsp= app.nextCounter() ?></p>
```

After loading the assets application, request `/counter.lsp`, or
`/mybase/counter.lsp` when the site is mounted at `/mybase/`. Reloading the page
increments the counter. Restarting the assets application resets it because
the counter is held in memory.

### `onunload()`

Define a global `onunload` function in `assets/.preload`. It receives no
arguments; its return values are ignored:

```lua
function onunload()
   -- Stop timers and threads.
   -- Unlink VFS nodes created by this app.
   -- Remove app.cms listeners.
   -- Close app-owned resources.
end
```

FuguHub calls it:

- before restarting the assets application;
- when the entire CMS application unloads.

The function is read directly from the assets app environment. Returning an
unload function from `.preload` is not supported.

### `app.restartAssetsApplication()`

This lifecycle method:

1. calls the current asset app's `onunload`;
2. removes `app.assetsApp`;
3. discards the old `assetsreq` module cache;
4. reruns `assets/.preload` when present;
5. restarts the SMQ broker when enabled;
6. updates the assets LSP environment;
7. invalidates CMS page tables, parsed-LSP cache, and presentation revision.

Call it without arguments. It returns a table:

| Field | Type | Meaning |
| --- | --- | --- |
| `ok` | boolean | Preload loading and any enabled SMQ broker restart succeeded. Check `unloaded` separately. |
| `unloaded` | boolean | The old app's unload hook completed without error, or no old app existed. |
| `loaded` | boolean | A new assets app table is installed. |
| `active` | boolean | Same value as `loaded`. |
| `preloadExists` | boolean | The active assets IO contains `.preload`. |
| `unloadError` | string or nil | Error from the old app's unload hook. |
| `loadError` | string or nil | Error loading or executing the new preload. |
| `smqError` | string or nil | Error restarting the enabled SMQ broker. |

With no `.preload`, a restart can succeed with `ok=true` and `loaded=false`.
Unloading and loading are separate results: an unload error does not prevent
the replacement from being attempted.

This is a lifecycle operation, not an ordinary request helper. Prefer the MCP
tool described below for remote development and administration.

Restart unloads the previous app before loading the replacement. There is no
automatic last-known-good rollback. If the new preload fails, the public
environment falls back to the internal CMS app until the preload is fixed and
restarted successfully.

### Restart through MCP

An MCP-connected AI agent can restart the assets application without restarting
Mako. Ask it with a prompt such as:

> Restart the assets application and verify that it loads successfully.

The agent will ask for confirmation before restarting, run the MCP lifecycle
operation, inspect the runtime trace, and report whether the new application
loaded. A restart is needed after changing `assets/.preload` or a module under
`assets/.lua/`. Static files and `.lsp` files become active immediately and
normally do not require a restart.

## Mount-safe URL API

Applications can be mounted at `/` or below a named Mako base such as
`/mybase/`. Use these helpers instead of `dir:baseuri()` or hard-coded
root-relative links.

### `app.url(path)`

Accepts an optional string `path` and returns a string URL below the current
CMS base. Omitting `path`, or passing `""` or `"/"`, returns the base itself:

```lua
app.url("/")             -- "/" or "/mybase/"
app.url("/library/")     -- "/library/" or "/mybase/library/"
app.url("images/a.png")  -- "/images/a.png" or "/mybase/images/a.png"
```

Absolute scheme URLs, protocol-relative URLs, fragment-only values, and values
already prefixed with the current base are returned unchanged.

### `app.pathFromUri(uri)`

Accepts a request URI string and returns its CMS-relative path as a string.
Query strings and fragments are removed. A path outside the current base is
returned without stripping another prefix; this helper does not validate that
a request belongs to the CMS:

```lua
local path = app.pathFromUri(request:uri())
-- "/mybase/library/?q=x" becomes "/library/" at that named mount.
```

### `app.urlEncode(value)`

Accepts a value, converts it to text, and returns a percent-encoded string for
one URL component. `nil` and `false` become an empty string. ASCII letters, digits,
`-`, `.`, `_`, and `~` are left unchanged:

```lua
local href = app.url("/search/?q=" .. app.urlEncode("Lua & LSP"))
```

This function encodes `/`; call it on one path or query component, not on a
complete URL.

### `app.redirect(_ENV, path, permanent, return2caller)`

Sends a redirect using `app.url(path)`. `_ENV` is the current request table and
`path` is a URL string. The optional booleans `permanent` and `return2caller`
default to `false`: redirects use HTTP 302, and successful redirection ends
request execution. Set `permanent=true` for HTTP 301:

```lua
app.redirect(_ENV, "/login/")
return
```

The flags are passed to BAS `response:sendredirect()`. If control returns,
this wrapper returns `true`; it does not forward the native method's error
results. Use the [BAS response API](https://realtimelogic.com/ba/doc/en/lua/lua.html#response_sendredirect)
directly when you need those results. A successful redirect invalidates the
request/response object even with `return2caller=true`.

## CMS LSP And HTMX

HTMX is a small browser library that uses declarative HTML attributes such as
`hx-get`, `hx-target`, and `hx-swap` to request server-rendered HTML and replace
part of the current page. This works naturally with LSP because an LSP endpoint
can generate the requested HTML fragment directly, without a JSON API or
client-side rendering code. See
[LSP + htmx: A Powerful Duo for Embedded Web Apps](https://realtimelogic.com/articles/LSP-htmx-A-Powerful-Duo-for-Embedded-Web-Apps)
for a concise introduction.

HTMX is disabled by default. Enable it in [Public Site Settings](FuguHub-User-Manual.md#public-site-settings)
and use a theme that supports the full-page and fragment rendering contract
described in the [theme guide](../cms/.info/guides/themes.md).

A CMS content record can contain Lua in LSP tags when its render mode is
`lsp`. This makes a database page a natural full-page entry point for an HTMX
interface. The page can render the initial HTML and use `hx-get`, `hx-post`, or
other HTMX attributes to request HTML fragments from `.lsp` endpoints in the
site's assets application.

For example, the assets application can expose a Lua service:

```lua
-- assets/.lua/status.lua
local M = {}

function M.current()
   return "Ready"
end

return M
```

```lua
-- assets/.preload
statusService = assetsreq "status"
```

A database CMS page with `render_mode='lsp'` can then contain:

```lsp
<?lsp
page.loads = (page.loads or 0) + 1
?>
<section>
  <h1>Status</h1>
  <p>This page has rendered <?lsp= page.loads ?> times.</p>
  <button type="button"
          hx-get="<?lsp= app.url('/api/status.lsp') ?>"
          hx-target="#status-result"
          hx-swap="innerHTML">
    Refresh status
  </button>
  <div id="status-result">Ready</div>
</section>
```

The corresponding endpoint is a normal file in `assets/api/status.lsp`:

```lsp
<?lsp
local isHtmx = tostring(request:header("HX-Request") or ""):lower() == "true"
if not response:isinclude() and not isHtmx then
   response:senderror(404, "Not found")
   return
end

local status = app.statusService and app.statusService.current() or "Ready"
?>
<p><?lsp= status ?></p>
```

The browser requests the endpoint at the URL produced by
`app.url("/api/status.lsp")`. Always use `app.url()` so the same code works at
the root mount and at a named mount such as `/mybase/`.

The default theme loads the CMS-owned local HTMX runtime from
`cms/assets/htmx/htmx.min.js` when the HTMX setting is enabled. Its public URL
is generated by the theme; it is not loaded from a CDN and is distinct from
the site's top-level `assets/` application. A custom theme that supports HTMX
must likewise load the CMS-provided local runtime and preserve the CMS fragment
contract.

HTMX endpoints return HTML fragments, not JSON. Their response root must match
the caller's `hx-target` and `hx-swap`. The `HX-Request` check only prevents
ordinary direct navigation to a fragment endpoint; it is not authentication or
authorization. Protected endpoints must separately check their
application-specific session and enforce cross-site request forgery (CSRF)
protection for mutations.

The full CMS page request and the HTMX fragment request are separate HTTP
requests. They share the public `app` application state and can share durable
SQLite data, but they do not share request-local variables. Each physical asset
LSP file has its own persistent BAS `page` table. A database-stored LSP page
uses the CMS virtual page table described below.

For which changes need an application restart, see [Restart through MCP](#restart-through-mcp).

## SMQ Real-Time API

Simple Message Queue (SMQ) delivers events and remote procedure calls (RPC)
over a persistent browser connection. It depends on HTMX, and both settings
are disabled by default. Enable them in [Public Site Settings](FuguHub-User-Manual.md#public-site-settings). The CMS then owns one application-local broker and one
mount-aware endpoint at `app.url("/SMQ/")`. The full theme shell owns the
browser connection; HTMX fragments own temporary page scopes.

### Browser page scope

Database and asset pages must not create page-local `SMQ.Client` instances.
Use the shell API:

```html
<!-- Pair this page with the getDeviceStatus registration below. -->
<output id="state">Waiting for device status</output>
<script>
window.cmsSmq.mountPage("Device status", function (scope) {
  scope.subscribeToEvent("DeviceState", function (message) {
    document.getElementById("state").textContent = message.state;
  });

  scope.onReady(async function () {
    var status = await scope.rpc.getDeviceStatus();
    document.getElementById("state").textContent = status.state;
  });

  scope.onCleanup(function () {
    // Stop page-owned timers and remove non-SMQ listeners.
  });
});
</script>
```

`mountPage(name, init)` takes a string label and a function `init(scope)`. It
cleans up the previous page scope, initializes the new one, and returns a
zero-argument cleanup function. The `scope` object provides:

| Method | Arguments and result |
| --- | --- |
| `subscribeToEvent(topic, handler, datatype)` | String topic and function `handler(message, ptid, tid, subtid)`; optional native SMQ datatype string defaults to `"json"`. Returns `undefined`. |
| `subscribeToDirectMessage(subtopic, handler, datatype)` | String subtopic; same handler and datatype contract as event subscriptions. Returns `undefined`. |
| `sendToBroker(subtopic, payload)` | String subtopic and JSON-serializable payload; sends to the broker. Returns `undefined`. |
| `sendToPeer(peerTid, subtopic, payload)` | Numeric peer topic ID, string subtopic, and JSON-serializable payload. Returns `undefined`. |
| `publishEvent(topic, payload)` | String topic and JSON-serializable payload. Returns `undefined`. |
| `callRpc(name, ...args)` or `rpc.methodName(...args)` | String method name and JSON-serializable arguments. Returns a Promise for the server result; rejects on a reported error, disconnect, or scope cleanup. |
| `onReady(callback)` | Function `callback(client)` receiving the native SMQ client after connection/subscription setup. Returns `undefined`. |
| `onCleanup(callback)` | Zero-argument function for releasing page-owned resources. Returns `undefined`. |

Subscription handlers receive the decoded message and numeric publisher,
topic, and subtopic IDs. With the default datatype, messages are decoded from
JSON. The send methods substitute `{}` for a missing or falsy payload; use an
object such as `{value: false}` when transmitting a boolean value.

`onReady` runs after the page's SMQ subscriptions have been acknowledged.
HTMX cleanup rejects pending RPC Promises and removes page-owned handlers while
leaving the shell connection active.

If the connection is lost, the CMS shell keeps retrying. After an in-process
CMS reload or a Mako restart on the same origin, it restores the active page's
subscriptions and runs `onReady` again. Treat `onReady` as repeatable
initialization rather than a one-time page-load callback. Explicitly disabling
SMQ in the admin panel is terminal and does not reconnect.

### `app.smq:registerRpcMethod(name, callback)`

Register server RPC in `assets/.preload`. The required `name` is a string of
1-128 characters, beginning with a letter or underscore and containing only
letters, digits, underscores, dots, colons, or hyphens. The required `callback`
is a function receiving the remote call's arguments:

```lua
local remove, err = app.smq:registerRpcMethod("getDeviceStatus", function()
   return { state = "ready" }
end)
if not remove then error(err) end
```

Callbacks return a JSON-serializable result or `nil, errorMessage` (string).
A raised Lua error is also reported to the caller. The registration returns a
zero-argument remover function on success, or `nil, errorMessage` for invalid
arguments or a name owned by another application. Registrations made during `assets/.preload` are
automatically owned by that assets application and removed during its unload.

### `app.smq:onBrokerStart(callback)`

The required `callback` is a function receiving the active native broker.
The method returns a zero-argument remover function, or `nil, errorMessage`
(string) for an invalid callback or an error in its immediate invocation.
Use it for native broker subscriptions:

```lua
local remove, err = app.smq:onBrokerStart(function(broker)
   broker:subscribe("self", {
      subtopic = "SetOutput",
      json = true,
      onmsg = function(data, ptid)
         broker:publish({ ok = true }, ptid, "SetOutputResp")
      end
   })
end)
if not remove then error(err) end
```

The callback runs immediately when the broker is active and again whenever it
is recreated. Do not retain the supplied native broker across restarts.

### `app.smq:publish(data, topic, subtopic)`

Publishes through the active CMS broker. `data` is a string or table accepted
by the native broker; `topic` is a topic-name string or numeric topic ID.
`subtopic` is an optional string or numeric ID. Returns the native numeric
queued-message count, or `nil, errorMessage` (string) if publishing raises an
error. With no active broker it returns `nil, "SMQ is disabled"`.
The wrapper forwards only the native first return value, so a native failure
such as a full queue can return `nil` without an error message. The payload
limit is 65,520 bytes after JSON encoding; a queue count is not a delivery
acknowledgement.

```lua
local queued, err = app.smq:publish({ state = "ready" }, "DeviceState")
if queued == nil then mako.log(err or "SMQ publish failed") end
```

### SMQ state

These methods take no arguments. `isEnabled()` and `isRunning()` return
booleans; `broker()` returns the current native broker object or `nil`.

```lua
app.smq:isEnabled() -- persisted setting, also requires HTMX
app.smq:isRunning() -- active broker exists
app.smq:broker()    -- active native broker or nil
```

`restartAssetsApplication` removes old asset-owned RPC and broker-start
registrations and recreates an enabled broker after loading the replacement
assets application.

Admin authentication does not protect public SMQ clients. Application code
must validate RPC and command payloads and add the required broker
authentication and authorization policy.

## Persistent Page And Render State

### `app.pageTable(scope, key)`

Returns a table for a virtual page. `scope` and `key` are optional string or
number identifiers, converted to strings. Their defaults are `"default"` and
`""`. The same pair returns the same table until its scope is cleared:

```lua
local state = app.pageTable("my-app", "dashboard")
state.count = (state.count or 0) + 1
```

The CMS uses the same API to provide the `page` argument:

- content pages use scope `"content"` and the content id or path;
- route pages such as the blog archive use scope `"route"` and the route path.

Page tables are in-memory, process-local state. They are not durable storage
and should not be used as a cross-thread synchronization primitive.

### `app.clearPageTables(scope)`

Clears the optional string or number `scope`; omitting it clears all scopes.
This function returns no values:

```lua
app.clearPageTables("my-app")
app.clearPageTables()
```

### `app.clearRenderCache()`

Takes no arguments and returns no values. Clears the parsed database-LSP
cache. The next request reparses LSP bodies as
needed.

### `app.clearReadCache()`

Takes no arguments and returns no values. Clears the published-content,
redirect, menu, and content-term read
caches. The next request reloads the required rows from SQLite. Prefer
`app.invalidateRuntime()` when a change can also affect page state, rendered
output, or validators.

### `app.invalidateRuntime()`

Takes no arguments and returns no values. Clears page tables, parsed-LSP
state, and database read caches, advances the
presentation revision, and therefore changes CMS-generated ETags:

```lua
app.invalidateRuntime()
```

Call this after trusted Lua changes data outside normal CMS admin or MCP
mutations when that data affects rendered output. Avoid calling it on every
request.

## Category API

Database and asset LSP pages can read blog categories through `app.cms`. These
methods use the CMS read connection and are safe to call from a request. Public
post queries always exclude drafts.

### `app.cms:categories(options)`

Accepts an optional `options` table and returns an array of category tables
ordered by name:

```lua
local categories = app.cms:categories {
   limit = 100,
   includeEmpty = false
}
```

`options.limit` is an optional number, rounded down and clamped to 1-500;
the default is 100. `options.includeEmpty` is an optional boolean, default
`true`. Set it to `false` to include only categories with published posts.

Category records contain:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | number | Category ID. |
| `name`, `slug`, `description` | string | Display name, URL slug, and description. |
| `path` | string | CMS-relative archive path; pass to `app.url()` for links. |
| `assignmentCount` | number | Total assignments, including unpublished content. |
| `publishedPostCount` | number | Assigned published posts. |

The count fields are populated by `categories()`. Single-category and
per-content lookups do not calculate counts and return zero in those fields.

### `app.cms:category(slugOrId)`

Accepts a required string slug or numeric ID and returns one category table:

```lua
local category, err = app.cms:category("security")
```

It returns `nil, err` when the selector is invalid or the category does not
exist.

### `app.cms:postsByCategory(slugOrId, options)`

Accepts a required string slug or numeric ID and an optional `options` table.
Returns an array of published post tables, or `nil, errorMessage` (string) for
an invalid or missing category. A category with no matching posts returns an
empty array:

```lsp
<?lsp
local http = app.appreq "cmshttp"
local posts, err = app.cms:postsByCategory("security", {
   limit = 20,
   offset = 0
})
if not posts then
   response:senderror(404, err)
   return
end

for _, post in ipairs(posts) do
   response:write("<a href='", http.htmlAttr(app.url(post.path)), "'>",
      http.html(post.title), "</a>")
end
?>
```

`options.limit` is an optional number, rounded down and clamped to 1-100;
the default is 20. `options.offset` is an optional number, rounded down with a
minimum of zero; the default is zero. Results are ordered by most recently
updated, then descending ID, and contain the [content fields](design/database-schema.md).
`post.path` is the public path including `blogBasePath`. Database failures raise
Lua errors rather than returning the category-validation error pair.

### `app.cms:categoriesForContent(contentId)`

Accepts a required numeric `contentId` and returns an array of assigned category
tables. An unknown or nonnumeric ID returns an empty array. Treat the returned
records as read-only because the CMS caches them. Public post theme models
also expose this list as `model.categories` and
`model.content.categories`.

Category archives are routed below the blog base:

```text
<blogBasePath>category/<slug>/
```

For example, `/articles/category/security/`.

## SQLite API

FuguHub creates one dedicated SQLite writer thread and owns one persistent
write connection. All runtime writes, including writes to application-specific
tables, must use `app.db.writeSync()` or `app.db.writeAsync()`. Opening an
independent writer from request code can cause SQLite `BUSY` failures.

Every CMS connection enables `PRAGMA foreign_keys=ON`.

### `app.db.openRead()`

Takes no arguments and returns two LuaSQL objects: the environment and an open
connection. Opening or configuring the database can raise an error. The caller
owns these objects and must close them after use:

```lua
local env, conn = app.db.openRead()
local cur, err = conn:execute(
   "SELECT id, title FROM content ORDER BY updated_at DESC"
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

Always close cursors, the connection, and the LuaSQL environment.

### `app.db.writeSync(writeFn)`

The required `writeFn` is a function receiving the CMS-owned LuaSQL connection.
It runs on the writer thread. FuguHub commits when it returns normally and
returns its first three Lua result values to the caller. Do not close or retain
the supplied connection.

This example creates an application-owned table and records one event:

```lua
local id = app.db.writeSync(function(conn)
   -- Use an application-specific table rather than changing CMS tables.
   assert(conn:execute([[
      CREATE TABLE IF NOT EXISTS app_events(
         id INTEGER PRIMARY KEY, status TEXT NOT NULL
      )
   ]]))
   local ok, err = conn:execute(
      "INSERT INTO app_events(status) VALUES('pending')"
   )
   if not ok then
      error(err)
   end

   local cur, selectErr = conn:execute(
      "SELECT last_insert_rowid() AS id"
   )
   if not cur then
      error(selectErr)
   end
   local row = cur:fetch({}, "a")
   cur:close()
   return row and tonumber(row.id)
end)
```

If the callback raises an error, the CMS rolls back and propagates the error.
LuaSQL commonly reports SQL errors as `nil, message`; check and raise those
errors explicitly. Do not manually commit or roll back the CMS connection.
Returning `nil, message` alone does not trigger rollback; it is a normal Lua
return. The same rule applies to `writeAsync`.

`writeSync` blocks the calling thread until the writer callback completes.

### `app.db.writeAsync(writeFn, resultFn)`

Queues the required function `writeFn(conn)` and returns no values without
waiting for the write. Its connection and transaction rules are the same as
`writeSync`. The optional `resultFn` is a function called on the writer thread
after commit or rollback.

With the `app_events` table from the preceding example:

```lua
app.db.writeAsync(function(conn)
   -- Raise SQL errors so this transaction rolls back on failure.
   local changed, err = conn:execute(
      "INSERT INTO app_events(status) VALUES('pending')"
   )
   if not changed then error(err) end
   return changed
end, function(runtimeOk, result)
   if not runtimeOk then
      mako.log(tostring(result), "my-app")
   end
end)
```

The callback receives:

```text
resultFn(runtimeOk, value1, value2, value3)
```

`runtimeOk` is a boolean. On failure it is `false` and `value1` is the Lua
error value. On success it is `true` and `value1` through `value3` are the first
three values returned by `writeFn`, including any `nil` values. Return values
from `resultFn` are ignored. A result-callback error is logged after the
transaction has already completed.

If no result callback is supplied, FuguHub logs execution failures and a falsy
first result with `mako.log(..., "cms-db")`. Return a truthy first result when a
write succeeds and has no other result to report.

### `app.db.thread`

The underlying `ba.thread` instance is exposed for advanced coordination:

```lua
app.db.thread:run(function()
   -- Short work that must share writer-thread ordering.
end)
```

Prefer `writeAsync` for SQLite mutations. Never call `writeSync`, wait for
new work on `app.db.thread`, perform network calls, sleep, or do heavy
computation from a writer or result callback. Those patterns can deadlock the
writer or block unrelated requests.

Use the normal request thread for HTTP calls whose result is needed by the
response. Use `response:deferred()` only when another thread will complete the
response.

## CMS Event API

`app.cms` is an EventEmitter-backed object. FuguHub adds convenient
subscription methods.

### `app.cms:on(event, callback)`

Takes a required event-name string and callback function, and returns a
zero-argument unsubscribe function. Invalid argument types raise an error.
The callback receives the arguments supplied by the emitter. For `"access"`,
these are the request environment table and the context table described below:

```lua
local unsubscribe = app.cms:on("access", function(_ENV, ctx)
   -- Handle the event.
end)

unsubscribe()
```

### `app.cms:off(event, callback)`

Takes the event-name string and the callback function used at registration.
Returns `true` if a matching listener was removed, or `false` otherwise.
Omitting the callback removes all listeners for that event. Prefer the remover
returned by `on()` when releasing only your application's listener:

```lua
app.cms:off("access", callback)
```

### `app.cms:emit(event, ...)`

Takes an event-name string and any callback arguments. Emitting is synchronous:
listeners run in the caller's execution context. The CMS router emits the built-in `access`
event. Site applications may use other event names for their own components.
Returns a boolean indicating whether listeners were registered. EventEmitter
catches listener errors and reports them through its error handler or trace;
this return value does not indicate that every callback succeeded.

### Built-in `access` event

Register long-lived listeners in `assets/.preload`:

```lua
local removeAccessListener = app.cms:on("access", function(_ENV, ctx)
   if ctx.route == "content" then
      trace("CMS page:", ctx.path)
   end
end)
```

The event is emitted only after the CMS recognizes a renderable CMS route. It
is not emitted for static assets, admin pages, redirects, or unknown routes
when editable 404 handling is disabled.

Current route values are:

- `"content"`: a published content row;
- `"archive"`: the configured blog archive;
- `"category"`: a category archive below the configured blog base;
- `"preview"`: authenticated draft preview;
- `"not-found"`: the editable CMS 404 page.

The context contains:

| Member | Type | Meaning |
| --- | --- | --- |
| `ctx.event` | string | `"access"`. |
| `ctx.path` | string | Content row path when a row exists; otherwise the request URI. |
| `ctx.uri` | string | Original request URI. |
| `ctx.method` | string | HTTP method. |
| `ctx.route` | string | Route value listed above. |
| `ctx.content` | table or nil | Associated content or synthetic archive row. |
| `ctx.isHtmx` | boolean | Whether the `HX-Request` header is present. |

Context methods:

All take no arguments. `handle()` returns no values; the `is...()` methods
return booleans.

```lua
ctx:handle()       -- mark the response as handled
ctx:isHandled()
ctx:isAdmin()      -- false for current CMS access events
ctx:isStatic()     -- false for current CMS access events
ctx:isCmsRoute()   -- true for current CMS access events
```

If a listener writes or redirects the response, call `ctx:handle()`. The router
also stops when the response is already committed.

For an editable 404 event, `ctx.path` is the configured 404 content path while
`ctx.uri` is the URL that was not found. Use `ctx.uri` when the original
missing URL matters.

Access listeners execute in the request path. Keep them short. Start
idempotent background work or queue short database writes instead of doing
slow network or database work directly in the listener.

## Theme API

Themes should render data and avoid durable mutations.

### `app.theme.getTemplate(name)`

Takes a template-name string without `.lsp` and returns a compiled function
from the active theme. An optional template that fails to load returns `nil`
on the first attempt and cached `false` on later attempts; the CMS also logs
the error. Check for a function before calling it. Use it to delegate from
`page.lsp`, `post.lsp`, `archive.lsp`, optional `taxonomy.lsp`, or
`not-found.lsp`:

```lsp
<?lsp
local model = select(6, ...)
local templateName = model.htmxFragment and "fragment" or "layout"
-- Stop with a useful error if the selected template cannot be loaded.
local template = assert(app.theme.getTemplate(templateName),
   "Cannot load theme template: " .. templateName)
return template(_ENV, pathname, io, page, app, model)
?>
```

`app.theme.hasTemplate(name)` takes the same string name and returns a boolean
indicating whether the template file exists. It does not validate or compile
the template.

### Theme `model`

Common fields are:

| Field | Type | Meaning |
| --- | --- | --- |
| `model.site.title` | string | Default site title. |
| `model.site.baseUri` | string | CMS base URI. |
| `model.content` | table | Current content or synthetic archive row. |
| `model.menu` | array of tables | Visible primary-menu tree, with hidden items removed. |
| `model.posts` | array of tables or nil | Published posts for archive rendering. |
| `model.category` | table or nil | Current category on a category archive. |
| `model.categories` | array of tables or nil | Categories for the current content row. |
| `model.pageState` | table | State for the virtual page. |
| `model.htmxEnabled` | boolean | Whether CMS HTMX navigation is enabled. |
| `model.htmxFragment` | boolean | Whether this request should return a fragment. |
| `model.smqEnabled` | boolean | Whether SMQ messaging and browser page scopes are enabled. |
| `model.smqEndpoint` | string | URL such as `/SMQ/` or `/mybase/SMQ/`. |
| `model.responseHeaders` | table | Header-name strings mapped to values chosen by the engine. |
| `model.url` | function | Same function as `app.url`. |
| `model.pathFromUri` | function | Same function as `app.pathFromUri`. |
| `model.renderBody` | function or nil | Renders a content row's HTML or LSP body; absent on archive models. |

In a page/post template, call `model.renderBody()` with no arguments where the
body belongs. It writes to the current response and returns no values. Archive
templates iterate `model.posts` instead. The engine owns HTML versus LSP
rendering.

Menu items contain the SQLite row fields described in the
[database schema](design/database-schema.md), plus a `children` array of menu
item tables. `label` and `url` are strings; numeric row values such as `id`,
`parent_id`, `content_id`, and `position` follow LuaSQL's returned types. Use
`tonumber()` when doing arithmetic or numeric comparisons, and handle absent
parent/content IDs. Treat the cached menu tree as read-only.

### HTML escaping utility

Load the CMS escaping helper through the application-private loader:

```lua
local http = app.appreq "cmshttp"
local esc = http.html
local attr = http.htmlAttr
```

Both accept any value and return a string; `nil` and `false` become an empty
string. They convert other values to text and escape `&`, `<`, `>`, `"`, and
`'`. Use `html()` for text and `htmlAttr()` for quoted attribute values. These
functions escape syntax; they do not validate URL schemes or make untrusted
HTML safe. Do not use global `require` to load CMS-private modules.

## Optional Plugins

This section is for developers extending FuguHub or calling its bundled
services. For package selection, user management, file sharing, and email
workflows, see [Plugins in the User Manual](FuguHub-User-Manual.md#plugins).

FuguHub discovers trusted extensions under `plugins/` in the engine IO and then
under the top-level home IO. The source tree uses a top-level `plugins/`
directory for development. The full deployment builder places the shipped
plugins inside `cms.zip`; the core builder omits them. When neither IO contains
a `plugins/` root, the plugin loader is not loaded.

Each immediate child is active at the next CMS start:

```text
plugins/
  example/
    .preload
    .lua/
  packaged-example.zip
```

A directory or ZIP package must contain `.preload` at its root. Its name must
be a lowercase plugin ID containing letters, digits, and hyphens. Installing,
removing, or replacing a package is a filesystem operation followed by a CMS
restart. Plugins are executable administrator-installed code, not sandboxes.

### Plugin `.preload`

The preload runs in a private plugin app environment and returns a descriptor:

```lua
local service = pluginreq "service"

return {
   id = "example",
   requires = { "identity-access" },

   start = function(ctx)
      return service.start(ctx)
   end,

   stop = function(ctx)
      service.stop(ctx)
   end
}
```

Descriptor fields are:

| Field | Type | Contract |
| --- | --- | --- |
| `id` | string, required | Plugin ID matching its directory or ZIP name. |
| `requires` | array of strings, optional | Dependency plugin IDs; defaults to no dependencies. |
| `start` | function, optional | Called as `start(ctx)`; its returned value becomes the dependency service. |
| `stop` | function, optional | Called as `stop(ctx)` before owned cleanup; return values are ignored. |

There are no API revision numbers or dependency version constraints.

The environment provides:

```text
app        private plugin app table
io         package IO
homeIo     Mako home IO
pluginreq  private loader for package .lua modules
require    plugin-local first, then Mako runtime modules
```

`app` inherits documented CMS fields and methods, but plugin assignments stay
in the plugin table. `pluginreq "service"` maps to `.lua/service.lua`; dotted
names map to subdirectories. Its cache is private to the plugin and is
discarded when the CMS unloads.

### Plugin context

`start(ctx)` and `stop(ctx)` receive a context table:

| Field or method | Type and purpose |
| --- | --- |
| `ctx.id` | String plugin ID. |
| `ctx.io` | IO object for the plugin package. |
| `ctx.dataIo` | Writable IO object for this plugin's data. |
| `ctx.db` | Shared SQLite API table. |
| `ctx.identity` | Core identity service table. |
| `ctx.app` | Internal CMS app table. Prefer the documented APIs. |
| `ctx.admin` | Admin registration/helper table described below. |
| `ctx:requirePlugin(id)` | Required string ID; returns that declared dependency's service or raises an error if undeclared or not running. |
| `ctx:own(cleanup)` | Required zero-argument function; returns an idempotent remover that runs it at most once. |
| `ctx:mount(name, dir)` | Required string mount name and BAS directory object; returns `dir, unmount` or raises for invalid/reserved/occupied names or insertion failure. |
| `ctx:trace(...)` | Writes values to trace with the plugin ID; returns no values. |

`ctx.io` is the package source. `ctx.dataIo` is the writable
`data/plugins/<id>/` IO and is created only for a plugin that is ready to
start. Use `ctx.db.writeSync()` or `ctx.db.writeAsync()` for SQLite writes.

`ctx:requirePlugin(id)` returns the service from a running dependency named in
`requires`. `ctx:own(fn)` registers cleanup in reverse order. The CMS calls
`stop(ctx)` first and then runs owned cleanup even if stopping fails.
`ctx:mount(name, dir)` returns the directory and an idempotent unmount function.
Calling that function supports live disable/reconfiguration; cleanup can call it
again safely.

### Native VFS endpoints

Plugins expose public protocols and resources as BAS VFS directories:

```lua
local files = ba.create.dir("example")
files:setfunc(handler)
ctx:mount("example", files)
```

The name must be a free top-level name and must match the directory's public
role. The mount follows the CMS base automatically, such as `/example/` or
`/mybase/example/`, and is unlinked during cleanup. Plugins do not add public
routes to the CMS content router.

Use an ordinary `env` parameter for BAS callbacks and access request objects
explicitly. Capture the plugin app before the callback when it is also needed:

```lua
local pluginApp = app
dir:setfunc(function(env, relpath)
   env.response:write(pluginApp.baseUri)
   return true
end)
```

### Admin handlers

The plugin API supports exact Lua handlers under
`/admin/plugins/<plugin-id>/`. Existing CMS administrator authentication, POST
parsing, CSRF checks, mount-safe URLs, and error handling remain in force.

`ctx.admin:addPage(spec)` takes a table with required string `id`, string
`label`, and function `handler(env, pluginApp, ctx)`. Optional `path` is a
relative route string (default `""`); optional numeric `order` controls menu
ordering and defaults to 1000. Registration errors raise Lua errors. The
example's handler needs only the request environment:

```lua
ctx.admin:addPage {
   id = "settings",
   label = "Example",
   path = "",
   order = 600,
   handler = function(env)
      return ctx.admin:layout(env, "Example", function()
         env.response:write("<section class='panel'>...</section>")
      end)
   end
}
```

`ctx.admin:addRoute(path, handler)` adds an exact handler without a navigation
entry. `path` is a relative string, and the callback has the same signature as
`addPage`. Both calls return cleanup-managed remover functions and are also removed
automatically during plugin cleanup.

Use one server-rendered admin shell plus protected JavaScript, CSS, and JSON
handlers for interactive plugin administration. The browser owns incremental
rendering; the server continues to own authentication, CSRF checks, input
validation, authorization, persistence, and sanitized errors. Register static
resource filenames exactly and a directory-shaped API route:

```lua
ctx.admin:addRoute("admin.js", serveJavaScript)
ctx.admin:addRoute("admin.css", serveCss)
ctx.admin:addRoute("api/", jsonApi)
```

The shell may use relative `admin.js`, `admin.css`, and `api/` URLs, which remain
correct at root and named CMS mounts.

For a state-changing form, render the CMS token and read the already parsed,
CSRF-validated POST data:

```lua
ctx.admin:csrfField(env)

if env.request:method() == "POST" then
   local data = ctx.admin:postData(env)
end

local safe = ctx.admin.html(untrusted)
```

Here `env` is the request environment table. `layout(env, title, body)` takes
a string title and a zero-argument body function that writes the page body;
it returns `true` after rendering.
`postData(env)` returns the parsed POST table; `csrfField(env)` writes a hidden
form input and returns no values. `html(value)` returns an escaped string. Do not parse a second copy
of the request body in an admin handler.

Plugins start after core settings, theme, MCP, and SMQ initialization and
before `assets/.preload`. At shutdown, FuguHub stops the assets application,
then plugins in reverse dependency order, then the remaining CMS services.
One failed plugin does not prevent unrelated plugins or the standalone CMS
from starting; its dependants remain stopped.

### Included management plugins

Use the core `app.identity` service for site authentication. Plugins can also
obtain declared dependency services with `ctx:requirePlugin(id)`. The following
method indexes and integration notes are grouped by service; operator
procedures remain in the manual.

#### Identity and Access service

The CMS core provides `app.identity`. The optional
`plugins/identity-access/` package adds the Users & Access UI and returns this
same service to plugins that declare it as a dependency:

```text
identity.newFormAuthenticator(options)
identity.newDavAuthenticator(options)
identity.newAuthorizer(constraints, options)
identity.verifyCredentials(username, password, requiredRole)
identity.currentUser(env)
identity.hasRole(env, role)
identity.requireRole(env, role)
identity.users()
identity.roles()
identity.cmsAdminCount()
identity.onChange(listener)
identity.saveUser(input, actor)
identity.deleteUser(username, actor)
identity.saveRole(input, actor)
identity.deleteRole(name, actor)
identity.reset(actor)
```

Profiles, queryable role assignments, audit events, and one Base64-encoded
TPM-encrypted authenticator blob all live in the CMS SQLite database. Passwords
are never stored in profile or role rows. A user mutation stages a replacement
TPM database, writes it in the same serialized SQLite transaction as profile
and role changes, and activates the replacement authenticator only after the
transaction commits.

The authenticator blob uses the device-unique mode of `ba.tpm.jsonuser`; it
cannot be decrypted on another computer. The MCP token and Large File Mailer
SMTP password likewise use keys derived from `ba.tpm.uniquekey`. Moving the CMS
database therefore requires the manual's [credential reset and migration procedure](FuguHub-User-Manual.md#move-an-existing-database-to-another-computer).

Password changes, disable/re-enable changes, session-policy changes, role
removals, and deletion terminate active BAS sessions for the affected user.
Profile changes and role additions preserve existing sessions. Dependants
subscribe with `identity.onChange()` and rebuild their native
authenticator/authorizer objects; the remover returned by `onChange()` belongs
in `ctx:own()`.

`verifyCredentials()` returns only a Boolean and optional error; it never
returns stored password material. `saveUser()` accepts profile fields,
`password`, `disabled`, session settings, and a `roles` array. Existing enabled
users may change profile, roles, or session settings without replacing their
password; new and re-enabled users require one.

The final enabled user with `cms-admin` cannot be deleted, disabled, or demoted
through ordinary mutations. `identity.reset(actor)` is the explicit operation
that removes every user and returns CMS administration to bootstrap mode.

On first startup after an upgrade, the core imports supported standalone and
Identity and Access encrypted user files into SQLite and removes those legacy files
only after the unified transaction commits.

Plugin contexts expose the same service as `ctx.identity`. In a multi-domain
installation, the control CMS injects it into consumer CMS environments before
preload; users remain stored only in the control CMS database while each domain
keeps its own browser sessions. Identity and Access, File Services, and Large File
Mailer run only in the control domain. Consumer admin pages link Users & Access
to the Identity and Access page derived from the control domain's configured host.

#### File Services service

`plugins/file-services/` depends on `identity-access` and provides a managed,
authenticated BAS Web File Server and WebDAV service. It is disabled by
default and fails closed if security construction or reconfiguration fails. A
fresh File Services schema contains one enabled `File administrators` access
control rule (ACL) that
grants the `file-admin` role write access to `/*`; write access includes read.
Every ACL selects one existing identity role, one path subtree, and either read
or write permission. ACL changes rebuild the File Services runtime without
terminating CMS admin sessions. Configure its storage root and public URL in
`mako.conf` as described under
[File Services](FuguHub-User-Manual.md#file-services). The dependency service
exposes:

```text
files.isEnabled()
files.mountUrl()
files.location()
files.normalizeRelativePath(path)
files.authorize(env, method, path)
files.authorizeUser(username, method, path)
files.statAuthorized(username, path)
files.openAuthorized(username, path, mode)
files.describeGrant(username, method, path)
files.addWfmPlugin(spec)
```

Dependent plugins use the authorization-aware methods rather than receiving the
underlying storage IO.

`location()` returns a table with boolean `enabled` and string fields `io`,
`path`, and `mountUrl`. `io` and `path` identify the
configured BAS IO root; `mountUrl` opens the corresponding Web File Manager (WFM).
File Services paths are absolute within that root, not native filesystem paths:
they must begin with `/`, use forward slashes, and cannot contain encoded
separators or `.`/`..` segments. With
`wfs={io="disk",path="/c/shared/",baseurl="/fs/"}`, the File Services path
`/reports/report.pdf` resolves to `C:\shared\reports\report.pdf`.
With `io="home"`, it resolves below the Mako home IO instead.

`addWfmPlugin()` registers an optional client module with the full-page Web File
Manager and returns an idempotent remover suitable for `ctx:own()`. The module
URL must be local and absolute. An optional server-side `allowed(env)` callback
decides whether the module is included for the authenticated request:

```lua
-- In a plugin's start(ctx); declare both dependencies in requires.
local files = ctx:requirePlugin("file-services")
local identity = ctx:requirePlugin("identity-access")
ctx:own(files.addWfmPlugin {
   id = "my-file-command",
   module = app.url("/my-app/wfm.js"),
   allowed = function(env)
      return identity.hasRole(env, "my-file-role")
   end
})
```

The ES module exports a WFM plugin function as `default` or `plugin` and uses
the documented WFM client API, normally `api.add("command", spec)`. Registration
controls presentation only. Every resulting server operation must independently
authorize its paths.

The specification requires string `id` and `module` fields. `id` begins with
a lowercase letter or digit and contains only lowercase letters, digits, and
hyphens; it must be unique. `module` is a local URL beginning with `/`.
Optional `allowed(env)` receives the request environment and returns a boolean.
Invalid specifications raise Lua errors.

File access is independent of CMS administration. A user, including one with
`cms-admin`, needs a matching enabled File Services role/path ACL. An
authenticated browser without a matching grant receives an HTML 403 page;
file-manager commands and WebDAV methods keep their protocol-specific errors.

#### Large File Mailer service

`plugins/large-file-mailer/` depends on both services. It is disabled by
default and exposes the following service only to plugins that declare it as a
dependency:

```text
mailer.state()
mailer.parseTemplate(emlSource)
mailer.saveSettings(settings)
mailer.sendTest(recipient)
mailer.contacts(query, page, pageSize [, listId [, includeUnsubscribed [, contactFilter]]])
mailer.previewContactsCsv(csvSource)
mailer.importContactsCsv(csvSource, columnMapping, destinationListId [, restoreUnsubscribed [, hasHeader]])
mailer.saveContact(contact)
mailer.resubscribeContact(id)
mailer.resubscribeContacts(contactIds)
mailer.resetContactPassword(id)
mailer.deleteContact(id)
mailer.deleteContacts(contactIds)
mailer.deleteAllContacts()
mailer.previewContactRemoval(text)
mailer.removeContactsFromText(text)
mailer.lists([includeMemberIds])
mailer.list(id)
mailer.saveList(list)
mailer.deleteList(id)
mailer.deleteAllLists()
mailer.addListMembers(listId, contactIds)
mailer.removeListMembers(listId, contactIds)
mailer.transferListMembers(sourceListId, destinationListId [, contactIds [, deleteSource]])
mailer.templates([includeSource])
mailer.saveTemplate(template)
mailer.deleteTemplate(id)
mailer.resolveRecipients(contactIds, listIds)
mailer.createJob(job)
mailer.createInvitationJob(job)
mailer.confirmationStats([listId])
mailer.job(id)
mailer.jobDetails(id)
mailer.queueJob(id)
mailer.cancelJob(id)
mailer.history(page, pageSize)
mailer.purgeHistory(olderThanUnixTime)
```

`sendTest(recipient)` sends a small message using the saved SMTP configuration.
The required recipient string accepts a bare address or `Display Name <address>`.
It returns the normalized recipient string on success and raises a Lua error
for an invalid address, missing SMTP settings, or a send failure. For the
browser's **Save and Test** workflow, see [Initial Setup](FuguHub-User-Manual.md#initial-setup).

`createJob()` accepts an authorized sender, `email`, `attachment`, or `link`
delivery, message bodies, `contactIds`, and `listIds`. `email` is ordinary mass
mail and neither accepts nor requires files; it also works when File Services is
disabled. `attachment` and `link` require file paths relative to the configured
File Services root. For example, `/reports/report.pdf` identifies the file at
that path inside the mounted file service, not a Windows or POSIX disk path.
For the browser workflow, see [Compose](FuguHub-User-Manual.md#compose).
Secure-link messages append a **Download files** section automatically.
`{{DOWNLOAD_LINKS}}` is optional and is used only to place that generated
section at a specific position in plain-text or HTML content. Password
invitations follow the same rule for `{{INVITATION_LINK}}`. Bulk messages can
place a personal preference URL with `{{UNSUBSCRIBE_LINK}}`; this macro requires
a Public base URL and saved contacts. The manual lists all supported
[message macros](FuguHub-User-Manual.md#message-macros).

The selected contacts are copied into the persistent job-recipient
queue inside one serialized SQLite write. List members are selected by SQLite
and are not loaded into a Lua table, so a large list is not constrained by the
individual-contact selection limit. File-delivery jobs snapshot every file with
SHA-256 and reject unauthorized paths, directories, duplicate recipients, oversized
attachment sets, and link jobs without a configured public base URL. Jobs are
drafts until explicitly queued. The older `recipients` input remains available
to Lua integrations that already have complete recipient records.

`createJob()`, `createInvitationJob()`, `job()`, `queueJob()`, and `cancelJob()`
return a bounded job summary. It contains job metadata plus `recipientCount`,
`sent`, `failed`, `active`, `cancelled`, `skipped`, and `fileCount`; it never
contains a recipient array. This keeps job creation and state changes bounded
when a selected list contains thousands of contacts.

`jobDetails(id)` returns the source fields persisted for the Jobs inspector:
job metadata, subject, text and HTML bodies, an optional EML template snapshot,
files, the total recipient count, and at most the first 100 recipient results.
`recipientsTruncated` reports when more results exist. This is not a copy of the
final personalized SMTP message and does not expose generated capability tokens,
password verifiers, or personalized links.

The worker claims one recipient through a short serialized SQLite write,
performs file hashing and SMTP outside the writer callback, and then commits
delivery or bounded retry state. It waits the configured send interval before
claiming the next recipient, which makes campaigns with thousands of recipients
predictably paced and restart-safe. SMTP passwords use `ba.tpm.uniquekey`
authenticated encryption. Link tokens use 32 random bytes and only SHA-256
hashes are stored. Downloads are served at the mount-safe `/mailer/d/<token>`
route with expiry, revocation, file-integrity, optional HTTPS/password,
failed-attempt, `no-store`, and audit checks.

`createInvitationJob()` creates the same persistent type of paced job for
contacts that have not established a download password. This registers a
password for later protected file downloads; it does not create a CMS or
Identity and Access login. The setup link is appended automatically;
`{{INVITATION_LINK}}` is optional and controls its position. Recipients must be
selected explicitly by individual contact IDs or list IDs; only unconfirmed
members of that selection are included. The public, single-use invitation
stores only a
SHA-256 token hash. Acceptance creates a per-contact PBKDF2-SHA256 verifier with
a random salt; the password itself is never stored. A link delivery with
`requireContactPassword=true` is accepted only when every selected contact is
confirmed. Each download checks the contact's current verifier, so resetting a
contact password immediately blocks old authorization sessions and requires a
new invitation before protected delivery can be created. Use
`confirmationStats()` for aggregate status and `resetContactPassword()` to
restart this workflow for one contact.

See [Password Invitations](FuguHub-User-Manual.md#password-invitations)
for the operator workflow.

##### Mailer HTTP endpoints

The operator application is mounted by the plugin, not the CMS content router:

```text
/mailer/             compose alias; mailer-user, mailer-manager, or cms-admin
/mailer/compose/     mass email and optional file deliveries; any mailer role
/mailer/contacts/    contact search and editing; manager or admin
/mailer/lists/       recipient-list management and list-scoped CSV import; manager or admin
/mailer/remove/      paste text, preview matching addresses, and remove contacts; manager or admin
/mailer/invitations/ password invitation selection and status; manager or admin
/mailer/templates/   revisioned EML template management; manager or admin
/mailer/jobs/        active jobs, stored source details, and delivery history; manager or admin
/mailer/manage/      compatibility alias for /mailer/jobs/
/mailer/api/         authenticated operator JSON/multipart API
/mailer/csv/preview/ raw CSV preview endpoint; manager or admin
/mailer/csv/import/  raw CSV import endpoint; manager or admin
/mailer/remove/preview/ raw email-extraction preview endpoint; manager or admin
/mailer/remove/execute/ raw confirmed contact-removal endpoint; manager or admin
/mailer/invite/<token> public single-use password setup
/mailer/unsubscribe/<token> public contact preferences and email opt-out
/mailer/d/<token>    public secure download grant
```

All paths follow the CMS base URI. While the shared identity database has no
users, the operator UI is deliberately available for initial setup, matching
the CMS administration bootstrap behavior. Creating the first identity user
immediately enables normal authentication and role enforcement. The operator
authenticator is rebuilt after
identity changes so newly added, disabled, or changed users take effect without
a Mako restart. Mutations require a session CSRF token and use multipart form
data, including large HTML and EML fields. The manual covers the [operator roles and setup](FuguHub-User-Manual.md#smtp-and-large-file-mailer).

For users with `mailer-user`, `mailer-manager`, or `cms-admin`, the mailer
registers an **Email selected files** command in WFM. It appears only when the
selection contains files and no directories. The command places canonical WFM
paths in same-origin session storage and opens the existing compose page, which
consumes the paths into its file list. This client handoff grants no authority:
job creation, delivery, and downloads reauthorize every file through File
Services.

##### Contacts, lists, and imports

`contacts()` and `history()` return `{items,page,pageSize,total}`. Supplying a
`listId` to `contacts()` restricts the result to that list. Passing `false` for
`includeUnsubscribed` excludes suppressed contacts from recipient selection.
`contactFilter` accepts `all`, `unassigned`, or `unsubscribed`; unknown values
are rejected.
Each returned contact includes parallel `listIds` and `listNames` arrays for all
current memberships, plus `unsubscribed`, `unsubscribedAt`, `confirmed`,
`confirmedAt`, `invitationSentAt`, and
`invitationExpiresAt` password-invitation state.
CSV import is
limited to a 2 MiB raw request body and 5000 data rows. The browser sends the
CSV bytes directly to the preview/import routes, which read bounded 8 KiB
chunks with `request:rawrdr()`; multipart buffering is not used for CSV. The
CSRF token is supplied in `X-FuguHub-CSRF`. Import also supplies the small
one-based column map in `X-FuguHub-CSV-Mapping` and the required destination
list ID in `X-FuguHub-List-ID`. Setting
`X-FuguHub-Restore-Unsubscribed: 1` performs an explicit opt-in restoration for
matching unsubscribed addresses and assigns them to the destination list. The
header must only be sent after operator confirmation. Preview reports
`hasHeader`; import preserves that decision with
`X-FuguHub-CSV-Has-Header: 1` or `0`. Headerless input receives generated column
labels and includes its first row as contact data. UTF-8 and Windows-1252 CSV
files are accepted and normalized to UTF-8; UTF-16 must be exported to one of
these encodings first. Call `previewContactsCsv()`
first, let the operator confirm or change the returned mapping, then call
`importContactsCsv()`. A destination list must already exist. New contacts and
valid contacts that already exist are assigned to that list; in-file duplicate
addresses are reported and skipped. `lists()` includes each list's `memberIds`
by default; pass `false` when only list metadata and membership counts are
needed. `list()` returns one list and its count. `addListMembers()` adds
memberships without disturbing other lists, while `removeListMembers()` removes
only the specified memberships. `transferListMembers()` moves selected contacts,
or the complete list when `contactIds` is omitted. Passing `deleteSource=true`
with a complete-list transfer implements an explicit merge. The service uses a
many-to-many contact/list model, so a contact may belong to several lists.
`resolveRecipients()` deduplicates contacts selected both directly and through
lists and is useful when Lua code explicitly needs the resulting records. Job
creation should normally pass `contactIds` and `listIds` instead, allowing
SQLite to populate the persistent queue without constructing the full campaign
in Lua memory.

Submitting `/mailer/unsubscribe/<token>` marks the contact unsubscribed,
removes all list memberships, and skips that contact in pending and future
deliveries. A `GET` only displays a confirmation page; the state change requires
the page's form submission so automated link inspection cannot opt a recipient
out. By default, CSV import reports the address as suppressed and does not
restore list membership. Passing `restoreUnsubscribed=true` explicitly restores
matching addresses and adds them to the import destination. `resubscribeContact()`
and `resubscribeContacts()` permit future delivery again, invalidate old opt-out
links, and deliberately leave list membership empty.

`previewContactRemoval()` extracts and case-insensitively deduplicates email
addresses found anywhere in arbitrary text, then returns matched contacts and
addresses not present in the database. `removeContactsFromText()` repeats that
lookup against current data and deletes the matches through the serialized
SQLite writer thread. The browser always previews first and asks for explicit
confirmation before calling the removal endpoint. Both HTTP endpoints accept a
bounded 2 MiB `text/plain` body in 8 KiB `request:rawrdr()` chunks, require the
session CSRF header, and cap input at 10000 unique addresses.

Deleting all contacts leaves empty lists; deleting all lists leaves contacts
intact. For browser procedures, see [Contacts](FuguHub-User-Manual.md#contacts)
and [Recipient Lists](FuguHub-User-Manual.md#recipient-lists).

Contacts store `email`, optional `firstName`, optional `lastName`, and optional
`externalId`. Message personalization is deliberately first-name oriented:
`{{FIRST_NAME}}` and the compatibility variable `{{NAME}}` both expand to the
first name, while `{{LAST_NAME}}` expands to the last name. SMTP recipient
headers use `First Last <email>` when either name is available and otherwise use
the bare email address. CSV imports map these contact fields directly; a source
`Display Name` column is not stored.

##### Templates and delivery history

`templates(false)` omits EML source bodies and is suitable for selection lists.
`saveTemplate()` accepts a complete EML source, validates it with the plugin's
private EML parser, and increments its revision on update. `parseTemplate()`
returns the parsed subject plus the first plain-text and HTML MIME bodies. The
authenticated operator API exposes the same parser through the `parse-eml`
action so Compose and Invitations can split pasted EML into editable fields.
When Compose uses a saved template, `createJob()` stores its EML source as an
immutable job snapshot so embedded MIME images remain available, but the job's
explicit Subject, Plain text, and HTML fields override the corresponding parsed
template fields. `purgeHistory()`
deletes only terminal jobs older than the supplied Unix timestamp.

## Related Documentation

- [README: product overview and deployment](../README.md)
- [User Manual: setup and administration](FuguHub-User-Manual.md)
- [Benefits and recorded performance](FuguHub-benefits.md)
- [FuguHub design summary](design/summary.md)
- [Application layout](design/application-layout.md)
- [Database schema](design/database-schema.md)
- [Embedded LSP application guide](../cms/.info/guides/lsp.md)
- [Embedded SMQ application guide](../cms/.info/guides/smq.md)
- [Embedded theme guide](../cms/.info/guides/themes.md)
- [Embedded MCP guide](../cms/.info/guides/mcp.md)
