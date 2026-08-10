# FuguHub User Manual

This manual explains how to install, configure, and operate FuguHub and its
included plugins. Developer-facing Lua APIs are documented separately in
[FuguHub-API.md](FuguHub-API.md).

## Getting Started

FuguHub requires Mako Server with BAS 5840 or newer. Startup stops with a
version error before installing the application when the BAS library is older.

### Choose a Package

FuguHub can be run from its source directories or from deployment ZIP files.
The repository provides two deployment builders:

| Builder | Result | Use it when |
| --- | --- | --- |
| `create-deploy.cmd` or `create-deploy.sh` | `deploy/cms.zip`, `CmsDomains.zip`, and themes | You want Identity and Access, File Services, the SMTP/Large File Mailer, or multiple domains. |
| `create-core-deploy.cmd` or `create-core-deploy.sh` | `deploy-core/cms.zip` and themes | You want only the standalone CMS. |

The full `cms.zip` contains the shipped plugins. Both package variants also
contain a built-in default theme used only when no external themes are
installed. The separate theme packages can be changed independently.

### Runtime Directory

A normal standalone runtime looks like this:

```text
runtime/
  cms.zip                 or cms/ during development
  themes/                  optional external themes
    default.zip
  assets/                 optional site files and LSP application
  assets.zip              optional packaged replacement for assets/
  data/                   created automatically
  mako.conf               recommended deployment configuration
```

Run Mako from this directory. FuguHub uses it as the home IO for themes,
assets, and mutable data. Do not place the SQLite database inside `cms.zip`.

### Start FuguHub

For deployment, add the application to `mako.conf`:

```lua
apps = {
   { name = "", path = "cms.zip" }
}
```

The empty `name` installs FuguHub as the root application. Start Mako from the
runtime directory and it automatically loads `mako.conf`:

```bat
mako
```

If the configuration file has another name or location, use `mako -c` followed
by its path.

For development from the source tree, change the configured path to `cms`, or
load it directly from the command line:

```bat
mako -l::cms
```

The equivalent command-line shortcut for a packaged runtime is:

```bat
mako -l::cms.zip
```

The first startup creates `data/cms.sqlite.db` when it is missing. It also
creates the required schema, default settings, a primary menu, and an editable
404 page. The database can therefore be omitted from a new deployment.

### Bootstrap From The Command Line

For a public VPS, create the first administrator while starting Mako instead
of briefly exposing an unprotected administration page:

```bat
mako -l::cms -credentials admin:choose-a-strong-password
```

When `mako.conf` already loads FuguHub, omit the load option:

```bat
mako -credentials admin:choose-a-strong-password
```

The value before the first colon is the username. Everything after it is the
password, so the password may contain additional colons. The new user receives
the `authenticated` and `cms-admin` roles.

An MCP bearer token can be installed and MCP enabled during the same first
startup:

```bat
mako -l::cms -credentials admin:choose-a-strong-password -token replace-with-a-long-random-token
```

These options are honored only when the identity database contains no users.
After the first user is created, later command-line bootstrap values are
ignored and cannot replace the administrator or MCP token.

Command-line secrets can appear in shell history and operating-system process
listings. Use these options only for the first startup, restrict access to the
host, and remove them from the startup command afterward.

With `CmsDomains`, the control domain starts first and consumes the bootstrap
credentials. Its CMS database also receives the MCP token. Consumer domains
share the resulting identity and ignore the bootstrap options because the
identity already has a user.

Open these pages after startup:

- `/` for the public site;
- `/admin/` for CMS administration;
- `/admin/help/` for concise help inside the application.

If FuguHub is mounted under a base path, include that path before these URLs.

### Secure Administration First

A new database has no administrator, so the admin pages initially remain open
for first-use setup. Create an administrator before exposing the server to an
untrusted network:

- With the full plugin package, open **Users & Access** and create the first CMS
  administrator.
- With the core package, open **Users** and create an admin user.

After the first enabled `cms-admin` user exists, `/admin/` requires login. The
CMS prevents removal or demotion of the final enabled administrator.

### Move an Existing Database to Another Computer

FuguHub stores content, configuration, user identities, and encrypted secrets
in the CMS SQLite database. The FuguHub user database, MCP bearer token, and
Large File Mailer SMTP password are all protected with keys unique to the
computer. Copying the SQLite file does not make these credentials usable on
another computer.

