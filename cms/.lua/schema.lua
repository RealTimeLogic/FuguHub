local db = appreq "db"

local M = {}

local function createPrefix(tableName, ifNotExists)
   return "CREATE TABLE " .. (ifNotExists and "IF NOT EXISTS " or "") .. tableName
end

function M.contentTableSql(tableName, ifNotExists)
   return createPrefix(tableName or "content", ifNotExists) .. [[ (
   id INTEGER PRIMARY KEY,
   type TEXT NOT NULL,
   path TEXT NOT NULL,
   title TEXT NOT NULL,
   body_html TEXT NOT NULL DEFAULT '',
   render_mode TEXT NOT NULL DEFAULT 'html',
   status TEXT NOT NULL DEFAULT 'published',
   created_at INTEGER,
   updated_at INTEGER,
   meta_description TEXT NOT NULL DEFAULT '',
   head_html TEXT NOT NULL DEFAULT '',
   cache_policy TEXT NOT NULL DEFAULT 'default',
   UNIQUE(type, path)
)]]
end

function M.contentTermsTableSql(ifNotExists)
   return createPrefix("content_terms", ifNotExists) .. [[ (
   content_id INTEGER NOT NULL REFERENCES content(id) ON DELETE CASCADE,
   term_id INTEGER NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
   PRIMARY KEY(content_id, term_id)
)]]
end

function M.menuItemsTableSql(ifNotExists)
   return createPrefix("menu_items", ifNotExists) .. [[ (
   id INTEGER PRIMARY KEY,
   menu_id INTEGER NOT NULL REFERENCES menus(id) ON DELETE CASCADE,
   parent_id INTEGER REFERENCES menu_items(id) ON DELETE SET NULL,
   content_id INTEGER REFERENCES content(id) ON DELETE SET NULL,
   label TEXT NOT NULL,
   url TEXT NOT NULL,
   position INTEGER NOT NULL DEFAULT 0,
   hidden INTEGER NOT NULL DEFAULT 0
)]]
end

M.statements = {
M.contentTableSql("content", true),
[[CREATE TABLE IF NOT EXISTS terms (
   id INTEGER PRIMARY KEY,
   type TEXT NOT NULL,
   name TEXT NOT NULL,
   slug TEXT NOT NULL,
   description TEXT NOT NULL DEFAULT '',
   UNIQUE(type, slug)
)]],
M.contentTermsTableSql(true),
[[CREATE TABLE IF NOT EXISTS menus (
   id INTEGER PRIMARY KEY,
   name TEXT NOT NULL,
   slug TEXT NOT NULL UNIQUE
)]],
M.menuItemsTableSql(true),
[[CREATE TABLE IF NOT EXISTS options (
   key TEXT PRIMARY KEY,
   value TEXT NOT NULL
)]],
[[CREATE TABLE IF NOT EXISTS redirects (
   id INTEGER PRIMARY KEY,
   from_path TEXT NOT NULL UNIQUE,
   to_path TEXT NOT NULL,
   status_code INTEGER NOT NULL DEFAULT 302
)]],
[[CREATE TABLE IF NOT EXISTS identity_credentials (
   id INTEGER PRIMARY KEY CHECK(id=1),
   encrypted_base64 TEXT NOT NULL
)]],
[[CREATE TABLE IF NOT EXISTS identity_profiles (
   username TEXT PRIMARY KEY,
   display_name TEXT NOT NULL DEFAULT '',
   email TEXT NOT NULL DEFAULT '',
   disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0,1)),
   max_users INTEGER NOT NULL DEFAULT 3 CHECK(max_users > 0),
   recycle INTEGER NOT NULL DEFAULT 0 CHECK(recycle IN (0,1)),
   inactive INTEGER NOT NULL DEFAULT 1200 CHECK(inactive >= 0),
   created_at INTEGER NOT NULL,
   updated_at INTEGER NOT NULL
)]],
[[CREATE TABLE IF NOT EXISTS identity_roles (
   name TEXT PRIMARY KEY,
   description TEXT NOT NULL DEFAULT '',
   system_role INTEGER NOT NULL DEFAULT 0 CHECK(system_role IN (0,1))
)]],
[[CREATE TABLE IF NOT EXISTS identity_user_roles (
   username TEXT NOT NULL REFERENCES identity_profiles(username) ON DELETE CASCADE,
   role_name TEXT NOT NULL REFERENCES identity_roles(name) ON DELETE RESTRICT,
   PRIMARY KEY(username, role_name)
)]],
[[CREATE TABLE IF NOT EXISTS identity_audit (
   id INTEGER PRIMARY KEY,
   actor TEXT,
   action TEXT NOT NULL,
   target TEXT,
   detail_json TEXT NOT NULL DEFAULT '{}',
   created_at INTEGER NOT NULL
)]],
[[CREATE INDEX IF NOT EXISTS idx_content_type_status_date ON content(type, status, updated_at)]],
[[CREATE INDEX IF NOT EXISTS idx_content_path_status_type ON content(path, status, type)]],
[[CREATE INDEX IF NOT EXISTS idx_menu_items_menu_parent_pos ON menu_items(menu_id, parent_id, position)]],
[[CREATE INDEX IF NOT EXISTS idx_terms_type_name ON terms(type, name)]],
[[CREATE INDEX IF NOT EXISTS idx_identity_user_roles_role ON identity_user_roles(role_name, username)]],
[[CREATE INDEX IF NOT EXISTS idx_identity_audit_created ON identity_audit(created_at DESC, id DESC)]],
}

