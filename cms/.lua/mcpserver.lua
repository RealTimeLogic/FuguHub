local FastMCP = require "fastmcp.engine"
local Http = require "fastmcp.http"
local db = appreq "db"
local mcpconfig = appreq "mcpconfig"
local content = appreq "mcpcontent"
local validation = appreq "validation"
local Archive = appreq "mcparchive"
local mcpassets = appreq "mcpassets"
local mcpthemes = appreq "mcpthemes"
local mcphelp = appreq "mcphelp"
local mcpsite = appreq "mcpsite"
local contentpath = appreq "contentpath"
local redirectservice = appreq "redirectservice"

local M = {}

local emptyObjectSchema = {
   type = "object",
   properties = {},
   additionalProperties = false
}

local selectionProperties = {
   ids = {
      type = "array",
      items = { type = "integer", minimum = 1 }
   },
   paths = {
      type = "array",
      items = { type = "string", minLength = 1, maxLength = 2048 }
   }
}

local termSchema = {
   type = "object",
   properties = {
      type = { type = "string", minLength = 1, maxLength = 64 },
      name = { type = "string", minLength = 1, maxLength = 255 },
      slug = { type = "string", minLength = 1, maxLength = 255 },
      description = { type = "string", maxLength = 65536 }
   },
   required = { "type", "name", "slug" },
   additionalProperties = false
}

local contentProperties = {
   type = { type = "string", enum = { "page", "post" } },
   path = {
      type = "string",
      minLength = 1,
      maxLength = 2048,
      description = "Stored content path. For posts, omit the configured blog base; publicPath includes it."
   },
   title = { type = "string", minLength = 1, maxLength = 1024 },
   bodyHtml = { type = "string", maxLength = 4 * 1024 * 1024 },
   renderMode = { type = "string", enum = { "html", "lsp" }, default = "html" },
   publish = {
      type = "boolean",
      default = false
   },
   metaDescription = { type = "string", maxLength = 65536, default = "" },
   headHtml = { type = "string", maxLength = 1024 * 1024, default = "" },
   cachePolicy = {
      type = "string",
      enum = { "default", "revalidate", "no-cache", "no-store" },
      default = "default"
   },
   terms = {
      type = "array",
      items = termSchema,
      default = {}
   }
}

local function registerRuntimeTools(mcp, app)
   mcp:tool("readRuntimeTrace", {
      description = "Return and clear the bounded server-global BAS trace buffer. Messages cannot be reliably attributed to this CMS instance.",
      inputSchema = emptyObjectSchema,
      annotations = { readOnlyHint = true, idempotentHint = true }
   }, function()
      if not app.runtimeTrace or type(app.runtimeTrace.read) ~= "function" then
         return {
            trace = "", bytes = 0, messageCount = 0, bufferSize = 0,
            enabled = false, cleared = true, scope = "server-global",
            cmsAttributionReliable = false
         }
      end
      return app.runtimeTrace.read()
   end)
end

local function toolError(message, code, details)
   details = details or {}
   details.code = code or details.code or "cmsOperationFailed"
   return FastMCP.error(message, details)
end

local function arrays(value)
   if type(value) ~= "table" then return value end
   for key, child in pairs(value) do
      if type(child) == "table" then value[key] = arrays(child) end
   end
   if next(value) == nil or #value > 0 then return FastMCP.array(value) end
   return value
end

local function clearRuntime(app)
   if app.invalidateRuntime then
      app.invalidateRuntime()
      return
   end
   if app.clearPageTables then app.clearPageTables() end
   if app.clearRenderCache then app.clearRenderCache() end
end

local function effectiveMenuUrl(app, row)
   if row.content_type and row.content_path then
      return assert(contentpath.publicPath(app, row.content_type, row.content_path))
   end
   return row.url
end

