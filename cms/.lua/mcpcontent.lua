local db = appreq "db"
local validation = appreq "validation"
local htmlfragment = appreq "htmlfragment"
local contentpath = appreq "contentpath"
local publicContent = appreq "content"

local M = {}
local clearRuntime

local function exec(conn, sql)
   local ok, err = conn:execute(sql)
   if not ok then error(tostring(err), 2) end
   return ok
end

local function requireText(value, label, maxLength)
   value = validation.trim(value)
   if value == "" then return nil, label .. " is required" end
   if #value > maxLength then return nil, label .. " is too long" end
   return value
end

local function contentType(value)
   value = validation.trim(value)
   if value ~= "page" and value ~= "post" then
      return nil, "Content type must be page or post"
   end
   return value
end

local function renderMode(value)
   value = validation.trim(value)
   if value == "" then value = "html" end
   if value ~= "html" and value ~= "lsp" then
      return nil, "Render mode must be html or lsp"
   end
   return value
end

local function cachePolicy(value)
   value = validation.trim(value)
   if value == "" then value = "default" end
   if value ~= "default" and value ~= "revalidate" and value ~= "no-cache" and value ~= "no-store" then
      return nil, "Cache policy must be default, revalidate, no-cache, or no-store"
   end
   return value
end

local function contentStatus(value)
   value = validation.trim(value)
   if value ~= "draft" and value ~= "published" then
      return nil, "Status must be draft or published"
   end
   return value
end

local function unsafeHtml(body)
   local inspected, err = htmlfragment.inspect(body)
   if not inspected then return err end
   return nil, inspected
end

