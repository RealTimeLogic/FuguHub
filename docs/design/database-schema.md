# FuguHub Core Database Schema

This document describes the core FuguHub SQLite schema maintained by the CMS
engine. Optional plugins own and migrate their own tables.

For shared terms and the runtime model, start with
[../../cms/.info/guides/site-builder.md](../../cms/.info/guides/site-builder.md).

## Tables

### `content`

Stores pages and posts.

```sql
CREATE TABLE IF NOT EXISTS content (
   id INTEGER PRIMARY KEY,
   type TEXT NOT NULL,
   path TEXT NOT NULL,
   title TEXT NOT NULL,
   body_html TEXT NOT NULL DEFAULT '',
   render_mode TEXT NOT NULL DEFAULT 'html',
   status TEXT NOT NULL DEFAULT 'published',
   created_at INTEGER,
   updated_at INTEGER,
   meta_description TEXT NOT NULL DEFAULT '',
   head_html TEXT NOT NULL DEFAULT '',
   cache_policy TEXT NOT NULL DEFAULT 'default',
   UNIQUE(type, path)
);
```

Fields:

- `type`: `page` or `post`. Other values may be added later, but the current renderer treats `post` as a post template and everything else as page-like content.
- `path`: stored clean path. Pages store their public path, such as
  `/products/`. Posts store only the article path, such as `/release-notes/`;
  the router prepends `options.blog_base_path` to form the public URL.
- `body_html`: HTML when `render_mode='html'`; LSP source when `render_mode='lsp'`.
- `render_mode`: `html` or `lsp`. Redirects are stored in the `redirects` table, not as content rows.
- `status`: `published` or `draft`. Public routing ignores drafts at the canonical URL.
- `meta_description`: optional page description for the theme head.
- `head_html`: optional trusted HTML inserted by the theme into the page head.
- `cache_policy`: `default`, `revalidate`, `no-cache`, or `no-store`.

Cache policy intent:

- `default`: HTML pages use browser revalidation by default; LSP pages default to no-cache.
- `revalidate`: send validators for stable output.
- `no-cache`: allow storage but require revalidation before reuse.
- `no-store`: prevent browser storage.

### `terms`

Stores taxonomy terms such as categories and tags.

```sql
CREATE TABLE IF NOT EXISTS terms (
   id INTEGER PRIMARY KEY,
   type TEXT NOT NULL,
   name TEXT NOT NULL,
   slug TEXT NOT NULL,
   description TEXT NOT NULL DEFAULT '',
   UNIQUE(type, slug)
);
```

Use `type='category'` or `type='tag'` for WordPress-like grouping. The `slug` is still useful for taxonomy URLs and stable identifiers even though content pages use clean `path` values.

Category archives are derived from the current blog base as
`<blog_base_path>category/<slug>/`. Category paths are not stored in the
database. Public LSP code can query published posts with
`app.cms:postsByCategory(slug, options)`.

### `content_terms`

Joins content to terms.

```sql
CREATE TABLE IF NOT EXISTS content_terms (
   content_id INTEGER NOT NULL REFERENCES content(id) ON DELETE CASCADE,
   term_id INTEGER NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
   PRIMARY KEY(content_id, term_id)
);
```

### `menus`

Stores named menu sets.

```sql
CREATE TABLE IF NOT EXISTS menus (
   id INTEGER PRIMARY KEY,
   name TEXT NOT NULL,
   slug TEXT NOT NULL UNIQUE
);
```

A normal site uses `slug='primary'` for the main navigation.

### `menu_items`

Stores menu links and hierarchy.

```sql
CREATE TABLE IF NOT EXISTS menu_items (
   id INTEGER PRIMARY KEY,
   menu_id INTEGER NOT NULL REFERENCES menus(id) ON DELETE CASCADE,
   parent_id INTEGER REFERENCES menu_items(id) ON DELETE SET NULL,
   content_id INTEGER REFERENCES content(id) ON DELETE SET NULL,
   label TEXT NOT NULL,
   url TEXT NOT NULL,
   position INTEGER NOT NULL DEFAULT 0,
   hidden INTEGER NOT NULL DEFAULT 0
);
```

Fields:

- `content_id`: optional linked content row. External links use `NULL`.
- `parent_id`: optional parent menu item.
- The admin UI accepts `0` as an explicit top-level value and stores it as
  `NULL`.
- `position`: sort order; use gaps such as 10, 20, 30.
- `hidden`: `1` hides the item from public menus while keeping it manageable in admin.

### `options`

Stores persistent site settings.

```sql
CREATE TABLE IF NOT EXISTS options (
   key TEXT PRIMARY KEY,
   value TEXT NOT NULL
);
```

Current keys:

- `active_theme`: active public theme name, for example `default`. The runtime
  prefers `themes/<name>.zip` and otherwise loads `themes/<name>/`.
- `htmx_enabled`: `1` when HTMX navigation is enabled.
- `smq_enabled`: `1` when the CMS-owned SMQ broker and shell client are
  enabled. The runtime treats this as `0` unless `htmx_enabled=1`.
- `blog_base_path`: public post archive and permalink base, defaulting to
  `/blog/`.
- `not_found_enabled`: `1` when the low-priority editable 404 directory is
  installed.
- `not_found_path`: CMS content path rendered for unmatched URLs, defaulting to
  `/404/`.
- `mcp_token_encrypted`: AES-GCM encrypted MCP bearer token. Its key is derived
  from `ba.tpm.uniquekey`; plaintext is never stored in SQLite.

### `redirects`

Stores URL redirects.

```sql
CREATE TABLE IF NOT EXISTS redirects (
   id INTEGER PRIMARY KEY,
   from_path TEXT NOT NULL UNIQUE,
   to_path TEXT NOT NULL,
   status_code INTEGER NOT NULL DEFAULT 302
);
```

