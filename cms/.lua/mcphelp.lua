local FastMCP = require "fastmcp.engine"
local rw = require "rwfile"

local M = {}

M.cmsVersion = "0.3.0"
M.apiVersion = "0.7.0"
M.schemaVersion = 2
M.mcpMilestone = "mcp-api-" .. M.apiVersion
M.mcpMilestoneDate = "2026-07-28"

local readAnnotations = { readOnlyHint = true, idempotentHint = true }

local guides = {
   {
      id = "site-builder",
      title = "FuguHub Site Builder",
      description = "BAS, Mako, LSP, VFS, application state, and site-building workflow.",
      path = ".info/guides/site-builder.md",
      relatedGuides = { "assets", "database", "lsp", "lsp-htmx", "smq", "themes", "deployment", "mcp" }
   },
   {
      id = "assets",
      title = "CMS Site Assets and Applications",
      description = "Site asset paths, public URL namespaces, ownership boundaries, MCP workflow, HTMX/SMQ lifecycle, and verification.",
      path = ".info/guides/assets.md",
      relatedGuides = { "site-builder", "lsp", "lsp-htmx", "smq", "themes", "deployment", "mcp" }
   },
   {
      id = "database",
      title = "CMS Database and Content",
      description = "SQLite schema and MCP content, menu, taxonomy, redirect, and option operations.",
      path = ".info/guides/database.md",
      relatedGuides = { "site-builder", "lsp", "mcp" }
   },
   {
      id = "lsp",
      title = "CMS LSP Applications",
      description = "Database LSP, assets preload, modules, events, page tables, and serialized writes.",
      path = ".info/guides/lsp.md",
      relatedGuides = { "site-builder", "assets", "database", "lsp-htmx", "smq", "deployment" }
   },
   {
      id = "lsp-htmx",
      title = "CMS LSP and HTMX Interfaces",
      description = "Full-page LSP shells, guarded HTML fragments, CSRF, multipart forms, swaps, history, and testing.",
      path = ".info/guides/lsp-htmx.md",
      relatedGuides = { "site-builder", "assets", "lsp", "smq", "themes" }
   },
   {
      id = "smq",
      title = "CMS SMQ Applications",
      description = "CMS-owned broker, HTMX page scopes, events, direct messaging, RPC, assets registration, security, and testing.",
      path = ".info/guides/smq.md",
      relatedGuides = { "site-builder", "assets", "lsp", "lsp-htmx", "themes" }
   },
   {
      id = "themes",
      title = "CMS Theme Authoring",
      description = "Staged theme creation, modification, validation, packaging, activation, and runtime contracts.",
      path = ".info/guides/themes.md",
      relatedGuides = { "site-builder", "assets", "lsp-htmx", "smq", "deployment" }
   },
   {
      id = "deployment",
      title = "CMS Deployment",
      description = "Runtime layout, ZIP packaging, writable data, and deployment diagnostics.",
      path = ".info/guides/deployment.md",
      relatedGuides = { "site-builder", "assets", "lsp", "themes", "mcp" }
   },
   {
      id = "mcp",
      title = "CMS MCP Agent",
      description = "MCP API milestone, agent rules, bearer configuration, administration, and transfer.",
      path = ".info/guides/mcp.md",
      relatedGuides = { "site-builder", "assets", "database", "lsp", "lsp-htmx", "smq", "themes", "deployment" }
   }
}

local guideById = {}
for _, guide in ipairs(guides) do guideById[guide.id] = guide end

