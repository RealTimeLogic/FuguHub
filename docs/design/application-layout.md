# FuguHub Application Layout

This document defines package ownership, IO selection, module loading, VFS
precedence, multi-domain ownership, and lifecycle rules. Public Lua methods are
documented in [FuguHub-API.md](../FuguHub-API.md).

## Runtime Layout

```text
runtime-root/
  cms/                         engine application or cms.zip
    .preload
    .appinfo
    .lua/                      application-private engine modules
    lib/.lua/fastmcp/          stable process-level library
    .info/                     embedded MCP instructions and guides
    admin/                     admin CSS, JS, includes, and LSP pages
    assets/                    engine-owned client dependencies
    fallback-theme/            packaged read-only default theme

  themes/                      installed public themes
    default/                   directory package
    packaged.zip               ZIP package

  assets/                      optional site files and LSP application
    .preload                   optional site startup
    .lua/                      modules loaded by assetsreq
  assets.zip                   deployed alternative to assets/

  plugins/                     optional external trusted packages
    example/.preload
    packaged.zip

  data/                        mutable state
    cms.sqlite.db
    plugins/<id>/
    FuguHub-theme-drafts/
```

The full deployment builder places shipped plugins inside `cms.zip`. The core
builder omits plugins. Both builders add the default theme as
`fallback-theme/`. External immediate plugin packages under the runtime root use
the same discovery contract.

## Ownership

`cms/` owns routing, rendering, the admin UI, core identity, MCP, SMQ, engine
assets, theme activation, SQLite access, cache policy, and runtime invalidation.
It must not depend on the optional site assets directory.

`themes/` owns installed presentation. A theme may be a directory or ZIP. The
runtime prefers `themes/<name>.zip`, then `themes/<name>/`. If no external theme
is installed, `pathio(app.engineIo, "fallback-theme")` exposes the packaged
default theme from either a directory application or `cms.zip`. Activation
compiles the complete template contract before replacing the active reader.

`assets/` or `assets.zip` owns site files and the optional public LSP
application. `assets.zip` takes precedence when both exist. Site assets take
VFS precedence over database content, but engine dependencies such as HTMX are
served from `cms/assets/`.

`plugins/` owns optional trusted executable extensions. Packages are read-only;
mutable state belongs under `data/plugins/<id>/`. Absence of a plugin root must
not prevent core CMS startup.

`data/` is the only mutable core location. The engine creates the CMS database
and seed data when absent. Package archives and themes are never used as
database storage.

## IO And Module Loading

Engine modules under `cms/.lua/` use Mako's application-private `appreq`. This
cache belongs to one CMS instance and is discarded during application reload.
CMS-private modules must not load each other with global `require`.

Stable FastMCP code is process-level and uses `require`. It is exposed through
a loader rooted at `cms/lib/.lua/fastmcp/`. The `pathio` module creates that
nested IO from either a directory application or `cms.zip`; a ZIP cannot create
the required nested IO with `ba.mkio()` alone.

The engine opens Mako home IO for sibling runtime resources:

```lua
local rootIo = ba.openio("home") or io
```

Run development instances from the runtime root so home IO resolves to the
directory containing `themes`, `assets`, and `data`.

The optional assets application gets `app.assetsreq`, a loader rooted at
`assets/.lua/` with a private cache. The loader exists only when
`assets/.preload` exists. Database LSP, asset LSP, and theme templates then use
`app.assetsApp`; otherwise they use the internal CMS `app`.

Each plugin gets an isolated environment and `pluginreq` cache. Dependencies
receive only the service value declared by the provider. Plugin-private modules
must not be exposed through global `require`.

## Mount-Safe Runtime

The original application directory remains owned by Mako. Runtime setup stores
it as `app.appDir`, derives `app.baseUri` from `app.appDir:baseuri()`, and exposes
mount-safe helpers:

```text
app.url(path)
app.pathFromUri(uri)
app.urlEncode(value)
app.redirect(env, path)
```

The CMS stores its inserted public chain in `app.publicDir`. It does not replace
or destroy the original `app.dir`, allowing `mako.stopapp()`, `mako.startapp()`,
and `mako.reloadapp()` to manage the application correctly.

## VFS Chain

The effective chain is:

```text
application directory
  assets resource reader
    priority 1 /admin/ API gate
    /admin/                  admin callback and physical admin resources
    /mcp/                    MCP Streamable HTTP and transfer endpoints
    /SMQ/                    optional broker endpoint
    /<plugin-mount>/         plugin-owned named directories
    unnamed CMS router       database-backed public routes
  priority -127 unnamed dir  editable CMS 404, when enabled
```

Representative construction:

