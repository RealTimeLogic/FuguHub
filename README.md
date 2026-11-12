# FuguHub

![FuguHub Logo](https://fuguhub.com/images/FuguHub.png "FuguHub Logo")

FuguHub is a content management system (CMS) for websites, customer portals,
and live dashboards you host yourself. Manage pages, blog posts, and themes in
your browser, add server-side Lua functionality, and connect an AI agent to
help build and maintain your site.

Start with the ready-to-run **Mako Server Developer Edition**, or deploy FuguHub
as a ZIP application on your own Mako Server. SQLite storage and an included
default theme keep initial setup small. The same application can serve a
public website, an internal portal, or a connected device's browser interface.

## Why FuguHub?

- **Keep your site under your control.** Run it on your own computer, server,
  or embedded Linux device. The default theme and browser libraries are served
  locally, with no public content delivery network (CDN) required.
- **Deploy fewer moving parts.** Mako runs the web server, Lua application
  logic, SQLite storage, and real-time messaging together. You do not need a
  separate database server for the CMS.
- **Build with AI on the running site.** The authenticated Model Context
  Protocol (MCP) interface lets an agent work with content, themes, and site
  applications using guidance supplied by the deployed CMS.
- **Grow from content into applications.** Use the browser editor for ordinary
  pages and posts, then add forms, portals, or device controls with Lua Server
  Pages (LSP). Application code can use Mako's MQTT, OPC UA, Modbus, and other
  protocol APIs.
- **Keep browser interfaces responsive.** Optional HTMX navigation updates
  parts of a page, while Simple Message Queue (SMQ) delivers live events,
  telemetry, and commands through a persistent connection.
- **Add services as you need them.** The full package includes Identity and
  Access, File Services, and Large File Mailer. It also supports multiple sites
  with shared identity and separate content databases.
- **Change presentation independently.** Install and activate themes without
  rebuilding the CMS package or restarting Mako.

See the [benefits and performance overview](docs/FuguHub-benefits.md) for
application examples, runtime design, and recorded benchmark results.

## Get Started

### Try FuguHub locally

The [Mako Server Developer Edition](https://makoserver.net/documentation/developer-package/)
includes FuguHub and the accompanying development tools. On Windows, install
it from the [Microsoft Store](https://apps.microsoft.com/detail/9nqr6ksk077k).
For the latest version or **other platforms**, follow the Developer Edition installation instructions.

Start Mako and open `http://localhost/admin/` to create your administrator and
begin building the site. The Developer Edition listens on the local computer
by default. Before enabling remote access, follow its
[credential and network setup instructions](https://makoserver.net/documentation/developer-package/#security).

### Deploy a dedicated site

Use a separate runtime directory for the deployed site. Keep it outside the
repository's generated `deploy/` and `deploy-core/` folders, which the packaging
scripts replace when rebuilding.

1. **Install Mako Server on the target computer.** Choose a package or build
   for your platform from the [Mako download page](https://makoserver.net/download/overview/).
   Use the standard `mako.zip` resource package for this dedicated deployment
   and make the `mako` executable available on your `PATH`. See the manual's
   [runtime requirements](docs/FuguHub-User-Manual.md#getting-started).

2. **Package FuguHub.** Clone or download this repository, then run the full
   package builder from the repository root.

   Windows Command Prompt:

   ```bat
   rem Package the CMS, bundled services, and themes for deployment.
   create-deploy.cmd
   ```

   Linux or macOS, with `zip` and `unzip` installed:

   ```sh
   # Package the CMS, bundled services, and themes for deployment.
   sh ./create-deploy.sh
   ```

   The output includes `deploy/cms.zip`. For a CMS without plugins, see the
   manual's [core package option](docs/FuguHub-User-Manual.md#choose-a-package).

3. **Prepare the runtime directory.** Copy the chosen `cms.zip` there. Copy
   [mako.conf.example](mako.conf.example) into the same directory as `mako.conf`;
   its default configuration loads `cms.zip` as the root application. The ZIP
   includes a default theme. Copy the generated `themes/` directory as well if
   you want the separately packaged themes. Keep the runtime directory writable
   so FuguHub can create its `data/` directory and SQLite database.

4. **Create the administrator on first startup.** From the runtime directory,
   run the following command after replacing both example values with your own
   administrator username and a long, unique password:

   ```text
   mako -credentials siteowner:replace-with-a-long-random-password
   ```

   Open `http://localhost/admin/` on that computer to sign in and create your
   homepage. On later starts, run `mako` without the credential option.
   Command-line secrets can appear in shell history and process listings;
   use them only during initial setup on a controlled host. See
   [administrator initialization](docs/FuguHub-User-Manual.md#bootstrap-from-the-command-line)
   for alternatives and optional MCP setup.

5. **Configure HTTPS and automatic startup.** Before enabling public access,
   follow the manual's [HTTPS and service setup](docs/FuguHub-User-Manual.md#https-and-automatic-startup).
   It links to the Mako instructions for your operating system and explains
   how to keep the service using this site's files and database.

CMS administration and MCP access can deploy executable application code.
Give these credentials only to trusted people and agents, and restrict access
to the administration endpoints. See the manual's
[security guidance](docs/FuguHub-User-Manual.md#secure-administration-first).

For existing sites, follow the
[database migration procedure](docs/FuguHub-User-Manual.md#move-an-existing-database-to-another-computer)
when changing computers. For shared-identity hosting, use the
[multiple-domain deployment guide](docs/FuguHub-User-Manual.md#advanced-multiple-domains).

## Build Your Site with AI

Connect an MCP-capable AI client using the
[MCP setup instructions](docs/FuguHub-User-Manual.md#mcp-setup), which also cover
the built-in guides and local project template. Start by asking the agent to
draft a page and show you its preview. Review its work before publishing,
activating a theme, or installing executable application code.

For an introduction to the application model, read
[how FuguHub combines LSP, HTMX, and real-time messaging](https://realtimelogic.com/articles/LSP-htmx-A-Powerful-Duo-for-Embedded-Web-Apps#FuguHub).

## Documentation

- [User Manual](docs/FuguHub-User-Manual.md): installation, content editing,
  themes, plugins, and multiple domains.
- [Lua API](docs/FuguHub-API.md): application services, data, events, and site
  assets.
- [Benefits and performance](docs/FuguHub-benefits.md): application examples,
  runtime design, and recorded benchmark results.
- [Security model and original FuguHub reports](docs/FuguHub-User-Manual.md#security-model-and-original-fuguhub):
  trusted administration and context for the earlier product.

## Develop FuguHub

To work on the CMS engine, install Mako Server and run from the repository root:

```bat
rem Load the unpacked CMS so you can work on its source.
mako -l::cms
```

Keep this development instance local until its administrator is configured.
AI agents maintaining the engine should start with [AGENTS.md](AGENTS.md).
See the [maintenance architecture](docs/design/summary.md) and
[Lua FastMCP framework](docs/FastMCP.md) for implementation details.

Run the integration suite from the repository root:

```powershell
# Test CMS behavior in isolated runtimes with separate databases.
powershell -ExecutionPolicy Bypass -File tests\run.ps1
```

The suite covers content, authentication, themes, plugins, MCP, packaged
deployments, and multiple domains. See [stress/README.md](stress/README.md)
for performance testing.

## License

FuguHub is available under the [MIT License](LICENSE).
