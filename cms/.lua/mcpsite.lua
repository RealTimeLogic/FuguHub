local db = appreq "db"
local validation = appreq "validation"
local settings = appreq "settings"
local theme = appreq "theme"
local notfound = appreq "notfound"
local smqservice = appreq "smqservice"
local schema = appreq "schema"
local redirectservice = appreq "redirectservice"

local M = {}

local readAnnotations = { readOnlyHint = true, idempotentHint = true }
local mutateAnnotations = { readOnlyHint = false, destructiveHint = false }
local destructiveAnnotations = { readOnlyHint = false, destructiveHint = true }

local required = validation.required
local slug = validation.slug

local function exec(conn, sql)
   local ok, err = conn:execute(sql)
   if not ok then error(tostring(err), 2) end
end

local function termRow(conn, id)
   local row = db.one(conn, [[SELECT t.*,
      (SELECT COUNT(*) FROM content_terms ct WHERE ct.term_id=t.id) assignment_count
      FROM terms t WHERE t.id=]] .. tonumber(id))
   if row then
      row.id = tonumber(row.id)
      row.assignmentCount = tonumber(row.assignment_count)
      row.assignment_count = nil
   end
   return row
end

local function registerTaxonomy(mcp, app, helpers)
   mcp:tool("listTerms", {
      description = "List taxonomy terms independently of content, including assignment counts.",
      inputSchema = {
         type = "object",
         properties = {
            type = { type = "string", minLength = 1, maxLength = 64 },
            query = { type = "string", minLength = 1, maxLength = 255 },
            afterId = { type = "integer", minimum = 0, default = 0 },
            limit = { type = "integer", minimum = 1, maximum = 500, default = 100 }
         },
         additionalProperties = false
      },
      annotations = readAnnotations
   }, function(args)
      local where = { "t.id>" .. math.floor(tonumber(args.afterId) or 0) }
      if args.type then where[#where + 1] = "t.type=" .. db.quote(args.type) end
      if args.query then
         local pattern = db.quote("%" .. validation.trim(args.query) .. "%")
         where[#where + 1] = "(t.name LIKE " .. pattern .. " OR t.slug LIKE " .. pattern .. ")"
      end
      local limit = math.floor(tonumber(args.limit) or 100)
      local rows = db.readRows(app, [[SELECT t.*,
         (SELECT COUNT(*) FROM content_terms ct WHERE ct.term_id=t.id) assignment_count
         FROM terms t WHERE ]] .. table.concat(where, " AND ") ..
         " ORDER BY t.id LIMIT " .. (limit + 1))
      local hasMore = #rows > limit
      if hasMore then rows[#rows] = nil end
      for _, row in ipairs(rows) do
         row.id = tonumber(row.id)
         row.assignmentCount = tonumber(row.assignment_count)
         row.assignment_count = nil
      end
      local result = { terms = rows, hasMore = hasMore }
      if hasMore and rows[#rows] then result.nextAfterId = rows[#rows].id end
      return helpers.arrays(result)
   end)

   mcp:tool("createTerm", {
      description = "Create a taxonomy term. Term type is extensible; category and tag are conventional types.",
      inputSchema = {
         type = "object",
         properties = {
            type = { type = "string", minLength = 1, maxLength = 64 },
            name = { type = "string", minLength = 1, maxLength = 255 },
            slug = { type = "string", minLength = 1, maxLength = 255 },
            description = { type = "string", maxLength = 65536, default = "" }
         },
         required = { "type", "name", "slug" },
         additionalProperties = false
      },
      annotations = mutateAnnotations
   }, function(args)
      local kind, err = required(args.type, "Term type", 64)
      if not kind then return helpers.toolError(err, "invalidTermType") end
      local name
      name, err = required(args.name, "Term name", 255)
      if not name then return helpers.toolError(err, "invalidTermName") end
      local termSlug
      termSlug, err = slug(args.slug, "Term slug")
      if not termSlug then return helpers.toolError(err, "invalidTermSlug") end
      local created
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         if db.one(conn, "SELECT id FROM terms WHERE type=" .. db.quote(kind) ..
            " AND slug=" .. db.quote(termSlug)) then
            error("A term with this type and slug already exists", 2)
         end
         exec(conn, "INSERT INTO terms(type,name,slug,description) VALUES(" ..
            db.quote(kind) .. "," .. db.quote(name) .. "," .. db.quote(termSlug) .. "," ..
            db.quote(args.description or "") .. ")")
         created = termRow(conn, db.one(conn, "SELECT last_insert_rowid() id").id)
      end)
      if not ok then return helpers.toolError(writeErr, "termCreateFailed") end
      helpers.clearRuntime(app)
      return created
   end)

   mcp:tool("updateTerm", {
      description = "Update a taxonomy term's type, name, slug, or description.",
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            type = { type = "string", minLength = 1, maxLength = 64 },
            name = { type = "string", minLength = 1, maxLength = 255 },
            slug = { type = "string", minLength = 1, maxLength = 255 },
            description = { type = "string", maxLength = 65536 }
         },
         required = { "id" },
         additionalProperties = false
      },
      annotations = mutateAnnotations
   }, function(args)
      local updated
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         local row = termRow(conn, args.id)
         if not row then error("Taxonomy term was not found", 2) end
         local kind, err = required(args.type or row.type, "Term type", 64)
         if not kind then error(err, 2) end
         local name
         name, err = required(args.name or row.name, "Term name", 255)
         if not name then error(err, 2) end
         local termSlug
         termSlug, err = slug(args.slug or row.slug, "Term slug")
         if not termSlug then error(err, 2) end
         local conflict = db.one(conn, "SELECT id FROM terms WHERE type=" .. db.quote(kind) ..
            " AND slug=" .. db.quote(termSlug) .. " AND id<>" .. tonumber(row.id))
         if conflict then error("A term with this type and slug already exists", 2) end
         exec(conn, "UPDATE terms SET type=" .. db.quote(kind) .. ",name=" .. db.quote(name) ..
            ",slug=" .. db.quote(termSlug) .. ",description=" ..
            db.quote(args.description ~= nil and args.description or row.description) ..
            " WHERE id=" .. tonumber(row.id))
         updated = termRow(conn, row.id)
      end)
      if not ok then return helpers.toolError(writeErr, "termUpdateFailed") end
      helpers.clearRuntime(app)
      return updated
   end)

   mcp:tool("deleteTerm", {
      description = "Permanently delete a taxonomy term and remove its content assignments. Requires explicit confirmation.",
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            confirmed = { type = "boolean" }
         },
         required = { "id", "confirmed" },
         additionalProperties = false
      },
      annotations = destructiveAnnotations
   }, function(args)
      if args.confirmed ~= true then
         return helpers.toolError("Explicit confirmation is required", "confirmationRequired")
      end
      local deleted
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         local row = termRow(conn, args.id)
         if not row then error("Taxonomy term was not found", 2) end
         exec(conn, "DELETE FROM terms WHERE id=" .. tonumber(row.id))
         deleted = {
            deleted = true,
            id = row.id,
            type = row.type,
            slug = row.slug,
            removedAssignments = row.assignmentCount
         }
      end)
      if not ok then return helpers.toolError(writeErr, "termDeleteFailed") end
      helpers.clearRuntime(app)
      return deleted
   end)