```lua
local assetsDir = ba.create.resrdr(app.dirPrio, app.assetsIo)
assetsDir:lspfilter(app.assetsApp or app)

local adminDir = ba.create.dir("admin")
adminDir:setfunc(admin.new(app))
assetsDir:insert(adminDir, true)

local mcpDir = ba.create.dir("mcp")
mcpDir:setfunc(mcpserver.new(app))
assetsDir:insert(mcpDir, true)

local cmsDir = ba.create.dir()
cmsDir:setfunc(router.new(app))
assetsDir:insert(cmsDir, true)

app.appDir:insert(assetsDir, true)
```

Important rules:

- The assets reader handles static and asset-LSP resources before dynamic CMS
  routing.
- Admin, MCP, SMQ, and plugins use native named children; the CMS router does
  not inspect their prefixes.
- A child directory without a name acts as a sibling in the BAS chain.
- The editable 404 directory is attached to `app.appDir` at priority `-127`, so
  it runs only after all higher-priority resources decline the request.
- A callback returns `false` only when it did not handle the resource and did
  not commit a response.
- Every inserted node must be owned and unlinked by its component during
  reconfiguration or unload.

## Admin And Authentication Nodes

The priority-1 admin API gate protects plugin API paths before a physical
resource can handle them. The normal admin directory owns callback dispatch and
the native form authenticator/authorizer. Physical LSP pages perform the
additional `session.isCmsAdmin` and CSRF checks described in
[admin-ui.md](admin-ui.md).

The MCP directory is independent of browser authentication and uses its
encrypted Bearer token. The SMQ directory is installed consistently but handles
requests only while SMQ is enabled.

Plugins mount native VFS nodes through owner-scoped context helpers. Cleanup is
registered at mount time so failed startup, plugin stop, and CMS unload cannot
leave stale nodes.

## Assets Application Lifecycle

`assets/.preload` runs before the public LSP filter is finalized. It may return
an unload function or define global `onunload`. The CMS stores the environment
as `app.assetsApp`.

`app.restartAssetsApplication()` performs this sequence:

1. call the current assets `onunload`;
2. discard the private assets module cache;
3. load and execute the current `.preload`;
4. update the resource reader's LSP environment;
5. invalidate public page, parsed-LSP, read-cache, and ETag state.

CMS unload invokes the same assets unload hook. Do not retain site resources or
callbacks outside this lifecycle.

## Plugin Lifecycle

Plugin discovery scans bundled engine IO and runtime home IO. It validates all
descriptors, resolves required dependencies, and starts packages in dependency
order. A failed required dependency prevents its dependants from starting.

Each started plugin owns its VFS nodes, admin navigation/routes, APIs, service
registrations, and cleanup callbacks. Unload stops plugins in reverse dependency
order after the assets application has stopped. Shared services such as core
identity are injected explicitly; plugins do not locate another CMS through
global mutable state.

## Multi-Domain Ownership

`CmsDomains` loads several CMS applications in one Mako process. Exactly one
entry sets `control=true`:

```lua
cmsdomains = {
   { host = "a.local", control = true },
   { host = "b.local" }
}
```

The control CMS starts first and owns core identity plus the shared Identity
Access, File Services, and Large File Mailer plugins. Consumers receive the
control identity service before their preload runs and suppress those shared
plugins without reporting dependency failures. Each consumer keeps its own CMS
database, content, settings, assets application, theme, and browser session.

The loader derives database names as `cms-<host>.sqlite.db` and asset sources as
`assets-<host>/` or `assets-<host>.zip`. It derives the shared Users & Access URL
from the control host. Consumers unload before the control.

For archive deployment, `CmsDomains.zip` opens sibling `cms.zip` with `pathio`.
Use the full `cms.zip` builder for the control because it bundles shared
plugins. The plugin-free core archive is for standalone CMS startup, not the
multi-domain controller.

## Database Ownership

The preload exposes `app.db` and `app.db.thread`. All runtime writes use
`app.db.writeSync`, `app.db.writeAsync`, or `db.withWrite`; the writer thread is
the exclusive write owner.

Before routing is installed, startup checks database existence and required
schema. `dbsetup.lua` is loaded only for creation, known additive repair, or the
supported content-path migration. Unsupported mismatches enter the fatal
startup state instead of attempting destructive repair.

## Lifecycle Validation

Changes to IO, loaders, VFS nodes, plugins, or startup must test:

- directory and ZIP engine packages;
- directory and ZIP themes and assets;
- root and named application mounts;
- hot stop/start/reload without stale VFS nodes or module state;
- failed startup and failed assets/plugin initialization;
- multi-domain control-first startup and consumer-first unload;
- a second process attempting to own the same SQLite database.
