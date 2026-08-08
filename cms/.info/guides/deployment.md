---
name: fuguhub-deployment
description: Use when running, packaging, deploying, or verifying FuguHub runtime layout, including full and core cms.zip packages, bundled plugins, CmsDomains.zip, external themes, assets, mutable data, startup commands, and deployment troubleshooting.
---

# FuguHub Deployment Skill

## Remote MCP Boundary

When this guide is delivered by a remote FuguHub MCP server, every inspection
or operation on that deployed server must use its HTTP MCP tools, resources, or
prompts. Never open or infer host filesystem paths, run server shell commands,
open SQLite directly, or bypass MCP with another server-side access method.
Runtime paths and commands below explain the deployment model; they are not
remote access instructions. Read the `site-builder` guide with
`getGuide { "id": "site-builder" }`. If a deployment operation is not exposed
by `getCapabilities`, report it as unsupported.

Use this skill when preparing or troubleshooting a FuguHub runtime deployment. This skill is about how the CMS is arranged and launched, not about editing content, writing LSP app logic, or designing themes.

## Runtime Layout

The intended runtime layout is:

```text
work/
  cms/          CMS engine application during development
  plugins/      optional external plugin packages during development
  themes/       installed themes outside the engine
  assets/       development assets directory
  assets.zip    optional deployed assets package
  data/         mutable SQLite database and runtime data
```

Keep these responsibilities separate:

- `cms/`: engine code. The full deployment builder packages the shipped plugins
  into `cms.zip`; the core builder omits them.
- `plugins/`: optional external trusted packages supported during development.
  The shipped production plugins are normally bundled into the full `cms.zip`.
- `themes/`: installed public themes. Use either theme directories or theme ZIP files. Do not put themes inside the engine package.
- `assets/`: site-owned static files and optional public LSP app files for development.
- `assets.zip`: deployed assets package. If present, it takes precedence over `assets/`.
- `data/`: writable runtime data, including `cms.sqlite.db`.

The database is optional in a new runtime. When `data/cms.sqlite.db` is absent,
startup creates the required schema and seeds default settings, a primary menu,
and an editable LSP 404 page.

## Startup

Start the CMS from the runtime root:

```powershell
cd path\to\work
mako -l::cms
```

For packaged standalone core CMS startup, use `mako -l::cms.zip`. For a full
packaged multi-domain runtime, use `mako -l::CmsDomains.zip`; the loader opens
the sibling `cms.zip`.

For repository development, run the isolated root/named-mount integration suite:

```powershell
powershell -ExecutionPolicy Bypass -File tests\run.ps1
```

The test runner creates temporary runtime directories and databases under
`.test-runtime/`; it does not use the runtime's normal `data/` files. Its named
case starts `mako -lmybase::cms` and verifies HTML, database LSP, admin,
authentication, theme resources, editable 404 handling, and mount-safe LSP
URLs below `/mybase/`.

## Hardware Stress Deployment

The source repository includes `create-stress-deploy.cmd` and `stress/` for
repeatable concurrent GET testing. The builder first packages the CMS and
themes, starts an isolated packaged CMS, lets the CMS create its canonical
schema, and inserts ten published benchmark entries through the admin HTTP API.
It writes a separate `deploy-stress/` runtime containing `cms.zip`, theme ZIPs,
`data/cms.sqlite.db`, and the tested URL manifest.

The corpus has five pages and five posts, ranges from approximately 2 KiB to
512 KiB, and has exactly five LSP-enabled entries. The external Python client
supports configurable host or IP address, port, base path, concurrency,
request count, HTTP/HTTPS, compression, keep-alive, and CSV output. Run the
load generator on another computer when measuring constrained hardware.

The stress database intentionally has no admin users or MCP token. It is not a
production deployment and must not be exposed to an untrusted network.

In the command above, replace `path\to\work` with the directory that contains
`cms/`, `themes/`, `assets/`, and `data/`.

## Fatal Startup Page

Mako Server can keep running even when the CMS application cannot initialize.
For fatal CMS startup errors, the engine installs a high-priority app directory
that returns a minimal inline `503 Service Unavailable` page for requests under
the mounted CMS app. The same error is printed with `trace()`.

Fatal startup errors include:

- the SQLite database is already owned by another FuguHub process;
- schema creation or migration fails;
- theme activation fails.

A site-owned `assets/.preload` failure is nonfatal. The CMS writes it to trace,
continues without the assets application table, and uses the internal CMS app
environment for public LSP. Repair the preload and use the confirmed
`restartAssetsApplication` MCP tool; its structured result reports whether the
replacement loaded.

