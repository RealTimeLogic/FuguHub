# FuguHub

![Fuguhub Logo](https://fuguhub.com/images/FuguHub.png "Fuguhub Logo")

FuguHub is a compact content-management and Lua web-application platform for
Mako Server. It combines database-backed pages and posts with LSP, HTMX, SMQ,
SQLite, themes, optional plugins, and a Streamable HTTP MCP interface for AI
agents.

This Mako Server-based implementation supersedes the
[original FuguHub](https://fuguhub.com/). Existing users may continue running
the original version, while new installations should use this version. The
easiest way to get started is with the
[Mako Server Developer Edition](https://makoserver.net/documentation/developer-package/).

## Highlights

- Clean page and blog URLs with HTML or server-side LSP content.
- External directory or ZIP themes with immediate activation.
- Optional HTMX navigation and SMQ real-time events, messaging, and RPC.
- AI administration through a documented, authenticated MCP API.
- Optional Identity and Access, File Services, and Large File Mailer plugins.
- Standalone and shared-identity multi-domain deployment.
- Self-contained ZIP deployment for Mako Server.

## Quick Start

On Windows, the easiest way to get started is to install
[Mako Server Developer Edition from the Microsoft Store](https://apps.microsoft.com/detail/9nqr6ksk077k).
It provides Mako Server and a ready-to-run Developer Edition with FuguHub,
Xedge, LSP-Claw, and MQTT tools. Use the
[first-start credential procedure](#initialize-all-mako-developer-edition-credentials)
before enabling remote access.

For a manual source checkout, install Mako Server and make sure `mako` is on
`PATH`, then run from the repository root:

```bat
mako -l::cms
```

Open `http://localhost/admin/`. FuguHub creates `data/cms.sqlite.db` and its
initial schema automatically.

For a standalone FuguHub first startup, create the administrator and optionally
enable MCP from the command line:

```bat
mako -l::cms -credentials siteowner:choose-a-strong-password -token choose-a-long-random-token
```

Command-line secrets may appear in shell history and process listings. Use
these options only for the first startup and restrict access to the host.

## Security

FuguHub is both a content-management system and a server-side application
environment. Treat access to CMS administration and the Model Context Protocol
(MCP) interface as code-deployment access, not only as permission to edit text.

Before exposing FuguHub to an untrusted network:

- Prefer command-line initialization of the administrator credentials and MCP
  token on the first startup. This initializes the new database without
  requiring browser-based administrator setup. If you start without these
  options, keep the server restricted to the local computer or a trusted
  network until you create the administrator through the browser.
- Use a long, unique password and a non-obvious administrator username. Avoid
  common names such as `admin` and `root`. A less predictable username does not
  replace a strong password.
- If MCP is enabled, generate a long, random bearer token. Store it as a secret,
  never commit it to source control, and replace it if it may have been exposed.
- Use HTTPS and restrict access to the administration and MCP endpoints where
  the deployment permits it.
- Give administrative and MCP credentials only to people and agents trusted to
  deploy application code.

See the [User Manual](docs/FuguHub-User-Manual.md) for administrator bootstrap,
MCP configuration, identity storage, and deployment guidance.

### Initialize all Mako Developer Edition credentials

The complete Mako Developer Edition includes FuguHub and other embedded
applications. On the first startup, you can initialize the same administrator
username and password and the same MCP bearer token for all included
applications. Open Command Prompt in the directory containing `mako` and run:

```bat
mako -credentials username:password -token XjTi57sCSQgHyUrPrMuL59GO7iauxjqn
```

Replace all three example values with private, unpredictable values. The token
must be at least 16 bytes. Each application imports the supplied values into
its own authenticator and retains its own authorization state. Existing
credentials are not replaced.

This command avoids leaving the embedded applications open for interactive
credential setup. Command-line secrets may still be visible in Command Prompt
history or process information, so run it only on a controlled host during
initialization. Before enabling remote access, verify administrator
authentication and bearer-token authentication for every enabled application.

See [Mako Developer Edition security notes](https://makoserver.net/documentation/developer-package/#security)
for the complete package behavior, including how imported secrets are protected
and why they cannot be transferred to another computer.

### Trusted Lua application development

The ability to execute server-side Lua is intentional. Both pages stored in the
SQLite database and files in the site assets application can use
[Lua Server Pages (LSP)](https://realtimelogic.com/products/lua-server-pages/).
This turns FuguHub from a traditional CMS into a managed web-application
environment where content, application logic, browser interfaces, real-time
communication, and persistent data can run together.

Because FuguHub runs on Mako Server, application code can use the protocol
libraries and APIs supplied by Mako, including OPC UA, Modbus, MQTT, SMQ, HTTP,
WebSockets, and database APIs. A FuguHub application can therefore implement a
working industrial command center that presents live telemetry, processes
alarms, issues authorized commands, and communicates with industrial devices.
The application remains responsible for authenticating users, authorizing each
operation, validating commands, and protecting the connected device network.

Only trusted administrators and developer-operators should create or modify
executable LSP. Static pages should use HTML render mode unless server-side
application logic is required.

#### Learn How FuguHub Works

Read the [full article](https://realtimelogic.com/articles/LSP-htmx-A-Powerful-Duo-for-Embedded-Web-Apps), which explains how JavaScript and lightweight server rendering work together, or jump directly to [how FuguHub works](https://realtimelogic.com/articles/LSP-htmx-A-Powerful-Duo-for-Embedded-Web-Apps#FuguHub).</p>


### Context for reports about the original FuguHub

Search results may show
[CVE-2023-24078](https://nvd.nist.gov/vuln/detail/CVE-2023-24078), which names
FuguHub 8.1 and earlier, as well as a separate public demonstration against
[FuguHub 8.4](https://github.com/SanjinDedic/FuguHub-8.4-Authenticated-RCE-CVE-2024-27697).
These reports concern the original FuguHub product, not the Mako Server-based
CMS in this repository.

The published demonstrations create or use an administrator account and then
use administrator-controlled file or page editing to deploy executable LSP.
On a correctly configured installation, this requires administrative access.
An unconfigured installation that exposes first-use administrator creation to
an untrusted network is not protected and must be configured before public
access.

The reports demonstrate the impact of obtaining code-deployment credentials,
but their short descriptions do not explain that trusted administrators were
intentionally allowed to deploy server-side Lua. They should not be interpreted
as unauthenticated code injection into an already configured site. Real Time
Logic has operated its public website on the original FuguHub for more than 15
years without a known compromise, but that operating history does not replace
strong credentials, HTTPS, restricted administrative access, and normal
application-security practices.

## Build Deployments

Create the full package with bundled plugins and the multi-domain loader:

```bat
create-deploy.cmd
```

```sh
sh ./create-deploy.sh
```

Create the standalone CMS without plugins:

```bat
create-core-deploy.cmd
```

```sh
sh ./create-core-deploy.sh
```

Generated archives are written under `deploy/` or `deploy-core/`. Each
`cms.zip` contains a built-in copy of the default theme, so it can start without
an external `themes/` directory. External theme ZIPs remain separate and take
precedence when installed. Copy `mako.conf.example` to the deployment directory
as `mako.conf` and adjust it for the target system.

## Test

Run the complete integration suite:

```powershell
powershell -ExecutionPolicy Bypass -File tests\run.ps1
```

The suite creates isolated runtimes, starts its own Mako processes, and tests
root and named mounts, database creation, LSP, HTMX, SMQ, authentication,
plugins, MCP, themes, ZIP deployments, and multi-domain behavior.

Build the seeded performance fixture with:

```bat
create-stress-deploy.cmd
```

```sh
sh ./create-stress-deploy.sh
```

See [stress/README.md](stress/README.md) for local and remote load-test usage.

## Documentation

- [User Manual](docs/FuguHub-User-Manual.md)
- [Lua API](docs/FuguHub-API.md)
- [Lua FastMCP framework](docs/FastMCP.md)
- [Benefits and performance overview](docs/FuguHub-benefits.md)
- [Maintenance architecture](docs/design/summary.md)

AI agents working in this source repository should start with
[AGENTS.md](AGENTS.md).

## Advanced Development

FuguHub can be used as a traditional CMS for creating pages, blog
posts, navigation menus, and themes without writing application
code. However, it also supports server-side application development
using
[Lua and LSP](https://realtimelogic.com/products/lua-server-pages/) in
database-backed pages or the site assets application, with optional
[HTMX and SMQ integration](https://realtimelogic.com/articles/LSP-htmx-A-Powerful-Duo-for-Embedded-Web-Apps).

When developing these advanced applications with an AI agent, preferably copy
[the FuguHub application AGENTS template](docs/templates/AGENTS.md) into the
local project directory before starting. It teaches the agent how to connect to
the deployed FuguHub MCP server, load the built-in guidance, choose between
database and asset-based Lua/LSP code, and test changes safely through the HTTP
MCP API.

## Repository Layout

```text
cms/          Core FuguHub application
CmsDomains/   Multi-domain loader
plugins/      Optional bundled services
themes/       Theme source packages
docs/         User, API, and maintenance documentation
tests/        Integration harness
stress/       Seeded concurrent-request benchmark
```

Runtime `assets/`, `data/`, and generated deployment directories are
intentionally not versioned.

## License

FuguHub is available under the [MIT License](LICENSE).
