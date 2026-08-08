# FuguHub Lua API

This document is the reference for Lua APIs provided by FuguHub.
It covers APIs intended for site-owned Lua, database-stored LSP, file-based
LSP, and theme templates.

FuguHub is designed for the [Mako Server](https://makoserver.net/), a
[Barracuda App Server](https://realtimelogic.com/products/barracuda-application-server/)
(BAS) derivative product. Standard objects such as `request`,
`response`, `ba.*`, IoIntf, LuaSQL connections, and VFS directories
are BAS APIs and are documented separately in the
[BAS API reference](https://realtimelogic.com/ba/doc/).

## Assets Application

The top-level `assets/` directory is the main application directory for the
site using FuguHub. Despite its name, it is not limited to images, CSS, and
JavaScript. It may contain:

- static files such as images, style sheets, scripts, and downloads;
- directly addressable `.lsp` pages and HTMX fragment endpoints;
- private Lua modules below `.lua/`;
- an optional `.preload` that initializes the site application.

The CMS engine remains separate under `cms/`. A typical site application is:

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
cms/
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

```lua
app     -- the assets app table itself
io      -- active assets IO
dir     -- public assets resource reader
homeIo  -- writable Mako home IO
assetsreq -- application-private loader for modules under assets/.lua/
```

The `app` table has the same identity in `assets/.preload`, LSP files under
`assets/`, LSP-enabled CMS pages, and theme templates. Printing `app` in each
environment therefore shows the same table reference.

In `assets/.preload`, the table is self-referential:

```lua
_ENV == app
app == _ENV.app
```

An LSP page instead receives a separate request/response environment containing
the shared app table:

```lua
_ENV ~= app
_ENV.app == app
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
app.siteName
```

Use locals for private preload state and modules. Use app fields only for
state and services intentionally shared with request code.

If loading or executing `.preload` fails, the CMS writes the failure to trace
and does not install the assets app table.

### `assetsreq(name)`

`assetsreq` is the application-private module loader for site code:

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

Example preload:

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

### `onunload()`

Define a global `onunload` function in `assets/.preload`:

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
5. updates the assets LSP environment;
6. invalidates CMS page tables, parsed-LSP cache, and presentation revision.

It returns:

```lua
{
   ok = true_or_false,
   unloaded = true_or_false,
   loaded = true_or_false,
   active = true_or_false,
   preloadExists = true_or_false,
   unloadError = optional_message,
   loadError = optional_message
}
```

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

## CMS LSP And HTMX

HTMX is a small browser library that uses declarative HTML attributes such as
`hx-get`, `hx-target`, and `hx-swap` to request server-rendered HTML and replace
part of the current page. This works naturally with LSP because an LSP endpoint
can generate the requested HTML fragment directly, without a JSON API or
client-side rendering code. See
[LSP + htmx: A Powerful Duo for Embedded Web Apps](https://realtimelogic.com/articles/LSP-htmx-A-Powerful-Duo-for-Embedded-Web-Apps)
for a concise introduction.

FuguHub HTMX support is disabled by default. Enable **Enable HTMX navigation**
on the **Admin > Settings** page before using HTMX attributes in CMS content.
The active theme must also support the FuguHub full-page and fragment rendering
contract.

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
application-specific session and enforce CSRF for mutations.

The full CMS page request and the HTMX fragment request are separate HTTP
requests. They share the public `app` application state and can share durable
SQLite data, but they do not share request-local variables. Each physical asset
LSP file has its own persistent BAS `page` table. A database-stored LSP page
uses the CMS virtual page table described below.

Changes to static files and `.lsp` files become active immediately. Changes to
`assets/.preload` or modules under `assets/.lua/` require an assets application
restart.

## SMQ Real-Time API

SMQ support depends on HTMX and is disabled by default. Enable both settings in
the admin panel. The CMS then owns one application-local broker and one
mount-aware endpoint at `app.url("/SMQ/")`. The full theme shell owns the
browser connection; HTMX fragments own temporary page scopes.

### Browser page scope

Database and asset pages must not create page-local `SMQ.Client` instances.
Use the shell API:

```html
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

The page scope provides:

- `subscribeToEvent(topic, handler, datatype)`
- `subscribeToDirectMessage(subtopic, handler, datatype)`
- `sendToBroker(subtopic, payload)`
- `sendToPeer(peerTid, subtopic, payload)`
- `publishEvent(topic, payload)`
- `callRpc(name, ...args)` and `rpc.methodName(...args)`
- `onReady(callback)` and `onCleanup(callback)`

`onReady` runs after the page's SMQ subscriptions have been acknowledged.
HTMX cleanup rejects pending RPC Promises and removes page-owned handlers while
leaving the shell connection active.

If the connection is lost, the CMS shell keeps retrying. After an in-process
CMS reload or a Mako restart on the same origin, it restores the active page's
subscriptions and runs `onReady` again. Treat `onReady` as repeatable
initialization rather than a one-time page-load callback. Explicitly disabling
SMQ in the admin panel is terminal and does not reconnect.

### `app.smq:registerRpcMethod(name, callback)`

Register server RPC in `assets/.preload`:

```lua
local remove, err = app.smq:registerRpcMethod("getDeviceStatus", function()
   return { state = "ready" }
end)
if not remove then error(err) end
```

Callbacks may return a result or `nil, errorMessage`. The returned function
removes that method. Registrations made during `assets/.preload` are
automatically owned by that assets application and removed during its unload.

### `app.smq:onBrokerStart(callback)`

Use this for native broker subscriptions:

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

Publishes through the active CMS broker and returns the native queued-message
count. If SMQ is disabled, it returns `nil, "SMQ is disabled"`.

```lua
local queued, err = app.smq:publish({ state = "ready" }, "DeviceState")
if queued == nil then mako.log(tostring(err)) end
```

### SMQ state

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

## Optional Plugins

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

Only `id` is required. `requires`, `start`, and `stop` are optional. There are
no API revision numbers or version constraints. A value returned by `start`
becomes the one service available to declared dependants.

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

`start(ctx)` and `stop(ctx)` receive:

```text
ctx.id
ctx.io
ctx.dataIo
ctx.db
ctx.admin
ctx:requirePlugin(id)
ctx:own(cleanup)
ctx:mount(name, dir)       -- returns dir, unmount
ctx:trace(...)
```

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
entry. Both calls return owner-scoped remover functions and are also removed
automatically during plugin cleanup.

Use one server-rendered admin shell plus protected JavaScript, CSS, and JSON
handlers for interactive plugin administration. The browser owns incremental
rendering; the server continues to own authentication, CSRF validation,
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

Plugins start after core settings, theme, MCP, and SMQ initialization and
before `assets/.preload`. At shutdown, FuguHub stops the assets application,
then plugins in reverse dependency order, then the remaining CMS services.
One failed plugin does not prevent unrelated plugins or the standalone CMS
from starting; its dependants remain stopped.

### Included management plugins

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
Identity Access encrypted user files into SQLite and removes those legacy files
only after the unified transaction commits.

Plugin contexts expose the same service as `ctx.identity`. In a multi-domain
installation, the control CMS injects it into consumer CMS environments before
preload; users remain stored only in the control CMS database while each domain
keeps its own browser sessions. Identity Access, File Services, and Large File
Mailer run only in the control domain. Consumer admin pages link Users & Access
to the Identity Access page derived from the control domain's configured host.

`plugins/file-services/` depends on identity-access and provides a managed,
authenticated BAS Web File Server and WebDAV service. It is disabled by
default and fails closed if security construction or reconfiguration fails. A
fresh File Services schema contains one enabled `File administrators` ACL that
grants the `file-admin` role write access to `/*`; write access includes read.
Every ACL selects one existing identity role, one path subtree, and either read
or write permission. ACL changes rebuild the File Services runtime without
terminating CMS admin sessions. Its IO, storage path, and base URL come from
`mako.conf`;
the default serves the Mako home IO root at `/fs/`:

```lua
wfs = {
   io = "home",
   path = "/",
   baseurl = "/fs/",
   lockdir = ".locks"
}
```

`lockdir` is the WebDAV lock directory inside the configured WFS IO after
`path` is applied. The CMS creates the final directory if it does not exist;
its parent must already exist. For example,
`wfs={io="disk",path="/c/",lockdir="temp/.LOCK",baseurl="/fs/"}` uses
`C:\temp\.LOCK`. When `path="/"` selects the disk IO root, use an IO path such
as `c/tmp/.LOCK` so locks are not created in the virtual drive-list root.

The admin UI presents this as a role-centered workflow. Selecting a role shows
its assigned-user count and all path grants. ACL names and IDs remain internal;
operators work only with role, path, permission, and enabled state. Duplicate
role/path grants are rejected. The selector omits built-in roles owned by CMS,
Identity Access, and the mailer. It includes `file-admin`, custom roles, and any
role that already has a File Services ACL so existing configuration remains
editable.

The equivalent disk configuration may use
`wfs={io="disk",path="/c/",baseurl="/fs/"}`. The dependency service exposes:

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

`location()` returns `{enabled,io,path,mountUrl}`. `io` and `path` identify the
configured BAS IO root; `mountUrl` opens the corresponding Web File Manager.
File Services paths are absolute within that root, not native filesystem paths:
they must begin with `/`, use forward slashes, and cannot contain encoded
separators or `.`/`..` segments. With
`wfs={io="disk",path="/c/",baseurl="/fs/"}`, the File Services path
`/reports/report.pdf` resolves below disk IO `/c/` (the Windows `C:\` drive).
With `io="home"`, it resolves below the Mako home IO instead.

`addWfmPlugin()` registers an optional client module with the full-page Web File
Manager and returns an idempotent remover suitable for `ctx:own()`. The module
URL must be local and absolute. An optional server-side `allowed(env)` callback
decides whether the module is included for the authenticated request:

```lua
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

File access is independent of CMS administration. A user, including one with
`cms-admin`, needs a matching enabled File Services role/path ACL. When an
authenticated browser opens the WFM without such access, the plugin returns a
self-contained HTML 403 page. The page lists the current user's enabled access
roots as mount-aware, clickable URLs and identifies each root as read-only or
read/write. CMS administrators also receive a link to File Services
configuration. This presentation is generated by Lua through the WFS
`pageaccessdenied` callback and applies only to a commandless `GET` that would
render the WFM. It does not expose roles, ACL identifiers, or grants belonging
to other users. WFS JSON commands and WebDAV methods retain their
protocol-specific error responses.

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

`sendTest()` sends a small message using the saved SMTP configuration. In the
admin UI, **Save and Test** saves first and sends to a test-recipient field that
defaults to the configured From address. From, Reply-to, and test-recipient
fields accept either a bare address or standard `Display Name <address>` mailbox
syntax; contact records continue to store bare addresses.

`createJob()` accepts an authorized sender, `email`, `attachment`, or `link`
delivery, message bodies, `contactIds`, and `listIds`. `email` is ordinary mass
mail and neither accepts nor requires files; it also works when File Services is
disabled. `attachment` and `link` require file paths relative to the configured
File Services root. For example, `/reports/report.pdf` identifies the file at
that path inside the mounted file service, not a Windows or POSIX disk path.
The WFM **Email selected files** command is the preferred way to populate these
paths. Compose hides the path field in email-only mode. In file-delivery modes,
it shows the configured IO and root path plus a link to browse File Services.
Path validation errors identify both the rejected syntax and configured root.
Secure-link messages append a **Download files** section automatically.
`{{DOWNLOAD_LINKS}}` is optional and is used only to place that generated
section at a specific position in plain-text or HTML content. Password
invitations follow the same rule for `{{INVITATION_LINK}}`. Bulk messages can
   place a personal preference URL with `{{UNSUBSCRIBE_LINK}}`; this macro requires
   a Public base URL and saved contacts. The public page lets the recipient update
   their email address and first or last name without changing memberships, or
   unsubscribe from all future mailer deliveries.
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
Identity Access login. The setup link is appended automatically;
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

The Invitations UI requires the Public base URL configured under **Mailer
Settings** because every message contains an absolute setup link. When it is
missing, the UI links administrators directly to the settings page and disables
queueing. Recipients must be selected explicitly as contacts, lists, or both.
Success and error feedback appears beside the Queue button.

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
data, including large HTML and EML fields. The operator header presents only
the tabs authorized for the current user. CMS administrators also receive a
Settings tab that opens the plugin page under CMS administration. The admin
settings page uses the same tabs so operators can move between configuration
and mailer work without adding more CMS sidebar entries.

For users with `mailer-user`, `mailer-manager`, or `cms-admin`, the mailer
registers an **Email selected files** command in WFM. It appears only when the
selection contains files and no directories. The command places canonical WFM
paths in same-origin session storage and opens the existing compose page, which
consumes the paths into its file list. This client handoff grants no authority:
job creation, delivery, and downloads reauthorize every file through File
Services.

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

The Contacts UI is a paged address book showing every contact and all list
memberships. Search is server-side and updates after a short delay as the
operator types. List names are links to dedicated list pages. The Lists index is
a compact catalog; each list page provides its own paged live search, list-scoped
CSV import, selected-contact move/removal, move-all, and explicit merge-and-delete
operations. Editing one contact can also change all of that contact's list
memberships. Individual and bulk deletion are explicit: deleting all contacts
leaves empty lists, while deleting all lists leaves contacts intact.

Compose does not render or transfer the complete contact directory. Its contact
picker starts empty, performs debounced server-side search as the operator
types, and pages broad result sets. Selected contacts are kept separately and
remain selected while the search text or result page changes. Recipient lists
remain a separate selector, and job creation deduplicates contacts selected both
directly and through lists. This same compose workflow is used when WFM hands
selected file paths to the mailer.

Contacts store `email`, optional `firstName`, optional `lastName`, and optional
`externalId`. Message personalization is deliberately first-name oriented:
`{{FIRST_NAME}}` and the compatibility variable `{{NAME}}` both expand to the
first name, while `{{LAST_NAME}}` expands to the last name. SMTP recipient
headers use `First Last <email>` when either name is available and otherwise use
the bare email address. CSV imports map these contact fields directly; a source
`Display Name` column is not stored.

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

## Public API Boundary

The supported application-facing CMS surface is:

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
- the `cmshttp` escaping utility loaded with `app.appreq`.
- the optional plugin descriptor and owner-scoped `ctx` methods documented
  above.

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

When `assets/.preload` exists, FuguHub creates `app.assetsApp`. Database-stored
LSP, file-based asset LSP, and theme templates receive this same public table
as `app`. Without `assets/.preload`, they receive the internal CMS app table.

### Database-stored LSP

Content with `render_mode='lsp'` is parsed by the engine with `ba.parselsp()`
and invoked as:

```lua
fn(_ENV, pathname, io, page, app)
```

- `_ENV` is the BAS request/response command environment.
- `pathname` is the clean CMS content path.
- `io` is the active application IO.
- `page` is the persistent table for this virtual CMS page.
- `app` is the active public app table.

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

The first five arguments have the same meaning as database LSP. `model` is the
CMS render model described under [Theme API](#theme-api).

## Application Table

### Common fields

The following fields are available to public application code:

| Field | Meaning |
| --- | --- |
| `app.baseUri` | Normalized CMS mount path, always beginning and ending with `/`. |
| `app.db` | CMS SQLite access object. |
| `app.cms` | EventEmitter-backed CMS event object. |
| `app.smq` | CMS-owned SMQ service and application registration API. |
| `app.settings` | Current in-memory CMS settings. Treat as read-only. |
| `app.homeIo` | Mako home IO, rooted at the runtime directory. |
| `app.dataIo` | Writable IO rooted at `data/`. |
| `app.assetsIo` | Active site-assets IO, from `assets.zip` or `assets/`. |
| `app.assetsSource` | `"zip"` or `"directory"`. |
| `app.assetsApp` | Public assets app table when `.preload` exists; normally accessed indirectly as `app`. |
| `app.appreq` | Mako's application-private loader used for CMS engine modules. |
| `app.theme` | Active theme state. Application code should only rely on `getTemplate()` as documented below. |

The public assets app also has direct `io`, `dir`, and `homeIo` fields. See
[Assets Application](#assets-application).

Current settings fields are:

```lua
app.settings.htmxEnabled
app.settings.smqEnabled
app.settings.blogBasePath
app.settings.notFoundEnabled
app.settings.notFoundPath
```

Do not persist settings by assigning these fields. Use the CMS admin UI or MCP
settings API so validation, related public-link rebasing, and runtime
invalidation all occur. Post rows store only their article path; the CMS
prepends `app.settings.blogBasePath` when routing and rendering them.

## Mount-safe URL API

Applications can be mounted at `/` or below a named Mako base such as
`/skillvault/`. Use these helpers instead of `dir:baseuri()` or hard-coded
root-relative links.

### `app.url(path)`

Returns a URL below the current CMS base:

```lua
app.url("/")             -- "/" or "/skillvault/"
app.url("/library/")     -- "/library/" or "/skillvault/library/"
app.url("images/a.png")  -- "/images/a.png" or "/skillvault/images/a.png"
```

Absolute scheme URLs, protocol-relative URLs, fragment-only values, and values
already prefixed with the current base are returned unchanged.

### `app.pathFromUri(uri)`

Returns the CMS-relative path for a request URI. Query strings and fragments
are removed:

```lua
local path = app.pathFromUri(request:uri())
-- "/skillvault/library/?q=x" becomes "/library/" at that named mount.
```

### `app.urlEncode(value)`

Percent-encodes one URL component using UTF-8 bytes. ASCII letters, digits,
`-`, `.`, `_`, and `~` are left unchanged:

```lua
local href = app.url("/search/?q=" .. app.urlEncode("Lua & LSP"))
```

This function encodes `/`; call it on one path or query component, not on a
complete URL.

### `app.redirect(_ENV, path, permanent, return2caller)`

Sends a base-aware redirect through the current response:

```lua
app.redirect(_ENV, "/login/")
return
```

`permanent` and `return2caller` are passed to the BAS
`response:sendredirect()` API. The function returns `true`.

## Persistent Page And Render State

### `app.pageTable(scope, key)`

Returns a stable table for a virtual page:

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

Clears one page-table scope or all scopes:

```lua
app.clearPageTables("my-app")
app.clearPageTables()
```

### `app.clearRenderCache()`

Clears the parsed database-LSP cache. The next request reparses LSP bodies as
needed.

### `app.clearReadCache()`

Clears the in-memory published-content, redirect, menu, and content-term read
caches. The next request reloads the required rows from SQLite. Prefer
`app.invalidateRuntime()` when a change can also affect page state, rendered
output, or validators.

### `app.invalidateRuntime()`

Clears page tables, parsed-LSP state, and database read caches, advances the
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

Returns categories ordered by name:

```lua
local categories = app.cms:categories {
   limit = 100,
   includeEmpty = false
}
```

`limit` defaults to 100 and is capped at 500. `includeEmpty` defaults to
`true`. Each category contains `id`, `name`, `slug`, `description`,
`assignmentCount`, `publishedPostCount`, and `path`. The path is CMS-relative;
pass it to `app.url()` when emitting a link.

### `app.cms:category(slugOrId)`

Returns one category by slug or numeric id:

```lua
local category, err = app.cms:category("security")
```

It returns `nil, err` when the selector is invalid or the category does not
exist.

### `app.cms:postsByCategory(slugOrId, options)`

Returns published posts assigned to one category:

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

`limit` defaults to 20 and is capped at 100. Results are ordered by most
recently updated and contain the normal content fields. `post.path` is the
derived public path including `blogBasePath`.

### `app.cms:categoriesForContent(contentId)`

Returns the categories assigned to one content id. Public post theme models
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

Opens a short-lived read environment and connection:

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

Runs `writeFn(conn)` on the CMS writer thread, commits after it returns, and
returns its Lua values to the caller:

```lua
local id = app.db.writeSync(function(conn)
   local ok, err = conn:execute(
      "INSERT INTO jobs(status) VALUES('pending')"
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

`writeSync` blocks the calling thread until the writer callback completes.

### `app.db.writeAsync(writeFn, resultFn)`

Queues `writeFn(conn)` and returns immediately:

```lua
app.db.writeAsync(function(conn)
   return conn:execute(
      "INSERT INTO jobs(status) VALUES('pending')"
   )
end)
```

If `resultFn` is provided, it runs on the writer thread after commit or
rollback:

```lua
app.db.writeAsync(function(conn)
   return conn:execute(
      "INSERT INTO jobs(status) VALUES('pending')"
   )
end, function(runtimeOk, result, sqlError)
   if not runtimeOk then
      mako.log(tostring(result), "my-app")
   elseif not result then
      mako.log(tostring(sqlError), "my-app")
   end
end)
```

The callback receives:

```text
resultFn(runtimeOk, value1, value2, value3)
```

`runtimeOk=false` means `writeFn` raised an error; `value1` is that error.
When `runtimeOk=true`, the remaining values are exactly what `writeFn`
returned. If no result callback is supplied, FuguHub logs failures with
`mako.log(..., "cms-db")`.

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

Registers a listener and returns an unsubscribe function:

```lua
local unsubscribe = app.cms:on("access", function(_ENV, ctx)
   -- Handle the event.
end)

unsubscribe()
```

### `app.cms:off(event, callback)`

Removes a specific listener:

```lua
app.cms:off("access", callback)
```

### `app.cms:emit(event, ...)`

Emits an application-local event. FuguHub itself emits the built-in `access`
event. Site applications may use other event names for their own components.

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

| Member | Meaning |
| --- | --- |
| `ctx.event` | `"access"` |
| `ctx.path` | Content row path when a row exists; otherwise the request URI |
| `ctx.uri` | Original request URI |
| `ctx.method` | HTTP method |
| `ctx.route` | Route value listed above |
| `ctx.content` | Content row when one is associated with the route |
| `ctx.isHtmx` | `true` when `HX-Request` is present |

Context methods:

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

Returns a compiled template from the active theme. Use it to delegate from
`page.lsp`, `post.lsp`, `archive.lsp`, optional `taxonomy.lsp`, or
`not-found.lsp`:

```lsp
<?lsp
local model = select(6, ...)
local templateName = model.htmxFragment and "fragment" or "layout"
return app.theme.getTemplate(templateName)(
   _ENV, pathname, io, page, app, model
)
?>
```

`app.theme.hasTemplate(name)` reports whether an optional template exists
without attempting to compile it.

### Theme `model`

Common fields are:

| Field | Meaning |
| --- | --- |
| `model.site.title` | Default site title. |
| `model.site.baseUri` | CMS base URI. |
| `model.content` | Current content or synthetic archive row. |
| `model.menu` | Visible primary-menu tree. Hidden items are already removed. |
| `model.posts` | Recent published posts for archive rendering. |
| `model.category` | Current category on a category archive, otherwise `nil`. |
| `model.categories` | Categories assigned to the current post. |
| `model.pageState` | Stable table for the virtual page. |
| `model.htmxEnabled` | Whether CMS HTMX navigation is enabled. |
| `model.htmxFragment` | Whether this request should return a fragment. |
| `model.smqEnabled` | Whether the CMS-owned SMQ service and browser page scopes are enabled. |
| `model.smqEndpoint` | Mount-aware SMQ connection URL, such as `/SMQ/` or `/skillvault/SMQ/`. |
| `model.responseHeaders` | Cache and variant headers chosen by the engine. |
| `model.url` | Same mount-safe function as `app.url`. |
| `model.pathFromUri` | Same function as `app.pathFromUri`. |
| `model.renderBody` | Renders the current HTML or database LSP body. |

Call `model.renderBody()` exactly where page/post content belongs. The engine
owns HTML versus LSP rendering.

Menu items commonly include `id`, `parent_id`, `content_id`, `label`, `url`,
`position`, and `children`.

### HTML escaping utility

Load the CMS escaping helper through the application-private loader:

```lua
local http = app.appreq "cmshttp"
local esc = http.html
local attr = http.htmlAttr
```

Both functions convert their value to text and escape `&`, `<`, `>`, `"`, and
`'`. Use `html()` for text and `htmlAttr()` for quoted attribute values. These
functions escape syntax; they do not validate URL schemes or make untrusted
HTML safe. Do not use global `require` to load CMS-private modules.

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

## Related Documentation

- [FuguHub design summary](design/summary.md)
- [Application layout](design/application-layout.md)
- [Database schema](design/database-schema.md)
- [Embedded LSP application guide](../cms/.info/guides/lsp.md)
- [Embedded SMQ application guide](../cms/.info/guides/smq.md)
- [Embedded theme guide](../cms/.info/guides/themes.md)
- [Embedded MCP guide](../cms/.info/guides/mcp.md)