local references = {
   {
      id = "bas-api", title = "BAS API bundle",
      url = "https://realtimelogic.com/downloads/basapi.md",
      appliesTo = { "Mako Server", "Xedge", "Xedge32" },
      scope = "Authoritative BAS, Lua, LSP, VFS, request, response, and IoIntf APIs"
   },
   {
      id = "xedge32-api", title = "Xedge32 and ESP32 API",
      url = "https://realtimelogic.com/downloads/esp32api.md",
      appliesTo = { "Xedge32" },
      scope = "Xedge32 and ESP32-specific APIs; outside the core FuguHub runtime"
   },
   {
      id = "opcua-api", title = "OPC UA API",
      url = "https://realtimelogic.com/downloads/opcuaapi.md",
      appliesTo = { "BAS runtimes with OPC UA" },
      scope = "OPC UA APIs; optional and outside the core FuguHub runtime"
   },
   {
      id = "vfs", title = "VFS and routing skill",
      url = "https://realtimelogic.com/downloads/ai-skills/VFS-skill.md",
      appliesTo = { "Mako Server", "Xedge", "Xedge32" },
      scope = "Directory chaining, resource readers, callbacks, subdirectories, and routing"
   },
   {
      id = "authentication", title = "Authentication and authorization skill",
      url = "https://realtimelogic.com/downloads/ai-skills/Authentication-Authorization-Skill.md",
      appliesTo = { "BAS applications" },
      scope = "Identity, sessions, roles, permissions, and protected VFS subtrees"
   },
   {
      id = "owasp", title = "General application security skill",
      url = "https://realtimelogic.com/downloads/ai-skills/OWASP-General-Security-Skill.md",
      appliesTo = { "Public BAS applications" },
      scope = "Untrusted input, uploads, CORS, cookies, TLS, secrets, and public exposure"
   },
   {
      id = "smq", title = "SMQ real-time messaging skill",
      url = "https://realtimelogic.com/downloads/ai-skills/SMQ-Skill.md",
      appliesTo = { "BAS applications using SMQ" },
      scope = "Publish/subscribe, browser/device messaging, broker authorization, and reconnect testing"
   },
   {
      id = "sqlite", title = "SQLite writer skill",
      url = "https://realtimelogic.com/downloads/ai-skills/SQLite-Skill.md",
      appliesTo = { "BAS applications using SQLite" },
      scope = "Dedicated-writer serialization and BUSY avoidance"
   },
   {
      id = "lua-bindings", title = "Lua C/C++ binding skill",
      url = "https://realtimelogic.com/downloads/ai-skills/Lua-Binding-Skill.md",
      appliesTo = { "Native BAS extensions" },
      scope = "Native ba.* modules, factories, IoIntf, and HttpDir-derived bindings"
   },
   {
      id = "mako-deployment", title = "Mako Server deployment skill",
      url = "https://realtimelogic.com/downloads/ai-skills/Deploy-Mako-Server-Skill.md",
      appliesTo = { "Mako Server" },
      scope = "Service installation, unattended operation, logging, restart, and ACME"
   },
   {
      id = "lsp-interfaces", title = "LSP browser interfaces skill",
      url = "https://realtimelogic.com/downloads/ai-skills/Build-LSP-Web-Interfaces-Skill.md",
      appliesTo = { "BAS browser applications" },
      scope = "Choosing server rendering, HTMX, Fetch/JSON, WebSocket RPC, or SMQ"
   }
}

local referenceById = {}
for _, reference in ipairs(references) do referenceById[reference.id] = reference end

