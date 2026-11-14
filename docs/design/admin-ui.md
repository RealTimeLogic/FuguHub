# Admin UI Architecture

This document describes the current admin rendering and request contracts.
Read the embedded `lsp-htmx` guide for the reusable application-authoring
workflow; this file is for maintaining the CMS admin implementation.

## Source Layout

```text
cms/admin/
  admin.css
  admin.js
  .login.lsp
  includes/
    start.lsp
    end.lsp
  content/
    index.lsp
    editor.lsp
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
  settings/
    form.lsp
  redirects/
    page.lsp
  themes/
    form.lsp
  dashboard/
    page.lsp
  users/
    page.lsp
  mcp/
    form.lsp
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

The hidden `.login.lsp` is the pre-authentication exception. The native login
callback sets response headers and supplies `adminLogin`, a request-local table
containing the authenticator's optional string fields `username`, `seed`, and
`seedkey`. The template requires both a server-side include and this model;
it must not use the authenticated admin-page guard or CMS mutation CSRF token.
The callback route lets this exact resource reach the reader before attempting
authentication or the `/admin` canonical redirect, avoiding recursive login.
The native authenticator continues to own challenge validation and login.

## Rendering Split

LSP owns the shared admin shell and core page bodies, including Dashboard,
Users, and MCP, plus list/item fragments, confirmations, HTMX targets, swaps,
and history URLs. Help uses its existing included HTML resource. Login markup
is in `.login.lsp`; `adminauth.lua` retains the native authentication callback.
Login uses the shared `admin.cssVersion`, associated input labels, and error
alert styling while retaining the BAS form names, seed fields, and login button.
The submit button also supports Enter through the native challenge handler.
Failed login keeps the escaped username; the password field stays empty.
`admin.lua` owns reusable reads, validation, mutations, dependency checks, CSRF
helpers, callback controllers, and runtime invalidation. Durable writes remain
serialized through the CMS SQLite writer thread.

Callback pages include the same `includes/start.lsp` and `includes/end.lsp`
shell as physical LSP pages. The shell loads HTMX and preserves active plugin
navigation, authentication notices, and callback plugin-failure notices.
Controllers set headers, status, and redirects before including markup.

The editor controller supplies `adminContentEditor` in request-local `_ENV`.
`editor.lsp` requires this model as well as the normal guard; it cannot render
through a direct request, even with `HX-Request: true`. Keep form preparation
and mutations in Lua, with escaped values and field markup in the template.

The settings controller supplies `adminSettings`, a request-local table with
typed `values`, an optional error `message` string, and a `saved` boolean.
`settings/form.lsp` requires this model and the normal guard. The controller
validates paths, applies settings to storage and runtime, and handles response
status or redirects. Failed submissions retain raw paths and checkbox values;
GET requests display the current settings. Settings use ordinary POST/redirect,
and the existing `settings.js` controls the HTMX/SMQ checkbox dependency.

Redirects and Themes follow the same guarded include pattern. The Redirects
controller supplies `adminRedirects`, an array of saved redirect rows. The
Themes controller supplies `adminThemes`, a table with the saved `active` name
(string) and available `items` (array). Both templates require their controller
model even for an authenticated HTMX request. Add, delete, and activation remain
ordinary POST/redirect operations; validation, transaction failures, activation
rollback, and cache invalidation stay in Lua. The redirect table uses the shared
scroll container so long URLs do not hide its actions on narrow screens.

Dashboard, Users, and MCP also require guarded request-local models. The
dashboard controller supplies `adminDashboard`: six counts from one aggregate
query, plus the active theme name. Counts include drafts. The Users controller
supplies `adminUsers` with `users`, `available`, an optional error `message`,
and a `username` string (submitted value after a failed save, otherwise empty);
the MCP controller supplies `adminMcp` with `enabled` and an optional `message`.
Authentication, CSRF, user changes, and token persistence stay in Lua. Users
still delegates to the Identity Access UI when configured.

User and MCP validation errors use the shared error alert style. Save User
requires a password; only Remove Admin Access demotes an account. The user
table uses the shared scroll container for long usernames on narrow screens.
Passwords and saved MCP tokens are never filled into the forms. Disable MCP
retains `formnovalidate` so it works with an empty token field; `admin.js`
expands the connection URL using the browser's current address. Reset All
Users retains its confirmation and returns authentication to bootstrap mode.

The private `publicerror` module returns a formatter function. It accepts an
optional error value, converts it to a string (default `Request failed`), and
removes repeated Lua file/line prefixes from existing operator-facing messages.
Core Users responses, authentication failure reasons, and Identity Access JSON
errors use it at the response boundary; the identity service's exceptions and
stored authentication diagnostics retain their original detail. HTML escaping
and JSON encoding still belong to their respective response handlers. The
mailer shares this formatter instead of keeping a plugin-local copy.

The content editor posts multipart data because body and head fields can be
large. Existing-content save uses the LSP endpoint when HTMX is available and
retains the callback action for ordinary form submission. New content uses
ordinary POST/redirect. Inline validation keeps the browser draft, and success
feedback stays beside Save. Preview remains a full-page request using the
saved content ID, including after an inline type, path, or status change.

Content lists use server-side title/path search and 50-row pages. Search and
type filters survive pagination. HTMX responses push the full Content URL,
including its query parameters, so reload and browser history remain usable.

`admin.js` owns the shared labelled-field helper used by bundled plugin forms,
JSON error handling, and the collapsible navigation below 900 pixels. Native
labels and field descriptions remain associated with their controls.
The English admin and mailer shells provide a visible-on-focus skip link to
their main landmark. Collapsing navigation retains focus on the Menu button;
expanding the desktop layout moves focus from that button to the navigation.
Both login forms submit with Enter. Failed logins retain escaped usernames,
clear password fields, and describe the error at the focused username field.

Identity Access user, role, and bootstrap forms use native submit events and
constraint validation. A shared pending flag prevents repeat mutations, disables
enabled buttons, and sets `aria-busy` until the request settles. Feedback names
the operation; completion and errors receive focus and scroll into view. Failed
requests keep the form for correction or retry. Explicit New/Edit actions focus
and reveal the editor; initial rendering leaves the page position alone.
New and re-enabled users require a password. Existing enabled users can keep
their password by leaving the field blank; checking Disabled disables that field.
Server-side validation remains authoritative.
Successful identity reset reloads the page to obtain the new session's CSRF
token before creating another first administrator.

File Services uses native form submission and a shared pending guard for settings
and access rules. It disables enabled controls while a mutation is pending,
distinguishes save/delete feedback, and focuses completion or error messages.
Only the changed section is rebuilt after saving; switching roles rebuilds the
access section and restores focus to the role selector. Unsaved settings survive
access changes, and unsaved access fields survive a settings save. API errors use
the core public-error formatter without altering service diagnostics.

Mailer contact, list, and template editors share native submit validation and a
pending guard. The contact email field uses the browser's email validation.
Requests disable enabled controls until completion; failures retain drafts and
focus visible error feedback. Explicit New/Edit actions focus the first field;
successful saves refresh displayed records. These guards do not provide durable
request deduplication across reloads or retries after a lost response.
Cancel restores the button that opened a contact or list editor. Feedback uses
named status/alert regions so focused results can be read by screen readers;
the complete Identity Access and File Services editors are not live regions.

Menu actions refresh the complete menu-list fragment because parent or position
changes can move an item. Items render depth-first, with siblings ordered by
position then ID. Orphans remain visible at top level, and a visited-node guard
keeps malformed cyclic rows visible without recursive failure.

Add and edit forms share the parent-selector renderer in `item-template.lsp`.
The existing tree traversal supplies path labels, subtree boundaries, and
valid-ancestry flags. Selectors exclude the edited subtree and invalid ancestry;
server-side parent validation remains authoritative. Menu-list swaps also
refresh the add selector out of band, preserving its selected value when that
choice still exists. Failed edits retain submitted fields and use alert styling.

Content, category, and menu delete callbacks include their respective `delete.lsp`
templates, so full-page and HTMX confirmations share markup. Full-page forms
use ordinary POST/redirect and Cancel links; fragments replace the content row,
category list, or menu list. Content deletion receives its prepared dependency
model through request-local `adminContentDelete`; category deletion receives its
category table through `adminCategoryDelete`. Single-category and list queries
share count calculation so confirmations include draft assignments accurately.

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
- large multipart editor fields, escaped markup and Unicode, categories,
  HTML/LSP changes, inline errors, ordinary POST fallback, and saved previews;
- search and pagination beyond 500 records, including canonical HTMX URLs;
- mailer double-click protection and saved-versus-unsaved settings feedback;
- settings normalization, HTMX/SMQ dependencies, custom 404 behavior, retained
  fields after validation/write failures, and category confirmation counts;
- redirect add/replace/delete, 301/302 responses, escaped long URLs, and
  theme activation across directory/ZIP/built-in sources, including failures;
- dashboard counts, first-admin setup, password changes, required passwords,
  access removal, final-admin protection, reset cancellation/confirmation,
  and failed writes without credential changes;
- MCP token validation, save/replace/disable, encrypted persistence, restart,
  failed writes without token changes, and recovery from corrupt storage;
- clean core/Identity Access errors for user and role validation, protected
  accounts/roles, failed writes/reset, and successful recovery;
- keyboard login and identity forms, retained escaped usernames, empty password
  fields after failed login/core saves, native field validation, repeated requests,
  network failure/retry, password preservation, and disabled/re-enabled users;
- File Services and mailer editor keyboard submission, retained drafts, section
  refresh, repeated saves, canceled deletes, and network/write failure recovery;
- menu add/save/hide/show/delete, hierarchy ordering, reparenting, orphan and
  cycle handling, selector refresh, stale-parent rejection, and promotion after
  parent deletion;
- root and named-mount URLs;
- real HTMX swaps without page-shell replacement or JavaScript errors;
- desktop and mobile layouts without document-level horizontal overflow.

Accessibility checks also cover skip links, focus after responsive navigation
changes and editor cancellation, and accessible feedback/control names. Test
actual browser zoom and spoken screen-reader output separately from viewport
emulation and accessibility-tree assertions.

Any new admin LSP endpoint must be added to the direct-access rejection tests,
and every new mutation must have authorization, CSRF, success, validation, and
runtime-invalidation coverage.
