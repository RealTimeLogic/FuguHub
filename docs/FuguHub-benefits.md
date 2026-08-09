# FuguHub Benefits

FuguHub combines a compact content-management system with the native Lua,
LSP, virtual-file-system, SQLite, HTMX, SMQ, and security capabilities of Mako
Server. It is designed for dynamic websites and real-time web applications
that must run efficiently on anything from a development computer to
resource-constrained embedded hardware.

Its integrated SMQ messaging layer is particularly valuable for embedded
systems. A CMS page can become a live device interface with telemetry,
commands, events, and RPC without adding a separate WebSocket service,
message broker, or large browser framework.

## High Dynamic Throughput

The repository stress test measures complete CMS responses rather than static
files. Its ten-page corpus contains five normal pages and five blog posts,
ranging from approximately 2 KiB to 512 KiB. Five entries execute stored LSP
and Lua on every request. The CMS still renders and compresses each response;
it does not use a full-page response cache.

On an Intel Core i7-1165G7 with four physical cores and eight logical
processors, optimized FuguHub build 5839 produced:

| Measurement | Result |
| --- | ---: |
| Throughput | **793.98 requests/second** |
| Average latency at concurrency 32 | **40.19 ms** |
| Requests | 10,000 |
| Failures | 0 |

The load generator and FuguHub shared the same Windows computer, so the client
also consumed part of the available CPU. Published content rows, menus,
redirects, and category assignments were cached in memory, while LSP
execution, theme rendering, and deflate compression still occurred for every
request.

### Indicative WordPress Comparison

A 2025 Kinsta benchmark measured a default WordPress 6.8 installation with no
additional plugins or page-caching layer. WordPress 6.8 on PHP 8.5 produced
148.30 requests/second on a Google Cloud VM with 30 vCPUs. The test used
Nginx, PHP-FPM with OPcache, MariaDB, concurrency 15, and a 48.6 KiB response.

Against that published result, the measured FuguHub throughput is:

```text
793.98 / 148.30 = 5.35
```

FuguHub therefore delivered approximately **5.4 times the uncached dynamic
throughput** in these separate tests, despite running on a four-core mobile
processor and sharing it with the load generator.

A simple allocation calculation gives approximately 99.25 FuguHub requests
per second per local logical processor and 4.94 WordPress requests per second
per allocated cloud vCPU, suggesting about a 20x CPU-efficiency difference.
That figure is directional, not a controlled capacity measurement: cloud
vCPUs and local hardware threads are not equivalent, and Kinsta's concurrency
of 15 may not have exercised all 30 vCPUs.

CPU generation materially affects WordPress performance, but does not explain
the measured gap. Intel has reported up to 1.51x more WordPress throughput per
vCPU on newer GCP processors. Even applying that entire improvement to the
Kinsta result would produce about 224 requests/second, leaving the local
FuguHub result approximately 3.5x higher.

These figures are an informed estimate, not an apples-to-apples benchmark.
The response sizes, operating systems, databases, server configurations, and
test tools differ. The local FuguHub responses averaged approximately 3 KiB
after deflate compression, whereas Kinsta reported a 48.6 KiB WordPress
response. Kinsta also states that its PHP-version benchmark was not designed
as a cross-CMS comparison. A definitive comparison requires running both
products on the same hardware with the same content and load generator.
WordPress can serve much higher request rates through a full-page server or
CDN cache, but such requests bypass WordPress, PHP, and the database and
therefore measure the cache rather than dynamic CMS execution.

Sources:

