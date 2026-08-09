# FuguHub

FuguHub is a compact content-management and Lua web-application platform for
Mako Server. It combines database-backed pages and posts with LSP, HTMX, SMQ,
SQLite, themes, optional plugins, and a Streamable HTTP MCP interface for AI
agents.

## Highlights

- Clean page and blog URLs with HTML or server-side LSP content.
- External directory or ZIP themes with immediate activation.
- Optional HTMX navigation and SMQ real-time events, messaging, and RPC.
- AI administration through a documented, authenticated MCP API.
- Optional Identity and Access, File Services, and Large File Mailer plugins.
- Standalone and shared-identity multi-domain deployment.
- Self-contained ZIP deployment for Mako Server.

## Quick Start

FuguHub requires Mako Server with BAS 5840 or newer.

Install Mako Server and make sure `mako` is on `PATH`, then run from the
repository root:

```bat
mako -l::cms
```

Open `http://localhost/admin/`. FuguHub creates `data/cms.sqlite.db` and its
initial schema automatically.

For a public first startup, create the administrator and optionally enable MCP
from the command line:

```bat
mako -l::cms -credentials admin:choose-a-strong-password -token choose-a-long-random-token
```

Command-line secrets may appear in shell history and process listings. Use
these options only for the first startup and restrict access to the host.

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
- [Benefits and performance overview](docs/FuguHub-benefits.md)
- [Maintenance architecture](docs/design/summary.md)

AI agents working in this source repository should start with
[AGENTS.md](AGENTS.md). Agents connected to a deployed FuguHub instance should
read the embedded guides through its HTTP MCP API.

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
