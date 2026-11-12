# FuguHub Benefits

FuguHub is a content management system (CMS) that combines website publishing
with Lua application development on Mako Server. Use it for a public website,
a customer portal, or a live device dashboard, with content, application logic,
and data on a computer you control. Manage the site in your browser or connect
an AI agent to help build and maintain it.

For a short deployment walkthrough, start with the
[README](../README.md#get-started). The [User Manual](FuguHub-User-Manual.md)
covers setup and everyday administration.

## Compact, Self-Contained Deployment

Mako runs the web server, Lua application logic, SQLite storage, and Simple
Message Queue (SMQ) messaging together. For a website or connected application,
that means fewer services to install and manage. The CMS does not need a
separate database server.

FuguHub's default theme and browser libraries are served locally, so the site
does not depend on a public content delivery network (CDN). This is useful for
private networks, local servers, and embedded Linux devices.

The CMS package, site assets, themes, and writable data are kept separate. You
can update the engine or change the presentation while keeping your site's
content and application files in their own locations. See
[package choices](FuguHub-User-Manual.md#choose-a-package) and the
[runtime directory](FuguHub-User-Manual.md#runtime-directory) for the layout.

## AI-Native CMS Administration

Describe a new page, a navigation change, or a site feature to an AI agent,
then let it work with the running CMS through the authenticated Model Context
Protocol (MCP) interface.

An agent can help you draft and revise pages, update menus, develop a theme,
transfer content between sites, or investigate application errors. It can do
this through MCP without direct access to the host filesystem or database.
The CMS supplies guides for its deployed API, so the agent can work from the
capabilities of your installation.

Content creation starts with drafts. You decide when to publish, activate a
theme, or install executable application code. These are administration
capabilities, so give access only to trusted people and agents. Follow
[MCP Setup](FuguHub-User-Manual.md#mcp-setup) to connect a client and understand
the access it receives.

## More Than A Traditional CMS

Start with ordinary pages and blog posts, then add forms, customer portals,
or device controls with Lua Server Pages (LSP). Server-side Lua can combine
managed content with database queries, application services, and live data.
Application code can also use Mako's MQTT, OPC UA, Modbus, and other protocol
APIs to connect the browser interface to equipment and services.

Your site's `assets/` directory holds more than images and styles. It can also
contain LSP endpoints and private Lua modules, keeping custom application code
separate from the CMS engine. Reusable services can support several pages and
themes. This makes it possible to grow a site into an application without
maintaining a separate backend for those features.

Custom applications require Lua and browser development, whether you write
the code yourself or work with an AI agent. See
[Site Assets and LSP Applications](FuguHub-User-Manual.md#site-assets-and-lsp-applications)
for the application layout and the [Lua API](FuguHub-API.md) for programming
details.

## Embedded Real-Time Applications With SMQ

A device interface needs to react when equipment changes state. FuguHub
combines two optional features for this: HTMX updates parts of the page during
navigation and browser requests, while SMQ delivers asynchronous events from
the server or connected devices.

For example, a dashboard can show current measurements, display an alarm as
it arrives, and let an operator send a command without reloading the page.
Application code supplies the device integration and decides which users may
perform each action.

FuguHub manages the SMQ broker and browser connection in the same Mako
process. Its page APIs handle subscriptions, remote procedure calls (RPC),
cleanup during navigation, and reconnection. You can build these interfaces
with server-rendered HTML and focused JavaScript, without introducing a large
browser framework or a separate messaging service for SMQ.

Enable HTMX before enabling SMQ, and use a theme that supports HTMX navigation.
The manual covers the [site settings](FuguHub-User-Manual.md#public-site-settings).
For implementation, see the [SMQ API](FuguHub-API.md#smq-real-time-api).

## Add Services As Your Site Grows

The full package includes services for sites that need more than publishing:

| Service | What it adds |
| --- | --- |
| [Identity and Access](FuguHub-User-Manual.md#identity-and-access) | Manage user accounts, profiles, and roles. |
| [File Services](FuguHub-User-Manual.md#file-services) | Give authorized users browser-based access to selected folders. |
| [Large File Mailer](FuguHub-User-Manual.md#smtp-and-large-file-mailer) | Send email and share large files through download links. |

For several related sites, [multiple-domain hosting](FuguHub-User-Manual.md#advanced-multiple-domains)
provides shared identity with separate content databases. You can also install
and activate [themes](FuguHub-User-Manual.md#themes) without rebuilding the CMS
package or restarting Mako.

## Purpose-Built Runtime Design

FuguHub uses Mako's web, Lua, storage, and messaging facilities directly.
Bounded in-memory caches reduce repeated database reads, and a dedicated
SQLite writer serializes writes. Responses are compressed, while browser
cache validation avoids downloading unchanged resources. The
[performance design](design/performance.md) explains these choices for
maintainers.

## High Dynamic Throughput

The repository includes a repeatable stress test for complete CMS responses.
Its ten-page workload contains five pages and five blog posts, ranging from
approximately 2 KiB to 512 KiB. Five entries execute LSP and Lua on every
request. Content data is cached, but each response is still rendered and
compressed; the test does not serve pre-rendered pages from a full-page cache.

The recorded optimization baseline used **Mako build 5839** on a Windows
computer with an Intel Core i7-1165G7, four physical cores, and eight logical
processors:

| Measurement | Result |
| --- | ---: |
| Throughput | **793.98 requests/second** |
| Average latency at 32 concurrent requests | **40.19 ms** |
| Requests | 10,000 |
| Failures | 0 |

FuguHub and the load generator ran on the same computer. Connections were
persistent and responses used deflate compression. These are recorded results
for that build and workload, not a capacity guarantee for another site or
device. Use the current manual's runtime requirements when deploying.

The [performance report](design/performance.md) records the optimization
stages and cache behavior. The [stress-test guide](../stress/README.md) explains
how to measure your own deployment. Test with representative content,
application code, and target hardware before sizing a production system.

### Indicative WordPress Comparison

Published WordPress results provide context, but the tests used different
hardware and workloads. [Kinsta's December 2025 PHP benchmark](https://kinsta.com/blog/php-benchmarks/)
reported 148.30 requests/second for WordPress 6.8.0 on PHP 8.5, using a
30-vCPU cloud VM, 15 concurrent requests, and a roughly 48.6 KiB response.
Kinsta designed that test to compare PHP versions within each CMS.

Those conditions differ from the FuguHub test above. The figures do not
establish a relative speedup or CPU-efficiency advantage. For a useful product
comparison, run both systems on the same hardware with equivalent content,
application behavior, compression, caching, and load conditions.

## Where FuguHub Fits

FuguHub is a good fit for teams that want to build and control an application
with Mako and Lua while managing its content through a CMS. If your project
depends on a broad selection of third-party themes, plugins, or managed hosting
options, weigh those requirements alongside the integrated runtime and
application-development features described here.

Ready to try it? Follow [Get Started](../README.md#get-started), then use the
manual to [create your first page](FuguHub-User-Manual.md#create-your-first-page)
or [connect an AI agent](FuguHub-User-Manual.md#mcp-setup).
