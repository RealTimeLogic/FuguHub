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

local M = {}
local ADMIN_CSS_VERSION = "20260727-3"

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

local function selected(current, value)
   return tostring(current or "") == value and " selected" or ""
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
   response:write("<!doctype html><html><head><meta charset='utf-8'>")
   response:write("<meta name='viewport' content='width=device-width, initial-scale=1'>")
   response:write("<title>", esc(title), " - CMS Admin</title>")
   response:write("<link rel='stylesheet' href='", appUrl(app, "/admin/admin.css?v=" .. ADMIN_CSS_VERSION), "'>")
   response:write("<script defer src='", appUrl(app, "/admin/admin.js"), "'></script>")
   response:write("</head><body><div class='admin-shell'><aside class='sidebar'>")
   response:write("<h1 class='brand'>CMS Admin</h1><nav class='nav'>")
   local authInfo = adminauth.info(app)
   local identityAccessInstalled = app.identityAccessUi ~= nil
   local externalIdentityAccess = authInfo.borrowed and authInfo.managementUrl
   for _, item in ipairs(nav) do
      if item.id ~= "users" or
         (not identityAccessInstalled and not externalIdentityAccess) then
         response:write("<a href='", appUrl(app, item.href), "'")
         if item.id == active then response:write(" class='active'") end
         response:write(">", esc(item.label), "</a>")
      end
   end
   if externalIdentityAccess then
      response:write("<a href='", esc(appUrl(app, externalIdentityAccess)),
         "'>Users &amp; Access</a>")
   end
   local pluginAdmin = app.pluginAdmin
   if pluginAdmin then
      for _, item in ipairs(pluginAdmin.nav) do
         response:write("<a href='", appUrl(app, item.href), "'")
         if item.active == active then response:write(" class='active'") end
         response:write(">", esc(item.label), "</a>")
      end
   end
   response:write("</nav></aside><main class='content'>")
   response:write("<div class='topbar'><h1>", esc(title), "</h1><a href='", appUrl(app, "/"), "' class='button secondary'>View Site</a></div>")
   if not adminauth.available(app) then
      response:write("<div class='notice'>Admin authentication is unavailable: ",
         esc(adminauth.reason(app) or "Identity service error"), ".</div>")
    elseif not adminauth.enabled(app) then
      local setupUrl = "/admin/users/"
      local setupLabel = "Add an admin user"
      if identityAccessInstalled then
         setupUrl = app.identityAccessUi.managementUrl or
            "/admin/plugins/identity-access/"
         setupLabel = "Configure a CMS administrator"
      elseif authInfo.managementUrl then
         setupUrl = authInfo.managementUrl
         setupLabel = "Configure a CMS administrator"
      end
      response:write("<div class='notice'>Admin authentication is disabled. <a href='",
         esc(appUrl(app, setupUrl)), "'>", setupLabel, "</a> to enable it.</div>")
   end
   for _, failure in ipairs(pluginFailures(app)) do
      response:write("<div class='notice'><strong>Plugin ", esc(failure.id),
         " is unavailable.</strong> ", esc(failure.message), ".</div>")
   end
   body()
   response:write("</main></div></body></html>")
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

