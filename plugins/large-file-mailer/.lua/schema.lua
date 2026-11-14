local M = {}

local MAILER_JOBS_DEFINITION = [[(
   id INTEGER PRIMARY KEY,
   sender TEXT NOT NULL,
   status TEXT NOT NULL DEFAULT 'draft'
      CHECK(status IN ('draft','queued','sending','completed','retry','failed','cancelled','revoked')),
   delivery_mode TEXT NOT NULL CHECK(delivery_mode IN ('email','attachment','link')),
   subject TEXT NOT NULL,
   text_body TEXT NOT NULL DEFAULT '',
   html_body TEXT NOT NULL DEFAULT '',
   template_snapshot TEXT,
   password_salt TEXT,
   password_hash TEXT,
   password_iterations INTEGER,
   created_at INTEGER NOT NULL,
   queued_at INTEGER,
   completed_at INTEGER,
   cancelled_at INTEGER,
   job_type TEXT NOT NULL DEFAULT 'delivery',
   require_contact_password INTEGER NOT NULL DEFAULT 0
)]]

local function execute(conn, sql)
   local result, err = conn:execute(sql)
   if result == nil then error(tostring(err or "SQL execution failed"), 2) end
   if type(result) == "userdata" and result.close then result:close() end
end

local function hasColumn(conn, tableName, columnName)
   local cursor, err = conn:execute("PRAGMA table_info(" .. tableName .. ")")
   if not cursor then error(tostring(err or "Reading table schema failed"), 2) end
   while true do
      local row = cursor:fetch({}, "a")
      if not row then break end
      if row.name == columnName then
         cursor:close()
         return true
      end
   end
   cursor:close()
   return false
end

local function tableSql(conn, tableName)
   local cursor, err = conn:execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='" ..
      tableName .. "'")
   if not cursor then error(tostring(err or "Reading table definition failed"), 2) end
   local row = cursor:fetch({}, "a")
   cursor:close()
   return row and row.sql or ""
end

local function migrateEmailDelivery(conn)
   local sql = tableSql(conn, "mailer_jobs")
   if sql == "" or sql:find("'email'", 1, true) then return end

   local tables = {
      "mailer_jobs", "mailer_job_recipients", "mailer_job_files",
      "mailer_download_grants", "mailer_download_events", "mailer_download_stats"
   }
   local definitions = {}
   for _, name in ipairs(tables) do
      definitions[name] = tableSql(conn, name)
      execute(conn, "CREATE TEMP TABLE " .. name .. "_backup AS SELECT * FROM " .. name)
   end
   execute(conn, "DROP TABLE mailer_download_stats")
   execute(conn, "DROP TABLE mailer_download_events")
   execute(conn, "DROP TABLE mailer_download_grants")
   execute(conn, "DROP TABLE mailer_job_files")
   execute(conn, "DROP TABLE mailer_job_recipients")
   execute(conn, "DROP TABLE mailer_jobs")

   execute(conn, "CREATE TABLE mailer_jobs " .. MAILER_JOBS_DEFINITION)
   for index = 2, #tables do execute(conn, definitions[tables[index]]) end

   for _, name in ipairs(tables) do
      execute(conn, "INSERT INTO " .. name .. " SELECT * FROM " .. name .. "_backup")
   end
   for _, name in ipairs(tables) do execute(conn, "DROP TABLE " .. name .. "_backup") end
end

local function ensureRoles(identity)
   local existing = {}
   for _, role in ipairs(identity.roles()) do existing[role.name] = true end
   local roles = {
      ["mailer-user"] = "Compose and send approved file deliveries",
      ["mailer-manager"] = "Manage mailer contacts, lists, jobs, and history"
   }
   for name, description in pairs(roles) do
      if not existing[name] then
         identity.saveRole({ name = name, description = description },
            "large-file-mailer")
      end
   end
end

