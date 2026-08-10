local rw = require "rwfile"

local M = {}
-- These are persistence identifiers, not display names. Changing them would
-- make existing TPM-encrypted identity databases unreadable.
local KEY = "makocms-identity"
local LEGACY_IDENTITY_FILE = "plugins/identity-access/users.encrypted"
local LEGACY_ADMIN_FILE = "admin-users.encrypted"

local function execute(conn, sql)
   local result, err = conn:execute(sql)
   if result == nil then error(tostring(err or "SQL execution failed"), 2) end
   if type(result) == "userdata" and result.close then result:close() end
   return result
end

local function newTju(encrypted)
   local tju = ba.tpm.jsonuser(KEY, false)
   if encrypted then
      local ok, err = tju.setdb(encrypted)
      if not ok then
         error("CMS identity credentials are corrupt: " .. tostring(err), 2)
      end
   end
   return tju
end

local function readCredentialRow(app)
   local env, conn = app.db.openRead()
   local ok, row = pcall(function()
      local cursor, err = conn:execute(
         "SELECT encrypted_base64 FROM identity_credentials WHERE id=1")
      if not cursor then error(tostring(err or "Credential query failed"), 2) end
      local value = cursor:fetch({}, "a")
      cursor:close()
      return value
   end)
   conn:close()
   env:close()
   if not ok then error(row, 2) end
   return row
end

local function legacyTju(app, path, key)
   if not app.dataIo:stat(path) then return nil end
   local encrypted, err = rw.file(app.dataIo, path)
   if not encrypted then
      error("Cannot read legacy CMS identity data " .. path .. ": " ..
         tostring(err), 2)
   end
   -- Legacy external files used the global key. Read them only for the
   -- one-time migration into the device-unique SQLite identity store.
   local tju = ba.tpm.jsonuser(key, true)
   local ok, loadErr = tju.setdb(encrypted)
   if not ok then
      error("Cannot migrate legacy CMS identity data " .. path .. ": " ..
         tostring(loadErr), 2)
   end
   return tju
end

local function profile(conn, username)
   local cursor, err = conn:execute(
      "SELECT display_name,email,disabled,max_users,recycle,inactive," ..
      "created_at,updated_at FROM identity_profiles WHERE username=" ..
      luasql.quotestr(username))
   if not cursor then error(tostring(err or "Profile query failed"), 2) end
   local row = cursor:fetch({}, "a")
   cursor:close()
   return row
end

local function roles(conn, username)
   local cursor, err = conn:execute(
      "SELECT role_name FROM identity_user_roles WHERE username=" ..
      luasql.quotestr(username) .. " ORDER BY role_name")
   if not cursor then error(tostring(err or "Role query failed"), 2) end
   local result = {}
   while true do
      local row = cursor:fetch({}, "a")
      if not row then break end
      result[#result + 1] = row.role_name
   end
   cursor:close()
   return result
end

local function insertAdminProfile(conn, username)
   local quoted = luasql.quotestr(username)
   local now = os.time()
   execute(conn, string.format([[
INSERT OR IGNORE INTO identity_profiles(
 username,display_name,email,disabled,max_users,recycle,inactive,created_at,updated_at
) VALUES(%s,'','',0,3,0,1200,%d,%d)
]], quoted, now, now))
   execute(conn,
      "INSERT OR IGNORE INTO identity_user_roles(username,role_name) VALUES(" ..
      quoted .. ",'authenticated')")
   execute(conn,
      "INSERT OR IGNORE INTO identity_user_roles(username,role_name) VALUES(" ..
      quoted .. ",'cms-admin')")
end

local function migrateLegacy(app)
   local identity = legacyTju(app, LEGACY_IDENTITY_FILE, KEY)
   local standalone = legacyTju(app, LEGACY_ADMIN_FILE, "makocms-admin")
   if not identity and not standalone then return newTju() end

   local migrated = newTju()
   local encrypted
   app.db.writeSync(function(conn)
      if identity then
         for _, username in ipairs(identity.users()) do
            local p = profile(conn, username)
            if p then
               local password = identity.getauth():getpwd(username)
               encrypted = migrated.setuser(username, {
                  pwd = password,
                  roles = tonumber(p.disabled) == 1 and {} or
                     roles(conn, username),
                  maxUsers = tonumber(p.max_users) or 3,
                  recycle = tonumber(p.recycle) == 1,
                  inactive = tonumber(p.inactive) or 1200
               })
            else
               trace("Skipping orphaned legacy identity credential:", username)
            end
         end
      end
      if standalone then
         local present = {}
         for _, username in ipairs(migrated.users()) do present[username] = true end
         for _, username in ipairs(standalone.users()) do
            if not present[username] then
               encrypted = migrated.setuser(username, {
                  pwd = standalone.getauth():getpwd(username),
                  roles = { "authenticated", "cms-admin" },
                  maxUsers = 3,
                  recycle = false,
                  inactive = 1200
               })
               insertAdminProfile(conn, username)
            end
         end
      end
      local users = migrated.users()
      if #users > 0 then
         execute(conn,
            "INSERT OR REPLACE INTO identity_credentials(id,encrypted_base64) VALUES(1," ..
            luasql.quotestr(ba.b64encode(encrypted)) .. ")")
      end
      execute(conn, "DELETE FROM options WHERE key='admin_identity_provider'")
   end)

   for _, path in ipairs { LEGACY_IDENTITY_FILE, LEGACY_ADMIN_FILE } do
      if app.dataIo:stat(path) then
         local ok, err = app.dataIo:remove(path)
         if not ok then
            trace("Legacy identity data migrated but could not be removed:",
               path, tostring(err))
         end
      end
   end
   trace("Migrated legacy CMS identity data into SQLite")
   return migrated
end

function M.open(app)
   if not ba.tpm or not ba.tpm.jsonuser then
      error("Mako TPM user database support is unavailable", 2)
   end

   local row = readCredentialRow(app)
   local tju = row and newTju(ba.b64decode(row.encrypted_base64)) or
      migrateLegacy(app)
   local store = {}

   function store.users()
      local users = tju.users()
      table.sort(users)
      return users
   end

   function store.authuser()
      return tju.getauth()
   end

   function store.stage(username, user)
      local current = readCredentialRow(app)
      local replacement = newTju(current and ba.b64decode(
         current.encrypted_base64) or nil)
      local ok, encrypted = pcall(replacement.setuser, username, user)
      if not ok then return nil, tostring(encrypted) end
      return {
         tju = replacement,
         encryptedBase64 = #replacement.users() > 0 and
            ba.b64encode(encrypted) or nil
      }
   end

   function store.persist(conn, staged)
      if staged.encryptedBase64 then
         execute(conn,
            "INSERT OR REPLACE INTO identity_credentials(id,encrypted_base64) VALUES(1," ..
            luasql.quotestr(staged.encryptedBase64) .. ")")
      else
         execute(conn, "DELETE FROM identity_credentials WHERE id=1")
      end
   end

   function store.activate(staged)
      tju = staged.tju
   end

   function store.emptyStage()
      return { tju = newTju(), encryptedBase64 = nil }
   end

   return store
end

return M
