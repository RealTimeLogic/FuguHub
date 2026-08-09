---
name: fuguhub-theme-authoring
description: Use when creating, modifying, inspecting, packaging, exporting, validating, or activating a FuguHub theme, or when interpreting the theme runtime contract.
---

# FuguHub Theme Authoring

## Remote MCP Boundary

When this guide is delivered by a remote FuguHub MCP server, every operation on
that deployed server must use its HTTP MCP tools, resources, or prompts. Never
open or infer host filesystem paths or bypass MCP with another server-side
access method.

## Available MCP Operations

`getCapabilities` is authoritative. Theme work uses persistent staged drafts:

- Installed reads: `listThemes`, `listThemeFiles`, `getThemeFile`,
  `prepareThemeFileDownload`, and `prepareThemeExport`.
- Draft lifecycle: `listThemeDrafts`, `createThemeDraft`,
  `listThemeDraftFiles`, `getThemeDraftFile`, `validateThemeDraft`, and
  `discardThemeDraft`.
- Draft mutations: `writeThemeDraftText`, `prepareThemeDraftUpload`, and
  `deleteThemeDraftFile`.
- Installation and activation: `commitThemeDraft`, `validateTheme`, and
  `activateTheme`.
- Content contract: `getContentAuthoringContract`.

Theme tools do not operate on the site-owned `assets/` application. Installed
theme deletion, direct theme-package import, and browser visual QA are not
available.

When no external themes are installed, `listThemes` returns the read-only
`default` theme embedded in `cms.zip` with source `built-in`. It can be read or
used as `fromTheme` for a draft. Committing an external theme named `default`
supersedes the fallback.

Read the `assets` guide before referencing site-owned files. The source
directory name `assets/` is not part of their public URL. MCP asset
`chat/chat.js` is referenced as `model.url('/chat/chat.js')`; the
`/assets/...` namespace is reserved for CMS-owned runtime files.

## Draft Workflow

1. Call `getCapabilities`, `listThemes`, and `listThemeDrafts`.
2. Create a draft:
   - New empty theme: `createThemeDraft { "name": "example" }`.
   - New theme cloned from an installed theme:
     `createThemeDraft { "name": "example", "fromTheme": "default" }`.
   - Modify an existing theme: set `name` and `fromTheme` to that same exact
     installed theme name.
3. Inspect files with the installed or draft list/read tools.
4. Use `writeThemeDraftText` for text. Replacing a file requires the SHA-256
   returned by the latest read. LSP is executable and requires
   `confirmedExecutable=true` after explicit user approval.
   File listings omit SHA-256 by default; use `includeSha256=true` only for a
   bounded listing that needs content identities, or call the matching
   `getThemeFile`/`getThemeDraftFile` tool for one file.
5. Use `prepareThemeDraftUpload` for binary files. Upload the exact declared
   bytes to the returned one-time URL with the bearer token, declared content
   type, byte count, and SHA-256 digest. Do not follow redirects.
6. Call `validateThemeDraft`. It compiles all required templates and returns a
   fingerprint for the complete draft.
7. Show the result and ask the user to confirm packaging executable LSP. Call
   `commitThemeDraft` with the exact fingerprint, `confirmed=true`, and
   `confirmedExecutable=true`.
8. Commit rechecks the draft, detects installed-theme conflicts, builds a
   correctly rooted ZIP, validates that ZIP, and atomically installs it as an
   inactive theme by default.
9. If the draft has the same-name active target, the normally confirmed commit
   automatically performs the controlled in-place replacement and reload. No
   additional replacement flag or confirmation is required.
10. For an inactive target, validate the installed theme with `validateTheme`.
    Ask separately before calling `activateTheme` with `confirmed=true`.
11. Verify active state with `getCmsInfo`, then perform browser QA outside MCP.

Draft metadata is private and is never included in committed or exported
packages. Drafts persist across Mako restarts until `discardThemeDraft` is
called with confirmation.

