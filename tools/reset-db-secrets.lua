local function usage()
   return [[Usage:
  Set FUGUHUB_DB to the database file, then run:
  mako tools/reset-db-secrets.lua

The script prepares a FuguHub SQLite database for another computer:
  - removes the device-bound FuguHub user database;
  - removes the device-bound FuguHub MCP bearer token;
  - removes a device-bound SMTP password and disables the mailer when present.

The CMS returns to administrator bootstrap mode. Content and non-secret
configuration are preserved.

Stop every Mako process using the database before running this script. The
script creates <database-file>.before-secret-reset-<timestamp>.bak before
changing the database. The backup still contains the old secrets.]]
end

local processEnv = mako and mako.env or {}
local dbPath = processEnv.FUGUHUB_DB

if not dbPath or dbPath == "" then
   print(usage())
   return
end

local function quote(value)
   return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local env, envErr = luasql.sqlite()
if not env then error("Cannot initialize SQLite: " .. tostring(envErr), 0) end

local conn
local transactionOpen = false

local function close()
   if conn then
      if transactionOpen then pcall(function() conn:execute("ROLLBACK") end) end
      pcall(function() conn:close() end)
      conn = nil
   end
   if env then
      pcall(function() env:close() end)
      env = nil
   end
end

local function execute(sql)
   local result, err = conn:execute(sql)
   if result == nil then error(tostring(err or "SQLite operation failed"), 0) end
   if type(result) == "userdata" and result.close then result:close() end
   return result
end

local function firstValue(sql)
   local cursor, err = conn:execute(sql)
   if not cursor then error(tostring(err or "SQLite query failed"), 0) end
   local row = cursor:fetch({}, "n")
   cursor:close()
   return row and row[1] or nil
end

local function tableExists(name)
   return tonumber(firstValue(
      "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=" ..
      quote(name))) == 1
end

local function requireTable(name)
   if not tableExists(name) then
      error("Not a supported FuguHub database: missing table " .. name, 0)
   end
end

local function rowCount(tableName, condition)
   local sql = "SELECT count(*) FROM " .. tableName
   if condition then sql = sql .. " WHERE " .. condition end
   return tonumber(firstValue(sql)) or 0
end

local function run()
   local connectErr
   conn, connectErr = env:connect(dbPath, "NOCREATE")
   if not conn then
      error("Cannot open existing database " .. dbPath .. ": " ..
         tostring(connectErr), 0)
   end
   if conn.setbusytimeout then conn:setbusytimeout(1000) end

   requireTable("options")
   requireTable("identity_credentials")
   requireTable("identity_profiles")
   requireTable("identity_user_roles")
   requireTable("identity_audit")

   local quickCheck = tostring(firstValue("PRAGMA quick_check") or "")
   if quickCheck ~= "ok" then
      error("Database quick check failed: " .. quickCheck, 0)
   end

   execute("PRAGMA foreign_keys=ON")
   if tonumber(firstValue("PRAGMA foreign_keys")) ~= 1 then
      error("Could not enable SQLite foreign-key enforcement", 0)
   end

   local lock, lockErr = conn:execute("BEGIN IMMEDIATE")
   if not lock then
      error("Cannot acquire the database write lock. Stop Mako and any other " ..
         "process using the database, then try again: " .. tostring(lockErr), 0)
   end
   transactionOpen = true
   execute("ROLLBACK")
   transactionOpen = false

   local backupPath = dbPath .. ".before-secret-reset-" ..
      os.date("%Y%m%d-%H%M%S") .. ".bak"
   execute("VACUUM INTO " .. quote(backupPath))

   local hadMcpToken = rowCount("options", "key='mcp_token_encrypted'") > 0
   local hasMailerSecret = tableExists("mailer_smtp_secret")
   local hasMailerSettings = tableExists("mailer_settings")
   local hadSmtpPassword = hasMailerSecret and
      rowCount("mailer_smtp_secret", "singleton=1") > 0
   local identityUsers = rowCount("identity_profiles")

   execute("BEGIN IMMEDIATE")
   transactionOpen = true

   execute("DELETE FROM options WHERE key='mcp_token_encrypted'")

   if hadSmtpPassword then
      execute("DELETE FROM mailer_smtp_secret WHERE singleton=1")
      if hasMailerSettings then
         execute("UPDATE mailer_settings SET enabled=0 WHERE singleton=1")
      end
   end

   execute("DELETE FROM identity_credentials WHERE id=1")
   execute("DELETE FROM identity_profiles")
   execute(string.format([[
INSERT INTO identity_audit(actor,action,target,detail_json,created_at)
VALUES('offline-migration','identity.reset','*','{}',%d)
]], os.time()))

   execute("COMMIT")
   transactionOpen = false

   if rowCount("options", "key='mcp_token_encrypted'") ~= 0 then
      error("Verification failed: the MCP token row still exists", 0)
   end
   if hadSmtpPassword and rowCount("mailer_smtp_secret", "singleton=1") ~= 0 then
      error("Verification failed: the SMTP password row still exists", 0)
   end
   if rowCount("identity_credentials") ~= 0 or
      rowCount("identity_profiles") ~= 0 or
      rowCount("identity_user_roles") ~= 0 then
      error("Verification failed: identity rows still exist", 0)
   end
   local foreignKeyError = firstValue("PRAGMA foreign_key_check")
   if foreignKeyError ~= nil then
      error("Verification failed: SQLite reported a foreign-key error", 0)
   end

   conn:close()
   conn = nil
   env:close()
   env = nil

   print("FuguHub database secret reset completed.")
   print("Database: " .. dbPath)
   print("Backup: " .. backupPath)
   print("MCP token removed: " .. (hadMcpToken and "yes" or "not configured"))
   print("SMTP password removed: " .. (hadSmtpPassword and "yes" or "not configured"))
   print("Identity users removed: " .. identityUsers)
   print("Create a new administrator and MCP token on the next start with:")
   print("  mako -credentials username:password -token new-private-token")
   print("Protect or remove the backup after the migration is verified; it still contains the old secrets.")
end

local ok, err = pcall(run)
if not ok then
   close()
   error("FuguHub database secret reset failed: " .. tostring(err), 0)
end