The repository provides `tools/reset-db-secrets.lua` for this migration. Stop
every Mako process using the database before running it. Mako standalone script
mode accepts only the script filename on its command line, so provide the
database filename with the `FUGUHUB_DB` environment variable.

In PowerShell, run:

```powershell
$env:FUGUHUB_DB='C:\path\to\data\cms.sqlite.db'
mako tools/reset-db-secrets.lua
Remove-Item Env:FUGUHUB_DB
```

On Linux, run:

```sh
FUGUHUB_DB=/path/to/data/cms.sqlite.db mako tools/reset-db-secrets.lua
```

The script preserves content and non-secret configuration. It removes the user
credential database, identity profiles and role assignments, MCP token, and
SMTP password. It also disables the mailer when its password is removed.

The script creates a backup beside the database named
`<database-file>.before-secret-reset-<timestamp>.bak` before changing anything.
That backup still contains the old encrypted secrets and must be protected or
removed after the migration is verified.

On the destination computer, create a new administrator and MCP token during
the next startup:

```bat
mako -credentials admin:choose-a-strong-password -token replace-with-a-long-random-token
```

Then enter the SMTP password again before enabling the mailer. SQLite databases
created by an older FuguHub version may contain a user database protected by the
former global key mode. The current runtime deliberately rejects that credential
blob; run this reset utility before starting the upgraded or copied database and
create new user passwords afterward.

## CMS Administration

### Dashboard

The Dashboard shows counts for pages, posts, LSP content, redirects, and menu
items, plus the active theme. Use **View Site** to open the public site.

### Content

Open **Content** to view all content or filter it to Pages or Posts. Use **New
Content** to create an entry, or **Edit** to change an existing one.

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

Browser Cache choices are:

- **Default:** HTML uses revalidation; LSP uses no-cache behavior.
- **Revalidate:** uses an ETag so an unchanged request can return `304 Not
  Modified`.
- **No cache:** requests a fresh response each time.
- **No store:** prevents the browser from retaining the response.

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

Themes are normally installed outside the CMS engine under `themes/` as
directories or ZIP files. Open **Themes**, select one of the detected themes,
and choose **Save**. Activation is persistent and takes effect without
restarting Mako.

Both `cms.zip` variants contain a read-only built-in copy of the default theme.
It is listed as **default (built-in fallback)** only when the external theme
store is empty. Any external theme takes precedence; an external `default`
directory or ZIP replaces the fallback. Theme creation, validation,
replacement, and export are also available through MCP. If an active external
theme is unavailable during startup, FuguHub tries the external default and
then other installed themes. An invalid external theme is reported instead of
being hidden by the built-in fallback.

### Public Site Settings

Open **Settings** to configure site-wide behavior:

| Setting | Effect |
| --- | --- |
| Blog Base URL | Prefix added to every stored Post path. Changing it moves all post URLs without rewriting each post row. Update menu links that point to posts. |
| Enable HTMX navigation | Keeps the public theme shell loaded and fetches page fragments while navigating. The theme must implement the HTMX fragment contract. |
| Enable SMQ real-time messaging | Adds one persistent SMQ connection and page-scoped messaging/RPC support. HTMX must be enabled first. |
| 404 Page URL | Selects the editable CMS page used for unmatched public URLs. |
| Enable editable 404 page | Installs the low-priority CMS fallback and returns the selected page with HTTP status 404. |