An active replacement is validated and packaged before the current VFS theme
reader is released. The CMS atomically replaces the ZIP, reactivates the same
theme name, and invalidates runtime render state. A
ZIP-backed active theme is snapshotted first for rollback; a directory-backed
theme retains its directory and removes the new ZIP if reload fails. A
successful active replacement returns `active=true`, `reloaded=true`, and
`activationRequired=false`.

## Download And Export

`getThemeFile` returns text inline and marks binary data as available by
download. `prepareThemeFileDownload` and `prepareThemeDraftDownload` create
bounded immutable one-use downloads. `prepareThemeExport` creates a validated,
correctly rooted ZIP snapshot of an installed theme. Transfer URLs expire and
require the same bearer token; never print, log, or retain tokens or tickets.

There is no direct theme ZIP import. To reproduce a theme through the current
API, create a draft and write or upload its files individually.

## Theme Runtime Contract

The remaining sections describe the runtime contract enforced during draft
validation, commit, installed validation, and activation.

The engine loads content, menus, settings, redirects, and cache metadata, then
calls theme LSP templates to produce the response. A logical theme package has
this structure:

```text
work/
  cms/
  themes/
    theme-name/
      style.css
      cms.js
      templates/
        layout.lsp
        fragment.lsp
        page.lsp
        post.lsp
        archive.lsp
        taxonomy.lsp    optional category-archive adapter
        not-found.lsp
      images/
      fonts/
```

## Content Title Contract

The runtime reads `theme.json` at the package root:

```json
{
  "name": "example",
  "contentContract": {
    "rendersContentTitle": true,
    "titleElement": "h1",
    "titleHasAnchor": false,
    "recommendedBodyHeadingStart": 2,
    "canSuppressRenderedTitle": false
  }
}
```

The contract must match both full-page and fragment templates. A theme without
metadata remains loadable for compatibility, but the CMS reports
`declared=false` and cannot infer title ownership.

When `rendersContentTitle=true`, render `model.content.title` exactly once using
`titleElement`; content bodies should start at
`recommendedBodyHeadingStart`. Markdown importers promote the first H1 to the
CMS title and remove it from `bodyHtml`. Do not discard an H1 anchor targeted
by links; dedicated title-anchor storage remains an unresolved design point.

Installed themes may be directory-backed or ZIP-backed. A ZIP must contain the
theme files at its root, for example `style.css` and `templates/layout.lsp`,
not a nested theme-name folder. If both sources exist for one name, the CMS
uses the ZIP.

The CMS mounts the active theme with a resource reader named `theme`. At a root
mount its browser assets are under `/theme/...`; at a named mount they are
under `<base>/theme/...`.

When the active theme is changed or re-saved in `/admin/themes/`, the CMS
reloads the theme resource reader and compiled template cache immediately. A
Mako restart should not be required for this operation.

Theme templates are compiled functions. `activateTheme` reloads the theme
resource reader and compiled template cache. Direct file edits are outside this
MCP API and are not an activation mechanism.

Generate theme URLs with the model helper:

```lsp
<?lsp
local attr = (app.appreq "cmshttp").htmlAttr
local url = model.url
?>
<link rel="stylesheet" href="<?lsp= attr(url('/theme/style.css')) ?>">
<script defer src="<?lsp= attr(url('/theme/cms.js')) ?>"></script>
<script defer src="<?lsp= attr(url('/assets/htmx/htmx.min.js')) ?>"></script>
<img src="<?lsp= attr(url('/theme/images/logo.png')) ?>" alt="">
```

Do not hard-code root-relative application URLs. They bypass the CMS base when
the application is mounted below a name.

Use stable asset URLs without generated query strings. The CMS engine ships
HTMX under `cms/assets/htmx/` and serves it at `/assets/htmx/`; do not add a CDN
dependency or require the site-owned top-level `assets/` directory for a
shipped theme.

## Theme Versus Site Application

Themes own reusable presentation: document structure, menus, typography,
responsive layout, theme CSS, and generic HTMX/SMQ shell support. Site-specific
browser behavior belongs in site assets.

Do not add a path-specific theme condition to load one page's application:

```lsp
<?lsp if model.content.path == "/chat/" then ?>
<!-- This couples the application to this theme. -->
<?lsp end ?>
```

This also breaks HTMX entry from another page because the full
`templates/layout.lsp` is not rerendered when `templates/fragment.lsp` is
swapped. FuguHub MCP API `0.7.0` does not expose a per-content asset declaration
that manages browser dependencies across swaps. If the requested application
needs that facility, report the limitation instead of hiding it in a theme.

When a site deliberately requires a theme to reference a shared site entry
point, use `model.url('/<logical-site-asset>')`, verify the returned asset
tool's `publicUrl` with `testPublicPath`, and test both full-page and HTMX entry
under root and named mounts.

## Template Invocation

Theme templates are LSP files compiled by the CMS with `ba.parselsp()`. The CMS calls a template with:

```lua
template(_ENV, pathname, io, page, app, model)
```

Meaning:

- `_ENV`: BAS request/response command environment.
- `pathname`: request path.
- `io`: application IO.
- `page`: persistent page table for the virtual CMS page.
- `app`: active public application table (`app.assetsApp` when an asset preload
  exists, otherwise the internal CMS app table).
- `model`: page render model from the CMS engine.

The theme should read request data from `_ENV.request`, write with `_ENV.response` or `print`, and use `model` for CMS data.

## Important Model Fields

Common fields:

- `model.content`: current content row.
- `model.content.id`: content ID.
- `model.content.type`: usually `page` or `post`.
- `model.content.path`: canonical clean URL path, such as `/products/`.
- `model.content.title`: page title.
- `model.content.body_html`: stored HTML or LSP source.
- `model.content.render_mode`: `html` or `lsp`.
- `model.content.status`: `published` or `draft`.
- `model.content.meta_description`: optional meta description.
- `model.content.head_html`: optional extra HTML for the document head.
- `model.menu`: tree of visible menu items.
- `model.posts`: post list for archive templates.
- `model.category`: current category for a category archive.
- `model.categories`: categories assigned to the current post.
- `model.renderBody`: function that renders the content body.
- `model.pageState`: stable table for this virtual CMS page.
- `model.htmxEnabled`: true when HTMX navigation is enabled.
- `model.htmxFragment`: true when this request should render only the fragment.
- `model.smqEnabled`: true when both HTMX and SMQ are enabled.
- `model.smqEndpoint`: mount-aware CMS SMQ endpoint.
- `model.responseHeaders`: headers selected by the CMS engine.

Do not mutate database state from a theme template. Themes should render.

## Required Template Roles

### `layout.lsp`

Renders the complete HTML document:

- `<!doctype html>`
- `<html>`, `<head>`, `<body>`
- CSS links
- optional JavaScript links
- header/nav/footer
- main content container
- `content.head_html`
- HTMX attributes when enabled

This is the template returned for normal full-page requests.

### `fragment.lsp`

Renders only the content section that should replace the current page during HTMX navigation.

It should not output:

- `<!doctype html>`
- `<html>`
- `<head>`
- global CSS links
- global script tags

It should output:

- A stable wrapper element for the content area.
- Enough metadata for client script to update title or selected menu state if needed.
- The same page body markup used by full-page rendering.
- A declarative page-head marker even when `content.head_html` is empty, so the
  client can remove prior page-owned head nodes and update or clear the meta
  description.

The default theme brackets initial `content.head_html` in `layout.lsp`, adopts
only the nodes inside those boundaries, and manages later fragment head nodes in
its external client script. A custom HTMX theme must preserve this lifecycle:
never claim permanent shell dependencies as page-owned, remove the previous
page's nodes before installing the next set, and define script re-entry
behavior. Inline page scripts run again each time the page is entered; their
external listeners, timers, or other side effects need their own cleanup.

### `page.lsp`

Adapts a normal CMS page to either `layout.lsp` or `fragment.lsp`.

Recommended pattern:

```lsp
<?lsp
local model = select(6, ...)
model.body = function()
   model.renderBody()
end
app.theme.getTemplate(model.htmxFragment and "fragment" or "layout")(_ENV, pathname, io, page, app, model)
?>
```