end

local function menuRow(conn, id)
   local row = db.one(conn, [[SELECT m.*,
      (SELECT COUNT(*) FROM menu_items mi WHERE mi.menu_id=m.id) item_count
      FROM menus m WHERE m.id=]] .. tonumber(id))
   if row then
      row.id = tonumber(row.id)
      row.itemCount = tonumber(row.item_count)
      row.item_count = nil
   end
   return row
end

local function registerMenus(mcp, app, helpers)
   mcp:tool("getMenuLocations", {
      description = "List CMS menu locations and the menu currently used at each location.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      local primary = db.readOne(app, "SELECT id,name,slug FROM menus WHERE slug='primary'")
      if primary then primary.id = tonumber(primary.id) end
      return helpers.arrays({
         locations = {
            {
               id = "primary",
               description = "Primary public navigation",
               menu = primary
            }
         }
      })
   end)

   mcp:tool("createMenu", {
      description = "Create a named menu definition. Add entries separately with createMenuItem.",
      inputSchema = {
         type = "object",
         properties = {
            name = { type = "string", minLength = 1, maxLength = 255 },
            slug = { type = "string", minLength = 1, maxLength = 255 }
         },
         required = { "name", "slug" },
         additionalProperties = false
      },
      annotations = mutateAnnotations
   }, function(args)
      local name, err = required(args.name, "Menu name", 255)
      if not name then return helpers.toolError(err, "invalidMenuName") end
      local menuSlug
      menuSlug, err = slug(args.slug, "Menu slug")
      if not menuSlug then return helpers.toolError(err, "invalidMenuSlug") end
      local created
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         if db.one(conn, "SELECT id FROM menus WHERE slug=" .. db.quote(menuSlug)) then
            error("A menu with this slug already exists", 2)
         end
         exec(conn, "INSERT INTO menus(name,slug) VALUES(" .. db.quote(name) .. "," ..
            db.quote(menuSlug) .. ")")
         created = menuRow(conn, db.one(conn, "SELECT last_insert_rowid() id").id)
      end)
      if not ok then return helpers.toolError(writeErr, "menuCreateFailed") end
      helpers.clearRuntime(app)
      return created
   end)

   mcp:tool("updateMenu", {
      description = "Update a menu definition without changing its items.",
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            name = { type = "string", minLength = 1, maxLength = 255 },
            slug = { type = "string", minLength = 1, maxLength = 255 }
         },
         required = { "id" },
         additionalProperties = false
      },
      annotations = mutateAnnotations
   }, function(args)
      local updated
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         local row = menuRow(conn, args.id)
         if not row then error("Menu was not found", 2) end
         local name, err = required(args.name or row.name, "Menu name", 255)
         if not name then error(err, 2) end
         local menuSlug
         menuSlug, err = slug(args.slug or row.slug, "Menu slug")
         if not menuSlug then error(err, 2) end
         local conflict = db.one(conn, "SELECT id FROM menus WHERE slug=" .. db.quote(menuSlug) ..
            " AND id<>" .. tonumber(row.id))
         if conflict then error("A menu with this slug already exists", 2) end
         exec(conn, "UPDATE menus SET name=" .. db.quote(name) .. ",slug=" .. db.quote(menuSlug) ..
            " WHERE id=" .. tonumber(row.id))
         updated = menuRow(conn, row.id)
      end)
      if not ok then return helpers.toolError(writeErr, "menuDefinitionUpdateFailed") end
      helpers.clearRuntime(app)
      return updated
   end)

   mcp:tool("deleteMenu", {
      description = "Permanently delete a menu definition and all its items. Requires explicit confirmation.",
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            confirmed = { type = "boolean" }
         },
         required = { "id", "confirmed" },
         additionalProperties = false
      },
      annotations = destructiveAnnotations
   }, function(args)
      if args.confirmed ~= true then
         return helpers.toolError("Explicit confirmation is required", "confirmationRequired")
      end
      local deleted
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         local row = menuRow(conn, args.id)
         if not row then error("Menu was not found", 2) end
         if row.slug == "primary" then error("The primary menu cannot be deleted", 2) end
         exec(conn, "DELETE FROM menus WHERE id=" .. tonumber(row.id))
         deleted = {
            deleted = true,
            id = row.id,
            slug = row.slug,
            removedItems = row.itemCount
         }
      end)
      if not ok then return helpers.toolError(writeErr, "menuDefinitionDeleteFailed") end
      helpers.clearRuntime(app)
      return deleted
   end)