local requiredIndexes = {
   "idx_content_type_status_date",
   "idx_content_path_status_type",
   "idx_menu_items_menu_parent_pos",
   "idx_terms_type_name",
   "idx_identity_user_roles_role",
   "idx_identity_audit_created",
}

local requiredColumns = {
   content = {
      "id", "type", "path", "title", "body_html", "render_mode", "status",
      "created_at", "updated_at", "meta_description", "head_html", "cache_policy"
   },
   terms = { "id", "type", "name", "slug", "description" },
   content_terms = { "content_id", "term_id" },
   menus = { "id", "name", "slug" },
   menu_items = {
      "id", "menu_id", "parent_id", "content_id", "label", "url", "position", "hidden"
   },
   options = { "key", "value" },
   redirects = { "id", "from_path", "to_path", "status_code" },
   identity_credentials = { "id", "encrypted_base64" },
   identity_profiles = {
      "username", "display_name", "email", "disabled", "max_users",
      "recycle", "inactive", "created_at", "updated_at"
   },
   identity_roles = { "name", "description", "system_role" },
   identity_user_roles = { "username", "role_name" },
   identity_audit = { "id", "actor", "action", "target", "detail_json", "created_at" },
}

local function columnSet(conn, tableName)
   local cols = {}
   local ok, rows = pcall(db.rows, conn, "PRAGMA table_info(" .. tableName .. ")")
   if not ok then
      return nil
   end
   for _, row in ipairs(rows) do
      cols[row.name] = true
   end
   return cols
end

function M.missingRequired(app)
   return db.withRead(app, function(conn)
      for tableName, columns in pairs(requiredColumns) do
         local row = db.one(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name=" .. db.quote(tableName))
         if not row then
            return true, "missing table " .. tableName
         end
         local cols = columnSet(conn, tableName)
         if not cols then
            return true, "cannot inspect table " .. tableName
         end
         for _, col in ipairs(columns) do
            if not cols[col] then
               return true, "missing column " .. tableName .. "." .. col
            end
         end
      end
      for _, indexName in ipairs(requiredIndexes) do
         local row = db.one(conn,
            "SELECT name FROM sqlite_master WHERE type='index' AND name=" ..
            db.quote(indexName))
         if not row then
            return true, "missing index " .. indexName
         end
      end
      return false
   end)
end

function M.contentPathMigrationRequiredConn(conn)
   local row = db.one(conn,
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='content'")
   if not row or not row.sql then return false end
   local sql = tostring(row.sql):lower():gsub("%s+", "")
   return not sql:find("unique(type,path)", 1, true)
end

function M.contentPathMigrationRequired(app)
   return db.withRead(app, M.contentPathMigrationRequiredConn)
end

function M.ensure(app)
   return appreq("dbsetup").ensure(app, { created = false })
end

return M
