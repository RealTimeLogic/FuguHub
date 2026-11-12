# FuguHub User Manual

Use this manual to install FuguHub, publish content, connect an AI agent, and
manage the services your site needs. FuguHub is a content management system
(CMS) that runs on Mako Server. You can use it for ordinary websites or add Lua
application logic for portals, dashboards, and device interfaces.

For a product overview and a short deployment walkthrough, start with the
[README](../README.md). For application programming, see the
[Lua API](FuguHub-API.md).

| What you want to do | Start here |
| --- | --- |
| Try FuguHub or deploy a dedicated site | [Getting Started](#getting-started) |
| Publish a page, change navigation, or select a theme | [CMS Administration](#cms-administration) |
| Connect an AI agent | [MCP Setup](#mcp-setup) |
| Manage users, share files, or send email | [Plugins](#plugins) |
| Move an existing site to another computer | [Database migration](#move-an-existing-database-to-another-computer) |
| Host several sites with shared user accounts | [Multiple Domains](#advanced-multiple-domains) |
| Understand administrator permissions and earlier FuguHub reports | [Security Model](#security-model-and-original-fuguhub) |

## Getting Started

Install [Mako Server](https://makoserver.net/download/overview/) for your target
computer. FuguHub requires a Mako build with Barracuda App Server (BAS) library
version 6017 or newer. An unsupported build reports a version error at startup.

### Choose a Package

**To try FuguHub locally**, use the
[Mako Server Developer Edition](https://makoserver.net/documentation/developer-package/),
which already includes FuguHub. On Windows, it is available from the
[Microsoft Store](https://apps.microsoft.com/detail/9nqr6ksk077k). Follow the
Developer Edition's [first-start and security instructions](https://makoserver.net/documentation/developer-package/#security).
You can then continue with [CMS Administration](#cms-administration) below.

**For a dedicated site**, use Mako's standard `mako.zip` resource package and
choose one of these FuguHub packages:

| Package | Use it when | Generated files |
| --- | --- | --- |
| Full | You want the CMS with Identity and Access, File Services, Large File Mailer, or multiple domains. | `deploy/cms.zip`, `deploy/CmsDomains.zip`, and `deploy/themes/` |
| Core | You want a standalone CMS without the optional plugins. | `deploy-core/cms.zip` and `deploy-core/themes/` |

To create the full package, clone or download this repository and run the
builder from the repository root.

Windows Command Prompt:

```bat
rem Package the CMS, bundled services, and themes.
create-deploy.cmd
```

Linux or macOS, with `zip` and `unzip` installed:

```sh
# Package the CMS, bundled services, and themes.
sh ./create-deploy.sh
```

For the core package, use `create-core-deploy.cmd` or
`sh ./create-core-deploy.sh` instead. Each builder replaces its output folder,
so keep your live site in a separate runtime directory.

Both versions of `cms.zip` include a default theme. The full version also
contains the three plugins. You can install external themes independently of
the CMS package. Only multiple-domain deployments need `CmsDomains.zip`.

### Runtime Directory

The **runtime directory** is the folder containing your site's configuration,
application packages, and writable data. A standalone site uses this layout:

```text
runtime/
  cms.zip                 packaged FuguHub application
  mako.conf               Mako configuration for this site
  themes/                 optional external themes
    default.zip
  assets/                 optional site files and Lua application code
  assets.zip              optional packaged alternative to assets/
  data/                   database and runtime data, created automatically
```

Copy the chosen `cms.zip` into this directory. Copy
[mako.conf.example](../mako.conf.example) here as `mako.conf`; its default
configuration loads a standalone site. Copy the generated `themes/` directory
as well if you want those themes available for selection.

Run Mako from the runtime directory and allow it to write there. Mako's
executable must be on your `PATH` or called by its full path, with its
`mako.zip` resource file installed as described in the Mako instructions.
Keep mutable data outside `cms.zip` and `assets.zip`.

### Start FuguHub

The Mako startup commands below work in Windows Command Prompt, PowerShell,
or a Linux/macOS shell when `mako` is on your `PATH`.

For a packaged site, `mako.conf` contains:

```lua
-- Serve the packaged CMS at the site's root URL.
apps = {
   { name = "", path = "cms.zip" }
}
```

The empty `name` makes the public site available at `/` and administration at
`/admin/`. For a new site, create the administrator with the
[first-start command below](#bootstrap-from-the-command-line). Once that
account exists, start Mako from the runtime directory with:

```text
mako
```

If the configuration file has another name or location, use `mako -c` followed
by its path. For a quick packaged run without an `apps` entry in `mako.conf`,
use `mako -l::cms.zip`. For engine development from an unpacked checkout, see
[Develop FuguHub](../README.md#develop-fuguhub).

The first startup creates `data/cms.sqlite.db`, its tables, default settings,
a primary menu, and an editable 404 page. You do not need to supply a database
for a new site. An empty site may show its 404 page until you
[publish a homepage](#create-your-first-page).

Open these addresses on the server computer:

- `http://localhost/` for the public site;
- `http://localhost/admin/` for administration;
- `http://localhost/admin/help/` for help inside the application.

For a remote server, use its configured hostname and HTTPS address. If FuguHub
runs below a base path such as `/mybase/`, include that path before these URLs.

### Bootstrap From The Command Line

Here, **bootstrap** means creating the first administrator on a new site. This
lets you protect administration before allowing access from another computer.
Replace the example username and password with your own values, then run from
the runtime directory where `mako.conf` loads FuguHub:

```text
mako -credentials siteowner:replace-with-a-long-random-password
```

Choose a unique username and a long, unique password. Everything before the
first colon is the username; everything after it is the password. The new user
receives the `authenticated` and `cms-admin` roles.

To enable AI access through the Model Context Protocol (MCP) at the same time,
also supply a long, random token. Replace every example value before running:

```text
mako -credentials siteowner:replace-with-a-long-random-password -token replace-with-a-long-random-token
```

You can instead enable MCP later through the admin interface; see
[MCP Setup](#mcp-setup).

These options apply only when the identity database has no users. They do not
change existing passwords or replace an existing MCP token after the first
user is created. Remove the options from later startup commands. Command-line
secrets can appear in shell history and process listings, so use this procedure
only during initial setup on a controlled host.

With `CmsDomains`, the control domain starts first and creates the shared
administrator. Only its CMS database receives the supplied MCP token. Configure
MCP separately for any other domain that needs AI access.

### Secure Administration First

If you created the administrator from the command line, sign in with that
account. For browser-based setup, keep a new site restricted to the local
computer or a trusted network until the account is created. A new database
initially permits administrator creation without a login.

- In the full package, open **Users & Access** and choose **Create First CMS
  Administrator**.
- In the core package, open **Users**, enter a username and password, and
  choose **Save User**.

After the first enabled `cms-admin` user exists, `/admin/` requires a login.
FuguHub protects the final enabled administrator from deletion, disabling, or
removal of its administrator role. Returning to first-use setup requires the
explicit authentication reset described under [Standalone Admin Users](#standalone-admin-users).

CMS administration and MCP access can deploy executable Lua code. Give those
credentials only to trusted people and agents. Use HTTPS for remote access and
restrict access to administration where your deployment permits it.

### HTTPS and Automatic Startup

Configure the site's hostname and HTTPS using the
[Mako configuration manual](https://realtimelogic.com/ba/doc/en/Mako.html#cfgfile).
After testing the site interactively, follow the
[Windows service](https://makoserver.net/articles/Installing-the-Mako-Server-as-a-Windows-Service)
or [Linux service](https://makoserver.net/articles/Installing-Mako-Server-as-a-Service-on-Linux)
instructions for automatic startup.

Point the service at the same runtime directory and `mako.conf` used during
setup. Its account needs access to the site files and permission to write the
database. On Windows, set `homeio` as explained in the service instructions;
the service does not inherit your terminal's working directory. Verify that
the service opens the existing site and accepts your administrator login.

## CMS Administration

Sign in at `/admin/` to manage your site. Start with **Content** to publish a
page, **Menus** to add navigation, and **Themes** to choose its appearance.
The sections below follow those everyday tasks.

### Dashboard

The Dashboard shows counts for pages, posts, LSP content, redirects, and menu
items, plus the active theme. Use **View Site** to open the public site.

### Content

Open **Content** to view all content or filter it to Pages or Posts. Use **New
Content** to create an entry, or **Edit** to change an existing one. A **Page**
has its own address, such as `/about/`. A **Post** belongs to the blog and uses
the configured Blog Base URL.

#### Create Your First Page

1. Open **Content > New Content** and leave Type set to **Page**.
2. Enter a title. Use `/` for the homepage or a path such as `/about/` for
   another page.
3. Leave Render Mode set to **HTML** and enter the body as HTML, for example
   `<p>Welcome to our site.</p>`.
4. Keep Status set to **Draft**, choose **Save**, then use **Preview** to check
   the result.
5. When ready, change Status to **Published** and choose **Save** again. Open
   the public path to check it. Add a [menu item](#menus) if visitors should
   find it through the site's navigation.

Use **LSP** (Lua Server Pages) only when the body needs trusted server-side
application code. Ordinary content can stay in HTML mode.

#### Content Fields

| Field | Purpose |
| --- | --- |
| Type | A Page has its own public path. A Post is published below the configured Blog Base URL. |
| Status | Published content is public. Draft content is available only through its admin Preview link. |
| Title | Public title supplied to the active theme. |
| Path | For a page, use a site path such as `/about/`. For a post, use only its article path, such as `/release-notes/`; do not include `/blog/` or another configured blog base. |
| Render Mode | HTML sends the body as content. LSP executes trusted server-side LSP tags in the body. |
| Browser Cache | Controls browser revalidation and storage for this entry. |
| Meta Description | Supplies the page description to the theme. |
| Extra Head HTML | Adds trusted page-specific markup to the document head. |
| Categories | Assigns one or more blog categories to a post. |
| Body | The page or post HTML, optionally containing LSP when Render Mode is LSP. |

Browser Cache choices control how a browser reuses the response:

- **Default:** uses revalidation for HTML and no-cache behavior for LSP.
- **Revalidate:** lets the browser check whether its saved copy is still
  current. An unchanged response can return `304 Not Modified` without sending
  the body again.
- **No cache:** requests a fresh response each time.
- **No store:** tells the browser not to retain the response.

Keep **Default** unless the page needs a different policy.

LSP content is executable server code. Only trusted administrators should add
or edit it. A draft shows **Preview**; published entries use their normal public
URL. Deleting content first shows affected menu items, redirects, categories,
and child content so dependencies can be handled deliberately.

### Categories

Categories organize Posts. Open **Categories**, enter a Name, optional Slug,
and Description, then add the category. A slug is the short, URL-friendly name
used in web addresses; for example, the category **Product News** can use
`product-news`. If Slug is blank, FuguHub derives it from the name. Assign
categories from the content editor.

Deleting a category removes the category assignment, not the posts. Themes may
provide category archive pages, and LSP pages can query posts by category using
the public CMS Lua API.

### Menus

The **Menus** page manages the primary navigation tree.

- **Label** is the text displayed by the theme.
- **URL** is the destination. A menu link to a post must include the current
  Blog Base URL, for example `/articles/release-notes/`.
- **Parent ID** nests an item below another menu item. Leave it blank to infer a
  parent from the URL, or enter `0` for a top-level item.
- **Position** controls ordering among siblings; `0` is valid.

Child items are displayed below their parents in the admin tree. **Hide** keeps
the item in the admin page but removes it from public menus. A hidden item is
marked **hidden**, and its action changes to **Show**. Hiding a menu item does
not unpublish or delete its destination. Deleting a parent promotes its children
to the top level and does not delete content.

### Redirects

Use **Redirects** to map an old path to a new internal or external URL. Enter
the From path, To URL, and status code. Use `301` for a permanent move and `302`
for a temporary redirect. Redirect sources must be unique.

### Themes

To change your site's appearance, open **Themes**, select an available theme,
and choose **Save**. The selection is saved and takes effect immediately,
without restarting Mako.

Install external themes in the runtime directory's `themes/` folder, either as
directories or ZIP files. Theme creation, validation, replacement, and export
are also available through [MCP](#mcp-setup).

Both `cms.zip` variants contain a read-only built-in copy of the default theme.
It is listed as **default (built-in fallback)** only when the external theme
store is empty. Any external theme takes precedence; an external `default`
directory or ZIP replaces the fallback. If an active external theme is
unavailable during startup, FuguHub tries the external default and
then other installed themes. An invalid external theme is reported instead of
being hidden by the built-in fallback.

### Public Site Settings

Open **Settings** to configure site-wide behavior:

| Setting | Effect |
| --- | --- |
| Blog Base URL | Prefix added to every stored Post path. Changing it moves all post URLs without rewriting each post row. Update menu links that point to posts. |
| Enable HTMX navigation | Updates the page content while keeping the surrounding layout loaded. The theme must support HTMX navigation. |
| Enable SMQ real-time messaging | Adds live events and browser-to-server calls through Simple Message Queue (SMQ). Requires HTMX navigation to be enabled. |
| 404 Page URL | Selects the editable CMS page used for unmatched public URLs. |
| Enable editable 404 page | Installs the low-priority CMS fallback and returns the selected page with HTTP status 404. |

HTMX and SMQ are disabled by default. For the application pattern, see
[LSP and HTMX](https://realtimelogic.com/articles/LSP-htmx-A-Powerful-Duo-for-Embedded-Web-Apps).
For implementation, use the [HTMX examples](FuguHub-API.md#cms-lsp-and-htmx)
and [SMQ API](FuguHub-API.md#smq-real-time-api).

### Site Assets and LSP Applications

Use the optional `assets/` directory for site-owned images, stylesheets,
JavaScript, downloads, and LSP application files. For example,
`assets/reports/status.lsp` is served at `/reports/status.lsp`, not below an
`/assets/` URL prefix. Site assets take precedence over CMS content at the same
URL, so choose their paths accordingly.

Application developers can also add private Lua modules under `assets/.lua/`
and initialize services in `assets/.preload`. See the [Assets Application API](FuguHub-API.md#assets-application)
for those programming details.

When `assets.zip` exists, it replaces the `assets/` directory. Use the ZIP form
for immutable deployed assets. An assets application can be restarted through
MCP after changing `.preload` or its Lua modules; the CMS itself does not need
to be restarted.

### Standalone Admin Users

The core package uses **Users** to manage CMS administrator access. Enter a
username and password, then choose **Save User** to create an administrator or
update that user's password. Every user saved through this page receives the
`cms-admin` role.

**Remove Admin Access** removes that role from the selected account; it does
not delete the account. The final enabled administrator is protected from this
action. **Reset All Users** is a separate, confirmed action that clears every
user and returns administration to unprotected first-use setup. Restrict the
server's network access before using it and create a new administrator before
allowing remote access again.

The Identity and Access plugin provides the fuller **Users & Access** interface
for these same accounts, including profiles, roles, and session settings.
When it is installed, `/admin/users/` redirects to that interface.

### Help

Open **Help** for a compact description of the admin pages, content rendering,
menus, themes, caching, HTMX, SMQ, assets, and authentication. Use this manual
for installation, configuration, and complete plugin workflows.

## MCP Setup

Connect an AI client to FuguHub using the Model Context Protocol (MCP). The
client uses the site's authenticated endpoint to manage content, themes, and
applications.

MCP is enabled by saving a bearer token during
[command-line initialization](#bootstrap-from-the-command-line) or through the
admin page below. Treat this token as a password for the site's MCP interface.
Review the agent's work before publishing content, activating a theme, or
installing executable code.

### Enable MCP

If you already supplied a token at first startup, open **MCP** to find the
endpoint and continue with the client settings below. Otherwise:

1. Open **MCP** in the admin menu.
2. Generate a long, random token with at least 16 ASCII characters and store
   it securely. Use a different token for each site.
3. Enter it and choose **Save Token**. FuguHub will not display it again.
4. Configure the AI client's MCP connection with the endpoint shown on the
   page and that token, using the settings below.

The page displays the exact endpoint. At the root it is:

```text
http://localhost/mcp/
```

For a CMS mounted at `/mybase/`, it is:

```text
http://localhost/mybase/mcp/
```

Configure the client with:

| Client setting | Value |
| --- | --- |
| Transport | Streamable HTTP |
| URL | The exact `/mcp/` URL shown in the admin page, including its trailing slash |
| Authentication | `Authorization: Bearer <your-token>` |

The `localhost` addresses above are for a client on the same computer as
FuguHub. For remote access, use the site's HTTPS address.

For a connection check with MCP Inspector, select Streamable HTTP, enter the
endpoint, and add the bearer token in the Authorization header. Local Inspector
origins are accepted for testing.

After connecting, ask the agent to check `getCapabilities` and read the
applicable guides through `listGuides` and `getGuide`. This gives it the API and
workflows supported by this deployment.

A useful first task is to draft a page and show you its preview. New content
defaults to Draft; you decide when it is ready to publish. For a local project
used alongside the deployed site, copy the
[FuguHub application AGENTS template](templates/AGENTS.md) into the project
directory to give the agent the connection and development workflow.

Use **Disable MCP** to stop the endpoint. Saving a replacement token requires
all clients to be updated. Each CMS database has its own MCP token, including
each site in a multi-domain installation.

The token is encrypted in SQLite using a key derived from the Mako TPM API.
Never put it in page content, prompts, logs, source control, or URLs.

## Plugins

The full package includes three services in addition to the CMS:

| Service | Admin menu | What it adds |
| --- | --- | --- |
| Identity and Access | **Users & Access** | User profiles, roles, passwords, and session controls. |
| File Services | **Files** | Browser file management and WebDAV access to selected storage. |
| Large File Mailer | **Mailer** | Outgoing email, file attachments, and expiring download links. |

The core package contains none of these plugins. Its **Users** page manages
CMS administrators. In the full package, File Services uses Identity and
Access, and Large File Mailer uses both. They are already bundled in
`cms.zip`; you do not need to install them separately.

When developing from source, trusted plugin packages can also be loaded from
the repository's top-level `plugins/` directory.

### Identity and Access

Open **Users & Access** to manage the shared user database and roles. When this
plugin is installed, it replaces the standalone **Users** workflow.

For a new database, **Create First CMS Administrator** creates the first user
with `authenticated` and `cms-admin`. Afterward you can add users, edit their
profile and session limits, assign roles, disable accounts, change passwords,
or create application-specific roles.

Built-in roles are:

| Role | Purpose |
| --- | --- |
| `authenticated` | Automatically assigned to every enabled user. |
| `cms-admin` | Full CMS administration. It also satisfies the included plugin administration checks. |
| `identity-admin` | User and role management. |
| `file-admin` | Full read/write File Services access through the default `/*` rule. |
| `mailer-user` | Compose deliveries using files the user may read. |
| `mailer-manager` | Manage mailer settings, contacts, lists, jobs, and history. |

The final enabled CMS administrator is protected from deletion, disabling, or
removal of the `cms-admin` role. **Reset All Users** deliberately clears all
accounts and returns the site to first-use setup; use it only with network
access restricted.

Changing roles does not normally sign the current user out. New authorization
rules apply to subsequent requests. Disabling a user or making a credential or
session-security change may invalidate that user's sessions.

### File Services

File Services lets users manage files in a browser or connect with a WebDAV
client, such as an operating system's network-drive feature. Set the storage
folder and public URL in `mako.conf`, then manage limits and access rules under
**Files**.

By default, the service uses Mako's runtime directory. The equivalent
configuration is:

```lua
wfs = {
   io = "home",       -- Mako's configured runtime directory
   path = "/",
   baseurl = "/fs/",   -- Public file-service URL
   lockdir = ".locks"  -- Writable folder for WebDAV locks
}
```

For a dedicated shared folder on Windows, create `C:\shared` and use:

```lua
wfs = {
   io = "disk",
   path = "/c/shared/", -- Share C:\shared rather than the runtime directory
   baseurl = "/fs/",
   lockdir = ".fuguhub-locks"
}
```

`io` selects a BAS file interface, and `path` selects the folder within it.
Use forward slashes in these paths. `lockdir` is relative to the File Services
root and must be writable. `baseurl` must contain one URL segment, such as
`/fs/`. Restart Mako after changing these `mako.conf` values.

On **Files** you can enable the service and configure maximum uploads, maximum
locks, Session URL lifetime, and path case sensitivity. The browser file manager
is then available at the configured Base URL.

File access is role based. Select a file-specific role, add a path, and choose
**Read only** or **Read & write**. Paths start with `/` and are relative to the
configured File Services root. `/` grants the whole root; `/reports/` grants
that subtree. One role can have several path rules, but only one rule for the
same path. Users see clickable links to the roots their roles allow.

### SMTP and Large File Mailer

Large File Mailer uses an outgoing email server through SMTP (Simple Mail
Transfer Protocol). You can:

- send ordinary email to selected contacts or recipient lists;
- deliver files as attachments or secure download links.

Messages are placed in a queue and sent at the interval you choose. Temporary
delivery failures are retried automatically.

#### Access

The plugin uses Identity and Access roles:

| Role | Access |
| --- | --- |
| `mailer-user` | Compose and queue deliveries. |
| `mailer-manager` | Compose plus Contacts, Lists, Invitations, Templates, and Jobs. |
| `cms-admin` | All mailer functions, including Mailer Settings. |

To send files, the sender must also have permission to read those files in File
Services. Being a CMS administrator does not automatically grant file access.

#### Initial Setup

1. Open **CMS Admin > Mailer**.
2. Enter the SMTP server, port, security mode, credentials, and From address.
3. Set **Test recipient**. It initially follows the From address but can be
   changed independently.
4. For download links, password invitations, or email-preference links, set
   **Public base URL** to the public origin, such as `https://example.com`. Do
   not include `/mailer/` or a CMS base path; the application adds its mounted
   path.
5. Select **Enabled**.
6. Click **Save and Test** and verify that the test message arrives.

Leaving the password field blank keeps the saved SMTP password. Select
**Clear saved password** only when it should be removed.

#### Settings

| Setting | Purpose |
| --- | --- |
| SMTP server and port | Destination SMTP service. |
| Security | Match your email provider: `tls` encrypts from the start, `starttls` upgrades the connection to TLS, and `none` is unencrypted. |
| Username and password | Login required by the SMTP service, if any. |
| From address | Sender used for all jobs. A bare address or `Name <address>` is accepted. |
| Test recipient | Destination used by **Save and Test**. |
| Reply-to | Optional reply address. |
| Public base URL | Public HTTP or HTTPS origin used for download, invitation, and email-preference links. |
| Attachment limit | Maximum combined byte size for an attachment job. Use secure links for larger files. |
| Link lifetime | Number of seconds before invitation and download links expire. The default is `604800` seconds (7 days). |
| Maximum attempts | Maximum SMTP attempts for each recipient. |
| Retry delay | Initial delay in seconds after a temporary failure. Later retries use increasing delays. |
| Send interval | Minimum number of seconds between recipients. This controls mass-mail pacing. |
| Require HTTPS downloads | Rejects non-HTTPS public base URLs and protects download use. |

#### Contacts

Open **Mailer > Contacts** to search, add, edit, or delete contacts. A contact
contains:

- email address;
- first name;
- last name;
- optional external ID;
- membership in zero or more recipient lists.

Search updates while typing and matches email, first name, and last name.
Use the **Show** selector to switch between all contacts, contacts that are not
assigned to any list, and unsubscribed contacts. Deleting a recipient list does
not delete its contacts; those contacts appear under **Unassigned contacts**.
Unsubscribed contacts remain saved for opt-out enforcement and appear under
**Unsubscribed contacts**. Select them there and choose **Restore selected** only
when they have explicitly asked to receive email again. Restoring from Contacts
does not restore previous list memberships; add the contact to the appropriate
lists afterward.

##### Import CSV

Import a comma-separated values (CSV) file into a recipient list:

1. Create or open the destination under **Lists**.
2. Use **Import CSV into _list name_**.
3. Select a CSV file and click **Preview**.
4. Map the CSV columns. An email column is required; first name, last name, and
   external ID are optional.
5. Confirm the import.

Files may include column headings or begin directly with contact data. Preview
identifies headerless files, gives their columns temporary names, and includes
the first row in the import. Always verify the preview and column mapping.

If an active email address already exists, the existing contact is added to the
selected list instead of creating a duplicate. Existing opt-outs are skipped by
default. To act on renewed consent, select **Restore unsubscribed contacts found
in this CSV** and confirm the warning; those contacts are restored and added to
the destination list.

##### Remove Contacts in Bulk

Open **Mailer > Remove** and paste any text containing email addresses. The
preview extracts addresses and reports which saved contacts match. Review the
result before confirming removal.

#### Recipient Lists

Open **Mailer > Lists** to create and search lists. Selecting a list opens its
detail view, where you can:

- search that list's contacts;
- remove selected contacts from the list;
- move selected contacts to another list;
- move all contacts to another list;
- merge the complete list into another list and delete the source;
- import a CSV directly into the list;
- edit or delete the list.

Deleting a list removes the membership relationships, not the contacts.

#### Compose

To send a message:

1. Open **Mailer > Compose**.
2. Select contacts, recipient lists, or both. A contact selected directly and
   through a list receives only one message.
3. Enter the subject and message, or select a saved [EML template](#eml-templates).
4. Choose a delivery mode from the table below. For file delivery, select
   files through File Services or enter their paths as described below.
5. Choose **Queue Delivery**, then open **Jobs** to follow progress.

Review the recipient selection and message before queuing the delivery.

The delivery modes are:

| Mode | Files | Result |
| --- | --- | --- |
| Email only | Not used | Sends the message without files. |
| File attachments | Required | Attaches the selected files, subject to the configured combined size limit. |
| Secure download links | Required | Creates an expiring URL for each file and includes the URLs in the message. |

Use **Jobs** to inspect delivery errors or cancel a queued job.

##### File Services Paths

The file field is shown only for attachment and secure-link modes. Enter one
File Services path per line. Each path:

- starts with `/`;
- is relative to the File Services root;
- identifies a file, not a directory;
- must be readable by the sending user.

For example, if File Services is configured to use `C:\shared`, the mailer
path `/reports/status.pdf` identifies `C:\shared\reports\status.pdf`. Do not
enter a Windows path such as `C:\shared\reports\status.pdf` in Compose.

The easiest workflow is to open File Services, select files, and choose
**Email selected files**. This opens Compose with the correct paths already
filled in. Do not change or replace a selected file while its delivery is in
progress.

#### Secure Download Links

Secure-link delivery requires **Public base URL**. Each recipient receives
separate links that expire after the configured link lifetime.

Download links are appended to the plain-text and HTML bodies automatically.
Use `{{DOWNLOAD_LINKS}}` only when the links should appear at a particular
position in the message.

Selecting **Require each recipient's confirmed password** adds a second check.
Every selected contact must first accept a password invitation. The password is
personal to that contact and is not an Identity and Access or CMS login password.

#### Password Invitations

Open **Mailer > Invitations** to invite contacts to create personal download
passwords. Select individual contacts, recipient lists, or both and queue the
job. The mailer includes only unconfirmed contacts from that explicit
selection. There is no database-wide invitation action.

The setup link is appended automatically. Use `{{INVITATION_LINK}}` only to
control its location in the invitation body. A link is single-use and expires
after the configured link lifetime.

After accepting an invitation, the contact can open deliveries that require a
confirmed password. Resetting the contact's password requires that contact to
accept a new invitation.

#### Message Macros

A macro is a placeholder that the mailer replaces with a value for each
recipient. Write its name in uppercase between double braces, for example:

```text
Hello {{FIRST_NAME}},
```

Use macros in the Compose subject, plain-text body, HTML body, or a saved EML
template. Put link macros in the body so the recipient can use them. Values are
filled in when the message is sent.

| Macro | Value |
| --- | --- |
| `{{FIRST_NAME}}` | Contact's first name. |
| `{{LAST_NAME}}` | Contact's last name. |
| `{{NAME}}` | Alias for the first name. It is not the full name. |
| `{{CONTACT_ID}}` | Contact's saved ID number. |
| `{{EXPIRY}}` | Link expiry in UTC, calculated at send time from **Link lifetime** in Mailer Settings. The default lifetime is `604800` seconds (7 days); the rendered value is formatted like `2026-08-13 10:30 UTC`. |
| `{{DOWNLOAD_LINKS}}` | Secure-download links. Plain text uses one `filename: URL` per line; HTML uses clickable file-name links. |
| `{{INVITATION_LINK}}` | Password invitation URL. HTML uses a clickable **Set your password** link. |
| `{{UNSUBSCRIBE_LINK}}` | A personal link that lets the recipient update their name or email address, or stop future mail. HTML uses a clickable **Manage email preferences** link. |

There is currently no `{{EMAIL}}` macro. An unknown or misspelled macro is left
visible in the delivered message, so check macro spelling before sending.

##### Secure-Link Example

```text
Hello {{FIRST_NAME}},

Your files are available until {{EXPIRY}}:

{{DOWNLOAD_LINKS}}

Regards,
Support
```

Omitting `{{DOWNLOAD_LINKS}}` is valid; the mailer adds a **Download files**
section after this text.

##### Invitation Example

```text
Hello {{FIRST_NAME}},

Create your personal download password here:
{{INVITATION_LINK}}
```

Omitting `{{INVITATION_LINK}}` is also valid; the mailer appends a **Set your
password** section.

##### Bulk Email Example

```text
Hello {{FIRST_NAME}},

Here is this month's news.

To stop receiving these messages, use this link:
{{UNSUBSCRIBE_LINK}}
```

`{{UNSUBSCRIBE_LINK}}` requires the **Public base URL** in Mailer Settings. On
the personal preferences page, the recipient can update their first name, last
name, or email address without changing list membership. They can instead
choose **Unsubscribe from emails**. Unsubscribing marks the contact
**Unsubscribed**, removes it from recipient lists, and excludes it from future
deliveries. Importing the same address again does not subscribe it unless the
operator uses the explicit restore option during CSV import.

For restoring a subscription, see [Contacts](#contacts) or the explicit restore
option under [Import CSV](#import-csv).

#### EML Templates

An EML file stores an email message, including its headers and body. Open
**Mailer > Templates** to save one as a reusable starting point. This minimal
plain-text example uses placeholder addresses; the mailer supplies the actual
sender and recipients when sending:

```eml
From: placeholder@example.com
To: placeholder@example.com
Subject: Placeholder
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: 7bit

Hello {{FIRST_NAME}},

Your files:
{{DOWNLOAD_LINKS}}
```

When a template is selected in Compose, the mailer parses its subject,
plain-text body, and HTML body into the corresponding editable fields. Changes
made there apply only to the new delivery; they do not revise the saved
template. Mailer Settings supply `From` and `Reply-To`, and selected contacts
supply `To`. The queued job keeps a copy of the selected EML so images embedded in the
message remain available. The editable Subject, Plain text, and HTML fields
control the message that is sent.

The HTML field in Compose and Invitations also recognizes a complete EML
message pasted into it. After detecting the EML header block, the mailer uses
the same server-side parser as saved templates and splits the message into the
editable Subject, Plain text, and HTML fields. Pasting an ordinary HTML fragment
continues to behave normally.

#### Jobs and Delivery Results

Open **Mailer > Jobs** to inspect active and completed deliveries. Each
recipient has a status and attempt count. A failure for one recipient does not
stop delivery to the others.

Click **View** on a job to inspect the subject, source text or HTML, template
snapshot, files, and recipient results saved in the database. This is the job's
stored source data, not an exact copy of each personalized email. Generated
download, invitation, and email-preference links are therefore not displayed.
For large deliveries, the page shows the first 100 recipients and the total
recipient count.

Cancelling a job stops messages that have not yet been sent. Queued work
continues after Mako is restarted.

#### Troubleshooting

| Problem | Check |
| --- | --- |
| Save and Test fails | Verify SMTP host, port, security mode, credentials, From address, and server network access. |
| Secure-link job says Public base URL is required | Set the public origin under **CMS Admin > Mailer**. |
| File Services path is invalid | Use a `/`-prefixed path relative to the configured File Services root, or paste an HTTP(S) File Services URL below the configured mount. OS paths and unrelated URLs are rejected. |
| File is forbidden | Give the sender a File Services role with permission to read that path. |
| Recipient must accept an invitation | Send a password invitation or clear **Require each recipient's confirmed password**. |
| Download link is absent from custom text | Create a new delivery. Jobs already in the queue keep the message with which they were created. |
| Delivery remains in retry | Open **Jobs** and inspect the recipient error; verify SMTP availability and the configured retry delay. |
| Link opens but download is rejected | Check expiry, HTTPS settings, the contact's password status, file permissions, and whether the source file changed. |

## Move an Existing Database to Another Computer

FuguHub stores content, settings, user identities, and encrypted credentials
in SQLite. The user credential database, MCP token, and saved SMTP password
use keys unique to the computer. Copying the database alone does not make
these credentials usable on another computer.

Use `tools/reset-db-secrets.lua` from this repository to prepare a copy for the
destination. It preserves content and non-secret settings, but removes user
credentials, identity profiles and role assignments, the MCP token, and the
saved SMTP password. The mailer is disabled when its password is removed.
Plan to recreate user accounts and their access permissions on the destination.

1. Stop Mako before copying the source database so the copy is consistent.
   Work on the copy you intend to move, keeping the original for recovery.
2. From the repository root, run the reset utility against that copy. Set
   `FUGUHUB_DB` to its full path using one of the commands below.
3. Copy the prepared database into the destination's `data/` directory. Copy
   the site's assets, external themes, and configuration separately, adjusting
   hostnames and filesystem paths for the new computer.
4. From the destination runtime directory, create a new administrator using
   the [first-start command](#bootstrap-from-the-command-line). Configure a new
   MCP token if needed, recreate users and permissions, and enter the SMTP
   password before enabling the mailer.
5. Check the public site, administrator login, file permissions, and any MCP
   or mailer connection you use before allowing normal access.

In PowerShell, replace the example path with the database copy:

```powershell
# Prepare the copy for the destination; keep the original database unchanged.
$env:FUGUHUB_DB='C:\migration\cms.sqlite.db'
mako tools/reset-db-secrets.lua
Remove-Item Env:FUGUHUB_DB
```

On Linux:

```sh
# Prepare the copy for the destination; keep the original database unchanged.
FUGUHUB_DB=/path/to/migration/cms.sqlite.db mako tools/reset-db-secrets.lua
```

The utility creates a backup beside the selected database named
`<database-file>.before-secret-reset-<timestamp>.bak` before changing it. That
backup still contains the old encrypted credentials; protect it or remove it
after verifying the migration. Do not run the utility on a database still in
use by Mako.

If an older database is rejected because its user credentials use the former
global key mode, use the same reset utility and create new passwords afterward.

## Advanced: Multiple Domains

FuguHub can serve several host names from one Mako process. Each host receives
its own CMS database, content, settings, theme selection, and assets application.
One host is the **control domain** and owns the shared Users & Access, File
Services, and Large File Mailer applications. The other domains use the control
domain's users and roles but do not start separate copies of those services.

This keeps account management, the file server, and the mailer in one place.
Signing in is still browser-domain specific, so a user may be asked to sign in
again when moving between host names.

### Build the Packages

Use the **full** package builder under [Choose a Package](#choose-a-package).
The core package does not include the multiple-domain loader or shared services.

Copy `deploy/cms.zip` and `deploy/CmsDomains.zip` into your runtime directory.
Copy `deploy/themes/` if you want the external themes available. Keep that
runtime separate from the generated `deploy/` folder so a rebuild does not
replace site data.

### Configure the Domains

In the prepared runtime directory, configure `CmsDomains.zip` as the root
application and define the host names in `mako.conf`:

```lua
-- Load the shared services once, on the control domain.
apps = {
   { name = "", path = "CmsDomains.zip" }
}

cmsdomains = {
   { host = "a.example.com", control = true },
   { host = "b.example.com" }
}
```

Replace the example hostnames with names that resolve to your server. Exactly
one domain must set `control=true`. The other domains link their **Users &
Access** entry to that host. No management URL is required; FuguHub derives it
from the control host.

The loader uses these per-domain names:

| Resource | Name |
| --- | --- |
| Database | `data/cms-<host>.sqlite.db` |
| Development assets | `assets-<host>/` |
| Packaged assets | `assets-<host>.zip` |

Configure `wfs` in the same `mako.conf` when the control domain uses File
Services. That configuration is process-wide and belongs to the single control
instance.

### Start the Packaged System

For the first startup, use [command-line initialization](#bootstrap-from-the-command-line)
to create the shared administrator. Later starts read the `apps` entry from
`mako.conf`:

```text
mako
```

The equivalent command-line shortcut, useful for testing without the `apps`
entry, is:

```text
mako -l::CmsDomains.zip
```

The loader opens the sibling `cms.zip`, starts the control domain first, then
starts the other domains. On shutdown it stops the other domains before the
control domain.

Verify that every host resolves to the server and check:

1. Each host serves its own CMS site and `/admin/` dashboard.
2. Only the control domain shows local Users & Access, Files, and Mailer pages.
3. On each other domain, **Users & Access** opens the control domain.
4. Credentials created on the control domain authenticate CMS administration on
   the other domains.
5. Separate `cms-<host>.sqlite.db` files are created under `data/`.

The packaged layouts are covered by the local integration harness. Deployment
to the final target server or hardware should still be verified before release.

## Security Model and Original FuguHub

FuguHub administration and the Model Context Protocol (MCP) interface provide
code-deployment access. Both database-backed pages and the site assets
application can execute trusted Lua Server Pages (LSP). Give administrative
and MCP credentials only to people and agents trusted to deploy application
code. Use HTML render mode for pages that do not need server-side logic.

Applications remain responsible for authenticating users, authorizing each
operation, validating commands, and protecting any connected device network.
For setup, see [Secure Administration First](#secure-administration-first),
[command-line initialization](#bootstrap-from-the-command-line), and
[MCP Setup](#mcp-setup).

### Context for Reports About the Original FuguHub

This Mako Server-based implementation supersedes the
[original FuguHub](https://fuguhub.com/). Existing users may continue running
the original version, while new installations should use this version.

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