local function inferParentId(app, conn, menuId, url)
   local found
   for _, row in ipairs(db.rows(conn, [[SELECT mi.id,mi.url,c.type content_type,c.path content_path
      FROM menu_items mi LEFT JOIN content c ON c.id=mi.content_id
      WHERE mi.menu_id=]] .. tonumber(menuId) ..
      " AND COALESCE(mi.hidden,0)=0 ORDER BY LENGTH(mi.url) DESC,mi.id")) do
      local candidate = validation.url(effectiveMenuUrl(app, row), true)
      if candidate and not candidate:find("^[%w][%w%+%-%.]*:") and candidate:sub(1, 2) ~= "//" then
         local prefix = candidate:sub(-1) == "/" and candidate or candidate .. "/"
         if url ~= candidate and url:sub(1, #prefix) == prefix then
            found = tonumber(row.id)
            break
         end
      end
   end
   return found
end

local function menuItemResult(app, row)
   local parentId = tonumber(row.parent_id)
   local contentId = tonumber(row.content_id)
   return {
      id = tonumber(row.id),
      menuId = tonumber(row.menu_id),
      parentId = parentId or ba.json.null,
      topLevel = parentId == nil,
      contentId = contentId or ba.json.null,
      label = row.label,
      url = effectiveMenuUrl(app, row),
      position = tonumber(row.position),
      hidden = tonumber(row.hidden or 0) ~= 0
   }
end

local function registerContentTools(mcp, app)
   mcp:tool("getCmsInfo", {
      description = "Read mount-aware CMS metadata, active settings, theme, and content counts. This tool is read-only.",
      inputSchema = emptyObjectSchema,
      annotations = { readOnlyHint = true, idempotentHint = true }
   }, function()
      return db.withRead(app, function(conn)
         local function count(sql)
            return tonumber(db.one(conn, sql).count)
         end
         return {
            name = "FuguHub",
            baseUri = app.baseUri,
            mcpPath = app.url("/mcp/"),
            activeTheme = app.theme and app.theme.name or app.defaultTheme,
            themeContract = app.theme and app.theme.contract,
            settings = {
               htmxEnabled = app.settings.htmxEnabled == true,
               smqEnabled = app.settings.smqEnabled == true,
               blogBasePath = app.settings.blogBasePath,
               notFoundEnabled = app.settings.notFoundEnabled == true,
               notFoundPath = app.settings.notFoundPath
            },
            counts = {
               content = count("SELECT COUNT(*) count FROM content"),
               pages = count("SELECT COUNT(*) count FROM content WHERE type='page'"),
               posts = count("SELECT COUNT(*) count FROM content WHERE type='post'"),
               drafts = count("SELECT COUNT(*) count FROM content WHERE status='draft'")
            }
         }
      end)
   end)

   mcp:tool("listContent", {
      description = "Search and page through CMS content with stable opaque cursors. Bodies and taxonomy assignments are omitted unless explicitly requested.",
      inputSchema = {
         type = "object",
         properties = {
            type = { type = "string", enum = { "page", "post" } },
            status = { type = "string", enum = { "draft", "published" } },
            renderMode = { type = "string", enum = { "html", "lsp" } },
            pathPrefix = {
               type = "string",
               minLength = 1,
               maxLength = 2048,
               description = "Stored path prefix. Post paths do not include the configured blog base."
            },
            query = { type = "string", minLength = 1, maxLength = 1024 },
            searchBody = { type = "boolean", default = false },
            termType = { type = "string", minLength = 1, maxLength = 64 },
            termSlug = { type = "string", minLength = 1, maxLength = 255 },
            updatedAfter = { type = "integer", minimum = 0 },
            updatedBefore = { type = "integer", minimum = 0 },
            sort = {
               type = "string",
               enum = { "updatedAt", "createdAt", "title", "path", "id" },
               default = "updatedAt"
            },
            direction = { type = "string", enum = { "asc", "desc" }, default = "desc" },
            cursor = { type = "string", minLength = 3, maxLength = 4096 },
            limit = { type = "integer", minimum = 1, maximum = 500, default = 100 },
            includeBody = { type = "boolean", default = false },
            includeTerms = { type = "boolean", default = false },
            includeTotal = { type = "boolean", default = false }
         },
         additionalProperties = false
      },
      annotations = { readOnlyHint = true, idempotentHint = true }
   }, function(args)
      local result, err = content.list(app, args)
      if not result then return toolError(err, "contentListFailed") end
      return arrays(result)
   end)

   mcp:tool("validateContent", {
      description = "Validate HTML/LSP content against the CMS safety, size, render-mode, and internal-link rules without saving or executing it.",
      inputSchema = {
         type = "object",
         properties = {
            bodyHtml = { type = "string", maxLength = 4 * 1024 * 1024 },
            renderMode = { type = "string", enum = { "html", "lsp" }, default = "html" },
            title = { type = "string", maxLength = 1024 }
         },
         required = { "bodyHtml" },
         additionalProperties = false
      },
      annotations = { readOnlyHint = true, idempotentHint = true }
   }, function(args)
      local result, err = content.validate(app, args)
      if not result then return toolError(err, "contentValidationFailed") end
      return arrays(result)
   end)

   mcp:tool("getContent", {
      description = "Read one CMS page or post by numeric id or clean CMS path.",
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            path = { type = "string", minLength = 1, maxLength = 2048 },
            type = { type = "string", enum = { "page", "post" } }
         },
         additionalProperties = false
      },
      annotations = { readOnlyHint = true, idempotentHint = true }
   }, function(args)
      local result, err = content.get(app, args)
      if not result then return toolError(err, "contentNotFound") end
      return arrays(result)
   end)

   mcp:tool("getContentBatch", {
      description = "Read up to 100 known content ids or paths in one request. Bodies and taxonomy assignments are optional.",
      inputSchema = {
         type = "object",
         properties = {
            ids = {
               type = "array",
               items = { type = "integer", minimum = 1 }
            },
            paths = {
               type = "array",
               items = { type = "string", minLength = 1, maxLength = 2048 }
            },
            includeBody = { type = "boolean", default = false },
            includeTerms = { type = "boolean", default = false }
         },
         additionalProperties = false
      },
      annotations = { readOnlyHint = true, idempotentHint = true }
   }, function(args)
      local result, err = content.getBatch(app, args)
      if not result then return toolError(err, "contentBatchFailed") end
      return arrays(result)
   end)

   mcp:tool("getContentDependencies", {
      description = "Inspect menu items, redirects, child paths, and required-page state before moving or permanently deleting content.",
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            path = { type = "string", minLength = 1, maxLength = 2048 },
            type = { type = "string", enum = { "page", "post" } }
         },
         additionalProperties = false
      },
      annotations = { readOnlyHint = true, idempotentHint = true }
   }, function(args)
      local result, err = content.dependencies(app, args)
      if not result then return toolError(err, "contentNotFound") end
      return arrays(result)
   end)

   mcp:tool("createContent", {
      description = [[Create a page or post. Use this only when the user clearly asked to create new content; if create versus update is ambiguous, ask first. bodyHtml must be a structurally valid HTML fragment. Before calling, auto-fix harmless structural mistakes, reject document wrappers, scripts, inline event handlers, and unsafe URL schemes, and convert user-supplied Markdown to HTML. New content is always draft unless publish=true, and publish=true may be sent only when the user explicitly asked to publish. Set renderMode=lsp only when the user explicitly requested executable LSP tags.]],
      inputSchema = {
         type = "object",
         properties = contentProperties,
         required = { "type", "path", "title", "bodyHtml" },
         additionalProperties = false
      }
   }, function(args)
      local result, err = content.create(app, args)
      if not result then return toolError(err, "contentCreateFailed") end
      return arrays(result)
   end)

   mcp:tool("copyContent", {
      description = [[Copy an existing page or post to a new path. The copy is a draft unless publish=true and the user explicitly requested publication. Copying trusted executable LSP requires allowLsp=true after explicit user approval.]],
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            path = { type = "string", minLength = 1, maxLength = 2048 },
            type = { type = "string", enum = { "page", "post" } },
            newPath = { type = "string", minLength = 1, maxLength = 2048 },
            title = { type = "string", minLength = 1, maxLength = 1024 },
            publish = { type = "boolean", default = false },
            allowLsp = { type = "boolean", default = false }
         },
         required = { "newPath" },
         additionalProperties = false
      }
   }, function(args)
      local result, err, code = content.copy(app, args)
      if not result then return toolError(err, code or "contentCopyFailed") end
      return arrays(result)
   end)

   local updateProperties = {}
   for key, value in pairs(contentProperties) do
      local copy = {}
      for field, fieldValue in pairs(value) do
         if field ~= "default" or key == "publish" then copy[field] = fieldValue end
      end
      updateProperties[key] = copy
   end
   updateProperties.id = { type = "integer", minimum = 1 }
   updateProperties.existingPath = { type = "string", minLength = 1, maxLength = 2048 }
   updateProperties.existingType = { type = "string", enum = { "page", "post" } }
   updateProperties.publish = nil
   updateProperties.expectedUpdatedAt = { type = "integer", minimum = 1 }
   mcp:tool("updateContent", {
      description = [[Update an existing page or post without changing its publication status. Use this only when the user clearly identified existing content; if create versus update or the target is ambiguous, ask first. Validate and auto-fix the HTML fragment before calling under the same safety rules as createContent. Send expectedUpdatedAt from the latest getContent result to reject stale writes. Use setContentStatus separately for an explicit publish or unpublish request.]],
      inputSchema = {
         type = "object",
         properties = updateProperties,
         additionalProperties = false
      }
   }, function(args)
      local result, err, code, details = content.update(app, args)
      if not result then return toolError(err, code or "contentUpdateFailed", details) end
      return arrays(result)
   end)

   mcp:tool("setContentStatus", {
      description = [[Publish or unpublish existing content without resending its body. Call this only when the user explicitly requested the status change. Send expectedUpdatedAt from the latest getContent result to reject stale writes.]],
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            path = { type = "string", minLength = 1, maxLength = 2048 },
            type = { type = "string", enum = { "page", "post" } },
            status = { type = "string", enum = { "draft", "published" } },
            expectedUpdatedAt = { type = "integer", minimum = 1 }
         },
         required = { "status" },
         additionalProperties = false
      },
      annotations = { readOnlyHint = false, destructiveHint = false }
   }, function(args)
      local result, err, code, details = content.setStatus(app, args)
      if not result then return toolError(err, code or "contentStatusFailed", details) end
      return arrays(result)
   end)

   mcp:tool("deleteContent", {
      description = [[Permanently delete one page or post. Trash is not available in this CMS version. Read getContentDependencies first and ask the user for explicit confirmation and how to handle linked menu items and related redirects. Child content is never deleted automatically.]],
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            path = { type = "string", minLength = 1, maxLength = 2048 },
            type = { type = "string", enum = { "page", "post" } },
            expectedUpdatedAt = { type = "integer", minimum = 1 },
            confirmed = { type = "boolean" },
            menuItemsAction = { type = "string", enum = { "preserve", "delete" } },
            redirectsAction = { type = "string", enum = { "preserve", "delete" } }
         },
         required = { "confirmed" },
         additionalProperties = false
      },
      annotations = { readOnlyHint = false, destructiveHint = true }
   }, function(args)
      local result, err, code, details = content.deletePermanent(app, args)
      if not result then return toolError(err, code or "contentDeleteFailed", details) end
      return arrays(result)
   end)