function M.ensure(ctx, identity)
   ensureRoles(identity)
   ctx.db.writeSync(function(conn)
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_settings (
   singleton INTEGER PRIMARY KEY CHECK(singleton=1),
   enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
   smtp_server TEXT NOT NULL DEFAULT '',
   smtp_port INTEGER NOT NULL DEFAULT 25 CHECK(smtp_port BETWEEN 1 AND 65535),
   smtp_security TEXT NOT NULL DEFAULT 'none'
      CHECK(smtp_security IN ('none','tls','starttls')),
   smtp_username TEXT NOT NULL DEFAULT '',
   from_address TEXT NOT NULL DEFAULT '',
   reply_to TEXT NOT NULL DEFAULT '',
   public_base_url TEXT NOT NULL DEFAULT '',
   attachment_limit INTEGER NOT NULL DEFAULT 10485760 CHECK(attachment_limit >= 0),
   grant_ttl INTEGER NOT NULL DEFAULT 604800 CHECK(grant_ttl > 0),
   max_attempts INTEGER NOT NULL DEFAULT 4 CHECK(max_attempts > 0),
   retry_base INTEGER NOT NULL DEFAULT 60 CHECK(retry_base > 0),
   send_interval INTEGER NOT NULL DEFAULT 1 CHECK(send_interval > 0),
   require_https INTEGER NOT NULL DEFAULT 1 CHECK(require_https IN (0,1))
)]] )
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_smtp_secret (
   singleton INTEGER PRIMARY KEY CHECK(singleton=1),
   encrypted_password TEXT NOT NULL
)]] )
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_contacts (
   id INTEGER PRIMARY KEY,
   external_id TEXT,
   email TEXT NOT NULL COLLATE NOCASE UNIQUE,
   first_name TEXT NOT NULL DEFAULT '',
   last_name TEXT NOT NULL DEFAULT '',
   unsubscribed_at INTEGER,
   created_at INTEGER NOT NULL,
   updated_at INTEGER NOT NULL
)]] )
      if hasColumn(conn, "mailer_contacts", "display_name") then
         execute(conn, "ALTER TABLE mailer_contacts DROP COLUMN display_name")
      end
      if not hasColumn(conn, "mailer_contacts", "unsubscribed_at") then
         execute(conn, "ALTER TABLE mailer_contacts ADD COLUMN unsubscribed_at INTEGER")
      end
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_contact_credentials (
   contact_id INTEGER PRIMARY KEY REFERENCES mailer_contacts(id) ON DELETE CASCADE,
   password_salt TEXT,
   password_hash TEXT,
   password_iterations INTEGER,
   confirmed_at INTEGER,
   invitation_token_hash TEXT UNIQUE,
   invitation_expires_at INTEGER,
   invitation_sent_at INTEGER,
   updated_at INTEGER NOT NULL
)]] )
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_lists (
   id INTEGER PRIMARY KEY,
   name TEXT NOT NULL COLLATE NOCASE UNIQUE,
   description TEXT NOT NULL DEFAULT '',
   created_at INTEGER NOT NULL,
   updated_at INTEGER NOT NULL
)]] )
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_list_members (
   list_id INTEGER NOT NULL REFERENCES mailer_lists(id) ON DELETE CASCADE,
   contact_id INTEGER NOT NULL REFERENCES mailer_contacts(id) ON DELETE CASCADE,
   PRIMARY KEY(list_id,contact_id)
)]] )
      execute(conn, [[
DELETE FROM mailer_list_members
WHERE NOT EXISTS (
   SELECT 1 FROM mailer_lists WHERE mailer_lists.id=mailer_list_members.list_id
) OR NOT EXISTS (
   SELECT 1 FROM mailer_contacts WHERE mailer_contacts.id=mailer_list_members.contact_id
)]] )
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_unsubscribe_tokens (
   id INTEGER PRIMARY KEY,
   contact_id INTEGER NOT NULL REFERENCES mailer_contacts(id) ON DELETE CASCADE,
   token_hash TEXT NOT NULL UNIQUE,
   created_at INTEGER NOT NULL,
   used_at INTEGER
)]] )
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_templates (
   id INTEGER PRIMARY KEY,
   name TEXT NOT NULL COLLATE NOCASE UNIQUE,
   eml_source TEXT NOT NULL,
   revision INTEGER NOT NULL DEFAULT 1,
   created_at INTEGER NOT NULL,
   updated_at INTEGER NOT NULL
)]] )
      execute(conn, "CREATE TABLE IF NOT EXISTS mailer_jobs " ..
         MAILER_JOBS_DEFINITION)
      if not hasColumn(conn, "mailer_jobs", "job_type") then
         execute(conn, "ALTER TABLE mailer_jobs ADD COLUMN " ..
            "job_type TEXT NOT NULL DEFAULT 'delivery'")
      end
      if not hasColumn(conn, "mailer_jobs", "require_contact_password") then
         execute(conn, "ALTER TABLE mailer_jobs ADD COLUMN " ..
            "require_contact_password INTEGER NOT NULL DEFAULT 0")
      end
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_job_recipients (
   id INTEGER PRIMARY KEY,
   job_id INTEGER NOT NULL REFERENCES mailer_jobs(id) ON DELETE CASCADE,
   contact_id INTEGER REFERENCES mailer_contacts(id) ON DELETE SET NULL,
   email TEXT NOT NULL,
   first_name TEXT NOT NULL DEFAULT '',
   last_name TEXT NOT NULL DEFAULT '',
   status TEXT NOT NULL DEFAULT 'pending'
      CHECK(status IN ('pending','sending','sent','retry','failed','skipped','cancelled')),
   attempts INTEGER NOT NULL DEFAULT 0,
   next_attempt_at INTEGER,
   lease_until INTEGER,
   last_error TEXT,
   sent_at INTEGER,
   UNIQUE(job_id,email)
)]] )
      if hasColumn(conn, "mailer_job_recipients", "display_name") then
         execute(conn, "ALTER TABLE mailer_job_recipients DROP COLUMN display_name")
      end
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_job_files (
   id INTEGER PRIMARY KEY,
   job_id INTEGER NOT NULL REFERENCES mailer_jobs(id) ON DELETE CASCADE,
   relative_path TEXT NOT NULL,
   download_name TEXT NOT NULL,
   byte_length INTEGER NOT NULL,
   modified_at INTEGER NOT NULL,
   sha256 TEXT NOT NULL,
   UNIQUE(job_id,relative_path)
)]] )
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_download_grants (
   id INTEGER PRIMARY KEY,
   recipient_id INTEGER NOT NULL REFERENCES mailer_job_recipients(id) ON DELETE CASCADE,
   file_id INTEGER NOT NULL REFERENCES mailer_job_files(id) ON DELETE CASCADE,
   token_hash TEXT NOT NULL UNIQUE,
   password_salt TEXT,
   password_hash TEXT,
   password_iterations INTEGER,
   expires_at INTEGER NOT NULL,
   revoked_at INTEGER,
   failed_attempts INTEGER NOT NULL DEFAULT 0,
   created_at INTEGER NOT NULL,
   UNIQUE(recipient_id,file_id)
)]] )
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_download_events (
   id INTEGER PRIMARY KEY,
   grant_id INTEGER REFERENCES mailer_download_grants(id) ON DELETE SET NULL,
   event_type TEXT NOT NULL,
   detail TEXT NOT NULL DEFAULT '',
   created_at INTEGER NOT NULL
)]] )
      execute(conn, [[
CREATE TABLE IF NOT EXISTS mailer_download_stats (
   recipient_id INTEGER NOT NULL REFERENCES mailer_job_recipients(id) ON DELETE CASCADE,
   file_id INTEGER NOT NULL REFERENCES mailer_job_files(id) ON DELETE CASCADE,
   successful_downloads INTEGER NOT NULL,
   last_downloaded_at INTEGER NOT NULL,
   PRIMARY KEY(recipient_id,file_id)
)]] )
      migrateEmailDelivery(conn)
      execute(conn, [[
CREATE INDEX IF NOT EXISTS mailer_recipient_queue
ON mailer_job_recipients(status,next_attempt_at,lease_until)
]] )
      execute(conn, [[
CREATE INDEX IF NOT EXISTS mailer_grant_expiry
ON mailer_download_grants(token_hash,expires_at,revoked_at)
]] )
      execute(conn, [[
CREATE INDEX IF NOT EXISTS mailer_invitation_token
ON mailer_contact_credentials(invitation_token_hash,invitation_expires_at)
]] )
      execute(conn, [[
CREATE INDEX IF NOT EXISTS mailer_unsubscribe_token
ON mailer_unsubscribe_tokens(token_hash)
]] )
      execute(conn, "INSERT OR IGNORE INTO mailer_settings(singleton) VALUES(1)")
   end)
end

return M