### `post.lsp`

Renders blog/article content. It normally wraps `model.renderBody()` in article markup and then delegates to `layout.lsp` or `fragment.lsp`.

### `archive.lsp`

Renders a listing of posts/articles. It uses `model.posts`. The engine also
uses it for category archives when the optional `taxonomy.lsp` is absent.

### `taxonomy.lsp` (optional)

Adapts a category archive to the layout or fragment template. Category
archives provide `model.category`, `model.posts`, and a synthetic
`model.content` whose `archive_type` is `"category"`. If this file is absent,
the CMS calls `archive.lsp`.

### `not-found.lsp`

Renders the editable CMS 404 row. It may delegate to `layout.lsp`, as the
default theme does, or provide a distinct missing-page presentation.

## Menu Generation

The CMS passes a visible menu tree as `model.menu`. Hidden menu items are already filtered by the engine and should not appear in the public theme.

Each menu item usually contains:

- `item.id`
- `item.parent_id`
- `item.content_id`
- `item.label`
- `item.url`
- `item.position`
- `item.children`

Recursive menu pattern:

```lsp
<?lsp
local function htmlAttr(value)
   return (app.appreq "cmshttp").htmlAttr(value)
end

local function isSelected(item)
   local current = model.pathFromUri(request:uri())
   return item.url == current or
      (item.url ~= "/" and current:find(item.url, 1, true) == 1)
end

local function emitMenu(items)
   if not items then return end
   response:write("<ul>")
   for _, item in ipairs(items) do
      local cls = isSelected(item) and " class='selected'" or ""
      response:write("<li", cls, "><a href='", htmlAttr(item.url), "'>", htmlAttr(item.label), "</a>")
      if item.children and #item.children > 0 then
         emitMenu(item.children)
      end
      response:write("</li>")
   end
   response:write("</ul>")
end

emitMenu(model.menu)
?>
```

The theme owns presentation choices such as menu order, dropdowns, mobile
layout, and selected state styling. Keep nested menus collapsed until hover,
focus, or an explicit disclosure control opens them. The default theme uses
`.submenu-toggle`, `aria-expanded`, and `.submenu-open` so large hierarchies
remain compact and usable with pointer, keyboard, and touch input.

Do not place a visual margin between a hover-triggering menu item and its
absolute submenu. A positive `top` or side offset creates a pointer dead zone
that closes the submenu while the user moves toward it. Touch or slightly
overlap the boxes, then create visual separation with submenu padding, borders,
or shadows. Test the pointer path at every supported nesting level.

On desktop, open nested submenus to the right by default. Measure the available
viewport space when a submenu opens by hover, disclosure click, or keyboard
focus, and flip it to the left only when the right side is too narrow and the
left side has more room. Recalculate after viewport resizing. On mobile, clear
the absolute left/right positioning and render nested menus in normal flow.

## HTMX Support

If `model.htmxEnabled` is true, the theme can enable boosted navigation on a stable scope:

```html
<div id="cms-htmx-scope"
     hx-boost="true"
     hx-push-url="true"
     hx-target="#cms-main"
     hx-swap="outerHTML show:window:top"
     hx-history-elt>
   <main id="cms-main">
      ...
   </main>
</div>
```

Place `hx-history-elt` on the stable wrapper that includes both the persistent page chrome and the swap target. Do not put it only on `#cms-main` when the header, menu, breadcrumbs, or other chrome can change state. If `hx-history-elt` is only on the swap target, browser Back/Forward can restore content while leaving stale menu selection or header state in the DOM.

The CMS decides whether a request should be full-page or fragment:

- Normal request: use `layout.lsp`.
- HTMX request: use `fragment.lsp`.

### Target And Swap Contract

Match the fragment root to the HTMX swap mode:

- If `fragment.lsp` returns the target element itself, such as `<main id="cms-main">...</main>`, use `hx-swap="outerHTML ..."` so HTMX replaces the old target instead of nesting the returned target inside it.
- If `fragment.lsp` returns only the target's children, use the default `innerHTML` swap or set `hx-swap="innerHTML ..."`.
- Do not return a second element with the same `id` inside the target. Duplicate IDs break later swaps, menu-state updates, focus handling, and browser automation checks.
- Keep full-page and fragment markup structurally compatible. The fragment root should carry any metadata needed by theme JavaScript, such as `data-cms-title` and `data-cms-path`.

### Scroll Behavior

Set the scroll behavior deliberately on boosted navigation. For normal menu links,
prefer returning to the top of the page:

```html
hx-swap="outerHTML show:window:top"
```

Without an explicit scroll policy, HTMX/browser focus behavior can leave the
viewport at the previous scroll offset or scroll the swap target below the
header. This is most visible when the user clicks a top menu item from a page
taller than the browser window.

Use a different scroll rule only when the theme has a clear reason, such as
preserving position in an infinite list or updating a small in-page panel.

Theme scripts may update selected menu state and `document.title` after HTMX swaps, but should not reimplement the CMS router.

For selected menu state with HTMX:

- Full-page renders should emit the correct selected state from `request:uri()` or `model.content.path`.
- Fragment renders should include stable metadata such as `data-cms-title` and `data-cms-path` so the theme script can update document title and menu state after swaps.
- Clicking a menu link must close all open ancestor and descendant submenus. Removing only `.submenu-open` is insufficient because the clicked link can retain `:focus-within` and the pointer can retain `:hover` after an HTMX swap. Use an explicit dismissed state that overrides both selectors until the pointer leaves the navigation or a disclosure control intentionally reopens a menu.
- Update menu state after `htmx:afterSwap`, `htmx:afterSettle`, `htmx:pushedIntoHistory`, and/or `htmx:historyRestore`. When using `outerHTML`, make sure the script can find metadata on the newly inserted target, not only on `event.detail.target`.
- Avoid changing selected menu state in `htmx:beforeRequest`; HTMX may snapshot the old page for history after that event, causing browser Back to restore the wrong menu state.
- Show a visible, inline-styled connection warning for `htmx:sendError`, `htmx:timeout`, and `htmx:responseError`. Without this, a failed fragment request can appear to do nothing, unlike a normal full page load that shows a browser error.
- Load the local theme HTMX helper before the vendored HTMX library, preferably with `defer`, so connection/error listeners are installed before HTMX starts issuing boosted requests.

Forms and command endpoints need deliberate HTMX behavior:

- Login, logout, registration, file downloads, and POST endpoints that rely on normal redirects or session-cookie changes should usually opt out with `hx-boost="false"` unless the endpoint was explicitly designed for HTMX.
- For forms that are designed for HTMX, preserve user-entered values across validation errors and show a visible busy state for slow actions.
- Avoid boosting destructive or state-changing links unless the server response and history behavior have been tested.

## SMQ Shell Support

Read the `smq` guide before implementing real-time theme support. When
`model.smqEnabled` is true, the full shell must load Mako's server-root
`/rtl/smq.js` and the CMS-owned mount-safe page-scope manager. Emit metadata
before loading the scripts:

```lsp
<meta name="fuguhub-smq-endpoint" content="<?lsp= attr(model.smqEndpoint) ?>">
<meta name="fuguhub-smq-target" content="#cms-main">
<script src="/rtl/smq.js"></script>
<script src="<?lsp= attr(model.url('/assets/smq/cms-smq.js')) ?>"></script>
```

The target metadata must identify the same element that HTMX replaces. Load
these scripts only in the full shell, not in fragment responses. The scripts
must execute before database page content so a direct full-page LSP render can
call `window.cmsSmq.mountPage(...)`.

Do not prefix `/rtl/smq.js` with `model.url`; it is supplied by Mako at the
server root. Do use `model.url` for the CMS-owned client and
`model.smqEndpoint`.

