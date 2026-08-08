---
name: fuguhub-content-db-editor
description: Use when creating or updating FuguHub pages, blog articles, menus, redirects, taxonomy terms, settings, or a fresh SQLite database from the CMS schema. This skill covers content data modeling and database writes, not runtime LSP execution.
---

# FuguHub DB Content Skill

## Remote MCP Boundary

When this guide is delivered by a remote FuguHub MCP server, every operation on
that deployed server must use its HTTP MCP tools, resources, or prompts. Never
open or infer host filesystem paths, open SQLite directly, or bypass MCP with
another server-side access method. Paths in this guide describe the CMS data
model, not files available to the client. Read the `site-builder` guide by
calling `getGuide` with `id="site-builder"`. If the required operation is not
exposed by `getCapabilities`, report it as unsupported instead of creating a
workaround.

Use this skill when adding or changing CMS pages, posts, menus, terms,
redirects, options, drafts, and cache policy through the MCP API.

This skill is intentionally about the CMS database shape and content operations. For runtime LSP execution, `assets/.preload`, `assets/.lua` modules, page tables, `app.assetsApp`, CMS access events, deferred responses, and the CMS SQLite write thread, read:

```text
getGuide { "id": "lsp" }
```

## Required Questions

The remote server selects and owns its SQLite database. Do not ask for a
filesystem database path and do not create a database directly. Call
`getCmsInfo`, `getSchemaInfo`, and the relevant read tools first.

Then ask for the missing content details:

- Content type: `page` or `post`.
- Content path, such as `/products/` for a page or `/example/` for a post.
  Post paths omit the configured blog base.
- Title.
- Body HTML.
- Render mode: `html` or `lsp`.
- Status: `published` or `draft`.
- Whether to add the item to a menu.
- Whether the menu item should be visible or hidden.
- Optional parent menu item, or whether to auto-select by URL prefix.
- Optional category/tag terms.
- Optional meta description.
- Optional trusted `head_html`.
- Optional cache policy.

## Write Mode

An MCP client must use the content, menu, redirect, taxonomy, settings, and
transfer tools exposed by this server. The schema below is explanatory and must
not be edited with a separate SQLite client.

Trusted LSP or asset application code created through MCP may need runtime
writes. That code must use the CMS DB helper and writer thread; it must not open
an independent SQLite write connection.

Runtime write pattern:

```lua
app.db.writeSync(function(conn)
   local ok, err = conn:execute("UPDATE content SET updated_at=strftime('%s','now') WHERE id=1")
   if not ok then
      error(err)
   end
end)
```

For details on the write thread and async result callbacks, call `getGuide` with
`id="lsp"`.

If a write is triggered by a CMS access event registered with `app.cms:on("access", ...)`, the same rule applies: do not open an independent SQLite write connection from the hook. Queue the write with the CMS DB helper or make the hook start an idempotent background job that uses the helper.

## Schema

Use this schema for a clean CMS database:

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

CREATE TABLE IF NOT EXISTS terms (
   id INTEGER PRIMARY KEY,
   type TEXT NOT NULL,
   name TEXT NOT NULL,
   slug TEXT NOT NULL,
   description TEXT NOT NULL DEFAULT '',
   UNIQUE(type, slug)
);

CREATE TABLE IF NOT EXISTS content_terms (
   content_id INTEGER NOT NULL REFERENCES content(id) ON DELETE CASCADE,
   term_id INTEGER NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
   PRIMARY KEY(content_id, term_id)
);

CREATE TABLE IF NOT EXISTS menus (
   id INTEGER PRIMARY KEY,
   name TEXT NOT NULL,
   slug TEXT NOT NULL UNIQUE
);

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