local examples = {
   ["html-page"] = {
      title = "HTML page fragment",
      description = "Static page content stored with renderMode=html.",
      content = [[<section>
  <h1>Example page</h1>
  <p>This is a structurally valid CMS HTML fragment.</p>
</section>]]
   },
   ["lsp-page"] = {
      title = "LSP page fragment",
      description = "Trusted executable content stored with renderMode=lsp.",
      content = [[<section>
  <h1><?lsp= page.title or "Example LSP page" ?></h1>
  <p>Mounted at <?lsp= app.baseUri ?></p>
</section>]]
   },
   ["mount-safe-link"] = {
      title = "Mount-safe link",
      description = "Generate a URL that works at root and under a named Mako mount.",
      content = [[<a href="<?lsp= app.url('/contact/') ?>">Contact</a>]]
   },
   ["serialized-write"] = {
      title = "Serialized SQLite write",
      description = "Use the CMS writer thread from trusted LSP application code.",
      content = [[app.db.writeAsync(function(conn)
   return conn:execute("INSERT INTO jobs(status) VALUES('pending')")
end, function(ok, err)
   if not ok then mako.log(tostring(err), "cms-db") end
end)]]
   },
   ["assetsreq-module"] = {
      title = "Private asset application module",
      description = "Load a site-owned module with assetsreq from assets/.preload.",
      content = [[-- assets/.preload
local greeting = assetsreq "greeting"
appGreeting = greeting.message

-- assets/.lua/greeting.lua
return {
   message = "Hello from the private asset application cache"
}]]
   },
   ["lsp-htmx-fragment"] = {
      title = "LSP shell and HTMX fragment",
      description = "Mount-safe navigable shell plus a fragment-only LSP endpoint.",
      content = [[<!-- assets/example/index.lsp -->
<main>
  <button hx-get="<?lsp= app.url('/example/status.lsp') ?>"
          hx-target="#status"
          hx-swap="innerHTML">Refresh</button>
  <div id="status">Ready</div>
</main>

<!-- assets/example/status.lsp -->
<?lsp
local isHtmx = tostring(request:header("HX-Request") or ""):lower() == "true"
if not response:isinclude() and not isHtmx then
   response:senderror(404, "Not found")
   return
end
?>
Updated]]
   },
   ["theme-link"] = {
      title = "Theme mount-safe asset link",
      description = "Use the render model URL helper in a theme template.",
      content = [[<link rel="stylesheet" href="<?lsp= model.url('/theme/style.css') ?>">]]
   },
   ["site-asset-link"] = {
      title = "Site asset path and theme reference",
      description = "A site asset MCP path is mounted at the CMS root, not below the public /assets namespace.",
      content = [[MCP asset path:
chat/chat.js

Mount-aware public URL returned by the asset tool:
/mybase/chat/chat.js

Portable reference in a theme LSP template:
<script defer src="<?lsp= model.url('/chat/chat.js') ?>"></script>

Incorrect:
<script defer src="<?lsp= model.url('/assets/chat/chat.js') ?>"></script>]]
   }
}

local exampleOrder = {
   "html-page", "lsp-page", "mount-safe-link", "serialized-write",
   "assetsreq-module", "lsp-htmx-fragment", "theme-link", "site-asset-link"
}

local function readFile(io, path)
   local ok, value = pcall(rw.file, io, path)
   if not ok or type(value) ~= "string" then
      return nil, "Cannot read " .. tostring(path) .. ": " .. tostring(value)
   end
   return value
end

function M.instructions(app)
   local text, err = readFile(app.io, ".info/instructions.md")
   if text then return text end
   trace("MCP instructions unavailable:", err)
   return "Use getCapabilities before changing this FuguHub instance."
end

function M.listGuides(app)
   local out = {}
   for _, guide in ipairs(guides) do
      local available = app.io:stat(guide.path) ~= nil
      out[#out + 1] = {
         id = guide.id,
         title = guide.title,
         description = guide.description,
         resourceUri = "fuguhub://guides/" .. guide.id,
         relatedGuides = guide.relatedGuides,
         appliesTo = M.cmsVersion,
         available = available
      }
   end
   return out
end

function M.getGuide(app, id)
   local guide = guideById[tostring(id or "")]
   if not guide then return nil, "Unknown guide: " .. tostring(id), "guideNotFound" end
   local text, err = readFile(app.io, guide.path)
   if not text then return nil, err, "guideUnavailable" end
   return {
      id = guide.id,
      title = guide.title,
      description = guide.description,
      relatedGuides = guide.relatedGuides,
      appliesTo = M.cmsVersion,
      mimeType = "text/markdown",
      content = text
   }
end