HTMX is disabled by default. For the application pattern, see
[LSP and HTMX](https://realtimelogic.com/articles/LSP-htmx-A-Powerful-Duo-for-Embedded-Web-Apps).

### Site Assets and LSP Applications

The optional `assets/` directory can contain images, stylesheets, JavaScript,
ordinary files, LSP pages, Lua modules, and an application `.preload`. Assets
take precedence over database-backed CMS pages at the same URL.

When `assets.zip` exists, it replaces the `assets/` directory. Use the ZIP form
for immutable deployed assets. An assets application can be restarted through
MCP after changing `.preload` or its Lua modules; the CMS itself does not need
to be restarted.

### Standalone Admin Users

The plugin-free core package uses **Users** to manage CMS administrators. Add a
username and password to enable admin authentication. Every user created here
is a CMS administrator; the standalone user store does not provide roles or
access to plugin services.

Removing the final standalone user disables admin authentication and returns
the CMS to first-use mode. When Identity and Access is installed, **Users &
Access** replaces this page and `/admin/users/` redirects there.

### Help

Open **Help** for a compact description of the admin pages, content rendering,
menus, themes, caching, HTMX, SMQ, assets, and authentication. Use this manual
for installation, configuration, and complete plugin workflows.

## MCP Setup

FuguHub includes a Streamable HTTP MCP server that lets an AI agent inspect and
manage the site through a bounded API. It is disabled until an administrator
sets a bearer token.

### Enable MCP

1. Open **MCP** in the admin menu.
2. Generate a strong private token of at least 16 characters.
3. Enter it once and choose **Save Token**.
4. Record the token in the MCP client's secure configuration. FuguHub does not
   display it again.

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

In MCP Inspector, select Streamable HTTP, enter that URL, and add the bearer
token in the Authorization header. Loopback Inspector origins are accepted for
local testing.

After connecting, the agent should call `getCapabilities` before assuming a
feature is available. The server supplies its own guides and instructions over
MCP. Depending on reported capabilities, an agent can manage content,
categories, menus, redirects, settings, themes, site assets, runtime trace, and
ZIP-based transfers between FuguHub servers.

Use **Disable MCP** to stop the endpoint. Saving a replacement token requires
all clients to be updated. Each CMS database has its own MCP token, including
each site in a multi-domain installation.

The token is encrypted in SQLite using a key derived from the Mako TPM API.
Never put it in page content, prompts, logs, source control, or URLs.

## Plugins

The full deployment package includes three plugins. The core package includes
none. In source development, trusted plugin packages may also be installed
under the top-level `plugins/` directory.

The included dependency order is:

1. Identity and Access
2. File Services, which requires Identity and Access
3. SMTP and Large File Mailer, which requires both other plugins

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

Changing roles does not normally sign the current user out. New authorization
rules apply to subsequent requests. Disabling a user or making a credential or
session-security change may invalidate that user's sessions.

### File Services

File Services provides the browser file manager and WebDAV-compatible file
access. Its storage root and public mount are configured in `mako.conf`; runtime
limits and access rules are managed from **Files**.

The default configuration uses the Mako home IO:

```lua
wfs = {
   io = "home",
   path = "/",
   baseurl = "/fs/", -- e.g. http://localhost/fs/
   lockdir = ".locks"  -- WebDAV locks
}
```

To expose the disk IO path instead:

```lua
wfs = {
   io = "disk",
   path = "/c/", -- Windows c:\
   baseurl = "/fs/",
   lockdir = ".fuguhub-locks"
}
```

`path` is resolved within the selected BAS IO. `lockdir` is also relative to
that File Services root and must be writable. Use forward slashes. `baseurl`
must contain one URL segment, such as `/fs/`. Restart Mako after changing these
`mako.conf` values.

On **Files** you can enable the service and configure maximum uploads, maximum
locks, Session URL lifetime, and path case sensitivity. The browser file manager
is then available at the configured Base URL.

File access is role based. Select a file-specific role, add a path, and choose
**Read only** or **Read & write**. Paths start with `/` and are relative to the
configured File Services root. `/` grants the whole root; `/reports/` grants
that subtree. One role can have several path rules, but only one rule for the
same path. Users see clickable links to the roots their roles allow.

### SMTP and Large File Mailer

Large File Mailer supports two related jobs:

- send ordinary email to selected contacts or recipient lists;
- deliver files as attachments or secure download links.

Messages are placed in a queue and sent at the interval you choose. Temporary
delivery failures are retried automatically.

#### Access

The plugin uses Identity Access roles:

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
4. For secure links or password invitations, set **Public base URL** to the
   public origin, such as `https://example.com`. Do not include `/mailer/` or a
   CMS base path; the application adds its mounted path.
5. Select **Enabled**.
6. Click **Save and Test** and verify that the test message arrives.

Leaving the password field blank keeps the saved SMTP password. Select
**Clear saved password** only when it should be removed.

#### Settings

| Setting | Purpose |
| --- | --- |
| SMTP server and port | Destination SMTP service. |
| Security | `none`, direct `tls`, or `starttls`. |
| Username and password | Login required by the SMTP service, if any. |
| From address | Sender used for all jobs. A bare address or `Name <address>` is accepted. |
| Test recipient | Destination used by **Save and Test**. |
| Reply-to | Optional reply address. |
| Public base URL | Public HTTP or HTTPS origin used to construct invitation and download URLs. |
| Attachment limit | Maximum combined byte size for an attachment job. Use secure links for larger files. |
| Link lifetime | Number of seconds before invitation and download links expire. The default is `604800` seconds (7 days). |
| Maximum attempts | Maximum SMTP attempts for each recipient. |
| Retry delay | Initial delay for a temporary failure. Later retries use increasing delays. |
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
when they have explicitly asked to receive email again.

##### Import CSV

CSV imports must target a recipient list:

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

Open **Mailer > Compose**, enter a subject and message, and select contacts,
lists, or both. A contact selected both directly and through a list receives
only one message.

The delivery modes are:

| Mode | Files | Result |
| --- | --- | --- |
| Email only | Not used | Sends the message without files. |
| File attachments | Required | Attaches the selected files, subject to the configured combined size limit. |
| Secure download links | Required | Creates an expiring URL for each file and includes the URLs in the message. |

Click **Queue Delivery** to start. Use **Jobs** to follow progress, inspect
delivery errors, or cancel a job.

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
personal to that contact and is not an Identity Access or CMS login password.

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

Macros use uppercase names inside two opening and two closing braces. For
example:

```text
Hello {{FIRST_NAME}},
```

They are expanded separately for every recipient when the message is sent.
They may be used in the Compose subject, plain-text body, HTML body, and the
body of a saved EML template. Link macros belong in a body, not a subject.

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

To allow mail again, open **Mailer > Contacts**, choose **Unsubscribed contacts**,
and restore the address. Restoring from Contacts does not restore previous list
memberships. An explicitly confirmed CSV restoration adds the address to that
CSV import's destination list.

#### EML Templates

Open **Mailer > Templates** to save reusable EML messages. A minimal plain-text
template is:

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
supply `To`. The queued job retains the selected EML snapshot so embedded MIME
images remain available, while the editable Subject, Plain text, and HTML fields
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

Run the full deployment builder from the project root:

```bat
create-deploy.cmd
```

On Linux, run:

```sh
sh ./create-deploy.sh
```

The Linux builder requires the standard `zip` and `unzip` commands. Both
builders produce and validate the same archive layout.

It creates:

```text
deploy/
  cms.zip                 CMS engine, plugins, and built-in fallback theme
  CmsDomains.zip          multi-domain loader
  themes/
    default.zip
    embedded-dashboard.zip
```

For a standalone CMS without the included plugins, run:

```bat
create-core-deploy.cmd
```

```sh
sh ./create-core-deploy.sh
```

That script creates `deploy-core/cms.zip` without a `plugins/` tree, plus the
compressed external themes. It intentionally does not create `CmsDomains.zip`;
the core package is for a standalone CMS.

The default theme is also embedded under `fallback-theme/` inside each
`cms.zip`, so the package can run by itself. External themes remain separate,
take precedence, and can be changed without rebuilding the CMS package. Site
assets and mutable `data/` files also remain outside the application ZIPs.

### Configure the Domains

Place `cms.zip`, `CmsDomains.zip`, and `mako.conf` in one runtime directory; add
`themes/` when using external themes. Configure `CmsDomains.zip` as the root
application and define the host names in the same `mako.conf`:

```lua
apps = {
   { name = "", path = "CmsDomains.zip" }
}

cmsdomains = {
   { host = "a.local", control = true },
   { host = "b.local" }
}
```

Exactly one domain must set `control=true`. The control domain starts Users &
Access, File Services, and Large File Mailer. Consumer domains share its
identity provider and link their **Users & Access** entry to the control host.
No management URL is required; FuguHub derives it from the control host.

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

The normal deployment startup reads the `apps` entry from `mako.conf`:

```bat
mako
```

The equivalent command-line shortcut, useful for testing without the `apps`
entry, is:

```bat
mako -l::CmsDomains.zip
```

The loader opens the sibling `cms.zip`, starts the control domain first, then
starts each consumer. On shutdown it stops consumers before the control domain.

Verify that every host resolves to the server and check:

1. Each host serves its own CMS site and `/admin/` dashboard.
2. Only the control domain shows local Users & Access, Files, and Mailer pages.
3. A consumer's **Users & Access** link opens the control domain.
4. Credentials created on the control domain authenticate CMS administration on
   the consumer domains.
5. Separate `cms-<host>.sqlite.db` files are created under `data/`.

The packaged layouts are covered by the local integration harness. Deployment
to the final target server or hardware should still be verified before release.
