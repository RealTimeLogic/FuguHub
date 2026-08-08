local M = {}

local SYSTEM_ROLES = {
   { "authenticated", "Enabled authenticated user" },
   { "cms-admin", "Full FuguHub administration" },
   { "identity-admin", "User and role management" },
   { "file-admin", "Full file service read and write access" },
   { "mailer-user", "May create mail jobs from readable files" },
   { "mailer-manager", "Contact, job, and mailer administration" }
}

local function quote(value)
   return luasql.quotestr(tostring(value or ""))
end

local function exec(conn, sql)
   local result, err = conn:execute(sql)
   if result == nil then error(tostring(err or "SQL execution failed"), 2) end
   if type(result) == "userdata" and result.close then result:close() end
   return result
end

function M.ensure(ctx)
   ctx.db.writeSync(function(conn)
      exec(conn, [[
CREATE TABLE IF NOT EXISTS identity_profiles (
   username TEXT PRIMARY KEY,
   display_name TEXT NOT NULL DEFAULT '',
   email TEXT NOT NULL DEFAULT '',
   disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0,1)),
   max_users INTEGER NOT NULL DEFAULT 3 CHECK(max_users > 0),
   recycle INTEGER NOT NULL DEFAULT 0 CHECK(recycle IN (0,1)),
   inactive INTEGER NOT NULL DEFAULT 1200 CHECK(inactive >= 0),
   created_at INTEGER NOT NULL,
   updated_at INTEGER NOT NULL
)]])
      exec(conn, [[
CREATE TABLE IF NOT EXISTS identity_roles (
   name TEXT PRIMARY KEY,
   description TEXT NOT NULL DEFAULT '',
   system_role INTEGER NOT NULL DEFAULT 0 CHECK(system_role IN (0,1))
)]])
      exec(conn, [[
CREATE TABLE IF NOT EXISTS identity_user_roles (
   username TEXT NOT NULL REFERENCES identity_profiles(username) ON DELETE CASCADE,
   role_name TEXT NOT NULL REFERENCES identity_roles(name) ON DELETE RESTRICT,
   PRIMARY KEY(username, role_name)
)]])
      exec(conn, [[
CREATE TABLE IF NOT EXISTS identity_audit (
   id INTEGER PRIMARY KEY,
   actor TEXT,
   action TEXT NOT NULL,
   target TEXT,
   detail_json TEXT NOT NULL DEFAULT '{}',
   created_at INTEGER NOT NULL
)]])
      exec(conn, [[
CREATE INDEX IF NOT EXISTS idx_identity_user_roles_role
ON identity_user_roles(role_name, username)
]])
      exec(conn, [[
CREATE INDEX IF NOT EXISTS idx_identity_audit_created
ON identity_audit(created_at DESC, id DESC)
]])

      for _, role in ipairs(SYSTEM_ROLES) do
         exec(conn, string.format(
            "INSERT OR IGNORE INTO identity_roles(name,description,system_role) VALUES(%s,%s,1)",
            quote(role[1]), quote(role[2])))
      end
   end)
end

M.systemRoles = SYSTEM_ROLES

return M
