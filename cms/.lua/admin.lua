local db = appreq "db"
local http = appreq "cmshttp"
local settings = appreq "settings"
local theme = appreq "theme"
local notfound = appreq "notfound"
local smqservice = appreq "smqservice"
local adminauth = appreq "adminauth"
local mcpconfig = appreq "mcpconfig"
local contentService = appreq "mcpcontent"
local contentpath = appreq "contentpath"
local terms = appreq "terms"
local csrf = appreq "csrf"
local validation = appreq "validation"
local redirectservice = appreq "redirectservice"

local M = { cssVersion = "20261114" }

local nav = {
   { id = "dashboard", label = "Dashboard", href = "/admin/" },
   { id = "content", label = "Content", href = "/admin/content/" },
   { id = "categories", label = "Categories", href = "/admin/categories/" },
   { id = "menus", label = "Menus", href = "/admin/menus/" },
   { id = "redirects", label = "Redirects", href = "/admin/redirects/" },
   { id = "themes", label = "Themes", href = "/admin/themes/" },
   { id = "settings", label = "Settings", href = "/admin/settings/" },
   { id = "users", label = "Users", href = "/admin/users/" },
   { id = "mcp", label = "MCP", href = "/admin/mcp/" },
   { id = "help", label = "Help", href = "/admin/help/" },
}

local esc = http.html
local quote = db.quote

local trim = validation.trim

local function now()
   return os.time()
end

local function appUrl(app, path)
   path = tostring(path or "")
   if path:match("^https?://") or path:sub(1, 2) == "//" then return path end
   return app.url and app.url(path) or path
end

