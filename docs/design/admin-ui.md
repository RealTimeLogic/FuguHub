# Admin UI Architecture

This document describes the current admin rendering and request contracts.
Read the embedded `lsp-htmx` guide for the reusable application-authoring
workflow; this file is for maintaining the CMS admin implementation.

## Source Layout

```text
cms/admin/
  admin.css
  admin.js
  includes/
    start.lsp
    end.lsp
  content/
    index.lsp
    list.lsp
    row-template.lsp
    row.lsp
    save.lsp
    delete.lsp
  menus/
    index.lsp
    list.lsp
    item-template.lsp
    item.lsp
    action.lsp
    delete.lsp
```

The existing application resource reader serves physical admin files. The
named admin callback handles dynamic routes and returns `false` for physical
resources so normal VFS resolution can continue. Do not add a second admin
resource reader.

## Authentication And Request Guard

The admin VFS owns the native BAS form authenticator and `cms-admin`
authorizer. Successful authentication marks the current session with
`session.isCmsAdmin`. That marker distinguishes CMS administration from a user
authenticated by another application.

Every directly served admin LSP starts through `admin.guardLsp(env, app,
fragmentOnly)`. The guard enforces:

- `session.isCmsAdmin` when admin authentication is active;
- server-side include or `HX-Request: true` for fragment-only resources;
- the session-backed CMS CSRF token for every mutation.

`HX-Request` selects response shape; it is not authorization. Direct requests
to fragment and template files return 404. Unauthorized HTMX requests return an
empty response with a mount-safe `HX-Redirect` to the admin login; ordinary
requests use a normal redirect.

## Rendering Split

LSP owns the complete Content and Menus pages, list/item fragments, inline
confirmations, HTMX targets, swaps, and history URLs. `admin.lua` owns reusable
reads, validation, mutations, dependency checks, CSRF helpers, callback pages,
and runtime invalidation. Durable writes remain serialized through the CMS
SQLite writer thread.

The content editor posts multipart data because body and head fields can be
large. Existing-content save uses the LSP endpoint when HTMX is available and
retains the callback action as a diagnostic fallback. Preview remains a
full-page request.

Menu actions refresh the complete menu-list fragment because parent or position
changes can move an item. Items render depth-first, with siblings ordered by
position then ID. Orphans remain visible at top level, and a visited-node guard
keeps malformed cyclic rows visible without recursive failure.

An HTMX delete must return an explicit replacement, even when that replacement
is only an inert HTML comment. An empty successful response does not reliably
remove an `outerHTML` target.

Unexpected server errors are traced and converted to a generic fragment error.
Validation errors intended for administrators remain visible beside the action.

## Required Validation

`tests/integration.py` and browser tests cover:

- direct fragment/template rejection and valid includes;
- CMS-admin sessions, unauthorized `HX-Redirect`, and CSRF rejection;
- content filtering, saving, preview, dependency display, and deletion;
- menu add/save/hide/show/delete, hierarchy ordering, reparenting, orphan and
  cycle handling, and promotion after parent deletion;
- root and named-mount URLs;
- real HTMX swaps without page-shell replacement or JavaScript errors;
- desktop and mobile layouts without document-level horizontal overflow.

Any new admin LSP endpoint must be added to the direct-access rejection tests,
and every new mutation must have authorization, CSRF, success, validation, and
runtime-invalidation coverage.
