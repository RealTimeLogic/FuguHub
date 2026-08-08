---
name: fuguhub-site-assets
description: Use when creating or referencing site-owned static files, browser JavaScript, CSS, LSP endpoints, assets/.preload, or assets/.lua modules through the FuguHub MCP API.
---

# FuguHub Site Assets And Applications

## Remote MCP Boundary

When this guide is delivered by a remote FuguHub MCP server, every operation on
that deployed server must use its HTTP MCP tools, resources, or prompts. Never
open or infer server filesystem paths. Asset paths in this guide are logical
paths supplied to MCP tools.

## The Rule That Prevents Most Path Errors

The runtime directory name `assets/` is not part of a site asset's public URL.
Its contents are mounted at the CMS application root.

For an asset stored through MCP as:

```text
chat/chat.js
```

the tools return a mount-aware `publicUrl`, for example:

```text
/chat/chat.js
/mybase/chat/chat.js
```

It is not served as `/assets/chat/chat.js`.

In a theme LSP template, keep the theme portable by generating the URL from the
logical application path:

```lsp
<script defer src="<?lsp= attr(model.url('/chat/chat.js')) ?>"></script>
```

Use the `publicUrl` returned by `listAssets`, `getAsset`, or a successful write
when testing the current server with `testPublicPath`. Do not guess or prepend
`/assets`.

## URL Namespaces

These namespaces have different owners:

| Resource | MCP or package path | Theme LSP URL | Owner |
| --- | --- | --- | --- |
| Site asset | `chat/chat.js` | `model.url('/chat/chat.js')` | Site application |
| Theme asset | `images/logo.png` in a theme draft | `model.url('/theme/images/logo.png')` | Active theme |
| CMS HTMX | Not a site asset | `model.url('/assets/htmx/htmx.min.js')` | CMS engine |
| CMS SMQ bridge | Not a site asset | `model.url('/assets/smq/cms-smq.js')` | CMS engine |
| Native SMQ client | Not managed by CMS asset tools | `/rtl/smq.js` | Mako Server |

The `/assets/...` public namespace is reserved for files packaged inside the CMS
engine. It does not expose the runtime's top-level site-owned `assets/`
directory.

## Decide Where The Work Belongs

Use this order:

1. Editorial page or article markup belongs in a CMS content row.
2. Site-specific CSS, browser JavaScript, images, downloads, and public LSP
   endpoints belong in site assets.
3. Shared site Lua services belong in `assets/.lua/` and are loaded from
   `assets/.preload` with `assetsreq`.
4. Reusable visual layout, menus, typography, and presentation belong in a
   theme.
5. General CMS routing, rendering, schema, or lifecycle behavior belongs in the
   CMS engine.

Do not put page-specific application behavior into a theme. Switching themes
must not disable a chat client, dashboard service, editor, or other site
application.

## MCP Asset Workflow

1. Call `getCapabilities`.
2. Read `getCapabilities.applicationModel.urlNamespaces`.
3. Call `getAssetCapabilities`. Stop if the active source is a read-only ZIP
   and the requested operation requires a write.
4. Use `listAssets` and `getAsset` before writing. Treat their `path` as the MCP
   path and `publicUrl` as the current mount-aware browser URL. `listAssets`
   omits file digests by default; request `includeSha256=true` only when a
   bounded listing needs content identities.
5. Write text with `writeTextAsset`; upload binary data through
   `prepareAssetUpload`. Use the latest SHA-256 when replacing a file.
6. For a successful write, read the returned `publicUrl`; do not construct a
   second URL.
7. Call `testPublicPath` with that exact `publicUrl`. A successful write does
   not prove that a guessed reference works.
8. For `.lua` or `.preload`, ask for confirmation, call
   `restartAssetsApplication`, and inspect `readRuntimeTrace`.
9. When a theme references a site asset, use `model.url('/<logical-path>')`.
10. After a theme commit or replacement, request a representative page and
    verify every changed same-origin script and stylesheet URL.

Static files and `.lsp` become active immediately. `.lua` modules and
`.preload` require an assets application restart.

## Themes Must Stay Generic

A theme may load:

- its own files from `/theme/...`;
- the CMS-owned HTMX and SMQ clients from `/assets/...`;
- a site application entry point when the site has deliberately defined that
  dependency.

A theme must not silently acquire application logic by checking a specific
content path and embedding page-specific code:

```lsp
<?lsp if model.content.path == "/chat/" then ?>
<!-- Do not hide a site application dependency here. -->
<?lsp end ?>
```

This fails when another theme is activated and can also fail during HTMX
navigation because `layout.lsp` runs only for full documents while
`fragment.lsp` supplies later swaps.

The default theme manages trusted `content.headHtml` across both full-page and
HTMX navigation. It owns the page-specific `script`, `link`, `meta`, and `style`
nodes, removes them when leaving the page, updates or removes the description
metadata, and installs the next page's nodes. Inline scripts therefore execute
again when the page is entered again. Script side effects outside those head
nodes still require explicit cleanup.

A custom theme that supports HTMX must implement the same page-owned head
lifecycle; read the `themes` guide and use the default theme as the reference.
Keep reusable application services under `assets/.lua/` and mount browser
behavior from site assets. Do not add a path-specific condition to a generic
theme.

## HTMX And SMQ Applications

The full theme shell owns HTMX and, when enabled, one SMQ browser connection.
Site application code belongs in site assets and mounts temporary behavior onto
the current fragment.

For SMQ:

```js
window.cmsSmq.mountPage("Chat", function (scope) {
   scope.subscribeToEvent("site:chat", function (message) {
      // Validate and render the message.
   });

   scope.onReady(function () {
      // The subscription barrier has completed.
   });

   scope.onCleanup(function () {
      // Remove page-owned listeners and timers.
   });
});
```

Do not create a second `SMQ.Client`. Use one consistent event envelope. Sender
and receiver must use the same identifier, channel, kind, and timestamp fields:

```json
{
  "kind": "typing",
  "channel": "lobby",
  "clientId": "browser-instance",
  "name": "Guest",
  "active": true,
  "at": 1785255000000
}
```

Test an SMQ page by entering it through a full page request and through HTMX
navigation from another page. Then navigate away and back. The code must mount
once, clean up once, retain the shell connection, and avoid duplicate events.

## Verification Checklist

- `listAssets` reports the expected logical `path` and `publicUrl`; SHA-256 is
  present only when `includeSha256=true`.
- `testPublicPath(publicUrl)` returns the expected status and content type.
- No site asset URL incorrectly starts with `/assets/`.
- Theme files use `/theme/...`.
- CMS-owned HTMX and SMQ files use `/assets/...`.
- `/rtl/smq.js` remains server-rooted.
- Root and named CMS mounts both work.
- Full-page and HTMX entry paths both load required application behavior.
- Switching themes does not remove site application services.
- Browser network and console output contain no missing resources or duplicate
  initialization errors.