local function pluginFailures(app)
   local failures = {}
   for id, record in pairs(app.plugins or {}) do
      if record.state == "failed" then
         local message = tostring(record.error or "Plugin initialization failed"):
            match("[^\r\n]+") or "Plugin initialization failed"
         message = message:match(":%d+:%s*(.+)$") or message
         failures[#failures + 1] = { id = id, message = message }
      end
   end
   table.sort(failures, function(a, b) return a.id < b.id end)
   return failures
end

local function normalizeCachePolicy(policy)
   policy = trim(policy)
   if policy == "revalidate" or policy == "no-cache" or policy == "no-store" then
      return policy
   end
   return "default"
end

local function layout(_ENV, app, title, active, body)
   response:setcontenttype("text/html; charset=utf-8")
   response:setheader("x-content-type-options", "nosniff")
   adminTitle, adminActive = title, active
   adminPluginFailures = pluginFailures(app)
   response:include(app.url("/admin/includes/start.lsp"), true)
   body()
   response:include(app.url("/admin/includes/end.lsp"), true)
   return true
end

local function isMultipart(_ENV)
   local contentType = _ENV.request:header("Content-Type") or ""
   return contentType:find("multipart/form-data", 1, true) ~= nil
end

local function postData(_ENV)
   if _ENV.cmsAdminPostData then return _ENV.cmsAdminPostData end
   if not isMultipart(_ENV) then
      _ENV.cmsAdminPostData = _ENV.request:data() or {}
      return _ENV.cmsAdminPostData
   end

   local data = {}
   local err
   local bufsize = tonumber(_ENV.request:header("Content-Length")) or 160*1024
   _ENV.request:multipart({
      formdata = function(name, value)
         data[name] = value
      end,
      error = function(emsg)
         err = emsg
      end
   }, bufsize)
   if err then
      error("Multipart form parse failed: " .. tostring(err), 2)
   end
   _ENV.cmsAdminPostData = data
   return data
end

local function redirect(_ENV, app, url)
   _ENV.response:sendredirect(appUrl(app, url))
   return true
end

function M.isAdmin(_ENV, app)
   if not adminauth.enabled(app) then
      return true
   end
   local session = _ENV.request:session()
   return session and session.isCmsAdmin == true or false
end

function M.isHtmx(_ENV)
   return tostring(_ENV.request:header("HX-Request") or ""):lower() == "true"
end

function M.guardLsp(_ENV, app, fragmentOnly)
   if not adminauth.checkIfAuth(app, _ENV) then
      return false
   end
   if fragmentOnly and not _ENV.response:isinclude() and not M.isHtmx(_ENV) then
      _ENV.response:senderror(404, "Not found")
      return false
   end
   if _ENV.request:method() == "POST" then
      local data = postData(_ENV)
      if not csrf.validate(_ENV, data) then
         _ENV.response:senderror(403, "Invalid or missing CSRF token")
         return false
      end
   end
   return true
end

M.requestData = postData
M.csrfField = csrf.field
M.nav = nav
M.html = esc
M.appUrl = appUrl

local function pluginSegment(value, field)
   value = tostring(value or "")
   if not value:match("^[a-z0-9][a-z0-9-]*$") then
      return nil, "Invalid plugin admin " .. field
   end
   return value
end

local function pluginPath(value, directory)
   value = tostring(value or ""):gsub("^/+", "")
   if value:find("\\", 1, true) or value:find("..", 1, true) or
      value:find("//", 1, true) then
      return nil, "Invalid plugin admin path"
   end
   if value ~= "" and not value:match("^[%w%._~%-/]+$") then
      return nil, "Invalid plugin admin path"
   end
   if directory and value ~= "" and value:sub(-1) ~= "/" then
      value = value .. "/"
   end
   return value
end

local function sortPluginNav(items)
   table.sort(items, function(a, b)
      if a.order == b.order then return a.active < b.active end
      return a.order < b.order
   end)
end

function M.installPluginApi(app)
   if app.pluginAdmin then return app.pluginAdmin end

   local registry = {
      routes = {},
      nav = {}
   }
   app.pluginAdmin = registry

   function registry.addRoute(owner, path, handler)
      owner = assert(pluginSegment(owner, "owner"))
      path = assert(pluginPath(path))
      assert(type(handler) == "function", "Plugin admin handler must be a function")
      local route = "plugins/" .. owner .. "/" .. path
      if registry.routes[route] then
         return nil, "Plugin admin route already exists: " .. route
      end
      registry.routes[route] = {
         owner = owner,
         handler = handler
      }
      local removed = false
      return function()
         if removed then return end
         removed = true
         local current = registry.routes[route]
         if current and current.owner == owner then registry.routes[route] = nil end
      end
   end

   function registry.addPage(owner, spec)
      owner = assert(pluginSegment(owner, "owner"))
      assert(type(spec) == "table", "Plugin admin page must be a table")
      local id = assert(pluginSegment(spec.id, "page ID"))
      local label = tostring(spec.label or "")
      if label == "" then return nil, "Plugin admin page label is required" end
      local path, pathErr = pluginPath(spec.path, true)
      if not path then return nil, pathErr end
      local handler = spec.handler
      if type(handler) ~= "function" then
         return nil, "Plugin admin page handler must be a function"
      end

      local active = "plugin:" .. owner .. ":" .. id
      for _, item in ipairs(registry.nav) do
         if item.active == active then
            return nil, "Plugin admin page already exists: " .. active
         end
      end

      local removeRoute, routeErr = registry.addRoute(owner, path, handler)
      if not removeRoute then return nil, routeErr end
      local item = {
         owner = owner,
         active = active,
         label = label,
         href = "/admin/plugins/" .. owner .. "/" .. path,
         order = tonumber(spec.order) or 1000
      }
      registry.nav[#registry.nav + 1] = item
      sortPluginNav(registry.nav)

      local removed = false
      return function()
         if removed then return end
         removed = true
         removeRoute()
         for index, current in ipairs(registry.nav) do
            if current == item then
               table.remove(registry.nav, index)
               break
            end
         end
      end, active
   end

   function registry.layout(env, title, active, body)
      return layout(env, app, title, active, body)
   end

   function registry.postData(env)
      return rawget(env, "cmsAdminPostData") or {}
   end

   function registry.csrfField(env)
      return csrf.field(env)
   end

   registry.html = esc

   return registry
end

local function clearRuntimePageTables(app)
   if app.invalidateRuntime then
      app.invalidateRuntime()
      return
   end
   if app.clearPageTables then
      app.clearPageTables()
   end
   if app.clearRenderCache then
      app.clearRenderCache()
   end
end

local function normalizeMenuUrl(url)
   return validation.url(url, true)
end

local function effectiveMenuUrl(app, row)
   if row.content_type and row.content_path then
      return assert(contentpath.publicPath(app, row.content_type, row.content_path))
   end
   return row.url
end

local function inferParentId(app, conn, menuId, url, currentId)
   url = normalizeMenuUrl(url)
   if not url or url:find("^[%w][%w%+%-%.]*:") or url:sub(1, 2) == "//" then return nil end
   local found
   for _, row in ipairs(db.rows(conn, [[SELECT mi.id,mi.url,c.type content_type,c.path content_path
      FROM menu_items mi LEFT JOIN content c ON c.id=mi.content_id
      WHERE mi.menu_id=]] .. tonumber(menuId) ..
      " AND COALESCE(mi.hidden,0)=0 ORDER BY LENGTH(mi.url) DESC,mi.id")) do
      local id = tonumber(row.id)
      local candidate = normalizeMenuUrl(effectiveMenuUrl(app, row))
      local prefix = candidate and (candidate:sub(-1) == "/" and candidate or candidate .. "/")
      if id ~= tonumber(currentId) and candidate and candidate ~= url and
         (candidate == "/" or url:sub(1, #prefix) == prefix) then
         found = id
         break
      end
   end
   return found
end

function M.contentRows(app, filterType, query, pageNumber)
   filterType = trim(filterType)
   local where = ""
   if filterType == "page" or filterType == "post" then
      where = " WHERE type=" .. quote(filterType)
   else
      filterType = ""
   end
   query = trim(query):sub(1, 200)
   if query ~= "" then
      where = where .. (where == "" and " WHERE " or " AND ") ..
         "(instr(lower(title),lower(" .. quote(query) .. "))>0 OR " ..
         "instr(lower(path),lower(" .. quote(query) .. "))>0)"
   end
   local total = tonumber(db.readOne(app, "SELECT COUNT(*) AS count FROM content" .. where).count)
   local pages = math.max(1, math.ceil(total / 50))
   pageNumber = math.max(1, math.min(pages, math.floor(tonumber(pageNumber) or 1)))
   local rows = db.readRows(app,
      "SELECT id,type,path,title,render_mode,status,updated_at,cache_policy FROM content" ..
      where .. " ORDER BY type,path LIMIT 50 OFFSET " .. ((pageNumber - 1) * 50))
   for _, row in ipairs(rows) do
      row.public_path = assert(contentpath.publicPath(app, row.type, row.path))
   end
   return rows, filterType, { page = pageNumber, pages = pages, total = total, query = query }
end

function M.contentRow(app, id)
   id = tonumber(id)
   if not id then return nil end
   local row = db.readOne(app,
      "SELECT id,type,path,title,render_mode,status,updated_at,cache_policy FROM content WHERE id=" .. id)
   if row then row.public_path = assert(contentpath.publicPath(app, row.type, row.path)) end
   return row
end

function M.menuItems(app)
   local rows = db.readRows(app, [[
SELECT mi.*,m.name menu_name,m.slug menu_slug,c.type content_type,c.path content_path
FROM menu_items mi
JOIN menus m ON m.id = mi.menu_id
LEFT JOIN content c ON c.id=mi.content_id
WHERE m.slug='primary'
ORDER BY mi.position,mi.id]])
   for _, row in ipairs(rows) do row.url = effectiveMenuUrl(app, row) end
   return rows
end

local function menuItemOrder(left, right)
   local leftPosition = tonumber(left.position) or 0
   local rightPosition = tonumber(right.position) or 0
   if leftPosition == rightPosition then
      return (tonumber(left.id) or 0) < (tonumber(right.id) or 0)
   end
   return leftPosition < rightPosition
end

function M.menuTreeItems(app)
   local items = M.menuItems(app)
   local byId = {}
   local children = {}
   local roots = {}

   for _, row in ipairs(items) do
      byId[tonumber(row.id)] = row
   end
   for _, row in ipairs(items) do
      local id = tonumber(row.id)
      local parentId = tonumber(row.parent_id)
      local parent = parentId and byId[parentId]
      if parent and parentId ~= id then
         local bucket = children[parentId]
         if not bucket then
            bucket = {}
            children[parentId] = bucket
         end
         row.tree_parent_label = parent.label
         bucket[#bucket + 1] = row
      else
         roots[#roots + 1] = row
      end
   end

   table.sort(roots, menuItemOrder)
   for _, bucket in pairs(children) do
      table.sort(bucket, menuItemOrder)
   end

   local ordered = {}
   local visited = {}
   local function append(row, depth, path, valid)
      local id = tonumber(row.id)
      if visited[id] then return end
      visited[id] = true
      row.tree_depth = depth
      row.tree_path = (path and path .. " / " or "") .. row.label
      row.tree_valid_parent = valid
      row.tree_start = #ordered + 1
      ordered[#ordered + 1] = row
      for _, child in ipairs(children[id] or {}) do
         append(child, depth + 1, row.tree_path, valid)
      end
      row.tree_end = #ordered
   end

   for _, row in ipairs(roots) do
      append(row, 0, nil, not tonumber(row.parent_id))
   end
   table.sort(items, menuItemOrder)
   for _, row in ipairs(items) do
      local id = tonumber(row.id)
      if not visited[id] then
         row.tree_parent_label = nil
         append(row, 0, nil, false)
      end
   end
   return ordered
end

function M.menuItem(app, id)
   id = tonumber(id)
   if not id then return nil end
   local row = db.readOne(app, [[
SELECT mi.*,m.name menu_name,m.slug menu_slug,c.type content_type,c.path content_path
FROM menu_items mi JOIN menus m ON m.id=mi.menu_id
LEFT JOIN content c ON c.id=mi.content_id
WHERE mi.id=]] .. id)
   if row then row.url = effectiveMenuUrl(app, row) end
   return row
end

local function dashboard(_ENV, app)
   _ENV.adminDashboard = db.readOne(app, [[SELECT COUNT(*) content,
      COUNT(CASE WHEN type='page' THEN 1 END) pages,
      COUNT(CASE WHEN type='post' THEN 1 END) posts,
      COUNT(CASE WHEN render_mode='lsp' THEN 1 END) lsp,
      (SELECT COUNT(*) FROM redirects) redirects,
      (SELECT COUNT(*) FROM menu_items) menuItems FROM content]])
   local activeTheme = db.readOne(app, "SELECT value FROM options WHERE key='active_theme'")
   _ENV.adminDashboard.theme = activeTheme and activeTheme.value or app.defaultTheme or "default"
   return layout(_ENV, app, "Dashboard", "dashboard", function()
      response:include(app.url("/admin/dashboard/page.lsp"), true)
   end)
end

local function contentForm(_ENV, app, row)
   row = row or {
      id = "",
      type = "page",
      path = "/",
      title = "",
      body_html = "",
      render_mode = "html",
      status = "draft",
      meta_description = "",
      head_html = "",
      cache_policy = "default",
   }
   row.cache_policy = normalizeCachePolicy(row.cache_policy)
   local isNew = row.id == ""
   local categories = terms.categories(app)
   local assignedCategories = {}
   if not isNew then
      for _, category in ipairs(terms.forContent(app, row.id, "category")) do
         assignedCategories[tonumber(category.id)] = true
      end
   end
   _ENV.adminContentEditor = {
      row = row, isNew = isNew, categories = categories,
      assignedCategories = assignedCategories
   }
   return layout(_ENV, app, isNew and "New Content" or "Edit Content", "content", function()
      response:include(app.url("/admin/content/editor.lsp"), true)
   end)
end

local function selectedCategoryIds(data)
   local ids = {}
   for key, value in pairs(data or {}) do
      local id = tostring(key):match("^category_(%d+)$")
      if id and tostring(value) ~= "" and tostring(value) ~= "0" then
         ids[#ids + 1] = tonumber(id)
      end
   end
   table.sort(ids)
   return ids
end

local function persistContent(app, data, isNew)
   local typeName = trim(data.type)
   local status = trim(data.status)
   local renderMode = trim(data.render_mode)
   local cachePolicy = normalizeCachePolicy(data.cache_policy)
   if typeName ~= "post" then typeName = "page" end
   if status ~= "published" then status = "draft" end
   if renderMode ~= "lsp" then renderMode = "html" end
   local path = trim(data.path)
   local pathErr
   path, pathErr = contentpath.storagePath(app, typeName, path)
   if not path then validation.fail(pathErr) end
   local title = trim(data.title)
   if title == "" then title = path end
   local savedId
   db.withWrite(app, function(conn)
      local id = not isNew and tonumber(data.id) or nil
      local conflict = db.one(conn, "SELECT id FROM content WHERE type=" .. quote(typeName) ..
         " AND path=" .. quote(path) .. (id and " AND id<>" .. id or ""))
      if conflict then
         validation.fail("A " .. typeName .. " already exists at " .. path)
      end
      if isNew then
         local ts = now()
         assert(conn:execute("INSERT INTO content(type,path,title,body_html,render_mode,status,created_at,updated_at,meta_description,head_html,cache_policy) VALUES(" ..
            quote(typeName) .. "," .. quote(path) .. "," .. quote(title) .. "," ..
             quote(data.body_html) .. "," .. quote(renderMode) .. "," .. quote(status) .. "," ..
             ts .. "," .. ts .. "," .. quote(data.meta_description) .. "," .. quote(data.head_html) .. "," .. quote(cachePolicy) .. ")"))
         local inserted = db.one(conn, "SELECT last_insert_rowid() id")
         savedId = inserted and tonumber(inserted.id)
      else
         assert(id, "Invalid content id")
         savedId = id
         local current = db.one(conn, "SELECT updated_at FROM content WHERE id=" .. id)
         assert(current, "Content was not found")
         assert(conn:execute("UPDATE content SET type=" .. quote(typeName) ..
            ",path=" .. quote(path) ..
            ",title=" .. quote(title) ..
            ",body_html=" .. quote(data.body_html) ..
            ",render_mode=" .. quote(renderMode) ..
            ",status=" .. quote(status) ..
            ",updated_at=" .. db.nextRevision(current.updated_at) ..
            ",meta_description=" .. quote(data.meta_description) ..
            ",head_html=" .. quote(data.head_html) ..
            ",cache_policy=" .. quote(cachePolicy) ..
            " WHERE id=" .. id))
      end
      terms.replaceContentCategoriesConn(conn, savedId,
         typeName == "post" and selectedCategoryIds(data) or {})
   end)
   clearRuntimePageTables(app)
   return M.contentRow(app, savedId)
end

function M.persistContent(app, data, isNew)
   return persistContent(app, data, isNew)
end

function M.categoryRows(app)
   return terms.categories(app)
end

function M.categoryRow(app, id)
   local row = terms.category(app, tonumber(id))
   return row
end

function M.mutateCategory(app, data)
   local action = trim(data.action)
   local name, nameErr = validation.required(data.name, "Category name", 255)
   if not name then validation.fail(nameErr) end
   local slugValue = trim(data.slug)
   if slugValue == "" then
      slugValue = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
   end
   local slug, slugErr = validation.slug(slugValue, "Category slug")
   if not slug then validation.fail(slugErr) end
   local description = tostring(data.description or "")
   if #description > 65536 then validation.fail("Category description is too long") end
   local savedId

   db.withWrite(app, function(conn)
      if action == "add" then
         if db.one(conn, "SELECT id FROM terms WHERE type='category' AND slug=" ..
            quote(slug)) then
            validation.fail("A category with this slug already exists")
         end
         assert(conn:execute("INSERT INTO terms(type,name,slug,description) VALUES('category'," ..
            quote(name) .. "," .. quote(slug) .. "," .. quote(description) .. ")"))
         savedId = tonumber(db.one(conn, "SELECT last_insert_rowid() id").id)
      elseif action == "update" then
         savedId = tonumber(data.id)
         if not savedId then validation.fail("Invalid category id") end
         if not db.one(conn,
            "SELECT id FROM terms WHERE type='category' AND id=" .. savedId) then
            validation.fail("Category does not exist")
         end
         if db.one(conn, "SELECT id FROM terms WHERE type='category' AND slug=" ..
            quote(slug) .. " AND id<>" .. savedId) then
            validation.fail("A category with this slug already exists")
         end
         assert(conn:execute("UPDATE terms SET name=" .. quote(name) ..
            ",slug=" .. quote(slug) .. ",description=" .. quote(description) ..
            " WHERE type='category' AND id=" .. savedId))
      else
         validation.fail("Unsupported category action")
      end
   end)
   clearRuntimePageTables(app)
   return terms.category(app, savedId)
end

function M.deleteCategory(app, id)
   id = tonumber(id)
   if not id then validation.fail("Invalid category id") end
   local deleted
   db.withWrite(app, function(conn)
      local row = db.one(conn, [[SELECT t.*,
         (SELECT COUNT(*) FROM content_terms ct WHERE ct.term_id=t.id) assignment_count
         FROM terms t WHERE t.type='category' AND t.id=]] .. id)
      if not row then validation.fail("Category does not exist") end
      assert(conn:execute("DELETE FROM content_terms WHERE term_id=" .. id))
      assert(conn:execute("DELETE FROM terms WHERE type='category' AND id=" .. id))
      deleted = {
         id = id,
         name = row.name,
         removedAssignments = tonumber(row.assignment_count) or 0
      }
   end)
   clearRuntimePageTables(app)
   return deleted
end

local function categoryDelete(_ENV, app)
   local data = postData(_ENV)
   local id = tonumber(data.id)
   if not id then return _ENV.response:senderror(400, "Missing category id") end
   local row = M.categoryRow(app, id)
   if not row then return _ENV.response:senderror(404, "Category not found") end

   if _ENV.request:method() == "POST" then
      if tostring(data.confirmed) ~= "true" then
         return _ENV.response:senderror(400, "Deletion was not confirmed")
      end
      M.deleteCategory(app, id)
      return redirect(_ENV, app, "/admin/categories/")
   end

   _ENV.adminCategoryDelete = row
   return layout(_ENV, app, "Delete Category", "categories", function()
      response:include(app.url("/admin/categories/delete.lsp"), true)
   end)
end

local function saveContent(_ENV, app, isNew)
   persistContent(app, postData(_ENV), isNew)
   return redirect(_ENV, app, "/admin/content/")
end

local function editContent(_ENV, app)
   if _ENV.request:method() == "POST" then
      return saveContent(_ENV, app, false)
   end
   local id = tonumber(postData(_ENV).id)
   if not id then return _ENV.response:senderror(400, "Missing content id") end
   local row = db.readOne(app, "SELECT * FROM content WHERE id=" .. id)
   if not row then return _ENV.response:senderror(404, "Content not found") end
   return contentForm(_ENV, app, row)
end

local function newContent(_ENV, app)
   if _ENV.request:method() == "POST" then
      return saveContent(_ENV, app, true)
   end
   return contentForm(_ENV, app)
end

local function previewContent(_ENV, app)
   local id = tonumber(postData(_ENV).id)
   if not id then return _ENV.response:senderror(400, "Missing content id") end
   local row = db.readOne(app, "SELECT * FROM content WHERE id=" .. id)
   if not row then return _ENV.response:senderror(404, "Content not found") end
   local publicPath = assert(contentpath.publicPath(app, row.type, row.path))
   return redirect(_ENV, app, publicPath .. "?cms-preview=" .. id)
end

local function contentDelete(_ENV, app)
   local data = postData(_ENV)
   local id = tonumber(data.id)
   if not id then return _ENV.response:senderror(400, "Missing content id") end
   local dependencies, dependencyErr = M.contentDependencies(app, id)
   if not dependencies then return _ENV.response:senderror(404, dependencyErr or "Content not found") end

   if _ENV.request:method() == "POST" then
      M.deleteContent(app, data, dependencies)
      return redirect(_ENV, app, "/admin/content/")
   end

   _ENV.adminContentDelete = dependencies
   return layout(_ENV, app, "Delete Content", "content", function()
      response:include(app.url("/admin/content/delete.lsp"), true)
   end)
end

function M.contentDependencies(app, id)
   return contentService.dependencies(app, { id = tonumber(id) })
end

function M.deleteContent(app, data, dependencies)
   local id = tonumber(data.id)
   if not id then validation.fail("Missing content id") end
   dependencies = dependencies or M.contentDependencies(app, id)
   if not dependencies then validation.fail("Content not found") end
   if tostring(data.confirmed) ~= "true" then validation.fail("Deletion was not confirmed") end
   local menuItemsAction = trim(data.menu_items_action)
   local redirectsAction = trim(data.redirects_action)
   if #dependencies.menuItems == 0 then
      menuItemsAction = "preserve"
   elseif menuItemsAction ~= "preserve" and menuItemsAction ~= "delete" then
      validation.fail("Choose whether linked menu items should be preserved or deleted")
   end
   if #dependencies.redirects == 0 then
      redirectsAction = "preserve"
   elseif redirectsAction ~= "preserve" and redirectsAction ~= "delete" then
      validation.fail("Choose whether related redirects should be preserved or deleted")
   end
   local deleted, deleteErr = contentService.deletePermanent(app, {
      id = id,
      expectedUpdatedAt = dependencies.content.updatedAt,
      confirmed = true,
      menuItemsAction = menuItemsAction,
      redirectsAction = redirectsAction,
   })
   if not deleted then validation.fail(deleteErr or "Content deletion failed") end
   clearRuntimePageTables(app)
   return deleted
end

function M.menuDeleteInfo(app, id)
   id = tonumber(id)
   local item
   for _, row in ipairs(M.menuTreeItems(app)) do
      if tonumber(row.id) == id then
         item = row
         break
      end
   end
   if not item then return nil, "Menu item not found" end
   local children = db.readRows(app,
      "SELECT id,label,url FROM menu_items WHERE parent_id=" .. id .. " ORDER BY position,id")
   return { item = item, children = children }
end

function M.deleteMenuItem(app, data)
   local id = tonumber(data.id)
   if not id then validation.fail("Missing menu item id") end
   if tostring(data.confirmed) ~= "true" then validation.fail("Deletion was not confirmed") end
   db.withWrite(app, function(conn)
      local current = db.one(conn, "SELECT id FROM menu_items WHERE id=" .. id)
      if not current then validation.fail("Menu item does not exist") end
      assert(conn:execute("DELETE FROM menu_items WHERE id=" .. id))
   end)
   clearRuntimePageTables(app)
   return true
end

local function menuDelete(_ENV, app)
   return _ENV.response:include(app.url("/admin/menus/delete.lsp"), true)
end

function M.mutateMenu(app, data)
   local action = trim(data.action)
   local affectedId
   db.withWrite(app, function(conn)
      if action == "toggle-hidden" then
         local id = assert(tonumber(data.id), "Invalid menu item id")
         assert(conn:execute("UPDATE menu_items SET hidden=CASE WHEN COALESCE(hidden,0)=0 THEN 1 ELSE 0 END WHERE id=" .. id))
         affectedId = id
      elseif action == "add" then
         local menu = db.one(conn, "SELECT id FROM menus WHERE slug='primary'")
         assert(menu, "Missing primary menu")
         local menuId = tonumber(menu.id)
         local url, urlErr = normalizeMenuUrl(data.url)
         if not url then validation.fail(urlErr) end
         local label = trim(data.label)
         if label == "" then validation.fail("Menu label is required") end
         local position = tonumber(data.position) or 0
         local parent = tonumber(data.parent_id) or inferParentId(app, conn, menuId, url)
         local parentErr
         parent, parentErr = validation.menuParent(conn, menuId, parent)
         if parentErr then validation.fail(parentErr) end
         local parentSql = parent and tostring(parent) or "NULL"
         assert(conn:execute("INSERT INTO menu_items(menu_id,parent_id,content_id,label,url,position,hidden) VALUES(" ..
            menuId .. "," .. parentSql .. ",NULL," .. quote(label) .. "," ..
            quote(url) .. "," .. position .. ",0)"))
         local inserted = db.one(conn, "SELECT last_insert_rowid() id")
         affectedId = inserted and tonumber(inserted.id)
      elseif action == "update" then
         local id = assert(tonumber(data.id), "Invalid menu item id")
         local item = db.one(conn, "SELECT menu_id FROM menu_items WHERE id=" .. id)
         if not item then validation.fail("Menu item does not exist") end
         local menuId = tonumber(item.menu_id)
         local url, urlErr = normalizeMenuUrl(data.url)
         if not url then validation.fail(urlErr) end
         local label = trim(data.label)
         if label == "" then validation.fail("Menu label is required") end
         local position = tonumber(data.position) or 0
         local parent = tonumber(data.parent_id)
         local parentErr
         parent, parentErr = validation.menuParent(conn, menuId, parent, id)
         if parentErr then validation.fail(parentErr) end
         local parentSql = parent and tostring(parent) or "NULL"
         assert(conn:execute("UPDATE menu_items SET label=" .. quote(label) ..
            ",url=" .. quote(url) ..
            ",parent_id=" .. parentSql ..
            ",position=" .. position ..
            " WHERE id=" .. id))
         affectedId = id
      else
         validation.fail("Unsupported menu action")
      end
   end)
   clearRuntimePageTables(app)
   return M.menuItem(app, affectedId)
end

local function redirectsPage(_ENV, app)
   local data = postData(_ENV)
   if _ENV.request:method() == "POST" then
      local action = trim(data.action)
      db.withWrite(app, function(conn)
         if action == "delete" then
            local id = assert(tonumber(data.id), "Invalid redirect id")
            assert(conn:execute("DELETE FROM redirects WHERE id=" .. id))
         elseif action == "add" then
            local status, statusErr = validation.redirectStatus(data.status_code)
            if not status then validation.fail(statusErr) end
            local fromPath, fromErr = validation.path(data.from_path)
            if not fromPath then validation.fail(fromErr) end
            local toPath, toErr = validation.url(data.to_path, true)
            if not toPath then validation.fail(toErr) end
            local saved, saveErr = redirectservice.saveConn(conn, fromPath, toPath, status)
            if not saved then validation.fail(saveErr) end
         else
            validation.fail("Unsupported redirect action")
         end
      end)
      clearRuntimePageTables(app)
      return redirect(_ENV, app, "/admin/redirects/")
   end
   _ENV.adminRedirects = db.readRows(app, "SELECT * FROM redirects ORDER BY from_path")
   return layout(_ENV, app, "Redirects", "redirects", function()
      response:include(app.url("/admin/redirects/page.lsp"), true)
   end)
end

local function themesPage(_ENV, app)
   local data = postData(_ENV)
   if _ENV.request:method() == "POST" then
      local themeName, themeErr = theme.normalizeName(data.theme)
      if not themeName then
         _ENV.response:senderror(400, themeErr)
         return true
      end
      local activated, activateErr = pcall(theme.activateAndPersist, app, themeName)
      if not activated then
         _ENV.response:senderror(400, "Theme activation failed: " .. tostring(activateErr))
         return true
      end
      clearRuntimePageTables(app)
      return redirect(_ENV, app, "/admin/themes/")
   end
   local active = db.readOne(app, "SELECT value FROM options WHERE key='active_theme'")
   active = theme.normalizeName(active and active.value or app.defaultTheme or "default") or app.defaultTheme or "default"
   _ENV.adminThemes = { active = active, items = theme.list(app) }
   return layout(_ENV, app, "Themes", "themes", function()
      response:include(app.url("/admin/themes/form.lsp"), true)
   end)
end

local function settingsPage(_ENV, app)
   local data = postData(_ENV)
   local values, message = app.settings or settings.load(app)
   if _ENV.request:method() == "POST" then
      values = {
         htmxEnabled = data.htmx_enabled == "1" or data.htmx_enabled == "on",
         smqEnabled = data.smq_enabled == "1" or data.smq_enabled == "on",
         blogBasePath = data.blog_base_path,
         notFoundEnabled = data.not_found_enabled == "1" or data.not_found_enabled == "on",
         notFoundPath = data.not_found_path
      }
      local blogPath, blogErr = validation.path(data.blog_base_path, "/blog/")
      local notFoundPath, notFoundErr = validation.path(data.not_found_path, "/404/")
      if not blogPath or not notFoundPath then
         message = blogErr or notFoundErr
         response:setstatus(400)
      else
         values.blogBasePath, values.notFoundPath = blogPath, notFoundPath
         local updated, updateErr = settings.updateWithRuntime(app, values, function()
            notfound.configure(app)
            local smqOk, smqErr = smqservice.configure(app)
            if not smqOk then error(smqErr, 2) end
         end)
         if not updated then
            mako.log("Updating CMS settings failed: " .. tostring(updateErr), "cms-admin")
            values.blogBasePath, values.notFoundPath = data.blog_base_path, data.not_found_path
            message = "Settings could not be applied. Check the server log before retrying."
            response:setstatus(500)
         else
            clearRuntimePageTables(app)
            return redirect(_ENV, app, "/admin/settings/?saved=1")
         end
      end
   end

   _ENV.adminSettings = { values = values, message = message, saved = data.saved == "1" }
   return layout(_ENV, app, "Settings", "settings", function()
      response:include(app.url("/admin/settings/form.lsp"), true)
   end)
end

local function usersPage(_ENV, app)
   local authInfo = adminauth.info(app)
   local managementUrl = app.identityAccessUi and
      app.identityAccessUi.managementUrl or
      (authInfo.borrowed and authInfo.managementUrl)
   if managementUrl then
      managementUrl = appUrl(app, managementUrl)
      if managementUrl:sub(1, 2) == "//" then
         _ENV.response:setstatus(302)
         _ENV.response:setheader("location", managementUrl)
         _ENV.response:write("")
      else
         _ENV.response:sendredirect(managementUrl)
      end
      return true
   end
   local message
   local data = postData(_ENV)
   if _ENV.request:method() == "POST" then
      local action = trim(data.action)
      if action == "save" then
         local ok, err
         if not data.password or data.password == "" then
            err = "Password is required"
         else
            ok, err = adminauth.setUser(app, data.username, data.password)
         end
         if ok then
            return redirect(_ENV, app, "/admin/users/")
         end
         message = err or "User update failed"
      elseif action == "remove" then
         local ok, err = adminauth.setUser(app, data.username, nil)
         if ok then
            return redirect(_ENV, app, "/admin/users/")
         end
         message = err or "User removal failed"
      elseif action == "reset" then
         local ok, err = adminauth.reset(app, _ENV.request:user())
         if ok then return redirect(_ENV, app, "/admin/users/") end
         message = err or "Authentication reset failed"
      end
   end

   _ENV.adminUsers = {
      users = adminauth.users(app), available = adminauth.available(app), message = message,
      username = message and data.action == "save" and data.username or ""
   }
   return layout(_ENV, app, "Users", "users", function()
      response:include(app.url("/admin/users/page.lsp"), true)
   end)
end

local function mcpPage(_ENV, app)
   local message
   local data = postData(_ENV)
   if _ENV.request:method() == "POST" then
      if data.action == "disable" then
         mcpconfig.disable(app)
         return redirect(_ENV, app, "/admin/mcp/")
      end
      local ok, err = mcpconfig.set(app, data.token)
      if ok then return redirect(_ENV, app, "/admin/mcp/") end
      message = err
   end

   _ENV.adminMcp = { enabled = mcpconfig.enabled(app), message = message }
   return layout(_ENV, app, "MCP", "mcp", function()
      response:include(app.url("/admin/mcp/form.lsp"), true)
   end)
end

local function helpPage(_ENV, app)
   return layout(_ENV, app, "Help", "help", function()
      response:include(appUrl(app, "/admin/.help.html"), true)
   end)
end

local routes = {
   [""] = dashboard,
   ["content/edit"] = editContent,
   ["content/new"] = newContent,
   ["content/preview"] = previewContent,
   ["content/delete"] = contentDelete,
   ["categories/delete"] = categoryDelete,
   ["menus/delete"] = menuDelete,
   ["redirects/"] = redirectsPage,
   ["themes/"] = themesPage,
   ["settings/"] = settingsPage,
   ["users/"] = usersPage,
   ["mcp/"] = mcpPage,
   ["help/"] = helpPage,
}

function M.handle(_ENV, app, relpath)
   local uri = _ENV.request:uri():gsub("%?.*$", "")
   local appPath = app.pathFromUri and app.pathFromUri(uri) or uri
   local path = tostring(relpath or ""):gsub("%?.*$", ""):gsub("^/+", "")
   -- The authenticator includes its hidden login page before a session exists.
   if path == ".login.lsp" then return false end
   if appPath == "/admin" then
      return redirect(_ENV, app, "/admin/")
   end
   if path == "content/" or path == "categories/" or path == "menus/" or
      path:match("^content/.+%.lsp$") or
      path:match("^categories/.+%.lsp$") or
      path:match("^menus/.+%.lsp$") or
      path:match("^settings/.+%.lsp$") or
      path:match("^redirects/.+%.lsp$") or
      path:match("^themes/.+%.lsp$") or
      path:match("^dashboard/.+%.lsp$") or
      path:match("^users/.+%.lsp$") or
      path:match("^mcp/.+%.lsp$") or
      path:match("^includes/.+%.lsp$") then
      return false
   end
   if not adminauth.authenticate(app, _ENV, path) then
      return true
   end
   if _ENV.request:method() == "POST" then
      local data = postData(_ENV)
      if not csrf.validate(_ENV, data) then
         _ENV.response:senderror(403, "Invalid or missing CSRF token")
         return true
      end
   end
   local handler = routes[path]
   if not handler and app.pluginAdmin then
      local entry = app.pluginAdmin.routes[path]
      handler = entry and entry.handler
   end
   if handler then
      local ok, result = pcall(handler, _ENV, app)
      if ok then return result end
      if type(result) == "table" and result.cmsValidation then
         if _ENV.response:initial() then _ENV.response:reset() end
         _ENV.response:senderror(400, result.message)
         return true
      end
      error(result, 2)
   end
   return false
end

function M.new(app)
   return function(_ENV, relpath)
      return M.handle(_ENV, app, relpath)
   end
end

return M