local function excerpt(text, startAt, queryLength)
   local first = math.max(1, startAt - 120)
   local last = math.min(#text, startAt + queryLength + 240)
   return text:sub(first, last):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.search(app, query, limit)
   query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
   if query == "" then return nil, "Search query is required", "invalidSearchQuery" end
   limit = math.floor(tonumber(limit) or 10)
   local needle = query:lower()
   local matches = {}
   for _, guide in ipairs(guides) do
      local text = readFile(app.io, guide.path)
      if text then
         local lower = text:lower()
         local from = 1
         while #matches < limit do
            local found = lower:find(needle, from, true)
            if not found then break end
            matches[#matches + 1] = {
               guideId = guide.id,
               title = guide.title,
               resourceUri = "fuguhub://guides/" .. guide.id,
               excerpt = excerpt(text, found, #query)
            }
            from = found + math.max(1, #needle)
         end
      end
      if #matches >= limit then break end
   end
   if #matches < limit then
      for _, reference in ipairs(references) do
         local searchable = table.concat({
            reference.id,
            reference.title,
            reference.scope,
            table.concat(reference.appliesTo or {}, " "),
            reference.url
         }, "\n")
         local found = searchable:lower():find(needle, 1, true)
         if found then
            matches[#matches + 1] = {
               kind = "reference",
               referenceId = reference.id,
               title = reference.title,
               url = reference.url,
               scope = reference.scope,
               appliesTo = reference.appliesTo,
               authoritative = true
            }
            if #matches >= limit then break end
         end
      end
   end
   return matches
end

function M.listExamples()
   local out = {}
   for _, id in ipairs(exampleOrder) do
      local example = examples[id]
      out[#out + 1] = {
         id = id,
         title = example.title,
         description = example.description
      }
   end
   return out
end

function M.getExample(id)
   id = tostring(id or "")
   local example = examples[id]
   if not example then return nil, "Unknown example: " .. id, "exampleNotFound" end
   return {
      id = id,
      title = example.title,
      description = example.description,
      content = example.content
   }
end

function M.listReferences()
   local out = {}
   for _, reference in ipairs(references) do
      local copy = {}
      for key, value in pairs(reference) do copy[key] = value end
      out[#out + 1] = copy
   end
   return out
end

function M.getReference(id)
   local reference = referenceById[tostring(id or "")]
   if not reference then return nil, "Unknown reference: " .. tostring(id), "referenceNotFound" end
   local copy = {}
   for key, value in pairs(reference) do copy[key] = value end
   copy.authoritative = true
   copy.retrieval = "Open the source URL; this MCP server returns reference metadata rather than mirroring the document"
   return copy
end

local operationClass = {
   getCmsInfo = "read",
   getCapabilities = "read",
   listGuides = "read",
   getGuide = "read",
   searchHelp = "read",
   getExample = "read",
   listReferences = "read",
   getReference = "read",
   getContentAuthoringContract = "read",
   readRuntimeTrace = "read",
   getAssetCapabilities = "read",
   listAssets = "read",
   getAsset = "read",
   getAssetDependencies = "read",
   testPublicPath = "read",
   prepareAssetDownload = "export",
   validateAssetCode = "read",
   writeTextAsset = "mutation",
   restartAssetsApplication = "privileged",
   prepareAssetUpload = "mutation",
   createAssetDirectory = "mutation",
   moveAsset = "destructive",
   deleteAsset = "destructive",
   prepareAssetsExport = "export",
   prepareAssetsImport = "privileged",
   listThemeFiles = "read",
   getThemeFile = "read",
   listThemeDrafts = "read",
   createThemeDraft = "mutation",
   listThemeDraftFiles = "read",
   getThemeDraftFile = "read",
   writeThemeDraftText = "mutation",
   prepareThemeDraftUpload = "mutation",
   prepareThemeDraftDownload = "export",
   commitThemeDraft = "privileged",
   prepareThemeFileDownload = "export",
   prepareThemeExport = "export",
   deleteThemeDraftFile = "destructive",
   validateThemeDraft = "read",
   discardThemeDraft = "destructive",
   listContent = "read",
   getContent = "read",
   getContentBatch = "read",
   getContentDependencies = "read",
   validateContent = "read",
   createContent = "mutation",
   copyContent = "mutation",
   updateContent = "mutation",
   setContentStatus = "publication",
   deleteContent = "destructive",
   listMenus = "read",
   getMenuLocations = "read",
   createMenu = "mutation",
   updateMenu = "mutation",
   deleteMenu = "destructive",
   createMenuItem = "mutation",
   updateMenuItem = "mutation",
   deleteMenuItem = "destructive",
   listRedirects = "read",
   setRedirect = "mutation",
   deleteRedirect = "destructive",
   listTerms = "read",
   createTerm = "mutation",
   updateTerm = "mutation",
   deleteTerm = "destructive",
   getSettings = "read",
   updateSettings = "mutation",
   listThemes = "read",
   validateTheme = "read",
   activateTheme = "privileged",
   getHealth = "read",
   getSchemaInfo = "read",
   runIntegrityCheck = "read",
   clearCache = "mutation",
   prepareContentExport = "export",
   prepareContentTransfer = "transfer",
   importContentTransfer = "transfer"
}

function M.capabilities(app, mcp, archive)
   local operations = {}
   for _, tool in ipairs(mcp:listTools({})) do
      operations[#operations + 1] = {
         name = tool.name,
         class = operationClass[tool.name] or "unknown",
         readOnly = tool.annotations and tool.annotations.readOnlyHint == true or false,
         destructive = tool.annotations and tool.annotations.destructiveHint == true or false
      }
   end

   local assetsSource = app.assetsSource or (app.homeIo:stat(app.assetsZipName) and "zip" or "directory")
   return {
      cms = {
         name = "FuguHub",
         version = M.cmsVersion,
         schemaVersion = M.schemaVersion,
         mcpApiVersion = M.apiVersion,
         mcpDesignStatus = "milestone",
         mcpMilestone = M.mcpMilestone,
         mcpMilestoneDate = M.mcpMilestoneDate
      },
      runtime = {
         baseUri = app.baseUri,
         mcpPath = app.url("/mcp/"),
         activeTheme = app.theme and app.theme.name or app.defaultTheme,
         assetsSource = assetsSource,
         themeContract = app.theme and app.theme.contract
      },
      applicationModel = {
         mountSafeUrlHelper = "app.url",
         requestEnvironment = "_ENV",
         persistentPageState = "page",
         publicApp = "app.assetsApp or app",
         cmsModuleLoader = "app." .. "app" .. "req",
         databaseLspCompiler = "ba.parselsp",
         sharedLspRequestChain = true,
         persistentVirtualPageTables = true,
         urlNamespaces = {
            siteAsset = {
               mcpPathExample = "chat/chat.js",
               publicUrlExample = app.url("/chat/chat.js"),
               themeLspExample = "model.url('/chat/chat.js')",
               rule = "The top-level assets directory is mounted at the CMS root; do not prepend /assets"
            },
            themeAsset = {
               packagePathExample = "images/logo.png",
               publicUrlExample = app.url("/theme/images/logo.png"),
               themeLspExample = "model.url('/theme/images/logo.png')"
            },
            cmsAsset = {
               publicUrlExample = app.url("/assets/htmx/htmx.min.js"),
               themeLspExample = "model.url('/assets/htmx/htmx.min.js')",
               rule = "/assets is reserved for CMS-owned runtime files"
            },
            makoSystem = {
               publicUrlExample = "/rtl/smq.js",
               themeLspExample = "/rtl/smq.js",
               rule = "Server-root resource; do not prefix with the CMS mount"
            }
         },
         categoryApi = {
            list = "app.cms:categories",
            get = "app.cms:category",
            posts = "app.cms:postsByCategory",
            contentAssignments = "app.cms:categoriesForContent"
         },
         smqApi = {
            registerRpc = "app.smq:registerRpcMethod",
            brokerStart = "app.smq:onBrokerStart",
            publish = "app.smq:publish",
            enabled = "app.smq:isEnabled",
            running = "app.smq:isRunning"
         }
      },
      realTimeMessaging = {
         smq = {
            available = app.smq ~= nil,
            enabled = app.settings.smqEnabled == true,
            requiresHtmx = true,
            htmxEnabled = app.settings.htmxEnabled == true,
            endpoint = app.url("/SMQ/"),
            guideId = "smq",
            referenceId = "smq",
            serverApi = "app.smq",
            browserApi = "window.cmsSmq.mountPage"
         }
      },
      contentPaths = {
         pagePath = "stored path is the public path",
         postPath = "stored path omits the configured blog base",
         publicPathField = "publicPath",
         uniqueness = "type,path"
      },
      assetApplication = {
         source = assetsSource,
         active = app.assetsApp ~= nil,
         readOnly = assetsSource == "zip",
         preloadPath = "assets/.preload",
         preloadExists = app.assetsIo:stat(".preload") ~= nil,
         moduleRoot = "assets/.lua/",
         moduleLoader = "assetsreq",
         moduleLoaderAvailable = app.assetsApp ~= nil and type(app.assetsApp.assetsreq) == "function",
         moduleCache = "application-private",
         moduleCacheRequiresPreload = true,
         publicApp = "app.assetsApp or app",
         unloadHook = "onunload",
         reloadTool = "restartAssetsApplication",
         reloadRequiresConfirmation = true,
         publicBaseUrl = app.baseUri,
         publicPathRule = "Asset contents are mounted at the CMS root; MCP path chat/chat.js has public URL app.url('/chat/chat.js')"
      },
      themeManagement = {
         sources = { "directory", "zip" },
         listTool = "listThemes",
         validateTool = "validateTheme",
         activateTool = "activateTheme",
         listFilesTool = "listThemeFiles",
         readFileTool = "getThemeFile",
         createDraftTool = "createThemeDraft",
         listDraftsTool = "listThemeDrafts",
         validateDraftTool = "validateThemeDraft",
         commitDraftTool = "commitThemeDraft",
         exportTool = "prepareThemeExport",
         activationRequiresConfirmation = true,
         commitRequiresConfirmation = true,
         executableConfirmationRequired = true,
         commitFormat = "zip",
         commitActivatesTheme = false,
         draftsPersistent = true,
         activeThemeReplacementAllowed = true,
         activeThemeReplacementAutomaticForConfirmedCommit = true,
         activeThemeReplacementRequiresSeparateConfirmation = false,
         activeThemeReplacementReloadsImmediately = true,
         canCreate = true,
         canModify = true,
         canUpload = true,
         canDownload = true,
         canDelete = false,
         canDeleteInstalled = false,
         canDeleteDraft = true,
         canReadSource = true,
         canImportPackage = false,
         canPerformVisualQa = false
      },
      modules = {
         content = true,
         menus = true,
         redirects = true,
         taxonomyAssignments = true,
         categoryArchives = true,
         themes = true,
         settings = true,
         htmx = app.settings.htmxEnabled == true,
         smq = app.smq ~= nil,
         smqEnabled = app.settings.smqEnabled == true,
         editableNotFound = app.settings.notFoundEnabled == true,
         selectedContentTransfer = true,
         assetManagement = true,
         assetsZipImportExport = true,
         themeDrafts = true,
         themeFileManagement = true,
         themeZipExport = true,
         runtimeTrace = app.runtimeTrace ~= nil,
         embeddedGuides = true,
         lspHtmxPattern = true,
         diagnostics = true,
         revisions = false,
         trash = false,
         permanentContentDelete = true,
         mediaLibrary = false,
         localization = false,
         comments = false
      },
      supported = {
         coreRuntime = "Mako Server",
         optionalOrExternalRuntimes = { "Xedge", "Xedge32" },
         contentTypes = { "page", "post" },
         contentStatuses = { "draft", "published" },
         renderModes = { "html", "lsp" },
         cachePolicies = { "default", "revalidate", "no-cache", "no-store" },
         redirectStatusCodes = { 301, 302 },
         taxonomyTypes = { "category", "tag" },
         categoryArchivePattern = "<blogBasePath>category/<slug>/",
         customTaxonomyTypesAllowed = true,
         themeSources = { "directory", "zip" },
         applicationPatterns = {
            "database-lsp", "asset-lsp", "lsp-htmx", "smq-page-scopes",
            "theme-fragments"
         },
         smqEndpoint = app.url("/SMQ/"),
         exportFormats = { archive.format .. "@" .. tostring(archive.version) }
      },
      limits = {
         contentBodyBytes = 4 * 1024 * 1024,
         headHtmlBytes = 1024 * 1024,
         metaDescriptionBytes = 65536,
         listContentMaximum = 500,
         mcpRequestBytes = 5 * 1024 * 1024,
         mcpResponseBytes = 6 * 1024 * 1024,
         contentArchiveBytes = 8 * 1024 * 1024,
         themeTextFileBytes = 4 * 1024 * 1024,
         themeBinaryFileBytes = 32 * 1024 * 1024,
         themeArchiveBytes = 64 * 1024 * 1024,
         themeExpandedBytes = 64 * 1024 * 1024,
         themeEntryBytes = 16 * 1024 * 1024,
         themeEntries = 2048,
         themeDepth = 32,
         themeTicketSeconds = 5 * 60,
         sessions = 16
      },
      transferCompatibility = {
         format = archive.format,
         version = archive.version,
         selectedContentOnly = true,
         menusIncluded = false,
         redirectsIncluded = false
      },
      unavailable = {
         { feature = "trash", reason = "Requires content lifecycle schema and retention policy" },
         { feature = "revisions", reason = "Requires revision storage and rollback model" },
         { feature = "scheduling", reason = "Requires scheduler and publication timestamps" },
         { feature = "mediaLibrary", reason = "Requires scoped binary storage and metadata model" },
         { feature = "standaloneArchiveImport", reason = "Requires a bounded upload endpoint" },
         { feature = "fullSiteBackupRestore", reason = "Requires atomic data and theme snapshots" },
         { feature = "usersRolesAudit", reason = "Requires separate security privilege scopes and audit storage" },
         { feature = "assetsRollback", reason = "Asset ZIP rollback is intentionally deferred" },
         { feature = "installedThemeDeletion", reason = "Installed themes cannot be deleted through MCP" },
         { feature = "themePackageImport", reason = "Theme files are authored through validated drafts; direct ZIP import is not exposed" },
         { feature = "themeVisualQa", reason = "The MCP API validates packages but does not control a browser" },
         { feature = "optionalModules", reason = "Comments, forms, localization, plugins, analytics, and webhooks are not installed" }
      },
      operations = operations,
      guides = M.listGuides(app)
   }
end

local function registerGuideTools(mcp, app, toolError, arrays)
   mcp:tool("listGuides", {
      description = "List version-matched CMS guides available through this MCP server.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      return arrays({ guides = M.listGuides(app), examples = M.listExamples() })
   end)

   mcp:tool("getGuide", {
      description = "Read one CMS guide in Markdown by its guide id.",
      inputSchema = {
         type = "object",
         properties = { id = { type = "string", minLength = 1, maxLength = 64 } },
         required = { "id" },
         additionalProperties = false
      },
      annotations = readAnnotations
   }, function(args)
      local result, err, code = M.getGuide(app, args.id)
      if not result then return toolError(err, code) end
      return result
   end)

   mcp:tool("searchHelp", {
      description = "Search the authoritative CMS guides and return bounded matching excerpts.",
      inputSchema = {
         type = "object",
         properties = {
            query = { type = "string", minLength = 1, maxLength = 256 },
            limit = { type = "integer", minimum = 1, maximum = 20, default = 10 }
         },
         required = { "query" },
         additionalProperties = false
      },
      annotations = readAnnotations
   }, function(args)
      local result, err, code = M.search(app, args.query, args.limit)
      if not result then return toolError(err, code) end
      return arrays({ matches = result })
   end)

   mcp:tool("getExample", {
      description = "Read a small version-matched example for a common CMS HTML, LSP, database, or theme task.",
      inputSchema = {
         type = "object",
         properties = { id = { type = "string", minLength = 1, maxLength = 64 } },
         required = { "id" },
         additionalProperties = false
      },
      annotations = readAnnotations
   }, function(args)
      local result, err, code = M.getExample(args.id)
      if not result then return toolError(err, code) end
      return result
   end)

   mcp:tool("listReferences", {
      description = "List authoritative BAS API references and optional public skills, including applicability and scope.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      return arrays({ references = M.listReferences() })
   end)

   mcp:tool("getReference", {
      description = "Read routing metadata for one authoritative BAS API reference or optional public skill.",
      inputSchema = {
         type = "object",
         properties = { id = { type = "string", minLength = 1, maxLength = 64 } },
         required = { "id" },
         additionalProperties = false
      },
      annotations = readAnnotations
   }, function(args)
      local result, err, code = M.getReference(args.id)
      if not result then return toolError(err, code) end
      return arrays(result)
   end)

   mcp:tool("getContentAuthoringContract", {
      description = "Return the active theme's machine-readable title and heading ownership contract for content and Markdown imports.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      return {
         theme = app.theme and app.theme.name or app.defaultTheme,
         contract = app.theme and app.theme.contract or {
            rendersContentTitle = false,
            titleElement = "h1",
            titleHasAnchor = false,
            recommendedBodyHeadingStart = 1,
            canSuppressRenderedTitle = false,
            declared = false
         },
         markdownRule = app.theme and app.theme.contract and app.theme.contract.rendersContentTitle and
            "Promote the first Markdown H1 to content.title and omit that H1 from bodyHtml; preserve any referenced anchor." or
            "Retain a body H1 because the active theme does not declare title ownership."
      }
   end)
end

local function promptText(app, path, replacements)
   local text, err = readFile(app.io, path)
   if not text then return "CMS prompt unavailable: " .. tostring(err) end
   for key, value in pairs(replacements or {}) do
      text = text:gsub("{{" .. key .. "}}", tostring(value))
   end
   return text
end

function M.register(mcp, app, archive, toolError, arrays)
   mcp:tool("getCapabilities", {
      description = "Read CMS, schema, MCP API, mount, module, operation, limit, and transfer compatibility capabilities.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      return arrays(M.capabilities(app, mcp, archive))
   end)

   registerGuideTools(mcp, app, toolError, arrays)

   mcp:resource("fuguhub://instructions", {
      name = "FuguHub MCP Instructions",
      description = "Stable instructions for agents using this CMS MCP server.",
      mimeType = "text/markdown",
      annotations = readAnnotations
   }, function()
      return FastMCP.resourceContent {
         text = M.instructions(app),
         mimeType = "text/markdown"
      }
   end)

   mcp:resource("fuguhub://capabilities", {
      name = "FuguHub Capabilities",
      description = "Current CMS and MCP capabilities for this mounted instance.",
      mimeType = "application/json",
      annotations = readAnnotations
   }, function()
      return arrays(M.capabilities(app, mcp, archive))
   end)

   mcp:resourceTemplate("fuguhub://guides/{id}", {
      name = "FuguHub Guide",
      description = "Read an authoritative CMS guide by id.",
      mimeType = "text/markdown",
      parameters = {
         id = { type = "string", minLength = 1, maxLength = 64, required = true }
      },
      annotations = readAnnotations
   }, function(args)
      local guide, err, code = M.getGuide(app, args.id)
      if not guide then return FastMCP.error(err, { code = code }) end
      return FastMCP.resourceContent {
         text = guide.content,
         mimeType = "text/markdown"
      }
   end)

   mcp:prompt("createCmsContent", {
      description = "Workflow for creating or updating a CMS page or post from a prompt, HTML fragment, or Markdown.",
      arguments = {
         userRequest = { description = "The user's content request.", required = false }
      }
   }, function(args)
      return promptText(app, ".info/createCmsContent.md", {
         userRequest = args.userRequest or "not specified"
      })
   end)

   mcp:prompt("importHtmlContent", {
      description = "Workflow for safely importing a saved or legacy HTML document into the active CMS theme with dependency and visual checks.",
      arguments = {
         userRequest = { description = "The legacy HTML import request and source.", required = false }
      }
   }, function(args)
      return promptText(app, ".info/importHtmlContent.md", {
         userRequest = args.userRequest or "not specified"
      })
   end)

   mcp:prompt("buildCmsLspApp", {
      description = "Workflow for building trusted LSP-backed CMS application content and asset modules.",
      arguments = {
         userGoal = { description = "The requested application behavior.", required = false }
      }
   }, function(args)
      return promptText(app, ".info/buildCmsLspApp.md", {
         userGoal = args.userGoal or "not specified"
      })
   end)

   mcp:prompt("buildCmsHtmxApp", {
      description = "Workflow for building a mount-aware LSP interface that returns HTMX HTML fragments.",
      arguments = {
         userGoal = { description = "The requested HTMX interface behavior.", required = false }
      }
   }, function(args)
      return promptText(app, ".info/buildCmsHtmxApp.md", {
         userGoal = args.userGoal or "not specified"
      })
   end)

   mcp:prompt("manageCmsTheme", {
      description = "Workflow for creating, modifying, validating, packaging, exporting, and activating a FuguHub theme.",
      arguments = {
         userGoal = { description = "The requested theme goal.", required = false }
      }
   }, function(args)
      return promptText(app, ".info/manageCmsTheme.md", {
         userGoal = args.userGoal or "not specified"
      })
   end)
end

return M
