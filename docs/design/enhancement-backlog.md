# Enhancement Backlog

These are deliberate limitations and plausible future enhancements. They do
not block the current release and must not be implemented through hidden
workarounds.

## Theme Title Anchors

`theme.json` declares whether a theme renders `content.title`, its heading
element, and the expected body heading level. Markdown import promotes the
first H1 to `content.title` and removes it from `bodyHtml`.

The content schema has no dedicated title-anchor field. An importer must not
silently discard an H1 ID targeted by links. A future design should decide
whether that anchor belongs in content metadata, a general metadata object, or
a theme render option.

## Asset Rollback

MCP can validate and install `assets.zip`; it becomes active after restart.
Package history, automatic rollback, and directory-source reactivation are not
implemented.

`restartAssetsApplication` unloads the old asset app before running the new
`.preload`. If loading fails, startup/restart reports `assetsPreloadFailed`;
there is no automatic last-known-good application rollback. A future solution
must define atomic source selection, cleanup, and VFS restoration rather than
masking preload errors.

## Dependency Analysis

`getAssetDependencies` performs bounded literal searches across CMS content,
active theme files, and text assets. Lua, LSP, CSS, and JavaScript may construct
paths dynamically, so the result intentionally reports `complete=false`.
Complete dependency analysis would require explicit manifests or runtime
instrumentation.

## MCP Authorization Scope

All MCP operations currently use one CMS bearer token. There are no separate
read, content-write, theme, asset, or executable-code scopes. Confirmation is
still required for executable writes, publication, destructive operations,
theme activation, and transfer conflicts.

Adding scopes would be an API and operator-workflow change. It must update
capabilities, embedded guidance, tests, and compatibility behavior together.

## Runtime Trace Attribution

Runtime trace uses a bounded server-global BAS buffer, streams
`notifications/message`, and exposes destructive `readRuntimeTrace`. Messages
cannot be reliably assigned to one CMS instance and are not redacted by the
CMS.

A future design may add non-destructive cursors and producer-side application
correlation. Until then, consumers must not attribute untagged messages to a
specific CMS instance.

## Shared Identity

Multi-domain mode uses one global `cms-admin` role and separate browser
sessions per domain. Per-site administrator roles and cross-domain SSO are not
implemented. Identity rows belong to the control CMS database and are injected
as a service into consumers, not copied.

## Admin Usability

Potential improvements that preserve the current security and VFS model:

- move the remaining callback-generated content editor markup to LSP only if
  it materially reduces `admin.lua` complexity;
- add server-side content search and pagination for large sites;
- replace numeric menu parent IDs with a hierarchy-oriented selector.

## Rendered Response Cache

FuguHub intentionally caches source rows rather than complete rendered or
precompressed responses. A future response cache requires deterministic-output
opt-in, bounded storage, full/HTMX and encoding variants, and strict exclusion
of previews, `no-store`, user-specific output, and dynamic LSP. See
[performance.md](performance.md).