Standalone application routes need the same deliberate handling. A theme can
boost normal CMS pages because the CMS can answer HTMX requests with
`fragment.lsp`, but an app-level route mounted from `.preload` or a custom
directory callback may return a complete HTML document with its own `<head>`,
CSS, and JavaScript. If such a route is swapped into `#cms-main`, the page can
look unstyled or behave incorrectly because the browser does not apply the
returned document head as a normal full page.

Use one of these patterns for routes outside the CMS fragment model:

- Add `hx-boost="false"` to theme menu links that target standalone app routes.
- Keep standalone app routes out of boosted navigation scopes when practical.
- Make the app route detect `request:header("HX-Request") == "true"` and return
  `HX-Redirect: /route/` so HTMX performs a full browser navigation.
- Do not rely on inline `<style>` or `<script>` in a standalone route being
  applied when the route is loaded through an HTMX swap.

## Database-Stored LSP Content

When `model.content.render_mode == "lsp"`, the engine parses and executes the content body before the theme completes rendering. The theme should call `model.renderBody()` exactly where the page body belongs.

Do not call `ba.parselsp()` from the theme for CMS content. That is an engine responsibility.

## CSS Guidance

Keep CSS in the theme, not the CMS engine. Use a small set of stable selectors:

- layout wrappers
- site header
- menu/nav states
- content area
- post/article views
- archive listings
- forms and tables if the public site uses them

Avoid admin CSS in public themes. Admin pages should have a hard-coded admin style or a separate admin theme.

CSS cannot call `model.url`. Use URLs relative to the stylesheet so they remain
inside the mounted `/theme/` directory:

```css
.brand {
  background-image: url("images/header.png");
}
```

Database content can contain media and preformatted examples wider than the
content column. A general-purpose theme should constrain article images and
video with `max-width: 100%` and `height: auto`, and contain `pre` overflow with
an internal horizontal scroller. Do not hide document overflow globally; that
would conceal broken content instead of containing it.

## Package Validation Reference

`validateTheme` compiles required templates, but it does not perform browser or
visual QA. The following checks describe the runtime expectations for a theme
package; do not claim they were performed unless another explicit capability
provides them:

- Load a normal published page.
- Load a page with `render_mode='html'`.
- Load a page with `render_mode='lsp'`.
- Load a post/article page.
- Load an archive page.
- Load a missing page and verify themed 404.
- Confirm hidden menu items do not appear.
- Confirm selected menu styling follows the current URL.
- Hover a root menu and move the pointer into its submenu, then repeat from a
  child into a grandchild menu. Both must remain open across the pointer path.
- Test a third-level menu near both viewport edges. It must open right by
  default, flip left when necessary, remain inside the viewport, and preserve a
  continuous pointer path in both directions.
- At a mobile viewport, verify wide images shrink to the content column and
  wide `pre` blocks scroll internally without widening the document.
- Confirm the mount-aware theme stylesheet and images load at both `/` and a
  named application base.
- If HTMX is enabled, confirm navigation requests return fragments and update only the content target.
- If the site has application pages, enter each page both directly and through
  HTMX navigation from a different page. Required site behavior must initialize
  in both cases and must survive a theme change.
- If HTMX is enabled, confirm the fragment/swap contract: a fragment that returns `<main id="cms-main">` must be paired with `hx-swap="outerHTML ..."`, while a fragment that returns only children may use `innerHTML`.
- If HTMX is enabled, click from one menu item to another and confirm exactly one item is selected after the swap.
- If HTMX is enabled, open a nested menu, click a child link, and confirm every submenu closes immediately even while the pointer remains over the old menu position. Then use the disclosure control and confirm the menu reopens normally.
- If HTMX is enabled, scroll down on a page taller than the viewport, click a top menu item, and confirm the new page starts at the top with the header and menu visible.
- If HTMX is enabled, use the browser Back and Forward buttons and confirm content, URL, document title, and selected menu state all match.
- If HTMX is enabled, test login/register/logout or other session-changing forms and confirm redirects, cookies, and error states behave correctly.
- If HTMX is enabled and the menu links to standalone app routes, confirm those routes force full-page navigation or opt out of boosting.
- If HTMX is disabled, confirm links perform normal full-page navigation.