CREATE TABLE IF NOT EXISTS options (
   key TEXT PRIMARY KEY,
   value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS redirects (
   id INTEGER PRIMARY KEY,
   from_path TEXT NOT NULL UNIQUE,
   to_path TEXT NOT NULL,
   status_code INTEGER NOT NULL DEFAULT 302
);

CREATE INDEX IF NOT EXISTS idx_content_type_status_date ON content(type, status, updated_at);
CREATE INDEX IF NOT EXISTS idx_content_path_status_type ON content(path, status, type);
CREATE INDEX IF NOT EXISTS idx_menu_items_menu_parent_pos ON menu_items(menu_id, parent_id, position);
CREATE INDEX IF NOT EXISTS idx_terms_type_name ON terms(type, name);
```

## Field Meanings

### `content`

- `id`: stable numeric content ID.
- `type`: `page` or `post`.
- `path`: stored clean path with a leading slash. Pages store their public
  path. Posts store only the article path and omit `blog_base_path`.
- `title`: display title and default document title.
- `body_html`: stored body content. It is HTML when `render_mode='html'`; it is LSP source when `render_mode='lsp'`.
- `render_mode`: `html` or `lsp`.
- `status`: `published` or `draft`.
- `created_at`: Unix epoch timestamp.
- `updated_at`: Unix epoch timestamp.
- `meta_description`: optional meta description.
- `head_html`: optional trusted HTML inserted into the page head by the theme.
- `cache_policy`: `default`, `revalidate`, `no-cache`, or `no-store`.

Cache policy intent:

- `default`: use CMS defaults. HTML pages revalidate by default; LSP pages default to no-cache.
- `revalidate`: enable validators when the page output is stable.
- `no-cache`: store but revalidate before reuse.
- `no-store`: do not store, useful for preview/admin-style content.

### `terms`

Taxonomy table for categories, tags, or other groupings.

- `type`: taxonomy type, such as `category` or `tag`.
- `name`: display name.
- `slug`: stable lowercase URL-safe identifier.
- `description`: optional description.

### `content_terms`

Many-to-many relation between content and terms.

### `menus`

Menu definitions. A typical public site uses:

```text
name = Primary
slug = primary
```

### `menu_items`

- `menu_id`: owning menu.
- `parent_id`: optional parent item for nested menus.
- `content_id`: optional linked content row.
- `label`: link text.
- `url`: target URL.
- `position`: sort order.
- `hidden`: `0` visible, `1` hidden from public menus.

Hidden menu items remain manageable in admin UI but do not appear in public theme menus.

### `options`

Persistent key/value settings. Common keys:

- `active_theme`: selected public theme.
- `htmx_enabled`: `1` when HTMX navigation is enabled, otherwise `0` or missing.
- `smq_enabled`: `1` when the CMS-owned SMQ service and browser page scopes are
  enabled. SMQ requires HTMX; disabling HTMX also stores this setting as `0`.
- `blog_base_path`: public post archive and post permalink base. Defaults to
  `/blog/`.
- `not_found_enabled`: `1` when the low-priority editable 404 handler is
  enabled.
- `not_found_path`: CMS content path used for unmatched URLs. Defaults to
  `/404/`.
- `mcp_token_encrypted`: TPM-key-encrypted MCP bearer token managed by the MCP
  admin page. Do not read, write, decrypt, or expose this value as content.

### `redirects`

- `from_path`: old URL.
- `to_path`: target URL.
- `status_code`: usually `301` or `302`.

The router sends `301` rows as permanent redirects and `302` rows as temporary
redirects.

## Automatic Database Creation

Normal FuguHub startup creates `data/cms.sqlite.db` when it is missing. The
schema setup module is loaded only for a new database or when required schema is
missing.

A new database is seeded with:

- the primary menu;
- the default theme, HTMX, blog archive, and editable-404 options;
- a published LSP page at `/404/` with a mount-safe link to the admin UI.

`data/cms.sqlite.db` also owns CMS identity profiles, roles, audit rows, and a
TPM-encrypted authenticator blob. Renaming or removing this database therefore
creates a genuinely fresh CMS identity store; there is no separate admin-user
or Identity Access credential file. Other optional plugins may still own their
own mutable data below `data/plugins/`.

This automatic runtime behavior does not remove the required first question for
an offline editing task: an agent must still confirm which database the user
wants to modify.

## Offline Insert Pattern

For offline migration or direct DB editing, use parameter binding. Example Python pattern:

```python
import sqlite3
import time

db_path = r"C:\path\to\cms.sqlite.db"
now = int(time.time())

with sqlite3.connect(db_path) as conn:
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("""
        INSERT INTO content(
            type, path, title, body_html, render_mode, status,
            created_at, updated_at, meta_description, head_html, cache_policy
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        "page", "/example/", "Example Page", "<p>Hello</p>", "html", "published",
        now, now, "", "", "default"
    ))
```

Use the same pattern for posts, menus, terms, options, and redirects.

## Add A Page

Insert into `content`:

- `type = 'page'`
- `path = '/example/'`
- `title = user-provided title`
- `body_html = page body`
- `render_mode = 'html'` unless the page intentionally contains LSP tags
- `status = 'published'` or `draft`
- `cache_policy = 'default'` unless there is a reason to override

For an LSP-enabled page, only set `render_mode='lsp'` and store the LSP source
in `body_html`. Do not duplicate LSP runtime instructions here; call `getGuide`
with `id="lsp"`.

## Add A Blog Article Or Post

Posts use the same `content` table:

- `type = 'post'`
- `path = user-selected article path without the configured blog base`
- `status = 'published'` to appear publicly

If `blog_base_path` is `/articles/`, store `/example-post/`; the public URL is
`/articles/example-post/`. The CMS returns both `path` and `publicPath` through
MCP so callers do not need to concatenate them. Changing the setting leaves
post rows unchanged and changes the derived public URLs. Matching menu URLs and
redirect targets are rebased.

The configured post archive path lists recent rows where:

```sql
type='post' AND status='published'
```

ordered by `updated_at DESC`. The option key is `blog_base_path`; if missing,
the CMS defaults to `/blog/`. Startup upgrades legacy databases that stored the
full post URL by removing the old blog-base prefix and changing content path
uniqueness from global to `(type, path)`.

## Add Categories Or Tags

The admin Categories page creates and edits `type='category'` terms. A blank
slug is generated from the category name. The content editor assigns
categories to posts and preserves unrelated tags.

Create or reuse a term:

```sql
INSERT OR IGNORE INTO terms(type, name, slug, description)
VALUES (?, ?, ?, ?);
```

Attach the term:

```sql
INSERT OR IGNORE INTO content_terms(content_id, term_id)
VALUES (?, ?);
```

Resolve `content_id` from `(content.type, content.path)` and `term_id` from
`(type, slug)`.

Public category archives use:

```text
<blog_base_path>category/<slug>/
```

Database and asset LSP pages can list published articles without writing SQL:

```lua
local posts, err = app.cms:postsByCategory("security", { limit = 20 })
```

Call `getGuide` with `id="lsp"` for the public application environment.

## Add A Menu Item

Ensure the menu exists:

```sql
INSERT OR IGNORE INTO menus(name, slug)
VALUES ('Primary', 'primary');
```

Then insert the item:

- `menu_id`: ID for `slug='primary'`.
- `content_id`: content row ID when linking to CMS content, otherwise NULL.
- `label`: menu label.
- `url`: canonical URL.
- `position`: next available sort position, usually `MAX(position)+10`.
- `hidden`: `0` visible, `1` hidden.

For parent selection:

- If the user specified a parent, use it.
- In the admin UI, `0` explicitly means a top-level item and is stored as
  `NULL`.
- If the user asked for auto-parenting, choose the visible parent whose URL is the longest prefix of the new URL.
- If no parent matches, use `NULL`.
- Report which parent was selected.

## Add A Redirect

Insert or replace a redirect:

```sql
INSERT OR REPLACE INTO redirects(from_path, to_path, status_code)
VALUES (?, ?, ?);
```

Ask whether the redirect should be temporary (`302`) or permanent (`301`) when unclear.

## Drafts And Preview

Draft rows use:

```text
status = draft
```

Public content lookup ignores drafts at their canonical URL. Admin preview can render drafts after an admin check.

Preview uses the canonical content path plus `?cms-preview=<id>`, so ordinary
relative links resolve from the same path as the published page. For links that
must work under both root and named CMS mounts, generate URLs in LSP with
`app.url(...)`; do not hard-code root-relative application URLs.

## Validation Queries

After writing content:

```sql
SELECT id, type, path, title, render_mode, status, cache_policy
FROM content
ORDER BY updated_at DESC, id DESC;

SELECT mi.id, mi.label, mi.url, mi.parent_id, mi.position, mi.hidden
FROM menu_items mi
JOIN menus m ON m.id = mi.menu_id
WHERE m.slug = 'primary'
ORDER BY COALESCE(mi.parent_id, 0), mi.position, mi.id;

SELECT from_path, to_path, status_code
FROM redirects
ORDER BY from_path;
```

Then test:

- The canonical page URL.
- The menu where the item should appear or be hidden.
- The configured `blog_base_path` archive and canonical post URL if a post was
  added.
- Any redirect source URL.
- Admin preview if the content is a draft.

## Safety Checklist

Before writing:

- Confirm DB path or create-new target.
- Confirm whether FuguHub is running against the target DB. If it is running, use runtime write APIs or stop the server before offline editing.
- Confirm content type and canonical path.
- Confirm `html` vs `lsp`.
- Confirm status.
- Confirm menu visibility.
- Confirm parent menu behavior.
- Use parameter binding for offline writes.
- Use the CMS write helper for runtime writes.

After writing:

- Verify the row exists.
- Verify menu visibility.
- Verify redirects.
- Verify rendered output.
- Restart or invalidate runtime state if the current process cached data affected by the change.