end

local function registerSettings(mcp, app, helpers)
   mcp:tool("getSettings", {
      description = "Read typed public-site settings. Secret options are never returned.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      return {
         htmxEnabled = settings.isHtmxEnabled(app),
         smqEnabled = settings.isSmqEnabled(app),
         blogBasePath = settings.blogBasePath(app),
         notFoundEnabled = settings.isNotFoundEnabled(app),
         notFoundPath = settings.notFoundPath(app)
      }
   end)

   mcp:tool("updateSettings", {
      description = "Validate and atomically update supported public-site settings. Use dryRun to inspect the effective values without saving.",
      inputSchema = {
         type = "object",
         properties = {
            htmxEnabled = { type = "boolean" },
            smqEnabled = { type = "boolean" },
            blogBasePath = { type = "string", minLength = 1, maxLength = 2048 },
            notFoundEnabled = { type = "boolean" },
            notFoundPath = { type = "string", minLength = 1, maxLength = 2048 },
            dryRun = { type = "boolean", default = false }
         },
         additionalProperties = false
      },
      annotations = mutateAnnotations
   }, function(args)
      local blogBasePath, err = validation.path(
         args.blogBasePath or settings.blogBasePath(app), "/blog/")
      if not blogBasePath then return helpers.toolError(err, "invalidBlogBasePath") end
      local notFoundPath
      notFoundPath, err = validation.path(
         args.notFoundPath or settings.notFoundPath(app), "/404/")
      if not notFoundPath then return helpers.toolError(err, "invalidNotFoundPath") end
      local htmxEnabled = args.htmxEnabled
      if htmxEnabled == nil then htmxEnabled = settings.isHtmxEnabled(app) end
      local smqEnabled = args.smqEnabled
      if smqEnabled == nil then smqEnabled = settings.isSmqEnabled(app) end
      smqEnabled = htmxEnabled == true and smqEnabled == true
      local notFoundEnabled = args.notFoundEnabled
      if notFoundEnabled == nil then notFoundEnabled = settings.isNotFoundEnabled(app) end
      local desired = {
         htmxEnabled = htmxEnabled,
         smqEnabled = smqEnabled,
         blogBasePath = blogBasePath,
         notFoundEnabled = notFoundEnabled,
         notFoundPath = notFoundPath
      }
      if args.dryRun then return { dryRun = true, settings = desired } end
      local updated, updateErr, updateDetails = settings.updateWithRuntime(
         app, desired, function()
         notfound.configure(app)
         local smqOk, smqErr = smqservice.configure(app)
         if not smqOk then error(smqErr, 2) end
      end)
      if not updated then
         local code = updateDetails and updateDetails.committed and
            "settingsPartiallyApplied" or "settingsUpdateFailed"
         return helpers.toolError(updateErr, code, updateDetails)
      end
      helpers.clearRuntime(app)
      return { dryRun = false, settings = updated }
   end)

   mcp:tool("listThemes", {
      description = "List installed directory and ZIP themes and identify the active runtime theme.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      return helpers.arrays({ themes = theme.list(app) })
   end)

   mcp:tool("validateTheme", {
      description = "Compile every required template in an installed directory or ZIP theme without activating it.",
      inputSchema = {
         type = "object",
         properties = {
            name = { type = "string", minLength = 1, maxLength = 255 }
         },
         required = { "name" },
         additionalProperties = false
      },
      annotations = readAnnotations
   }, function(args)
      local result, err = theme.validate(app, args.name)
      if not result then return helpers.toolError(err, "themeValidationFailed") end
      local templates = {}
      for _, name in ipairs(result.templates) do templates[#templates + 1] = name end
      result.templates = templates
      return helpers.arrays(result)
   end)

   mcp:tool("activateTheme", {
      description = "Validate, activate, and persist an installed directory or ZIP theme. Requires explicit user confirmation.",
      inputSchema = {
         type = "object",
         properties = {
            name = { type = "string", minLength = 1, maxLength = 255 },
            confirmed = { type = "boolean" }
         },
         required = { "name", "confirmed" },
         additionalProperties = false
      },
      annotations = mutateAnnotations
   }, function(args)
      if args.confirmed ~= true then
         return helpers.toolError("Explicit confirmation is required", "confirmationRequired")
      end
      local name, err = theme.normalizeName(args.name)
      if not name then return helpers.toolError(err, "invalidThemeName") end
      local activated, previous
      local ok, activateErr = pcall(function()
         activated, previous = theme.activateAndPersist(app, name)
      end)
      if not ok then
         return helpers.toolError(activateErr, "themeActivationFailed")
      end
      helpers.clearRuntime(app)
      return {
         previousTheme = previous,
         activeTheme = activated.name,
         source = activated.source,
         reloadRequired = false
      }
   end)
end

local function addIssue(issues, severity, code, message, entity)
   issues[#issues + 1] = {
      severity = severity,
      code = code,
      message = message,
      entity = entity
   }
end

local function redirectIssues(app, issues)
   for _, issue in ipairs(redirectservice.issues(app)) do
      addIssue(issues, "error", issue.code, issue.message, issue.entity)
   end
end

local function menuIssues(app, issues)
   local rows = db.readRows(app, "SELECT id,menu_id,parent_id FROM menu_items")
   local byId = {}
   for _, row in ipairs(rows) do
      row.id = tonumber(row.id)
      row.menu_id = tonumber(row.menu_id)
      row.parent_id = tonumber(row.parent_id)
      byId[row.id] = row
   end
   for _, row in ipairs(rows) do
      local seen, current = {}, row
      while current and current.parent_id do
         if seen[current.parent_id] then
            addIssue(issues, "error", "menuParentCycle",
               "Menu item parent relationship contains a cycle", tostring(row.id))
            break
         end
         seen[current.parent_id] = true
         local parent = byId[current.parent_id]
         if not parent then
            addIssue(issues, "error", "menuParentMissing",
               "Menu item parent does not exist", tostring(row.id))
            break
         end
         if parent.menu_id ~= row.menu_id then
            addIssue(issues, "error", "menuParentCrossesMenu",
               "Menu item parent belongs to another menu", tostring(row.id))
            break
         end
         current = parent
      end
   end
end

local function registerDiagnostics(mcp, app, helpers)
   local startedAt = os.time()

   mcp:tool("getHealth", {
      description = "Read safe CMS runtime, database, theme, assets, settings, and storage health details.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      local database = { connected = false, foreignKeys = false }
      local ok, healthErr = pcall(function()
         db.withRead(app, function(conn)
            database.connected = tonumber(db.one(conn, "SELECT 1 ok").ok) == 1
            local fk = db.one(conn, "PRAGMA foreign_keys")
            database.foreignKeys = tonumber(fk.foreign_keys) == 1
            database.sqliteVersion = db.one(conn, "SELECT sqlite_version() version").version
         end)
      end)
      if not ok then database.error = tostring(healthErr) end
      local missing, schemaDetail = schema.missingRequired(app)
      database.schemaValid = not missing
      if missing then database.schemaError = schemaDetail end
      local stat = app.dataIo and app.dataIo:stat((app.dbName or "cms") .. ".sqlite.db")
      if stat then database.bytes = tonumber(stat.size) end

      local activeTheme = app.theme and app.theme.name or app.defaultTheme
      local validTheme, themeErr = theme.validate(app, activeTheme)
      return {
         healthy = database.connected and database.foreignKeys and not missing and validTheme ~= nil,
         checkedAt = os.time(),
         startedAt = startedAt,
         baseUri = app.baseUri,
         database = database,
         theme = {
            name = activeTheme,
            source = app.theme and app.theme.source,
            valid = validTheme ~= nil,
            error = themeErr
          },
          assets = {
             source = app.assetsSource,
             name = app.assetsSource == "zip" and app.assetsZipName or app.assetsDirName,
             packageExists = app.homeIo:stat(app.assetsZipName) ~= nil,
             restartRequired = app.homeIo:stat(app.assetsZipName) ~= nil and app.assetsSource ~= "zip"
          },
         settings = {
            htmxEnabled = settings.isHtmxEnabled(app),
            notFoundEnabled = settings.isNotFoundEnabled(app)
         }
      }
   end)

   mcp:tool("getSchemaInfo", {
      description = "Read the CMS schema version, SQLite version, tables, columns, and indexes without exposing database content.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      return db.withRead(app, function(conn)
         local tables = {}
         for _, tableRow in ipairs(db.rows(conn, [[SELECT name FROM sqlite_master
            WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name]])) do
            local columns = {}
            for _, column in ipairs(db.rows(conn, "PRAGMA table_info(" .. tableRow.name .. ")")) do
               columns[#columns + 1] = {
                  name = column.name,
                  type = column.type,
                  notNull = tonumber(column.notnull) == 1,
                  primaryKey = tonumber(column.pk) ~= 0
               }
            end
            tables[#tables + 1] = { name = tableRow.name, columns = columns }
         end
         local indexes = {}
         for _, row in ipairs(db.rows(conn, [[SELECT name,tbl_name FROM sqlite_master
            WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name]])) do
            indexes[#indexes + 1] = { name = row.name, table = row.tbl_name }
         end
         return helpers.arrays({
            schemaVersion = helpers.schemaVersion,
            sqliteVersion = db.one(conn, "SELECT sqlite_version() version").version,
            tables = tables,
            indexes = indexes
         })
      end)
   end)

   mcp:tool("runIntegrityCheck", {
      description = "Run a bounded read-only integrity check over schema, foreign keys, content enums, redirects, menus, the editable 404 page, and the active theme.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = readAnnotations
   }, function()
      local issues = {}
      local missing, detail = schema.missingRequired(app)
      if missing then addIssue(issues, "error", "schemaInvalid", detail, "database") end
      db.withRead(app, function(conn)
         for _, row in ipairs(db.rows(conn, "PRAGMA foreign_key_check")) do
            addIssue(issues, "error", "foreignKeyViolation",
               "Foreign key constraint violation", tostring(row.table or "database"))
         end
         for _, row in ipairs(db.rows(conn, [[SELECT id,path FROM content
            WHERE type NOT IN ('page','post')
               OR render_mode NOT IN ('html','lsp')
               OR status NOT IN ('draft','published')
               OR cache_policy NOT IN ('default','revalidate','no-cache','no-store')]])) do
            addIssue(issues, "error", "invalidContentEnum",
               "Content has an unsupported type, render mode, status, or cache policy",
               tostring(row.id) .. ":" .. tostring(row.path))
         end
      end)
      redirectIssues(app, issues)
      menuIssues(app, issues)
      if settings.isNotFoundEnabled(app) then
         local row = db.readOne(app, "SELECT status FROM content WHERE type='page' AND path=" ..
            db.quote(settings.notFoundPath(app)))
         if not row then
            addIssue(issues, "error", "notFoundContentMissing",
               "The configured editable 404 page does not exist", settings.notFoundPath(app))
         elseif row.status ~= "published" then
            addIssue(issues, "warning", "notFoundContentDraft",
               "The configured editable 404 page is not published", settings.notFoundPath(app))
         end
      end
      local activeTheme = app.theme and app.theme.name or app.defaultTheme
      local valid, themeErr = theme.validate(app, activeTheme)
      if not valid then
         addIssue(issues, "error", "activeThemeInvalid", tostring(themeErr), activeTheme)
      end
      local errors, warnings = 0, 0
      for _, issue in ipairs(issues) do
         if issue.severity == "error" then errors = errors + 1 else warnings = warnings + 1 end
      end
      return helpers.arrays({
         ok = errors == 0,
         checkedAt = os.time(),
         summary = { errors = errors, warnings = warnings, total = #issues },
         issues = issues
      })
   end)

   mcp:tool("clearCache", {
      description = "Clear runtime-render or persistent page-table caches. This does not delete content or files.",
      inputSchema = {
         type = "object",
         properties = {
            scope = {
               type = "string",
               enum = { "all", "render", "page-tables" },
               default = "all"
            }
         },
         additionalProperties = false
      },
      annotations = mutateAnnotations
   }, function(args)
      local scope = args.scope or "all"
      if (scope == "all" or scope == "render") and app.clearRenderCache then
         app.clearRenderCache()
      end
      if (scope == "all" or scope == "page-tables") and app.clearPageTables then
         app.clearPageTables()
      end
      return { cleared = true, scope = scope, clearedAt = os.time() }
   end)
end

function M.register(mcp, app, helpers)
   registerTaxonomy(mcp, app, helpers)
   registerMenus(mcp, app, helpers)
   registerSettings(mcp, app, helpers)
   registerDiagnostics(mcp, app, helpers)
end

return M