Use `301` for permanent redirects and `302` for temporary redirects. The router
passes the stored value to `response:sendredirect()` as the permanent flag.

### Identity tables

The CMS core stores identity profiles, roles, assignments, audit events, and
the TPM-encrypted authenticator database in the same SQLite file:

```sql
CREATE TABLE IF NOT EXISTS identity_credentials (
   id INTEGER PRIMARY KEY CHECK(id=1),
   encrypted_base64 TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS identity_profiles (
   username TEXT PRIMARY KEY,
   display_name TEXT NOT NULL DEFAULT '',
   email TEXT NOT NULL DEFAULT '',
   disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0,1)),
   max_users INTEGER NOT NULL DEFAULT 3 CHECK(max_users > 0),
   recycle INTEGER NOT NULL DEFAULT 0 CHECK(recycle IN (0,1)),
   inactive INTEGER NOT NULL DEFAULT 1200 CHECK(inactive >= 0),
   created_at INTEGER NOT NULL,
   updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS identity_roles (
   name TEXT PRIMARY KEY,
   description TEXT NOT NULL DEFAULT '',
   system_role INTEGER NOT NULL DEFAULT 0 CHECK(system_role IN (0,1))
);

CREATE TABLE IF NOT EXISTS identity_user_roles (
   username TEXT NOT NULL REFERENCES identity_profiles(username) ON DELETE CASCADE,
   role_name TEXT NOT NULL REFERENCES identity_roles(name) ON DELETE RESTRICT,
   PRIMARY KEY(username, role_name)
);

CREATE TABLE IF NOT EXISTS identity_audit (
   id INTEGER PRIMARY KEY,
   actor TEXT,
   action TEXT NOT NULL,
   target TEXT,
   detail_json TEXT NOT NULL DEFAULT '{}',
   created_at INTEGER NOT NULL
);
```

`identity_credentials` has at most one row. Its value is a Base64 wrapper around
the device-unique TPM-encrypted BAS JSON user database, not plaintext JSON. A
copied credential blob cannot be decrypted on another computer. Profiles and
roles remain queryable without exposing passwords. The optional Identity
Access plugin manages these core tables; it does not own a second credential
store.

## Indexes

```sql
CREATE INDEX IF NOT EXISTS idx_content_type_status_date
   ON content(type, status, updated_at);

CREATE INDEX IF NOT EXISTS idx_content_path_status_type
   ON content(path, status, type);

CREATE INDEX IF NOT EXISTS idx_menu_items_menu_parent_pos
   ON menu_items(menu_id, parent_id, position);

CREATE INDEX IF NOT EXISTS idx_terms_type_name
   ON terms(type, name);

CREATE INDEX IF NOT EXISTS idx_identity_user_roles_role
   ON identity_user_roles(role_name, username);

CREATE INDEX IF NOT EXISTS idx_identity_audit_created
   ON identity_audit(created_at DESC, id DESC);
```

## Runtime Rules

- If `data/cms.sqlite.db` is absent, startup creates the schema and seeds:
  - a `primary` menu;
  - `active_theme=default`;
  - `htmx_enabled=0`;
  - `smq_enabled=0`;
  - `blog_base_path=/blog/`;
  - `not_found_enabled=1`;
  - `not_found_path=/404/`;
  - a published LSP page at `/404/` that links to the mount-safe admin URL.
- If the database exists but required tables or known columns are missing,
  startup loads `dbsetup.lua` to create tables and repair known additive
  columns before creating indexes. It rechecks the complete required schema
  afterward and shows the fatal startup page for unsupported mismatches. It
  does not perform arbitrary destructive migrations.
- Every runtime SQLite connection explicitly enables `PRAGMA foreign_keys=ON`.
- Identity writes stage a replacement TPM database, persist it with profile and
  role changes in one writer-thread transaction, and activate it only after a
  successful commit.
- A missing database creates an empty identity store. The final enabled
  `cms-admin` is protected from ordinary deletion, disablement, and demotion;
  only the explicit reset operation returns authentication to bootstrap mode.
- Public page routing fetches by page path. Public post routing removes the
  configured blog base before fetching the stored post path.
- Drafts render through admin preview after the admin check.
- The configured `blog_base_path` lists published rows where `type='post'`,
  ordered by `updated_at DESC`. The default is `/blog/`.
- A post stored as `/example/` is public at `/blog/example/` with the default
  setting. Changing `blog_base_path` changes the derived public URLs without
  rewriting post rows. Matching menu URLs and redirect targets are rebased.
- Startup upgrades the legacy globally unique `content.path` schema to
  `UNIQUE(type, path)` and removes the old blog-base prefix from stored posts.
  This also permits a page and a post to use the same stored path.
- Public menus filter out `menu_items.hidden=1`.
- Runtime writes must use the CMS write helper and its SQLite writer thread, exposed as `app.db.thread`.
- SQLite lock waits are limited to 2,000ms. Writer jobs expire after 5,000ms
  before commit; expired jobs cannot commit later. Once transaction completion
  begins, its actual outcome is returned. See the [SQLite API](../FuguHub-API.md#sqlite-api)
  for deadline and callback limits.
- Callback and commit failures roll back before the next job. Rollback or
  reservation-recovery failure disables the writer until application restart.
  The successful commit of one job is distinct from acquiring the next
  `IMMEDIATE` reservation.
- Every read and writer connection enables `PRAGMA foreign_keys=ON`; foreign-key
  cascades are part of the runtime contract.

For content editing workflows, use
[database.md](../../cms/.info/guides/database.md). For LSP and asset app
behavior, use [lsp.md](../../cms/.info/guides/lsp.md).