The most common deployment case is starting a second Mako process against the
same runtime `data/` directory. The fix is to stop the other process or start the
second app with a separate writable runtime/data directory.

## Home IO

The CMS preload uses:

```lua
local rootIo = ba.openio("home") or io
app.homeIo = rootIo
```

Run Mako from the runtime root so `home` points at the directory containing `cms/`, `themes/`, `assets/`, `assets.zip`, and `data/`.

If `home` points at the wrong directory, common symptoms are:

- theme cannot be opened
- database is missing or recreated in the wrong place
- assets are missing
- `assets/.preload` does not run

## Assets IO Selection

The CMS selects assets in this order:

```lua
local assetsIo, err

if rootIo:stat(app.assetsZipName) then
   assetsIo, err = ba.mkio(rootIo, app.assetsZipName)
   if not assetsIo then
      error("cannot open " .. app.assetsZipName .. ": " .. tostring(err))
   end
else
   if not rootIo:stat(app.assetsDirName) then
      local ok, mkdirErr = rootIo:mkdir(app.assetsDirName)
      if not ok then
         error("cannot create " .. app.assetsDirName .. ": " .. tostring(mkdirErr))
      end
   end
   assetsIo, err = ba.mkio(rootIo, app.assetsDirName)
   if not assetsIo then
      error("cannot open " .. app.assetsDirName .. ": " .. tostring(err))
   end
end
```

Defaults:

```lua
app.assetsDirName = "assets"
app.assetsZipName = "assets.zip"
```

Rules:

- If `assets.zip` exists, the CMS uses it and ignores `assets/`.
- If `assets.zip` does not exist, the CMS uses `assets/`, creating it if needed.
- If `assets.zip` exists but is corrupt or cannot be opened, startup should fail. Do not silently fall back to `assets/`; that can hide deployment mistakes.
- `assets.zip` may include static files, `.preload`, and `.lua/` modules.
- Code running from packaged assets should treat `app.assetsIo` as read-only. Write runtime data through `app.homeIo` under `data/` or another explicit writable location.

The MCP asset API follows the same rule. It lists and reads ZIP-backed assets
but rejects writes. `prepareAssetsImport` validates and installs a new
`assets.zip`; the current source remains active until Mako restarts.

## Public Asset App

If the selected assets IO contains `.preload`, the CMS loads it before installing the LSP filter.

The asset app receives:

```lua
app     -- public asset app table
io      -- selected assets IO, from assets.zip or assets/
dir     -- assets resource reader
homeIo  -- runtime home IO
```

The CMS then executes asset LSP and database-stored CMS LSP with the public app table:

```lua
app.assetsApp or app
```

When `.preload` exists, the public app also receives `assetsreq`, a private
loader for modules under `.lua/`. An MCP client activates changed `.lua` or
`.preload` files with the confirmed `restartAssetsApplication` tool. The CMS
calls the asset app's global `onunload` both during that restart and when the
CMS unloads.

For programming this public app, call `getGuide` with `id="lsp"`.

## Themes

Themes are loaded from:

```text
themes/<active-theme>/
```

The active theme is read from the `options` table using `active_theme`, then `theme`, then `app.defaultTheme`.

For an active theme named `example`, the CMS resolves the theme in this order:

```text
themes/example.zip
themes/example/
```

If both exist, the ZIP wins. The admin theme page lists directory themes and
zip-packaged themes, showing zip-backed themes as `name (zip)` while saving the
logical base name such as `example`.

Changing the active theme in `/admin/themes/` activates the selected theme immediately. The CMS unlinks the old `/theme` resource reader, inserts a new one, and clears the compiled template cache. Do not tell the user to restart Mako after a normal theme switch.

For remote theme implementation, call `getGuide` with `id="themes"`. The MCP
draft workflow packages validated files as `themes/<name>.zip`, leaves the new
package inactive by default, and requires a separate confirmed activation.
A normally confirmed commit whose draft has the same-name active target instead
atomically replaces and immediately reloads that theme.

## Database And Mutable Data

Keep the SQLite database outside the engine package:

```text
data/cms.sqlite.db
```

Do not put mutable databases inside `cms.zip` or `assets.zip`.

For content operations, call `getGuide` with `id="database"`. For runtime write
behavior, call `getGuide` with `id="lsp"`.

## Packaging Guidance

The repository has two deployment builders:

```bat
create-deploy.cmd
create-core-deploy.cmd
```

`create-deploy.cmd` writes `deploy/cms.zip` with the shipped Identity Access,
File Services, and Large File Mailer plugins bundled under `plugins/`. It also
writes `deploy/CmsDomains.zip` and compressed theme packages. Use this layout
for the supported multi-domain configuration.

`create-core-deploy.cmd` writes `deploy-core/cms.zip` without plugins and the
same compressed themes. It does not write `CmsDomains.zip`; this package is for
a standalone CMS that does not need the management plugins.

Both scripts validate ZIP roots and plugin inclusion or exclusion. The
integration harness starts both archive layouts and verifies the full
multi-domain plugin ownership model.

Package only stable application code:

- Package `cms/` as `cms.zip`; use the supplied builders so plugin contents are
  included or excluded consistently.
- Optional package candidate: `assets/` as `assets.zip` for deployed site assets.
- Keep outside packages: `data/`, generated cache/runtime files, logs, local backups.
- Keep themes outside the engine so a site can change themes without rebuilding `cms.zip`.
- Package a deployed theme as `themes/<theme>.zip` when you want immutable theme assets and templates.

### Packaged Multi-Domain Layout

```text
runtime/
  cms.zip
  CmsDomains.zip
  mako.conf
  themes/
    default.zip
    embedded-dashboard.zip
  assets-<host>/ or assets-<host>.zip
  data/
```

`mako.conf` must define `cmsdomains` with exactly one `control=true` entry. The
control domain owns Identity Access, File Services, and Large File Mailer;
consumer domains share its identity provider and keep separate CMS databases
and assets. The Users & Access URL is derived from the control host. Do not add
a separate management URL setting.

When deploying with packaged assets:

1. Build `assets.zip` from the contents of `assets/`, not from a parent folder that would create `assets/...` inside the ZIP.
2. Place `assets.zip` in the runtime root next to `cms/` or `cms.zip`.
3. Start Mako from the runtime root.
4. Request a known asset URL to prove the ZIP is active.

An MCP client may instead use `prepareAssetsExport` and
`prepareAssetsImport`. These workflows use bounded one-time URLs, byte-count
and SHA-256 verification, safe ZIP paths, expanded-size limits, and
compile-validation of executable entries. ZIP rollback is not implemented.

For themes, an MCP client may create or clone a persistent draft, write text,
upload binary files, validate the complete draft, and call `commitThemeDraft`
to atomically install a correctly rooted theme ZIP. `prepareThemeExport`
returns the same validated package shape. Active replacement uses a validated
rollback snapshot for ZIP themes and retains the source directory for directory
themes. Direct theme ZIP import and installed theme deletion are not exposed.

## Verification

Before testing, stop any old Mako process that may still be serving an older app or ZIP.

Check process command lines on Windows:

```powershell
Get-CimInstance Win32_Process -Filter "name = 'mako.exe'" |
  Select-Object ProcessId,CommandLine
```

Start the CMS:

```powershell
cd path\to\work
mako -l::cms
```

Again, replace `path\to\work` with the runtime root.

Verify:

- `GET /` returns the configured homepage, or the seeded themed 404 response
  for a new empty database.
- `GET /theme/style.css` returns a theme asset.
- A known file in `assets/` or `assets.zip` returns from `/...`.
- Admin pages still live under `/admin/`.
- `data/cms.sqlite.db` is the database being used.

For a named mount, apply the mount prefix to every URL above and verify the
application root, admin pages, theme resources, redirects, preview links, and
editable 404 path under that prefix.

To verify `assets.zip` precedence:

1. Put a marker file such as `zip-marker.txt` in `assets.zip`.
2. Start Mako.
3. Request `/zip-marker.txt` from the running server.
4. Confirm the response comes from the ZIP.
5. Remove the marker and temporary ZIP after the test if it was only for verification.

## Troubleshooting

If a file in `assets/` is ignored, check whether `assets.zip` exists. The ZIP has precedence.

If asset LSP state is missing, check whether the active assets IO contains `.preload`.

If `assetsreq` fails in `assets/.preload`, confirm the module is under the selected assets IO in `.lua/`.

If a DB appears empty or new, confirm Mako was started from the runtime root and `ba.openio("home")` resolves to the expected directory.

If a deployed app behaves differently from development, check for:

- stale `cms.zip`
- stale `assets.zip`
- wrong working directory
- old Mako process still running
- mutable data accidentally packaged into a ZIP
