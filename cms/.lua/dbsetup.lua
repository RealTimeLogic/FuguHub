local db = appreq "db"
local schema = appreq "schema"

local M = {}

local function exec(conn, sql)
   local ok, err = conn:execute(sql)
   if not ok then
      error(err, 2)
   end
   return ok
end

local function hasColumn(conn, tableName, columnName)
   for _, row in ipairs(db.rows(conn, "PRAGMA table_info(" .. tableName .. ")")) do
      if row.name == columnName then
         return true
      end
   end
   return false
end

local function addColumn(conn, tableName, columnSql)
   local columnName = columnSql:match("^%s*([%w_]+)")
   if columnName and not hasColumn(conn, tableName, columnName) then
      exec(conn, "ALTER TABLE " .. tableName .. " ADD COLUMN " .. columnSql)
   end
end

local function repairKnownColumns(conn)
   addColumn(conn, "content", "render_mode TEXT NOT NULL DEFAULT 'html'")
   addColumn(conn, "content", "status TEXT NOT NULL DEFAULT 'published'")
   addColumn(conn, "content", "created_at INTEGER")
   addColumn(conn, "content", "updated_at INTEGER")
   addColumn(conn, "content", "meta_description TEXT NOT NULL DEFAULT ''")
   addColumn(conn, "content", "head_html TEXT NOT NULL DEFAULT ''")
   addColumn(conn, "content", "cache_policy TEXT NOT NULL DEFAULT 'default'")
   addColumn(conn, "menu_items", "hidden INTEGER NOT NULL DEFAULT 0")
end

local function normalizePath(path, default)
   path = tostring(path or ""):gsub("^%s+", ""):gsub("%s+$", "")
   if path == "" then path = default or "/" end
   path = path:gsub("[?#].*$", "")
   if path:sub(1, 1) ~= "/" then path = "/" .. path end
   if path:sub(-1) ~= "/" then path = path .. "/" end
   return path
end