end

local function registerMenuTools(mcp, app)
   mcp:tool("listMenus", {
      description = "List every menu and menu item, including hidden entries and parent relationships.",
      inputSchema = emptyObjectSchema,
      annotations = { readOnlyHint = true, idempotentHint = true }
   }, function()
      local result = db.withRead(app, function(conn)
         local menus = db.rows(conn, "SELECT * FROM menus ORDER BY name")
         for _, menu in ipairs(menus) do
            menu.id = tonumber(menu.id)
            menu.items = db.rows(conn, [[SELECT mi.*,c.type content_type,c.path content_path
               FROM menu_items mi LEFT JOIN content c ON c.id=mi.content_id
               WHERE mi.menu_id=]] .. menu.id ..
               " ORDER BY COALESCE(mi.parent_id,0),mi.position,mi.id")
            for index, item in ipairs(menu.items) do
               menu.items[index] = menuItemResult(app, item)
            end
         end
         return menus
      end)
      return arrays({ menus = result })
   end)

   mcp:tool("createMenuItem", {
      description = "Create a menu item. Set topLevel=true to force a root item. Otherwise parentId is optional and the CMS infers the closest parent whose URL is a prefix when it is omitted.",
      inputSchema = {
         type = "object",
         properties = {
            menuSlug = { type = "string", minLength = 1, maxLength = 255, default = "primary" },
            label = { type = "string", minLength = 1, maxLength = 1024 },
            url = { type = "string", minLength = 1, maxLength = 2048 },
            parentId = { type = "integer", minimum = 1 },
            topLevel = { type = "boolean", default = false },
            contentId = { type = "integer", minimum = 1 },
            position = { type = "integer", default = 0 },
            hidden = { type = "boolean", default = false }
         },
         required = { "label", "url" },
         additionalProperties = false
      }
   }, function(args)
      local url, err = validation.url(args.url, true)
      if not url then return toolError(err, "invalidMenuUrl") end
      local label = validation.trim(args.label)
      if label == "" then return toolError("Menu label is required", "invalidMenuLabel") end
      local created
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         local menu = db.one(conn, "SELECT id FROM menus WHERE slug=" .. db.quote(args.menuSlug or "primary"))
         if not menu then error("Menu was not found", 2) end
         local menuId = tonumber(menu.id)
         local parentId
         if args.topLevel == true then
            parentId = nil
         elseif args.parentId ~= nil then
            parentId = args.parentId
         else
            parentId = inferParentId(app, conn, menuId, url)
         end
         parentId, err = validation.menuParent(conn, menuId, parentId)
         if err then error(err, 2) end
         local contentId = args.contentId and tonumber(args.contentId)
         if contentId and not db.one(conn, "SELECT id FROM content WHERE id=" .. contentId) then
            error("Linked content was not found", 2)
         end
         local parentSql = parentId and tostring(parentId) or "NULL"
         local contentSql = contentId and tostring(contentId) or "NULL"
         local inserted, insertErr = conn:execute("INSERT INTO menu_items(menu_id,parent_id,content_id,label,url,position,hidden) VALUES(" ..
            menuId .. "," .. parentSql .. "," .. contentSql .. "," .. db.quote(label) .. "," .. db.quote(url) .. "," ..
            math.floor(tonumber(args.position) or 0) .. "," .. (args.hidden and 1 or 0) .. ")")
         if not inserted then error(tostring(insertErr), 2) end
         created = db.one(conn, [[SELECT mi.*,c.type content_type,c.path content_path
            FROM menu_items mi LEFT JOIN content c ON c.id=mi.content_id
            WHERE mi.id=last_insert_rowid()]])
      end)
      if not ok then return toolError(writeErr, "menuCreateFailed") end
      clearRuntime(app)
      return menuItemResult(app, created)
   end)

   mcp:tool("updateMenuItem", {
      description = "Update a menu item, including its hidden state and parent relationship. Set topLevel=true to clear the current parent explicitly.",
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            label = { type = "string", minLength = 1, maxLength = 1024 },
            url = { type = "string", minLength = 1, maxLength = 2048 },
            parentId = { type = "integer", minimum = 1 },
            topLevel = { type = "boolean" },
            position = { type = "integer" },
            hidden = { type = "boolean" }
         },
         required = { "id" },
         additionalProperties = false
      }
   }, function(args)
      local updated
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         local row = db.one(conn, "SELECT * FROM menu_items WHERE id=" .. tonumber(args.id))
         if not row then error("Menu item was not found", 2) end
         local label = args.label ~= nil and validation.trim(args.label) or row.label
         if label == "" then error("Menu label is required", 2) end
         local url, err = validation.url(args.url ~= nil and args.url or row.url, true)
         if not url then error(err, 2) end
         local parentId
         if args.topLevel == true then
            parentId = nil
         elseif args.parentId ~= nil then
            parentId = args.parentId
         else
            parentId = tonumber(row.parent_id)
         end
         parentId, err = validation.menuParent(conn, row.menu_id, parentId, row.id)
         if err then error(err, 2) end
         local parentSql = parentId and tostring(parentId) or "NULL"
         local position = args.position ~= nil and math.floor(args.position) or tonumber(row.position)
         local hidden = args.hidden ~= nil and args.hidden or tonumber(row.hidden or 0) ~= 0
         local changed, changeErr = conn:execute("UPDATE menu_items SET label=" .. db.quote(label) ..
            ",url=" .. db.quote(url) .. ",parent_id=" .. parentSql .. ",position=" .. position ..
            ",hidden=" .. (hidden and 1 or 0) .. " WHERE id=" .. tonumber(row.id))
         if not changed then error(tostring(changeErr), 2) end
         updated = db.one(conn, [[SELECT mi.*,c.type content_type,c.path content_path
            FROM menu_items mi LEFT JOIN content c ON c.id=mi.content_id
            WHERE mi.id=]] .. tonumber(row.id))
      end)
      if not ok then return toolError(writeErr, "menuUpdateFailed") end
      clearRuntime(app)
      return menuItemResult(app, updated)
   end)

   mcp:tool("deleteMenuItem", {
      description = "Delete one menu item. Ask for confirmation before calling because this mutation is destructive.",
      inputSchema = {
         type = "object",
         properties = {
            id = { type = "integer", minimum = 1 },
            confirmed = { type = "boolean" }
         },
         required = { "id", "confirmed" },
         additionalProperties = false
      },
      annotations = { destructiveHint = true }
   }, function(args)
      if args.confirmed ~= true then
         return toolError("Explicit confirmation is required", "confirmationRequired")
      end
      local ok, err = pcall(db.withWrite, app, function(conn)
         if not db.one(conn, "SELECT id FROM menu_items WHERE id=" .. tonumber(args.id)) then
            error("Menu item was not found", 2)
         end
         local deleted, deleteErr = conn:execute("DELETE FROM menu_items WHERE id=" .. tonumber(args.id))
         if not deleted then error(tostring(deleteErr), 2) end
      end)
      if not ok then return toolError(err, "menuDeleteFailed") end
      clearRuntime(app)
      return { deleted = true, id = args.id }
   end)