- [Kinsta PHP and CMS benchmarks](https://kinsta.com/blog/php-benchmarks/)
- [Intel WordPress throughput-per-vCPU study](https://cdrdv2-public.intel.com/787232/wordpress-gcp-c3-n2-vms.pdf)
- [Local FuguHub performance design](design/performance.md)

## AI-Native CMS Administration

FuguHub includes a Streamable HTTP MCP server so an AI agent can work with a
deployed CMS through a documented, bounded API rather than direct filesystem
or database access.

The MCP API supports:

- discovering CMS capabilities, limits, guides, examples, and workflow
  prompts;
- finding, validating, creating, updating, copying, publishing, and deleting
  pages and blog posts;
- managing categories, menus, redirects, CMS settings, and cache state;
- creating and modifying site assets, including static files, LSP endpoints,
  and private Lua modules;
- creating persistent theme drafts, validating complete themes, installing
  theme ZIPs, and activating or replacing themes without restarting Mako;
- exporting selected content and transferring it directly between FuguHub
  servers using immutable ZIP snapshots and one-use tickets;
- inspecting health, schema information, SQLite integrity, and bounded BAS
  runtime trace output;
- restarting the site-owned assets application after trusted Lua changes,
  without restarting the Mako Server process.

Content creation defaults to drafts. Publishing, executable LSP, destructive
operations, theme installation and activation, and transfer conflicts require
explicit decisions. Optimistic timestamps and SHA-256 identities reject stale
updates. The MCP bearer token is encrypted in SQLite with a key derived from
`ba.tpm.uniquekey` and is never returned through MCP.

The operational documentation is embedded in the CMS package and exposed
through MCP. An agent can therefore learn the exact API and development
patterns from a remote `cms.zip` deployment without host filesystem access.

## More Than A Traditional CMS

FuguHub pages can contain trusted LSP and Lua, making the CMS a host for
server-side applications as well as static content.

The site-owned `assets/` application can contain:

- public images, CSS, JavaScript, downloads, and other static resources;
- directly addressable LSP and HTMX fragment endpoints;
- private Lua modules loaded through the application-specific `assetsreq`
  loader;
- an optional `.preload` that initializes reusable services and shared
  application state;
- an `onunload` lifecycle function for timers, subscriptions, VFS nodes, and
  other resources.

Database LSP pages, asset LSP files, Lua modules, and theme templates share the
same public application table. Site code can expose services once in
`assets/.preload` and use them throughout the application.

## Embedded Real-Time Applications With SMQ

Optional HTMX navigation lets FuguHub return server-rendered HTML fragments
without requiring a JSON API or a client-side application framework. This
reduces browser code while preserving clean URLs and normal full-page
navigation.

When HTMX is enabled, SMQ can add a persistent real-time connection managed by
the theme shell. The CMS owns the broker and browser connection lifecycle,
while application code registers Lua services and page-scoped behavior. This
makes it straightforward to connect CMS-managed interfaces to devices,
industrial equipment, sensors, controllers, and edge applications.

Page-scoped APIs support:

- publish and subscribe events;
- direct peer messages;
- browser-to-server RPC;
- automatic cleanup during HTMX navigation;
- reconnection, subscription restoration, and repeatable page initialization
  after a server or network interruption.

Typical embedded applications include:

- live telemetry and equipment-status dashboards;
- browser controls for device configuration and operation;
- alarms, notifications, and asynchronous state changes;
- request/response commands implemented as SMQ RPC;
- direct browser-to-device or peer messaging where permitted by the
  application security policy.

The same Mako process can host managed content, Lua application logic, the SMQ
broker, LSP endpoints, and browser assets. This reduces deployment complexity
and avoids coordinating an external broker or a separate real-time backend.
HTMX handles server-rendered navigation and partial updates, while SMQ handles
state changes that originate asynchronously from a device or server.

## Compact, Self-Contained Deployment

FuguHub keeps responsibilities separate:

```text
cms.zip       packaged CMS engine and built-in fallback theme
themes/       optional directory or ZIP-packaged themes
assets/       development site application
assets.zip    optional packaged site application
data/         writable CMS SQLite database and optional plugin data
```

The engine, built-in default theme, HTMX runtime, and SMQ integration are local;
the default deployment does not depend on a public CDN. External themes take
precedence when installed. If no database exists, FuguHub creates the schema,
default settings, primary menu, and editable 404 page automatically.

The same package can run at the server root or below a named base URI. Themes,
content, assets, admin pages, MCP, HTMX, SMQ, redirects, and preview links use
mount-aware URL helpers.

## Purpose-Built Runtime Design

FuguHub uses Mako and BAS facilities directly instead of layering a CMS over a
separate web server, process manager, language runtime, and database server.
Its runtime design includes:

- application-private Lua module loading for CMS and site code, enabling Mako
  application hot swapping without global `require` state;
- a dedicated SQLite writer thread that serializes all CMS and application
  writes to avoid competing SQLite writers;
- bounded in-memory read caches with explicit invalidation after admin, MCP,
  theme, settings, or application mutations;
- persistent virtual-page tables for database-backed LSP;
- native VFS composition for engine routes, site assets, themes, admin
  authentication, editable 404 handling, and named application mounts;
- automatic response compression and browser cache validation;
- TPM-backed administrator authentication and encrypted MCP configuration.

## Where FuguHub Fits

FuguHub is a strong fit when the priorities are:

- high dynamic throughput on limited CPU and memory;
- embedded, edge, appliance, or local-server deployment;
- AI-assisted administration through a first-class MCP API;
- Lua and LSP application logic integrated with managed content;
- real-time browser communication without a large client framework;
- compact ZIP deployment with SQLite rather than a multi-service stack;
- direct control over themes, navigation, routing, assets, and application
  lifecycle.

WordPress has a much larger plugin, theme, hosting, and editorial ecosystem.
FuguHub instead emphasizes a small, controllable runtime for developers
building efficient dynamic and real-time applications with Mako Server.