local function legacyPostStoragePath(path, blogBasePath)
   path = normalizePath(path)
   blogBasePath = normalizePath(blogBasePath, "/blog/")
   local suffix
   if path ~= blogBasePath and path:sub(1, #blogBasePath) == blogBasePath then
      suffix = path:sub(#blogBasePath + 1)
   else
      suffix = path:match("^/[^/]+/(.+)$") or path:match("^/(.+)$")
   end
   suffix = tostring(suffix or ""):gsub("^/+", "")
   if suffix == "" then
      error("Legacy post path cannot be converted to a relative path: " .. path, 2)
   end
   return normalizePath("/" .. suffix)
end

local function rebuildContentForRelativePostPaths(conn)
   local option = db.one(conn,
      "SELECT value FROM options WHERE key='blog_base_path'")
   local blogBasePath = option and option.value or "/blog/"
   local contentRows = db.rows(conn, "SELECT * FROM content ORDER BY id")
   local termRows = db.rows(conn, "SELECT * FROM content_terms ORDER BY content_id,term_id")
   local menuRows = db.rows(conn, "SELECT * FROM menu_items ORDER BY id")
   local keys = {}

   for _, row in ipairs(contentRows) do
      if row.type == "post" then
         row.path = legacyPostStoragePath(row.path, blogBasePath)
      end
      local key = tostring(row.type) .. "\0" .. tostring(row.path)
      if keys[key] then
         error("Content path migration produces duplicate " .. row.type ..
            " path " .. row.path, 2)
      end
      keys[key] = true
   end

   exec(conn, "DROP TABLE content_terms")
   exec(conn, "DROP TABLE menu_items")
   exec(conn, "ALTER TABLE content RENAME TO content_legacy_full_post_paths")
   exec(conn, schema.contentTableSql("content", false))

   for _, row in ipairs(contentRows) do
      exec(conn, "INSERT INTO content(id,type,path,title,body_html,render_mode,status,created_at,updated_at,meta_description,head_html,cache_policy) VALUES(" ..
         tonumber(row.id) .. "," .. db.quote(row.type) .. "," .. db.quote(row.path) .. "," ..
         db.quote(row.title) .. "," .. db.quote(row.body_html) .. "," ..
         db.quote(row.render_mode) .. "," .. db.quote(row.status) .. "," ..
         (row.created_at and tonumber(row.created_at) or "NULL") .. "," ..
         (row.updated_at and tonumber(row.updated_at) or "NULL") .. "," ..
         db.quote(row.meta_description) .. "," .. db.quote(row.head_html) .. "," ..
         db.quote(row.cache_policy) .. ")")
   end
   exec(conn, "DROP TABLE content_legacy_full_post_paths")

   exec(conn, schema.contentTermsTableSql(false))
   for _, row in ipairs(termRows) do
      exec(conn, "INSERT INTO content_terms(content_id,term_id) VALUES(" ..
         tonumber(row.content_id) .. "," .. tonumber(row.term_id) .. ")")
   end

   exec(conn, schema.menuItemsTableSql(false))
   for _, row in ipairs(menuRows) do
      local contentId = row.content_id and tonumber(row.content_id) or nil
      exec(conn, "INSERT INTO menu_items(id,menu_id,parent_id,content_id,label,url,position,hidden) VALUES(" ..
         tonumber(row.id) .. "," .. tonumber(row.menu_id) .. ",NULL," ..
         (contentId and tostring(contentId) or "NULL") .. "," ..
         db.quote(row.label) .. "," .. db.quote(row.url) .. "," ..
         (tonumber(row.position) or 0) .. "," .. (tonumber(row.hidden) or 0) .. ")")
   end
   for _, row in ipairs(menuRows) do
      if row.parent_id then
         exec(conn, "UPDATE menu_items SET parent_id=" .. tonumber(row.parent_id) ..
            " WHERE id=" .. tonumber(row.id))
      end
   end
end

local function seedEmptyCms(conn)
   local ts = os.time()
   local body = [[
<section class="empty-cms">
  <p>This FuguHub installation does not have public content yet.</p>
  <p><a href="<?lsp= app.url('/admin/') ?>">Open the admin panel</a> to create the first page, configure menus, and choose site settings.</p>
</section>]]

   exec(conn, "INSERT OR IGNORE INTO menus(name,slug) VALUES('Primary','primary')")
   exec(conn, "INSERT OR REPLACE INTO options(key,value) VALUES('active_theme','default')")
   exec(conn, "INSERT OR REPLACE INTO options(key,value) VALUES('htmx_enabled','0')")
   exec(conn, "INSERT OR REPLACE INTO options(key,value) VALUES('smq_enabled','0')")
   exec(conn, "INSERT OR REPLACE INTO options(key,value) VALUES('blog_base_path','/blog/')")
   exec(conn, "INSERT OR REPLACE INTO options(key,value) VALUES('not_found_enabled','1')")
   exec(conn, "INSERT OR REPLACE INTO options(key,value) VALUES('not_found_path','/404/')")
   exec(conn, "INSERT OR IGNORE INTO content(type,path,title,body_html,render_mode,status,created_at,updated_at,meta_description,head_html,cache_policy) VALUES(" ..
      db.quote("page") .. "," ..
      db.quote("/404/") .. "," ..
      db.quote("Page not found") .. "," ..
      db.quote(body) .. "," ..
      db.quote("lsp") .. "," ..
      db.quote("published") .. "," ..
      ts .. "," .. ts .. "," ..
      db.quote("This FuguHub installation is empty.") .. "," ..
      db.quote("") .. "," ..
      db.quote("no-store") .. ")")
end

function M.ensure(app, opts)
   opts = opts or {}
   db.withWrite(app, function(conn)
      for _, sql in ipairs(schema.statements) do
         if not sql:match("^CREATE%s+INDEX") then
            exec(conn, sql)
         end
      end
      repairKnownColumns(conn)
      if schema.contentPathMigrationRequiredConn(conn) then
         rebuildContentForRelativePostPaths(conn)
      end
      for _, sql in ipairs(schema.statements) do
         if sql:match("^CREATE%s+INDEX") then
            exec(conn, sql)
         end
      end
      exec(conn, "UPDATE content SET cache_policy='default' WHERE cache_policy NOT IN ('default','revalidate','no-cache','no-store')")
      if opts.created then
         seedEmptyCms(conn)
      end
   end)
   appreq("identityschema").ensure(app)
end

return M