end

local function registerRedirectTools(mcp, app)
   mcp:tool("listRedirects", {
      description = "List configured CMS redirects.",
      inputSchema = emptyObjectSchema,
      annotations = { readOnlyHint = true, idempotentHint = true }
   }, function()
      local rows = db.readRows(app, "SELECT * FROM redirects ORDER BY from_path")
      for _, row in ipairs(rows) do
         row.id = tonumber(row.id)
         row.status_code = tonumber(row.status_code)
      end
      return arrays({ redirects = rows })
   end)

   mcp:tool("setRedirect", {
      description = "Create or replace a redirect by its source path.",
      inputSchema = {
         type = "object",
         properties = {
            fromPath = { type = "string", minLength = 1, maxLength = 2048 },
            toPath = { type = "string", minLength = 1, maxLength = 2048 },
            statusCode = { type = "integer", enum = { 301, 302 }, default = 302 }
         },
         required = { "fromPath", "toPath" },
         additionalProperties = false
      }
   }, function(args)
      local fromPath, err = validation.path(args.fromPath)
      if not fromPath then return toolError(err, "invalidRedirectPath") end
      local toPath
      toPath, err = validation.url(args.toPath, true)
      if not toPath then return toolError(err, "invalidRedirectTarget") end
      local status
      status, err = validation.redirectStatus(args.statusCode)
      if not status then return toolError(err, "invalidRedirectStatus") end
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         local saved, saveErr = redirectservice.saveConn(conn, fromPath, toPath, status)
         if not saved then error(tostring(saveErr), 2) end
      end)
      if not ok then return toolError(writeErr, "redirectSaveFailed") end
      clearRuntime(app)
      return { fromPath = fromPath, toPath = toPath, statusCode = status }
   end)

   mcp:tool("deleteRedirect", {
      description = "Delete a redirect by source path. Ask for confirmation before calling.",
      inputSchema = {
         type = "object",
         properties = {
            fromPath = { type = "string", minLength = 1, maxLength = 2048 },
            confirmed = { type = "boolean" }
         },
         required = { "fromPath", "confirmed" },
         additionalProperties = false
      },
      annotations = { destructiveHint = true }
   }, function(args)
      if args.confirmed ~= true then
         return toolError("Explicit confirmation is required", "confirmationRequired")
      end
      local path, err = validation.path(args.fromPath)
      if not path then return toolError(err, "invalidRedirectPath") end
      local ok, writeErr = pcall(db.withWrite, app, function(conn)
         if not db.one(conn, "SELECT id FROM redirects WHERE from_path=" .. db.quote(path)) then
            error("Redirect was not found", 2)
         end
         local deleted, deleteErr = conn:execute("DELETE FROM redirects WHERE from_path=" .. db.quote(path))
         if not deleted then error(tostring(deleteErr), 2) end
      end)
      if not ok then return toolError(writeErr, "redirectDeleteFailed") end
      clearRuntime(app)
      return { deleted = true, fromPath = path }
   end)
