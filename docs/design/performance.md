# FuguHub Performance

This document records the repeatable public-request performance baseline and
the cache design established by comparison with the legacy FuguHub CMS.
Measurements used the
repository stress corpus, optimized Mako build 5839, 10,000 requests,
concurrency 32, persistent connections, and `Accept-Encoding: deflate`.

## Measured Results

| Request path | Throughput | Average latency |
|---|---:|---:|
| Current engine before optimization | 327.13 requests/s | 97.64 ms |
| Indexed lookup plus metadata caches | 557.63 requests/s | 57.25 ms |
| Bounded published-row cache | 793.98 requests/s | 40.19 ms |
| Legacy FuguHub CMS reference | 842.97 requests/s | 37.83 ms |

The maintained baseline is 2.43 times its pre-optimization throughput and
within about 6% of the measured legacy FuguHub result. Response bytes and the
ten-page workload
were unchanged, and both optimized 10,000-request runs completed without
failures.

## Original Cost

An ordinary request opened separate SQLite read lifecycles for redirect,
content, and primary-menu lookups. Posts opened another one for categories.
The old content query combined post and page-like candidates with `OR`,
`type<>'post'`, and `ORDER BY CASE`; SQLite scanned the content table instead
of using `UNIQUE(type,path)`.

## Current Design

`content.byPath()` uses exact `(type,path)` lookups for posts and pages. An
index on `(path,status,type)` preserves an efficient fallback for other
page-like content types.

Runtime read caches hold:

- the redirect map;
- menu trees by slug;
- term assignments by content id and term type;
- published content rows in a positive-only LRU.

The content LRU is bounded to 128 rows and approximately 4 MiB of row strings.
Rows larger than the byte limit are not retained. Misses are not cached, so
arbitrary 404 traffic cannot grow the cache.

Content rows are cached before `contentpath.decorate()` clones them. Request
rendering may therefore add model fields without mutating the shared cached
row. The cache stores source data only: HTML is still rendered and compressed
per request, and database LSP still executes per request.

## Invalidation

`app.invalidateRuntime()` clears page tables, parsed-LSP state, and all read
caches, then advances the presentation revision used by ETags. Admin, MCP,
settings, theme, and assets-restart mutations use this hook.

Trusted Lua that writes content, redirects, menus, terms, assignments, options,
or other presentation data outside those surfaces must call
`app.invalidateRuntime()` after the write commits. Direct external changes to
the SQLite file while FuguHub is running are unsupported because they bypass
the application invalidation lifecycle.

## Deferred Optimization

FuguHub does not currently cache complete rendered or precompressed responses.
Adding that feature would require an explicit deterministic-output contract,
separate full/HTMX-fragment and encoding variants, bounded storage, and strict
exclusion of preview, `no-store`, user-specific, and dynamic LSP output. The
current row cache recovers most of the measured legacy FuguHub gap without changing
LSP execution semantics.

## Reproduction

Build the seeded deployment and run:

```powershell
.\create-stress-deploy.cmd
.\stress\stress-test.cmd --host localhost --concurrency 32 --requests 10000
```

On Linux:

```sh
sh ./create-stress-deploy.sh
python3 ./stress/stress-test.py --host localhost --concurrency 32 --requests 10000
```

Use the same Mako executable, hardware, URL corpus, connection policy, and
compression header when comparing revisions.