function M.contentRows(app, filterType)
   filterType = trim(filterType)
   local where = ""
   if filterType == "page" or filterType == "post" then
      where = " WHERE type=" .. quote(filterType)
   else
      filterType = ""
   end
   local rows = db.readRows(app,
      "SELECT id,type,path,title,render_mode,status,updated_at,cache_policy FROM content" ..
      where .. " ORDER BY type,path LIMIT 500")
   for _, row in ipairs(rows) do
      row.public_path = assert(contentpath.publicPath(app, row.type, row.path))
   end
   return rows, filterType
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
   local function append(row, depth)
      local id = tonumber(row.id)
      if visited[id] then return end
      visited[id] = true
      row.tree_depth = depth
      ordered[#ordered + 1] = row
      for _, child in ipairs(children[id] or {}) do
         append(child, depth + 1)
      end
   end

   for _, row in ipairs(roots) do
      append(row, 0)
   end
   table.sort(items, menuItemOrder)
   for _, row in ipairs(items) do
      local id = tonumber(row.id)
      if not visited[id] then
         row.tree_parent_label = nil
         append(row, 0)
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
   local stats = {
      content = db.readOne(app, "SELECT COUNT(*) count FROM content"),
      pages = db.readOne(app, "SELECT COUNT(*) count FROM content WHERE type='page'"),
      posts = db.readOne(app, "SELECT COUNT(*) count FROM content WHERE type='post'"),
      lsp = db.readOne(app, "SELECT COUNT(*) count FROM content WHERE render_mode='lsp'"),
      redirects = db.readOne(app, "SELECT COUNT(*) count FROM redirects"),
      menuItems = db.readOne(app, "SELECT COUNT(*) count FROM menu_items"),
   }
   local activeTheme = db.readOne(app, "SELECT value FROM options WHERE key='active_theme'")
   return layout(_ENV, app, "Dashboard", "dashboard", function()
      response:write("<section class='grid'>")
      response:write("<div class='stat'><span class='value'>", esc(stats.content.count), "</span><span class='label'>Content</span></div>")
      response:write("<div class='stat'><span class='value'>", esc(stats.pages.count), "</span><span class='label'>Pages</span></div>")
      response:write("<div class='stat'><span class='value'>", esc(stats.posts.count), "</span><span class='label'>Posts</span></div>")
      response:write("<div class='stat'><span class='value'>", esc(stats.lsp.count), "</span><span class='label'>LSP Content</span></div>")
      response:write("<div class='stat'><span class='value'>", esc(stats.redirects.count), "</span><span class='label'>Redirects</span></div>")
      response:write("<div class='stat'><span class='value'>", esc(stats.menuItems.count), "</span><span class='label'>Menu Items</span></div>")
      response:write("<div class='stat'><span class='text-value'>", esc(activeTheme and activeTheme.value or app.defaultTheme or "default"), "</span><span class='label'>Theme</span></div>")
      response:write("</section>")
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
   return layout(_ENV, app, isNew and "New Content" or "Edit Content", "content", function()
      response:write("<section class='panel'><div class='panel-body'>")
      response:write("<form method='post' enctype='multipart/form-data' action='", appUrl(app, isNew and "/admin/content/new" or "/admin/content/edit"), "'")
      if not isNew then
         response:write(" hx-post='", appUrl(app, "/admin/content/save.lsp"),
            "' hx-encoding='multipart/form-data' hx-target='#content-save-status' hx-swap='innerHTML'")
      end
      response:write(">")
      csrf.field(_ENV)
      if not isNew then response:write("<input type='hidden' name='id' value='", esc(row.id), "'>") end
      response:write("<div class='form-grid'>")
      response:write("<div class='field'><label>Type</label><select name='type'>")
      response:write("<option value='page'", selected(row.type, "page"), ">Page</option>")
      response:write("<option value='post'", selected(row.type, "post"), ">Post</option></select></div>")
      response:write("<div class='field'><label>Status</label><select name='status'>")
      response:write("<option value='published'", selected(row.status, "published"), ">Published</option>")
      response:write("<option value='draft'", selected(row.status, "draft"), ">Draft</option></select></div>")
      response:write("<div class='field full'><label>Title</label><input name='title' value='", esc(row.title), "' required></div>")
      response:write("<div class='field'><label>Path</label><input name='path' value='", esc(row.path), "' required><span class='muted'>For posts, enter only the article path. The configured Blog Base URL is added automatically.</span></div>")
      response:write("<div class='field'><label>Render Mode</label><select name='render_mode'>")
      response:write("<option value='html'", selected(row.render_mode, "html"), ">HTML</option>")
      response:write("<option value='lsp'", selected(row.render_mode, "lsp"), ">LSP</option></select></div>")
      response:write("<div class='field'><label>Browser Cache</label><select name='cache_policy'>")
      response:write("<option value='default'", selected(row.cache_policy, "default"), ">Default</option>")
      response:write("<option value='revalidate'", selected(row.cache_policy, "revalidate"), ">Revalidate</option>")
      response:write("<option value='no-cache'", selected(row.cache_policy, "no-cache"), ">No cache</option>")
      response:write("<option value='no-store'", selected(row.cache_policy, "no-store"), ">No store</option></select></div>")
      response:write("<div class='field full'><label>Meta Description</label><textarea class='short' name='meta_description'>", esc(row.meta_description), "</textarea></div>")
      response:write("<div class='field full'><label>Extra Head HTML</label><textarea class='short' name='head_html'>", esc(row.head_html), "</textarea></div>")
      response:write("<fieldset class='field full'><legend>Categories</legend>")
      if #categories == 0 then
         response:write("<p class='muted'>No categories exist. <a href='",
            appUrl(app, "/admin/categories/"), "'>Create a category</a>.</p>")
      else
         response:write("<div class='category-options'>")
         for _, category in ipairs(categories) do
             response:write("<label class='choice-row'><input type='checkbox' name='category_",
                esc(category.id), "' value='1'",
                assignedCategories[tonumber(category.id)] and " checked" or "",
                "><strong>", esc(category.name), "</strong></label>")
          end
         response:write("</div><p class='muted'>Category assignments apply to posts.</p>")
      end
      response:write("</fieldset>")
      response:write("<div class='field full'><label>Body</label><textarea name='body_html'>", esc(row.body_html), "</textarea></div>")
      response:write("</div><div class='actions'><button type='submit'>Save</button>")
      if not isNew and row.status ~= "published" then response:write("<a class='button secondary' href='", appUrl(app, "/admin/content/preview?id=" .. tostring(row.id)), "'>Preview</a>") end
      response:write("<a class='button secondary' href='", appUrl(app, "/admin/content/"), "'>Cancel</a></div>")
      if not isNew then
         response:write("<div id='content-save-status' class='fragment-status' aria-live='polite'></div>")
      end
      response:write("</form></div></section>")
      if not isNew then
         response:write("<section class='panel danger-zone'><div class='panel-body'><h2>Delete Content</h2>")
         response:write("<p class='muted'>Permanently delete this ", esc(row.type), " after reviewing its dependencies.</p>")
         response:write("<a class='button danger' href='", appUrl(app, "/admin/content/delete?id=" .. tostring(row.id)), "'>Delete Permanently</a>")
         response:write("</div></section>")
      end
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

   return layout(_ENV, app, "Delete Category", "categories", function()
      response:write("<section class='panel danger-zone'><div class='panel-body'>")
      response:write("<h2>Delete Category</h2><p>Delete <strong>", esc(row.name),
         "</strong>? Its ", esc(row.assignmentCount),
         " content assignments will be removed. Posts are not deleted.</p>")
      response:write("<form method='post'>")
      csrf.field(_ENV)
      response:write("<input type='hidden' name='id' value='", esc(id), "'>")
      response:write("<input type='hidden' name='confirmed' value='true'>")
      response:write("<div class='actions'><button class='danger' type='submit'>Delete Category</button>")
      response:write("<a class='button secondary' href='",
         appUrl(app, "/admin/categories/"), "'>Cancel</a></div></form>")
      response:write("</div></section>")
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

   return layout(_ENV, app, "Delete Content", "content", function()
      response:write("<section class='panel danger-zone'><div class='panel-body'>")
      response:write("<h2>Delete Permanently</h2><p>This will permanently delete <strong>",
         esc(dependencies.content.title), "</strong> at <code>", esc(dependencies.content.path),
         "</code>. This CMS does not have a trash or restore feature.</p>")
      if dependencies.activeNotFoundPage then
         response:write("<div class='notice error'>The active editable 404 page cannot be deleted. Configure another 404 page or disable the editable 404 handler first.</div>")
         response:write("<a class='button secondary' href='",
            appUrl(app, "/admin/content/edit?id=" .. tostring(id)), "'>Back to Content</a>")
         response:write("</div></section>")
         return
      end
      response:write("<form method='post'>")
      csrf.field(_ENV)
      response:write("<input type='hidden' name='id' value='", esc(id), "'>")
      response:write("<input type='hidden' name='confirmed' value='true'>")

      if #dependencies.menuItems > 0 then
         response:write("<fieldset><legend>Linked Menu Items</legend><p class='muted'>Choose what happens to these menu entries:</p><ul class='dependency-list'>")
         for _, item in ipairs(dependencies.menuItems) do
            response:write("<li><strong>", esc(item.label), "</strong> in ", esc(item.menu_slug),
               " (<code>", esc(item.url), "</code>)</li>")
         end
         response:write("</ul><label class='choice-row'><input type='radio' name='menu_items_action' value='preserve' checked> Preserve the menu items and their URLs</label>")
         response:write("<label class='choice-row'><input type='radio' name='menu_items_action' value='delete'> Delete the linked menu items</label></fieldset>")
      end

      if #dependencies.redirects > 0 then
         response:write("<fieldset><legend>Related Redirects</legend><p class='muted'>Choose what happens to redirects that use this content path:</p><ul class='dependency-list'>")
         for _, item in ipairs(dependencies.redirects) do
            response:write("<li><code>", esc(item.from_path), "</code> to <code>",
               esc(item.to_path), "</code></li>")
         end
         response:write("</ul><label class='choice-row'><input type='radio' name='redirects_action' value='preserve' checked> Preserve the redirects</label>")
         response:write("<label class='choice-row'><input type='radio' name='redirects_action' value='delete'> Delete the related redirects</label></fieldset>")
      end

      if #dependencies.childContent > 0 then
         response:write("<div class='notice'><strong>Child paths will not be deleted.</strong><ul class='dependency-list'>")
         for _, item in ipairs(dependencies.childContent) do
            response:write("<li>", esc(item.title), " (<code>", esc(item.path), "</code>)</li>")
         end
         response:write("</ul></div>")
      end
      response:write("<div class='actions'><button class='danger' type='submit'>Delete Permanently</button>")
      response:write("<a class='button secondary' href='",
         appUrl(app, "/admin/content/edit?id=" .. tostring(id)), "'>Cancel</a></div>")
      response:write("</form></div></section>")
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
   local data = postData(_ENV)
   local id = tonumber(data.id)
   if not id then return _ENV.response:senderror(400, "Missing menu item id") end
   local info, infoErr = M.menuDeleteInfo(app, id)
   if not info then return _ENV.response:senderror(404, infoErr) end
   local item = info.item
   local children = info.children

   if _ENV.request:method() == "POST" then
      M.deleteMenuItem(app, data)
      return redirect(_ENV, app, "/admin/menus/")
   end

   return layout(_ENV, app, "Delete Menu Item", "menus", function()
      response:write("<section class='panel danger-zone'><div class='panel-body'>")
      response:write("<h2>Delete Menu Item</h2><p>Permanently delete <strong>", esc(item.label),
         "</strong> from ", esc(item.menu_name), "?</p><p class='muted'>The content at <code>",
         esc(item.url), "</code> will not be deleted.</p>")
      if #children > 0 then
         response:write("<div class='notice'><strong>Child items will become top-level menu items.</strong><ul class='dependency-list'>")
         for _, child in ipairs(children) do
            response:write("<li>", esc(child.label), " (<code>", esc(child.url), "</code>)</li>")
         end
         response:write("</ul></div>")
      end
      response:write("<form method='post'>")
      csrf.field(_ENV)
      response:write("<input type='hidden' name='id' value='", esc(id), "'>")
      response:write("<input type='hidden' name='confirmed' value='true'>")
      response:write("<div class='actions'><button class='danger' type='submit'>Delete Menu Item</button>")
      response:write("<a class='button secondary' href='", appUrl(app, "/admin/menus/"), "'>Cancel</a></div>")
      response:write("</form></div></section>")
   end)
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
   local redirects = db.readRows(app, "SELECT * FROM redirects ORDER BY from_path")
   return layout(_ENV, app, "Redirects", "redirects", function()
      response:write("<section class='panel'><div class='panel-body'><h2>Add Redirect</h2>")
      response:write("<form method='post'><input type='hidden' name='action' value='add'><div class='form-grid'>")
      csrf.field(_ENV)
      response:write("<div class='field'><label>From</label><input name='from_path' required></div>")
      response:write("<div class='field'><label>To</label><input name='to_path' required></div>")
      response:write("<div class='field'><label>Status</label><input name='status_code' value='302'></div>")
      response:write("</div><div class='actions'><button type='submit'>Add</button></div></form></div></section>")
      response:write("<section class='panel'><table><thead><tr><th>ID</th><th>From</th><th>To</th><th>Status</th><th></th></tr></thead><tbody>")
      for _, row in ipairs(redirects) do
         response:write("<tr><td>", esc(row.id), "</td><td>", esc(row.from_path), "</td><td>", esc(row.to_path), "</td><td>", esc(row.status_code), "</td>")
         response:write("<td><form class='inline' method='post'><input type='hidden' name='action' value='delete'><input type='hidden' name='id' value='", esc(row.id), "'>")
         csrf.field(_ENV)
         response:write("<button class='danger' type='submit'>Delete</button></form></td></tr>")
      end
      response:write("</tbody></table></section>")
   end)
end

local function listThemes(app)
   return theme.list(app)
end

local function normalizeThemeName(name)
   return theme.normalizeName(name)
end

local function themesPage(_ENV, app)
   local data = postData(_ENV)
   if _ENV.request:method() == "POST" then
      local themeName, themeErr = normalizeThemeName(data.theme)
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
   active = normalizeThemeName(active and active.value or app.defaultTheme or "default") or app.defaultTheme or "default"
   local themes = listThemes(app)
   return layout(_ENV, app, "Themes", "themes", function()
      response:write("<section class='panel'><div class='panel-body'><h2>Active Theme</h2>")
      response:write("<form method='post'>")
      csrf.field(_ENV)
      response:write("<div class='form-grid'><div class='field'><label>Theme</label><select name='theme'>")
      for _, theme in ipairs(themes) do
         local label = theme.name
         if theme.source == "zip" then
            label = label .. " (zip)"
         elseif theme.source == "built-in" then
            label = label .. " (built-in fallback)"
         end
         response:write("<option value='", esc(theme.name), "'", selected(active, theme.name), ">", esc(label), "</option>")
      end
      response:write("</select></div></div><div class='actions'><button type='submit'>Save</button></div></form>")
      response:write("<p class='muted'>Current runtime theme: ", esc(app.theme and app.theme.name or active))
      if app.theme and app.theme.source then
         response:write(" from ", esc(app.theme.source))
      end
      response:write("</p>")
      response:write("</div></section>")
   end)
end

local function settingsPage(_ENV, app)
   local data = postData(_ENV)
   if _ENV.request:method() == "POST" then
      local blogPath, blogErr = validation.path(data.blog_base_path, "/blog/")
      if not blogPath then return _ENV.response:senderror(400, blogErr) end
      local notFoundPath, notFoundErr = validation.path(data.not_found_path, "/404/")
      if not notFoundPath then return _ENV.response:senderror(400, notFoundErr) end
      local updated, updateErr = settings.updateWithRuntime(app, {
         htmxEnabled = data.htmx_enabled == "1" or data.htmx_enabled == "on",
         smqEnabled = data.smq_enabled == "1" or data.smq_enabled == "on",
         blogBasePath = blogPath,
         notFoundEnabled = data.not_found_enabled == "1" or data.not_found_enabled == "on",
         notFoundPath = notFoundPath
      }, function()
         notfound.configure(app)
         local smqOk, smqErr = smqservice.configure(app)
         if not smqOk then error(smqErr, 2) end
      end)
      if not updated then
         return _ENV.response:senderror(500,
            "Updating CMS settings failed: " .. tostring(updateErr))
      end
      clearRuntimePageTables(app)
      return redirect(_ENV, app, "/admin/settings/")
   end

   local htmxEnabled = settings.isHtmxEnabled(app)
   local smqEnabled = settings.isSmqEnabled(app)
   local blogBasePath = settings.blogBasePath(app)
   local notFoundEnabled = settings.isNotFoundEnabled(app)
   local notFoundPath = settings.notFoundPath(app)
   return layout(_ENV, app, "Settings", "settings", function()
      response:write("<section class='panel'><div class='panel-body'><h2>Public Site</h2>")
      response:write("<form method='post'>")
      csrf.field(_ENV)
      response:write("<div class='form-grid'><div class='field'><label>Blog Base URL</label><input name='blog_base_path' value='", esc(blogBasePath), "' placeholder='/blog/' required><span class='muted'>The CMS combines this base with each stored post path. Changing it updates public post URLs without rewriting post rows.</span></div></div>")
      response:write("<label class='check-row'><input id='setting-htmx' type='checkbox' name='htmx_enabled' value='1'", htmxEnabled and " checked" or "", ">")
      response:write("<span><strong>Enable HTMX navigation</strong><span class='muted'>Serve CMS page fragments for HTMX requests and keep the public page shell loaded during navigation.</span></span></label>")
      response:write("<label class='check-row'><input id='setting-smq' type='checkbox' name='smq_enabled' value='1'", smqEnabled and " checked" or "", htmxEnabled and "" or " disabled", ">")
      response:write("<span><strong>Enable SMQ real-time messaging</strong><span class='muted'>Keep one SMQ connection in the HTMX page shell and provide page-scoped messaging and RPC. Requires HTMX.</span></span></label>")
      response:write("<div class='form-grid' style='margin-top:16px'><div class='field'><label>404 Page URL</label><input name='not_found_path' value='", esc(notFoundPath), "' placeholder='/404/' required></div></div>")
      response:write("<label class='check-row'><input type='checkbox' name='not_found_enabled' value='1'", notFoundEnabled and " checked" or "", ">")
      response:write("<span><strong>Enable editable 404 page</strong><span class='muted'>Install a low-priority fallback directory that forwards unmatched public URLs to this CMS page with HTTP status 404.</span></span></label>")
      response:write("<div class='actions'><button type='submit'>Save Settings</button></div>")
      response:write("</form></div></section><script defer src='",
         appUrl(app, "/admin/settings.js"), "'></script>")
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
         local ok, err = adminauth.setUser(app, data.username, data.password)
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

   local users = adminauth.users(app)
   return layout(_ENV, app, "Users", "users", function()
      if message then
         response:write("<div class='notice'>", esc(message), "</div>")
      end
      response:write("<section class='panel'><div class='panel-body'><h2>Admin Users</h2>")
      if not adminauth.available(app) then
         response:write("<p class='muted'>TPM-backed authentication is not available in this runtime.</p>")
      else
         response:write("<p class='muted'>Create an administrator to protect the admin directory. Users and credentials are stored together in the CMS SQLite database.</p>")
         response:write("<form method='post'><input type='hidden' name='action' value='save'>")
         csrf.field(_ENV)
         response:write("<div class='form-grid'>")
         response:write("<div class='field'><label>Username</label><input name='username' autocomplete='username' required></div>")
         response:write("<div class='field'><label>Password</label><input name='password' type='password' autocomplete='new-password' required></div>")
         response:write("</div><div class='actions'><button type='submit'>Save User</button></div></form>")
      end
      response:write("</div></section>")

      response:write("<section class='panel'><table><thead><tr><th>Username</th><th>Status</th><th></th></tr></thead><tbody>")
      if #users == 0 then
         response:write("<tr><td colspan='3'><span class='muted'>No admin users configured.</span></td></tr>")
      else
         for _, user in ipairs(users) do
            response:write("<tr><td>", esc(user), "</td><td><span class='tag'>active</span></td><td>")
            response:write("<form class='inline-form' method='post'><input type='hidden' name='action' value='remove'>")
            csrf.field(_ENV)
            response:write("<input type='hidden' name='username' value='", esc(user), "'>")
            response:write("<button class='danger' type='submit'>Remove Admin Access</button></form>")
            response:write("</td></tr>")
         end
      end
      response:write("</tbody></table></section>")
      if #users > 0 then
         response:write("<section class='panel'><div class='panel-body'><h2>Reset Authentication</h2>")
         response:write("<p class='muted'>Explicitly remove all users and return the CMS to unprotected bootstrap mode.</p>")
         response:write("<form method='post' onsubmit=\"return confirm('Remove every user and disable authentication?')\">")
         csrf.field(_ENV)
         response:write("<input type='hidden' name='action' value='reset'><button class='danger' type='submit'>Reset All Users</button></form></div></section>")
      end
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

   local enabled = mcpconfig.enabled(app)
   return layout(_ENV, app, "MCP", "mcp", function()
      if message then response:write("<div class='notice'>", esc(message), "</div>") end
      response:write("<section class='panel'><div class='panel-body'><h2>MCP HTTP Server</h2>")
      response:write("<p class='muted'>The MCP endpoint is <code>", esc(appUrl(app, "/mcp/")),
         "</code>. Use this exact URL in MCP Inspector. It remains disabled until a bearer token is saved. The token is encrypted in SQLite with a TPM-derived key and is never displayed again.</p>")
      response:write("<p>Status: <span class='tag", enabled and "" or " hidden", "'>",
         enabled and "enabled" or "disabled", "</span></p>")
      if app.mcpTokenError then
         response:write("<div class='notice'>Stored token error: ", esc(app.mcpTokenError), "</div>")
      end
      response:write("<form method='post'>")
      csrf.field(_ENV)
      response:write("<div class='field'><label>Bearer Token</label><input type='password' name='token' minlength='16' autocomplete='new-password' required></div>")
      response:write("<div class='actions'><button type='submit' name='action' value='save'>Save Token</button>")
      if enabled then
         response:write("<button class='danger' type='submit' name='action' value='disable' formnovalidate>Disable MCP</button>")
      end
      response:write("</div></form></div></section>")
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
   if appPath == "/admin" then
      return redirect(_ENV, app, "/admin/")
   end
   if path == "content/" or path == "categories/" or path == "menus/" or
      path:match("^content/.+%.lsp$") or
      path:match("^categories/.+%.lsp$") or
      path:match("^menus/.+%.lsp$") or
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