end

local function registerTransferTools(mcp, app, archive)
   local selectionSchema = {
      type = "object",
      properties = selectionProperties,
      additionalProperties = false
   }
   mcp:tool("prepareContentExport", {
      description = "Prepare a one-time ZIP download containing selected pages/posts and all content metadata, including taxonomy assignments.",
      inputSchema = selectionSchema
   }, function(args, ctx)
      if not ctx.serverOrigin then return toolError("Cannot derive this server origin", "serverOriginUnavailable") end
      local result, err, code = archive:prepareExport(app, args, ctx.serverOrigin)
      if not result then return toolError(err, code) end
      return arrays(result)
   end)

   mcp:tool("prepareContentTransfer", {
      description = "Prepare an immutable one-time ZIP snapshot for direct transfer to another FuguHub MCP server. Relay the returned descriptor without exposing or logging transferTicket.",
      inputSchema = selectionSchema
   }, function(args, ctx)
      if not ctx.serverOrigin then return toolError("Cannot derive this server origin", "serverOriginUnavailable") end
      local result, err, code = archive:prepareTransfer(app, args, ctx.serverOrigin)
      if not result then return toolError(err, code) end
      return arrays(result)
   end)

   mcp:tool("importContentTransfer", {
      description = [[Import a prepared one-time ZIP transfer from another FuguHub server. First call without confirmedSourceOrigin so this tool can return the exact source origin that must be shown to and confirmed by the user. If conflicts are returned, ask the included question and collect one decision per path: skip, replace, or importDraft with a user-provided newPath. Never choose for the user. Imports remain drafts unless publish=true, which may be sent only when the user explicitly asked to publish imported source content. Never forward either server's persistent MCP bearer token.]],
      inputSchema = {
         type = "object",
         properties = {
            transferUrl = { type = "string", minLength = 1, maxLength = 2048 },
            transferTicket = { type = "string", minLength = 32, maxLength = 32 },
            expectedBytes = { type = "integer", minimum = 1, maximum = 8 * 1024 * 1024 },
            digest = { type = "string", minLength = 71, maxLength = 71 },
            expiresAt = { type = "integer", minimum = 1 },
            expiresInSeconds = { type = "integer", minimum = 1 },
            compression = { type = "string", enum = { "none" } },
            items = {
               type = "array",
               items = {
                  type = "object",
                  properties = {
                     path = { type = "string", minLength = 1, maxLength = 2048 },
                     type = { type = "string", enum = { "page", "post" } },
                     title = { type = "string", minLength = 1, maxLength = 1024 },
                     status = { type = "string", enum = { "draft", "published" } }
                  },
                  required = { "path", "type", "title", "status" },
                  additionalProperties = false
               }
            },
            confirmedSourceOrigin = { type = "string", maxLength = 2048 },
            decisions = {
               type = "array",
               items = {
                  type = "object",
                   properties = {
                      path = { type = "string", minLength = 1, maxLength = 2048 },
                      type = { type = "string", enum = { "page", "post" } },
                      action = { type = "string", enum = { "skip", "replace", "importDraft" } },
                     newPath = { type = "string", maxLength = 2048 }
                  },
                   required = { "path", "type", "action" },
                  additionalProperties = false
               },
               default = {}
            },
            publish = { type = "boolean", default = false }
         },
         required = { "transferUrl", "transferTicket", "expectedBytes", "digest", "items" },
         additionalProperties = false
      }
   }, function(args)
      local result, err, code, details = archive:importTransfer(app, args)
      if not result then return toolError(err, code, details) end
      return arrays(result)
   end)
end

local function isLoopbackAuthority(authority)
   authority = tostring(authority or ""):lower()
   return authority == "localhost" or authority:match("^localhost:%d+$") ~= nil or
      authority == "127.0.0.1" or authority:match("^127%.0%.0%.1:%d+$") ~= nil or
      authority == "[::1]" or authority:match("^%[::1%]:%d+$") ~= nil
end

local function isLoopbackOrigin(origin)
   local authority = tostring(origin or ""):match("^https?://(.+)$")
   return authority ~= nil and isLoopbackAuthority(authority)
end

local function authorize(app, origin, cmd)
   if origin ~= nil then
      local host = cmd:header("Host")
      local scheme = cmd:issecure() and "https" or "http"
      local sameOrigin = host and origin:lower() == (scheme .. "://" .. host):lower()
      local loopbackInspector = isLoopbackAuthority(host) and isLoopbackOrigin(origin)
      if not sameOrigin and not loopbackInspector then return false, "Origin forbidden" end
   end
   if cmd:method() == "OPTIONS" then return true end
   local header = cmd:header("Authorization")
   if not mcpconfig.secureEqual(header, "Bearer " .. tostring(app.mcpToken or "")) then
      return false, "Unauthorized"
   end
   return true
end

function M.install(app)
   local archive = Archive.create(app)
   archive.format = Archive.format
   archive.version = Archive.version
   local mcp = FastMCP.create {
      name = "FuguHub",
      version = mcphelp.apiVersion,
      strictSchemas = true,
      instructions = mcphelp.instructions(app)
   }
   registerContentTools(mcp, app)
   registerMenuTools(mcp, app)
   registerRedirectTools(mcp, app)
   registerTransferTools(mcp, app, archive)
   registerRuntimeTools(mcp, app)
   local assets = mcpassets.register(mcp, app)
   local themes = mcpthemes.register(mcp, app, {
      toolError = toolError,
      arrays = arrays
   })
   mcpsite.register(mcp, app, {
      toolError = toolError,
      arrays = arrays,
      clearRuntime = clearRuntime,
      schemaVersion = mcphelp.schemaVersion
   })
   mcphelp.register(mcp, app, archive, toolError, arrays)

   local transport = Http.streamable(mcp, {
      stateful = true,
      enableGetStream = true,
      protocolVersion = "2025-11-25",
      requireStrictAccept = false,
      allowNonSseGet = true,
      trustForwardedHeaders = false,
      maxRequestBodyBytes = 5 * 1024 * 1024,
      maxResponseBytes = 6 * 1024 * 1024,
      maxNotificationBytes = 256 * 1024,
      maxSessions = 16,
      maxStreamsPerSession = 2,
      sessionIdleTimeoutSeconds = 30 * 60,
      sessionMaxLifetimeSeconds = 8 * 60 * 60,
      authorizeOrigin = function(origin, cmd)
         return authorize(app, origin, cmd)
      end
   })

   local api = {
      archive = archive,
      assets = assets,
      themes = themes,
      transport = transport,
      mcp = mcp
   }

   function api:handle(_ENV, relpath)
      local path = tostring(relpath or ""):gsub("^/+", ""):gsub("%?.*$", "")
      if path == "transfer" then
         archive:handleTransfer(_ENV.request, _ENV.response)
         return true
      end
      if not mcpconfig.enabled(app) then
         local body = ba.json.encode({
            error = "MCP server is disabled",
            detail = app.mcpTokenError or "Configure an MCP token in the CMS admin panel"
         })
         _ENV.response:setstatus(503)
         _ENV.response:setcontenttype("application/json; charset=utf-8")
         _ENV.response:setheader("Cache-Control", "no-store")
         _ENV.response:send(body)
         return true
      end
      if path == "archive" then
         local authorized = mcpconfig.secureEqual(_ENV.request:header("Authorization"),
            "Bearer " .. app.mcpToken)
         archive:handleArchive(_ENV.request, _ENV.response, authorized)
         return true
      end
      if path == "assets" then
         local authorized = mcpconfig.secureEqual(_ENV.request:header("Authorization"),
            "Bearer " .. app.mcpToken)
         assets:handle(_ENV.request, _ENV.response, authorized)
         return true
      end
      if path == "themes" then
         local authorized = mcpconfig.secureEqual(_ENV.request:header("Authorization"),
            "Bearer " .. app.mcpToken)
         themes:handle(_ENV.request, _ENV.response, authorized)
         return true
      end
      if path == "" then
         transport:handle(_ENV.request)
         return true
      end
      return false
   end

   function api:close()
      archive:close()
      assets:close()
      themes:close()
   end

   app.mcp = api
   return api
end

function M.new(app)
   local api = assert(app.mcp, "MCP API is not installed")
   return function(_ENV, relpath)
      return api:handle(_ENV, relpath)
   end
end

return M
