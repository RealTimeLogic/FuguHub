---
name: fuguhub-lsp-htmx
description: Use when building or modifying FuguHub browser interfaces that combine BAS LSP pages with HTMX-rendered HTML fragments, including guarded fragment endpoints, CSRF, multipart forms, mount-safe URLs, history, and SQLite writes.
---

# FuguHub LSP and HTMX Skill

## Remote MCP Boundary

When this guide is delivered by a remote FuguHub MCP server, every operation on
that deployed server must use its HTTP MCP tools, resources, or prompts. Never
open or infer host filesystem paths, open SQLite directly, or bypass MCP with
another server-side access method. Paths are logical CMS asset paths supplied
to MCP tools. If the required operation is not exposed by `getCapabilities`,
report it as unsupported instead of creating a workaround.

Use this guide for server-rendered FuguHub interfaces where navigable LSP pages
return complete HTML and HTMX endpoints return HTML fragments. First call
`getGuide` with `id="site-builder"` and `id="lsp"` for the public application
environment, `assetsreq`, page tables, and SQLite writer rules.

The built-in Content and Menus admin pages use this pattern. An MCP-connected
agent may study the pattern, but the MCP asset tools modify only the site-owned
`assets/` application. They do not modify `cms/admin/` or other engine files.

## Choose The Response Shape

Use three resource types deliberately:

1. A navigable `index.lsp` renders the complete page shell.
2. Read-only fragment LSP files render lists, rows, status regions, or
   confirmations.
3. Mutation LSP files validate the request, invoke a Lua service, and return the
   smallest useful HTML replacement.

Do not return JSON when the browser expects an HTMX HTML fragment.

Typical engine layout:

```text
cms/admin/example/
  index.lsp
  list.lsp
  row.lsp
  save.lsp
  delete.lsp
```

A site-owned interface uses the same shape under `assets/`:

```text
assets/example/
  index.lsp
  list.lsp
  row.lsp
  save.lsp
```

Place reusable site services under `assets/.lua/` and load them from
`assets/.preload` with `assetsreq`. Keep validation and durable mutations out of
presentation fragments.

Read the `assets` guide for public URL rules. The logical MCP asset path
`example/status.lsp` is mounted at `app.url('/example/status.lsp')`, not
`app.url('/assets/example/status.lsp')`.

## Built-In Admin Guard

Every built-in admin LSP starts by loading the private admin module and invoking
its request guard:

```lsp
<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
?>
```

The final argument is `true` for fragment-only endpoints and `false` for a
directly navigable page.

The guard enforces:

- the CMS-specific authenticated session marker `session.isCmsAdmin`;
- `HX-Request: true` or `response:isinclude()` for fragment-only resources;
- a valid CMS CSRF token for POST requests;
- an `HX-Redirect` to the mount-safe admin URL when an HTMX request needs a
  login page.

`HX-Request` is only a response-shape and routing signal. It is not
authentication or authorization.

A site-owned app must provide its own authorization and CSRF policy. Do not call
the private admin guard unless modifying the CMS engine source itself. Use an
application-specific session marker so authentication performed by an unrelated
application does not grant access.

## Reject Direct Fragment Requests

Fragment-only files are implementation endpoints, not browser destinations.
Reject an ordinary direct request:

```lsp
<?lsp
local isHtmx = tostring(request:header("HX-Request") or ""):lower() == "true"
if not response:isinclude() and not isHtmx then
   response:senderror(404, "Not found")
   return
end
?>
```

Do this after the app's authorization check. Do not reveal a protected resource
by returning a more descriptive error to an unauthenticated caller.

## Full Page And Fragment Composition

Share shell markup with LSP includes:

```lsp
<?lsp response:include(app.url("/admin/includes/start.lsp"), true) ?>
<section id="example-list"
         hx-get="<?lsp= app.url('/admin/example/list.lsp') ?>"
         hx-trigger="load">
</section>
<?lsp response:include(app.url("/admin/includes/end.lsp"), true) ?>
```

All application URLs must use `app.url()`. Never assume the CMS is mounted at
`/`; test both:

```text
mako -l::cms
mako -lmybase::cms
```

## Mutation Pattern

An HTMX mutation endpoint should:

1. Authorize the CMS or application session.
2. Require `HX-Request` when the endpoint is fragment-only.
3. Require POST.
4. Parse the appropriate request body.
5. Validate CSRF and all user values.
6. Call a reusable Lua service for the mutation.
7. Return an HTML fragment representing the committed state.

Use `request:multipart()` for large editor forms. Do not rely on ordinary
URL-encoded form bodies for large page content.

Route every SQLite write through the CMS writer API described by the `lsp`
guide. Never open an independent SQLite write connection from an LSP request.

Keep the write callback DB-only. Perform rendering, outbound HTTP, file IO, and
other slow work before or after the serialized write callback.

## HTMX Response Rules

Match each response to its `hx-target` and `hx-swap`:

- Return the target element itself with `hx-swap="outerHTML"`.
- Return only target children with `hx-swap="innerHTML"`.
- Use `hx-swap-oob` when one action must update a second stable region.
- Return the refreshed list when sorting, parentage, or visibility can move an
  item.
- For deletion, return an inert comment or explicit replacement. Do not depend
  on an empty successful response removing an `outerHTML` target.

When an HTMX request loses authorization, use:

```text
HTTP 200
HX-Redirect: <mount-safe login URL>
empty body
```

This forces a full browser navigation that can render the login form correctly.

## Forms And Fallbacks

Keep the ordinary form action valid when practical:

```html
<form method="post"
      enctype="multipart/form-data"
      action="/base/admin/example/edit"
      hx-post="/base/admin/example/save.lsp"
      hx-encoding="multipart/form-data"
      hx-target="#save-status"
      hx-swap="innerHTML">
```

Generate both URLs with `app.url()` in LSP. The normal action provides a
diagnostic and non-HTMX fallback; the fragment endpoint provides the enhanced
interaction.

Use buttons with `name` and `value` for multiple actions in one form. Add
`formnovalidate` only when an action intentionally does not require the other
form fields.

## History And Navigation

For list filters and navigable views:

- use a stable target ID;
- set a mount-safe `hx-push-url`;
- return the same state when that URL is loaded directly;
- test browser Back and Forward;
- update the document title and selected navigation after swaps when needed.

Do not mutate selected navigation in `htmx:beforeRequest`; HTMX may snapshot the
old page for history after that event.

## Error Handling

Validation errors should return a visible fragment near the relevant form.
Unexpected Lua or database errors should:

- write detailed diagnostics to `trace()` without secrets;
- return a generic administrator-safe HTML fragment;
- preserve user-entered values when possible.

Public or theme-level HTMX interfaces must install a visible connection-failure
overlay for timeouts, connection refusal, and send errors. Without this, a dead
server makes navigation appear to do nothing.

For persistent real-time messaging across fragment swaps, enable SMQ and read
the `smq` guide. Page scripts must use `window.cmsSmq.mountPage(...)`, not
create page-local `SMQ.Client` instances.

Do not rely on a full-document theme condition to load a page-specific script
or stylesheet. A user can enter the page through an HTMX fragment, in which
case `layout.lsp` and the document head are not rerendered. MCP API `0.7.0`
does not expose automatic per-content browser dependencies; report that
limitation instead of coupling application code to one theme.

## Validation Checklist

- Direct fragment requests return 404.
- Includes and `HX-Request: true` can render fragments.
- Unauthorized HTMX requests perform `HX-Redirect`.
- A different application's authenticated session is insufficient.
- POST without valid CSRF fails.
- Large multipart editor content saves successfully.
- The response root matches `hx-swap`.
- Add, update, visibility, ordering, and deletion return committed state.
- Empty deletion responses are not relied upon.
- Browser Back and Forward restore URL, content, title, and selected state.
- SMQ pages clean their old page scope while keeping the shell connection.
- Network failure produces a visible warning.
- Root and named mounts generate correct shell, fragment, and history URLs.
- All DB writes use the dedicated CMS writer.