local function validateBody(app, body, mode, title)
   body = tostring(body or "")
   if #body > 4 * 1024 * 1024 then return nil, "Content body exceeds 4 MiB" end
   local err, inspected = unsafeHtml(body)
   if err then return nil, err end
   local hasLsp = body:find("<?lsp", 1, true) ~= nil
   if hasLsp and mode ~= "lsp" then
      return nil, "Content contains LSP tags; set renderMode to lsp only when the user explicitly requested executable LSP"
   end
   if mode == "lsp" and not hasLsp then
      return nil, "renderMode lsp requires an explicit LSP tag in the content"
   end

   local warnings, seen = {}, {}
   local function checkUrl(attribute, url)
      local path = url:match("^(/[^?#]*)")
      if path and not seen[path] and not path:match("^//") then
         seen[path] = true
         local normalized = validation.path(path)
         if normalized then
            local exists = publicContent.byPath(app, normalized)
            if not exists and attribute:lower() == "href" then
               warnings[#warnings + 1] = "Internal link does not match CMS content: " .. path
            end
         end
      end
   end
   for _, item in ipairs(inspected.urls) do
      checkUrl(item.attribute, item.value)
   end
   local contract = app.theme and app.theme.contract
   if contract and contract.rendersContentTitle == true then
      local heading = tostring(contract.titleElement or "h1"):lower()
      local count = 0
      for _, tag in ipairs(inspected.tags) do
         if tag == heading then count = count + 1 end
      end
      if count > 0 then
         warnings[#warnings + 1] = "The active theme renders content.title as <" .. heading ..
            ">; bodyHtml contains " .. count .. " additional <" .. heading .. "> element" ..
            (count == 1 and "" or "s")
      end
      if title and title ~= "" and body:lower():find("<" .. heading, 1, true) then
         warnings[#warnings + 1] = "When importing Markdown, promote the first H1 to title and omit it from bodyHtml"
      end
   end
   return body, warnings
end

local function termInput(term)
   if type(term) ~= "table" then return nil, "Each taxonomy term must be an object" end
   local kind, err = requireText(term.type, "Term type", 64)
   if not kind then return nil, err end
   local name
   name, err = requireText(term.name, "Term name", 255)
   if not name then return nil, err end
   local slug
   slug, err = requireText(term.slug, "Term slug", 255)
   if not slug then return nil, err end
   if not slug:match("^[%w][%w%-_]*$") then return nil, "Term slug contains invalid characters" end
   return {
      type = kind,
      name = name,
      slug = slug,
      description = tostring(term.description or "")
   }
end

local function normalizeTerms(terms)
   local out = {}
   for _, value in ipairs(terms or {}) do
      local term, err = termInput(value)
      if not term then return nil, err end
      out[#out + 1] = term
   end
   return out
end

local function replaceTerms(conn, contentId, terms)
   exec(conn, "DELETE FROM content_terms WHERE content_id=" .. tonumber(contentId))
   for _, term in ipairs(terms) do
      exec(conn, "INSERT OR IGNORE INTO terms(type,name,slug,description) VALUES(" ..
         db.quote(term.type) .. "," .. db.quote(term.name) .. "," ..
         db.quote(term.slug) .. "," .. db.quote(term.description) .. ")")
      exec(conn, "UPDATE terms SET name=" .. db.quote(term.name) ..
         ",description=" .. db.quote(term.description) ..
         " WHERE type=" .. db.quote(term.type) .. " AND slug=" .. db.quote(term.slug))
      local row = db.one(conn, "SELECT id FROM terms WHERE type=" .. db.quote(term.type) ..
         " AND slug=" .. db.quote(term.slug))
      exec(conn, "INSERT OR IGNORE INTO content_terms(content_id,term_id) VALUES(" ..
         tonumber(contentId) .. "," .. tonumber(row.id) .. ")")
   end
end

local function rowTerms(conn, id)
   return db.rows(conn, [[SELECT t.type,t.name,t.slug,t.description
FROM terms t JOIN content_terms ct ON ct.term_id=t.id
WHERE ct.content_id=]] .. tonumber(id) .. " ORDER BY t.type,t.name")
end

local function termsForRows(conn, rows)
   local ids, grouped = {}, {}
   for _, row in ipairs(rows) do
      local id = tonumber(row.id)
      ids[#ids + 1] = tostring(id)
      grouped[id] = {}
   end
   if #ids == 0 then return grouped end
   for _, term in ipairs(db.rows(conn, [[SELECT ct.content_id,t.type,t.name,t.slug,t.description
FROM content_terms ct JOIN terms t ON t.id=ct.term_id
WHERE ct.content_id IN (]] .. table.concat(ids, ",") ..
      ") ORDER BY ct.content_id,t.type,t.name")) do
      local contentId = tonumber(term.content_id)
      term.content_id = nil
      grouped[contentId][#grouped[contentId] + 1] = term
   end
   return grouped
end

local function serialize(app, conn, row)
   if not row then return nil end
   return {
      id = tonumber(row.id),
      type = row.type,
      path = row.path,
      publicPath = assert(contentpath.publicPath(app, row.type, row.path)),
      title = row.title,
      bodyHtml = row.body_html,
      renderMode = row.render_mode,
      status = row.status,
      createdAt = tonumber(row.created_at),
      updatedAt = tonumber(row.updated_at),
      metaDescription = row.meta_description or "",
      headHtml = row.head_html or "",
      cachePolicy = row.cache_policy or "default",
      terms = rowTerms(conn, row.id)
   }
end

local function serializeListRow(app, row, includeBody, rowTermList)
   local item = {
      id = tonumber(row.id),
      type = row.type,
      path = row.path,
      publicPath = assert(contentpath.publicPath(app, row.type, row.path)),
      title = row.title,
      renderMode = row.render_mode,
      status = row.status,
      createdAt = tonumber(row.created_at),
      updatedAt = tonumber(row.updated_at),
      metaDescription = row.meta_description or "",
      cachePolicy = row.cache_policy or "default"
   }
   if includeBody then
      item.bodyHtml = row.body_html
      item.headHtml = row.head_html or ""
   end
   if rowTermList then item.terms = rowTermList end
   return item
end

local function rowBySelector(app, conn, selector)
   if tonumber(selector.id) then
      return db.one(conn, "SELECT * FROM content WHERE id=" .. tonumber(selector.id))
   end
   if not selector.path then return nil, "A content id or path is required" end

   local path, err = validation.path(selector.path)
   if not path then return nil, err end
   if selector.type then
      local kind
      kind, err = contentType(selector.type)
      if not kind then return nil, err end
      local stored
      stored, err = contentpath.storagePath(app, kind, path)
      if not stored then return nil, err end
      return db.one(conn, "SELECT * FROM content WHERE type=" .. db.quote(kind) ..
         " AND path=" .. db.quote(stored))
   end

   local publicPostPath = contentpath.postStoragePath(app, path)
   if publicPostPath then
      local post = db.one(conn, "SELECT * FROM content WHERE type='post' AND path=" ..
         db.quote(publicPostPath))
      if post then return post end
   end

   local rows = db.rows(conn, "SELECT * FROM content WHERE (type<>'post' AND path=" ..
      db.quote(path) .. ") OR (type='post' AND path=" .. db.quote(path) ..
      ") ORDER BY id LIMIT 2")
   if #rows > 1 then
      return nil, "Content path is ambiguous; specify type or use the numeric id"
   end
   return rows[1]
end

function M.get(app, selector)
   selector = selector or {}
   return db.withRead(app, function(conn)
      local row, selectorErr = rowBySelector(app, conn, selector)
      if selectorErr then return nil, selectorErr end
      if not row then return nil, "Content was not found" end
      return serialize(app, conn, row)
   end)
end

function M.getBatch(app, args)
   args = args or {}
   local ids, paths = args.ids or {}, args.paths or {}
   if #ids + #paths == 0 then return nil, "At least one content id or path is required" end
   if #ids + #paths > 100 then return nil, "Batch content reads are limited to 100 selectors" end
   return db.withRead(app, function(conn)
      local rows, seen, missing = {}, {}, {}
      for _, id in ipairs(ids) do
         local row = rowBySelector(app, conn, { id = id })
         if row and not seen[row.id] then
            seen[row.id] = true
            rows[#rows + 1] = row
         else
            missing[#missing + 1] = "id:" .. tostring(id)
         end
      end
      for _, path in ipairs(paths) do
         local row, selectorErr = rowBySelector(app, conn, { path = path })
         if selectorErr then return nil, selectorErr end
         if row and not seen[row.id] then
            seen[row.id] = true
            rows[#rows + 1] = row
         elseif not row then
            missing[#missing + 1] = "path:" .. tostring(path)
         end
      end
      table.sort(rows, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
      local items = {}
      local groupedTerms = args.includeTerms == true and termsForRows(conn, rows) or nil
      for _, row in ipairs(rows) do
         items[#items + 1] = serializeListRow(
            app,
            row,
            args.includeBody == true,
            groupedTerms and groupedTerms[tonumber(row.id)]
         )
      end
      return {
         items = items,
         requested = #ids + #paths,
         found = #items,
         missing = #missing,
         missingSelectors = missing
      }
   end)
end

function M.list(app, args)
   args = args or {}
   local where = {}
   if args.type then
      local value, err = contentType(args.type)
      if not value then return nil, err end
      where[#where + 1] = "type=" .. db.quote(value)
   end
   if args.status then
      local value, err = contentStatus(args.status)
      if not value then return nil, err end
      where[#where + 1] = "status=" .. db.quote(value)
   end
   if args.renderMode then
      local value, err = renderMode(args.renderMode)
      if not value then return nil, err end
      where[#where + 1] = "render_mode=" .. db.quote(value)
   end
   if args.pathPrefix then
      local value, err = validation.path(args.pathPrefix)
      if not value then return nil, err end
      local escaped = value:gsub("\\", "\\\\"):gsub("%%", "\\%%"):gsub("_", "\\_")
      where[#where + 1] = "path LIKE " .. db.quote(escaped .. "%") .. " ESCAPE '\\'"
   end
   if args.query then
      local value = validation.trim(args.query)
      if value == "" then return nil, "Search query cannot be empty" end
      local escaped = value:gsub("\\", "\\\\"):gsub("%%", "\\%%"):gsub("_", "\\_")
      local pattern = db.quote("%" .. escaped .. "%")
      local searchable = {
         "title LIKE " .. pattern .. " ESCAPE '\\'",
         "path LIKE " .. pattern .. " ESCAPE '\\'",
         "meta_description LIKE " .. pattern .. " ESCAPE '\\'"
      }
      if args.searchBody == true then
         searchable[#searchable + 1] = "body_html LIKE " .. pattern .. " ESCAPE '\\'"
      end
      where[#where + 1] = "(" .. table.concat(searchable, " OR ") .. ")"
   end
   if args.updatedAfter ~= nil then
      where[#where + 1] = "COALESCE(updated_at,0)>=" .. math.floor(args.updatedAfter)
   end
   if args.updatedBefore ~= nil then
      where[#where + 1] = "COALESCE(updated_at,0)<=" .. math.floor(args.updatedBefore)
   end
   if args.termType or args.termSlug then
      local termWhere = { "ct.content_id=content.id" }
      if args.termType then termWhere[#termWhere + 1] = "t.type=" .. db.quote(args.termType) end
      if args.termSlug then termWhere[#termWhere + 1] = "t.slug=" .. db.quote(args.termSlug) end
      where[#where + 1] = [[EXISTS(SELECT 1 FROM content_terms ct
         JOIN terms t ON t.id=ct.term_id WHERE ]] .. table.concat(termWhere, " AND ") .. ")"
   end
   local limit = math.floor(tonumber(args.limit) or 100)
   if limit < 1 or limit > 500 then return nil, "Limit must be between 1 and 500" end

   local sort = args.sort or "updatedAt"
   local sortColumns = {
      id = { sql = "id", numeric = true },
      updatedAt = { sql = "COALESCE(updated_at,0)", numeric = true },
      createdAt = { sql = "COALESCE(created_at,0)", numeric = true },
      title = { sql = "LOWER(title)", field = "title" },
      path = { sql = "path", field = "path" }
   }
   local sortColumn = sortColumns[sort]
   if not sortColumn then return nil, "Unsupported content sort" end
   local direction = args.direction or "desc"
   if direction ~= "asc" and direction ~= "desc" then return nil, "Sort direction must be asc or desc" end
   local compare = direction == "asc" and ">" or "<"

   local countWhere = {}
   for index, clause in ipairs(where) do countWhere[index] = clause end
   if args.cursor then
      local cursorValue, cursorId = tostring(args.cursor):match("^(.*):(%d+)$")
      cursorId = tonumber(cursorId)
      if not cursorValue or not cursorId then return nil, "Invalid content cursor" end
      local valueSql
      if sortColumn.numeric then
         local number = tonumber(cursorValue)
         if not number then return nil, "Invalid numeric content cursor" end
         valueSql = tostring(number)
      else
         valueSql = db.quote(cursorValue)
      end
      where[#where + 1] = "(" .. sortColumn.sql .. compare .. valueSql ..
         " OR (" .. sortColumn.sql .. "=" .. valueSql .. " AND id" .. compare .. cursorId .. "))"
   end

   local sql = "SELECT * FROM content"
   if #where > 0 then sql = sql .. " WHERE " .. table.concat(where, " AND ") end
   sql = sql .. " ORDER BY " .. sortColumn.sql .. " " .. direction:upper() ..
      ",id " .. direction:upper() .. " LIMIT " .. (limit + 1)
   return db.withRead(app, function(conn)
      local out = {}
      local rows = db.rows(conn, sql)
      local hasMore = #rows > limit
      if hasMore then rows[#rows] = nil end
      local groupedTerms = args.includeTerms == true and termsForRows(conn, rows) or nil
      for _, row in ipairs(rows) do
         out[#out + 1] = serializeListRow(
            app,
            row,
            args.includeBody == true,
            groupedTerms and groupedTerms[tonumber(row.id)]
         )
      end
      local result = { items = out, hasMore = hasMore }
      if args.includeTotal == true then
         local countSql = "SELECT COUNT(*) count FROM content"
         if #countWhere > 0 then
            countSql = countSql .. " WHERE " .. table.concat(countWhere, " AND ")
         end
         result.total = tonumber(db.one(conn, countSql).count)
      end
      local last = rows[#rows]
      if hasMore and last then
         local value
         if sort == "id" then value = tonumber(last.id)
         elseif sort == "updatedAt" then value = tonumber(last.updated_at) or 0
         elseif sort == "createdAt" then value = tonumber(last.created_at) or 0
         else value = tostring(last[sortColumn.field] or ""):lower() end
         result.nextCursor = tostring(value) .. ":" .. tostring(last.id)
      end
      return result
   end)
end

function M.validate(app, args)
   args = args or {}
   local mode, err = renderMode(args.renderMode)
   if not mode then return nil, err end
   local body, warnings = validateBody(app, args.bodyHtml, mode, args.title)
   if not body then return nil, warnings end
   local compiled = false
   if mode == "lsp" then
      local ok, luaOrErr, parseErr = pcall(ba.parselsp, body)
      if not ok then return nil, "LSP parsing failed: " .. tostring(luaOrErr) end
      if not luaOrErr then return nil, "LSP parsing failed: " .. tostring(parseErr) end
      local fn, compileErr = load(luaOrErr, "=(MCP content validation)")
      if not fn then return nil, "LSP compilation failed: " .. tostring(compileErr) end
      compiled = true
   end
   return {
      valid = true,
      renderMode = mode,
      bodyBytes = #body,
      compiled = compiled,
      themeContract = app.theme and app.theme.contract or nil,
      warnings = warnings
   }
end

function M.dependencies(app, selector)
   local existing, err = M.get(app, selector or {})
   if not existing then return nil, err end
   return db.withRead(app, function(conn)
      local menuItems = db.rows(conn, [[SELECT mi.id,mi.label,mi.url,m.slug menu_slug
         FROM menu_items mi JOIN menus m ON m.id=mi.menu_id
         WHERE mi.content_id=]] .. tonumber(existing.id) .. " OR mi.url=" ..
         db.quote(existing.publicPath) .. " ORDER BY m.slug,mi.position,mi.id")
      for _, row in ipairs(menuItems) do row.id = tonumber(row.id) end
      local redirects = db.rows(conn, "SELECT id,from_path,to_path,status_code FROM redirects WHERE from_path=" ..
         db.quote(existing.publicPath) .. " OR to_path=" .. db.quote(existing.publicPath) .. " ORDER BY from_path")
      for _, row in ipairs(redirects) do
         row.id = tonumber(row.id)
         row.status_code = tonumber(row.status_code)
      end
      local prefix = existing.path:sub(-1) == "/" and existing.path or existing.path .. "/"
      local children = db.rows(conn, "SELECT id,path,title,status FROM content WHERE id<>" ..
         tonumber(existing.id) .. " AND type=" .. db.quote(existing.type) ..
         " AND path LIKE " .. db.quote(prefix .. "%") .. " ORDER BY path")
      for _, row in ipairs(children) do row.id = tonumber(row.id) end
      return {
         content = {
            id = existing.id,
            path = existing.path,
            publicPath = existing.publicPath,
            type = existing.type,
            title = existing.title,
            status = existing.status,
            updatedAt = existing.updatedAt
         },
         menuItems = menuItems,
         redirects = redirects,
         childContent = children,
         activeNotFoundPage = app.settings.notFoundEnabled == true and
             existing.type == "page" and app.settings.notFoundPath == existing.path
      }
   end)
end

function M.deletePermanent(app, args)
   args = args or {}
   if args.confirmed ~= true then
      return nil, "Explicit confirmation is required", "confirmationRequired"
   end
   local dependencies, err = M.dependencies(app, {
      id = args.id,
      path = args.path,
      type = args.type
   })
   if not dependencies then return nil, err end
   if dependencies.activeNotFoundPage then
      return nil,
         "The active editable 404 page cannot be deleted; configure another 404 page or disable it first",
         "requiredContent"
   end
   if #dependencies.menuItems > 0 and args.menuItemsAction == nil then
      return nil, "Choose whether linked menu items should be preserved or deleted",
         "contentDependenciesRequireDecision", {
            question = "Should the linked menu items be preserved with their URLs, or deleted?",
            menuItems = dependencies.menuItems,
            choices = { "preserve", "delete" }
         }
   end
   if #dependencies.redirects > 0 and args.redirectsAction == nil then
      return nil, "Choose whether related redirects should be preserved or deleted",
         "contentDependenciesRequireDecision", {
            question = "Should redirects whose source or target is this content path be preserved or deleted?",
            redirects = dependencies.redirects,
            choices = { "preserve", "delete" }
         }
   end
   local removedMenuItems, removedRedirects = 0, 0
   local ok, writeErr = pcall(db.withWrite, app, function(conn)
      local current = db.one(conn, "SELECT * FROM content WHERE id=" ..
         tonumber(dependencies.content.id))
      if not current then error("Content was not found", 2) end
      if args.expectedUpdatedAt ~= nil and
         tonumber(args.expectedUpdatedAt) ~= tonumber(current.updated_at) then
         error("CONTENT_CONFLICT:" .. tostring(current.updated_at or ""), 2)
      end
      if args.menuItemsAction == "delete" then
         removedMenuItems = #dependencies.menuItems
         exec(conn, "DELETE FROM menu_items WHERE content_id=" .. tonumber(current.id) ..
            " OR url=" .. db.quote(assert(contentpath.publicPath(app, current.type, current.path))))
      end
      if args.redirectsAction == "delete" then
         removedRedirects = #dependencies.redirects
         local publicPath = assert(contentpath.publicPath(app, current.type, current.path))
         exec(conn, "DELETE FROM redirects WHERE from_path=" .. db.quote(publicPath) ..
            " OR to_path=" .. db.quote(publicPath))
      end
      exec(conn, "DELETE FROM content WHERE id=" .. tonumber(current.id))
   end)
   if not ok then
      local currentUpdatedAt = tostring(writeErr):match("CONTENT_CONFLICT:(%d*)")
      if currentUpdatedAt then
         return nil, "Content changed after it was read", "contentConflict", {
            expectedUpdatedAt = tonumber(args.expectedUpdatedAt),
            currentUpdatedAt = tonumber(currentUpdatedAt)
         }
      end
      return nil, tostring(writeErr)
   end
   clearRuntime(app)
   return {
      deleted = true,
      id = dependencies.content.id,
      path = dependencies.content.path,
      publicPath = dependencies.content.publicPath,
      removedMenuItems = removedMenuItems,
      removedRedirects = removedRedirects,
      preservedMenuItems = args.menuItemsAction ~= "delete" and #dependencies.menuItems or 0,
      preservedRedirects = args.redirectsAction ~= "delete" and #dependencies.redirects or 0,
      childContentPreserved = #dependencies.childContent
   }
end

local function normalizedContent(app, args)
   local kind, err = contentType(args.type)
   if not kind then return nil, err end
   local path
   path, err = contentpath.storagePath(app, kind, args.path)
   if not path then return nil, err end
   local title
   title, err = requireText(args.title, "Title", 1024)
   if not title then return nil, err end
   local mode
   mode, err = renderMode(args.renderMode)
   if not mode then return nil, err end
   local body, warnings = validateBody(app, args.bodyHtml, mode, title)
   if not body then return nil, warnings end
   local policy
   policy, err = cachePolicy(args.cachePolicy)
   if not policy then return nil, err end
   local terms
   terms, err = normalizeTerms(args.terms)
   if not terms then return nil, err end
   local status
   if args.status ~= nil then
      status, err = contentStatus(args.status)
      if not status then return nil, err end
   else
      status = args.publish == true and "published" or "draft"
   end
   return {
      type = kind,
      path = path,
      title = title,
      bodyHtml = body,
      renderMode = mode,
      status = status,
      metaDescription = tostring(args.metaDescription or ""),
      headHtml = tostring(args.headHtml or ""),
      cachePolicy = policy,
      terms = terms,
      warnings = warnings
   }
end

clearRuntime = function(app)
   if app.invalidateRuntime then
      app.invalidateRuntime()
      return
   end
   if app.clearPageTables then app.clearPageTables() end
   if app.clearRenderCache then app.clearRenderCache() end
end

function M.create(app, args)
   local item, err = normalizedContent(app, args or {})
   if not item then return nil, err end
   local created
   local ok, writeErr = pcall(db.withWrite, app, function(conn)
      if db.one(conn, "SELECT id FROM content WHERE type=" .. db.quote(item.type) ..
         " AND path=" .. db.quote(item.path)) then
         error("Content already exists at " .. item.path, 2)
      end
      local ts = os.time()
      exec(conn, "INSERT INTO content(type,path,title,body_html,render_mode,status,created_at,updated_at,meta_description,head_html,cache_policy) VALUES(" ..
         db.quote(item.type) .. "," .. db.quote(item.path) .. "," .. db.quote(item.title) .. "," ..
         db.quote(item.bodyHtml) .. "," .. db.quote(item.renderMode) .. "," .. db.quote(item.status) .. "," ..
         ts .. "," .. ts .. "," .. db.quote(item.metaDescription) .. "," .. db.quote(item.headHtml) .. "," ..
         db.quote(item.cachePolicy) .. ")")
      local row = db.one(conn, "SELECT * FROM content WHERE type=" .. db.quote(item.type) ..
         " AND path=" .. db.quote(item.path))
      replaceTerms(conn, row.id, item.terms)
      created = serialize(app, conn, row)
   end)
   if not ok then return nil, tostring(writeErr) end
   created.terms = item.terms
   created.warnings = item.warnings
   clearRuntime(app)
   return created
end

function M.copy(app, args)
   args = args or {}
   local source, err = M.get(app, {
      id = args.id,
      path = args.path,
      type = args.type
   })
   if not source then return nil, err end
   if source.renderMode == "lsp" and args.allowLsp ~= true then
      return nil, "Copying executable LSP requires explicit approval", "lspConfirmationRequired"
   end
   local created, createErr = M.create(app, {
      type = source.type,
      path = args.newPath,
      title = args.title or source.title,
      bodyHtml = source.bodyHtml,
      renderMode = source.renderMode,
      publish = args.publish == true,
      metaDescription = source.metaDescription,
      headHtml = source.headHtml,
      cachePolicy = source.cachePolicy,
      terms = source.terms
   })
   if not created then return nil, createErr end
   created.copiedFrom = {
      id = source.id,
      path = source.path,
      updatedAt = source.updatedAt
   }
   return created
end

function M.update(app, args)
   args = args or {}
   local existing, err = M.get(app, {
      id = args.id,
      path = args.existingPath,
      type = args.existingType
   })
   if not existing then return nil, err end
   local merged = {
      type = args.type or existing.type,
      path = args.path or existing.path,
      title = args.title or existing.title,
      bodyHtml = args.bodyHtml ~= nil and args.bodyHtml or existing.bodyHtml,
      renderMode = args.renderMode or existing.renderMode,
      status = existing.status,
      metaDescription = args.metaDescription ~= nil and args.metaDescription or existing.metaDescription,
      headHtml = args.headHtml ~= nil and args.headHtml or existing.headHtml,
      cachePolicy = args.cachePolicy or existing.cachePolicy,
      terms = args.terms or existing.terms
   }
   local item
   item, err = normalizedContent(app, merged)
   if not item then return nil, err end
   local updated
   local ok, writeErr = pcall(db.withWrite, app, function(conn)
      local current = db.one(conn, "SELECT * FROM content WHERE id=" .. tonumber(existing.id))
      if not current then error("Content was not found", 2) end
      if args.expectedUpdatedAt ~= nil and
         tonumber(args.expectedUpdatedAt) ~= tonumber(current.updated_at) then
         error("CONTENT_CONFLICT:" .. tostring(current.updated_at or ""), 2)
      end
      local conflict = db.one(conn, "SELECT id FROM content WHERE type=" .. db.quote(item.type) ..
         " AND path=" .. db.quote(item.path) .. " AND id<>" .. tonumber(existing.id))
      if conflict then error("Content already exists at " .. item.path, 2) end
      local updatedAt = db.nextRevision(current.updated_at)
      exec(conn, "UPDATE content SET type=" .. db.quote(item.type) ..
         ",path=" .. db.quote(item.path) ..
         ",title=" .. db.quote(item.title) ..
         ",body_html=" .. db.quote(item.bodyHtml) ..
         ",render_mode=" .. db.quote(item.renderMode) ..
         ",status=" .. db.quote(item.status) ..
         ",updated_at=" .. updatedAt ..
         ",meta_description=" .. db.quote(item.metaDescription) ..
         ",head_html=" .. db.quote(item.headHtml) ..
         ",cache_policy=" .. db.quote(item.cachePolicy) ..
         " WHERE id=" .. tonumber(existing.id))
      replaceTerms(conn, existing.id, item.terms)
      updated = serialize(app, conn, db.one(conn, "SELECT * FROM content WHERE id=" .. tonumber(existing.id)))
   end)
   if not ok then
      local currentUpdatedAt = tostring(writeErr):match("CONTENT_CONFLICT:(%d*)")
      if currentUpdatedAt then
         return nil, "Content changed after it was read", "contentConflict", {
            expectedUpdatedAt = tonumber(args.expectedUpdatedAt),
            currentUpdatedAt = tonumber(currentUpdatedAt)
         }
      end
      return nil, tostring(writeErr)
   end
   updated.terms = item.terms
   updated.warnings = item.warnings
   clearRuntime(app)
   return updated
end

function M.setStatus(app, args)
   args = args or {}
   local status, err = contentStatus(args.status)
   if not status then return nil, err end
   local existing
   existing, err = M.get(app, {
      id = args.id,
      path = args.path,
      type = args.type
   })
   if not existing then return nil, err end

   local result
   local ok, writeErr = pcall(db.withWrite, app, function(conn)
      local current = db.one(conn, "SELECT * FROM content WHERE id=" .. tonumber(existing.id))
      if not current then error("Content was not found", 2) end
      if args.expectedUpdatedAt ~= nil and
         tonumber(args.expectedUpdatedAt) ~= tonumber(current.updated_at) then
         error("CONTENT_CONFLICT:" .. tostring(current.updated_at or ""), 2)
      end
      local previousStatus = current.status
      if previousStatus ~= status then
         exec(conn, "UPDATE content SET status=" .. db.quote(status) ..
            ",updated_at=" .. db.nextRevision(current.updated_at) ..
            " WHERE id=" .. tonumber(current.id))
         current = db.one(conn, "SELECT * FROM content WHERE id=" .. tonumber(current.id))
      end
      result = {
         previousStatus = previousStatus,
         newStatus = current.status,
         content = serialize(app, conn, current)
      }
   end)
   if not ok then
      local currentUpdatedAt = tostring(writeErr):match("CONTENT_CONFLICT:(%d*)")
      if currentUpdatedAt then
         return nil, "Content changed after it was read", "contentConflict", {
            expectedUpdatedAt = tonumber(args.expectedUpdatedAt),
            currentUpdatedAt = tonumber(currentUpdatedAt)
         }
      end
      return nil, tostring(writeErr)
   end
   clearRuntime(app)
   return result
end

function M.serialize(app, conn, row)
   return serialize(app, conn, row)
end

function M.replaceTerms(conn, contentId, terms)
   return replaceTerms(conn, contentId, terms)
end

function M.importBatch(app, items, plan, publish)
   local prepared = {}
   for _, source in ipairs(items or {}) do
      local decision = plan[contentpath.key(source.type, source.path)] or
         plan[source.path] or { action = "create" }
      if decision.action ~= "skip" then
         local targetPath = decision.action == "importDraft" and decision.newPath or source.path
         local normalized, err = normalizedContent(app, {
            type = source.type,
            path = targetPath,
            title = source.title,
            bodyHtml = source.bodyHtml,
            renderMode = source.renderMode,
            publish = decision.action ~= "importDraft" and publish == true and source.status == "published",
            metaDescription = source.metaDescription,
            headHtml = source.headHtml,
            cachePolicy = source.cachePolicy,
            terms = source.terms
         })
         if not normalized then return nil, source.path .. ": " .. tostring(err) end
         prepared[#prepared + 1] = {
            source = source,
            item = normalized,
            action = decision.action
         }
      end
   end

   local result = { created = {}, replaced = {}, skipped = {} }
   for _, source in ipairs(items or {}) do
      local decision = plan[contentpath.key(source.type, source.path)] or plan[source.path]
      if decision and decision.action == "skip" then
         result.skipped[#result.skipped + 1] = source.path
      end
   end

   local changedConflict
   local ok, writeErr = pcall(db.withWrite, app, function(conn)
      for _, entry in ipairs(prepared) do
         local item, source = entry.item, entry.source
         local existing = db.one(conn, "SELECT * FROM content WHERE type=" ..
            db.quote(item.type) .. " AND path=" .. db.quote(item.path))
         if entry.action == "replace" then
            local decision = plan[contentpath.key(source.type, source.path)] or plan[source.path]
            if not existing or
               tonumber(existing.id) ~= tonumber(decision and decision.existingId) or
               tonumber(existing.updated_at) ~= tonumber(decision and decision.expectedUpdatedAt) then
               changedConflict = {
                  path = item.path,
                  type = item.type,
                  expectedId = decision and decision.existingId,
                  expectedUpdatedAt = decision and decision.expectedUpdatedAt,
                  currentId = existing and tonumber(existing.id) or nil,
                  currentUpdatedAt = existing and tonumber(existing.updated_at) or nil
               }
               error("IMPORT_CONFLICT_CHANGED", 2)
            end
         elseif existing then
            error("Import conflict changed; content now exists at " .. item.path, 2)
         end

         local createdAt = math.floor(tonumber(source.createdAt) or os.time())
         local updatedAt = math.floor(tonumber(source.updatedAt) or createdAt)
         if existing then
            updatedAt = db.nextRevision(existing.updated_at, updatedAt)
            exec(conn, "UPDATE content SET type=" .. db.quote(item.type) ..
               ",title=" .. db.quote(item.title) ..
               ",body_html=" .. db.quote(item.bodyHtml) ..
               ",render_mode=" .. db.quote(item.renderMode) ..
               ",status=" .. db.quote(item.status) ..
               ",created_at=" .. createdAt ..
               ",updated_at=" .. updatedAt ..
               ",meta_description=" .. db.quote(item.metaDescription) ..
               ",head_html=" .. db.quote(item.headHtml) ..
               ",cache_policy=" .. db.quote(item.cachePolicy) ..
               " WHERE id=" .. tonumber(existing.id))
            replaceTerms(conn, existing.id, item.terms)
            result.replaced[#result.replaced + 1] = item.path
         else
            exec(conn, "INSERT INTO content(type,path,title,body_html,render_mode,status,created_at,updated_at,meta_description,head_html,cache_policy) VALUES(" ..
               db.quote(item.type) .. "," .. db.quote(item.path) .. "," .. db.quote(item.title) .. "," ..
               db.quote(item.bodyHtml) .. "," .. db.quote(item.renderMode) .. "," .. db.quote(item.status) .. "," ..
               createdAt .. "," .. updatedAt .. "," .. db.quote(item.metaDescription) .. "," ..
               db.quote(item.headHtml) .. "," .. db.quote(item.cachePolicy) .. ")")
            local inserted = db.one(conn, "SELECT id FROM content WHERE type=" ..
               db.quote(item.type) .. " AND path=" .. db.quote(item.path))
            replaceTerms(conn, inserted.id, item.terms)
            result.created[#result.created + 1] = item.path
         end
      end
   end)
   if not ok then
      if changedConflict then
         return nil, "Destination content changed after the conflict decision",
            "contentConflict", changedConflict
      end
      return nil, tostring(writeErr)
   end
   clearRuntime(app)
   return result
end

return M
