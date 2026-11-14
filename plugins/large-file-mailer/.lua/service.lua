local settingsModule = pluginreq "settings"
local contactsModule = pluginreq "contacts"
local util = pluginreq "util"
local trim = util.trim
local quote = util.quote
local execute = util.execute
local integer = util.integer
local rows = util.rows
local one = util.one
local sqlRow = util.sqlRow
local insertId = util.insertId
local emailAddress = util.emailAddress
local mailboxAddress = util.mailboxAddress

local parseEml = require "eml/EmailMessage"
local cleanError = app.appreq "publicerror"
require "socket.mail"

local M = {}
local runtime

local function htmlEscape(value)
   return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):
      gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function fileRootLabel(files)
   local location = files.location and files.location() or {}
   if location.io == "home" then
      return "Mako home IO at " .. tostring(location.path or "/")
   end
   return tostring(location.io or "configured") .. " IO at " ..
      tostring(location.path or "/")
end

local function secureEqual(a, b)
   a, b = tostring(a or ""), tostring(b or "")
   local length = math.max(#a, #b, 32)
   local different = #a == #b and 0 or 1
   for index = 1, length do
      if (a:byte(index) or 0) ~= (b:byte(index) or 0) then
         different = different + 1
      end
   end
   return different == 0
end

local function resolveFileServicesPath(files, path)
   local value = trim(path)
   local scheme = value:match("^([%a][%w+%.%-]*)://")
   if not scheme then return value end
   scheme = scheme:lower()
   if scheme ~= "http" and scheme ~= "https" then
      error("File Services URLs must use HTTP or HTTPS", 2)
   end
   local urlPath = value:match("^[%a][%w+%.%-]*://[^/]*(/.*)$")
   if not urlPath then error("File Services URL does not contain a path", 2) end
   if urlPath:find("?", 1, true) or urlPath:find("#", 1, true) then
      error("File Services URLs cannot contain a query or fragment", 2)
   end
   local lowerPath = urlPath:lower()
   if lowerPath:find("%%2f", 1, true) or lowerPath:find("%%5c", 1, true) then
      error("File Services URLs cannot contain encoded path separators", 2)
   end
   local location = files.location and files.location() or nil
   local mountUrl = location and tostring(location.mountUrl or "") or ""
   mountUrl = mountUrl:gsub("/+$", "") .. "/"
   if mountUrl == "/" or urlPath:sub(1, #mountUrl) ~= mountUrl then
      error("File Services URL path must be below " .. mountUrl, 2)
   end
   local relative = urlPath:sub(#mountUrl + 1)
   local decoded = ba.urldecode(relative)
   if not decoded then error("File Services URL path is not valid URL encoding", 2) end
   return "/" .. decoded
end

local function digestFile(files, username, path)
   local resolvedOk, resolved = pcall(resolveFileServicesPath, files, path)
   if not resolvedOk then return nil, cleanError(resolved) end
   local pathOk, normalized = pcall(files.normalizeRelativePath, resolved)
   if not pathOk then return nil, cleanError(normalized) end
   local stat, statErr = files.statAuthorized(username, normalized)
   if not stat then return nil, tostring(statErr or "File not found") end
   if stat.isdir then return nil, "Directories cannot be mailed" end
   local file, openErr = files.openAuthorized(username, normalized, "rb")
   if not file then return nil, tostring(openErr or "File cannot be opened") end
   local hash, size = ba.crypto.hash"sha256", 0
   while true do
      local chunk, readErr = file:read(16384)
      if chunk and #chunk > 0 then
         size = size + #chunk
         hash(chunk)
      elseif readErr then
         file:close()
         return nil, tostring(readErr)
      else
         break
      end
   end
   file:close()
   if size ~= tonumber(stat.size or 0) then
      return nil, "File changed while it was being inspected"
   end
   return {
      path = normalized,
      size = size,
      mtime = tonumber(stat.mtime or 0),
      sha256 = hash(true, "hex")
   }
end

local function hasMailerRole(identity, username)
   for _, user in ipairs(identity.users()) do
      if user.username == username and not user.disabled then
         for _, role in ipairs(user.roles or {}) do
            if role == "mailer-user" or role == "mailer-manager" or
               role == "cms-admin" then return true end
         end
      end
   end
   return false
end

local function requireMailerSender(identity, username)
   if username == "" then
      error("Mailer sending is disabled until an administrator account and " ..
         "password are set", 3)
   end
   if not hasMailerRole(identity, username) then
      error("Sender must have the mailer-user, mailer-manager, or cms-admin role", 3)
   end
end

local function displayName(path)
   local name = path:match("([^/]+)$") or "download"
   return name:gsub('[%z\r\n"\\]', "_")
end

local function passwordDigest(password, salt, iterations)
   return ba.crypto.PBKDF2("sha256", password, salt, iterations, 32)
end

local function absoluteUrl(settings, pluginApp, path)
   return settings.publicBaseUrl .. pluginApp.url(path)
end

function M.start(ctx, identity, files, pluginApp)
   local settings = settingsModule.load(ctx)
   local service = {}
   contactsModule.install(ctx, service)
   local stopped, busy, timer = false, false, nil
   local worker = ba.thread.create()
   local schedule

   function service.state()
      local fileServices = files and files.location and files.location() or nil
      return {
         settings = settingsModule.public(settings),
         identityReady = identity ~= nil,
         fileServicesReady = files ~= nil,
         fileServices = fileServices
      }
   end

   function service.parseTemplate(source)
      return parseEml(source)
   end

   function service.saveSettings(input)
      settings = settingsModule.save(ctx, input)
      if settings.enabled and schedule then
         schedule(1)
      elseif not settings.enabled and timer then
         timer:cancel()
         timer = nil
      end
      return true
   end

   function service.encryptPassword(password)
      return settingsModule.encrypt(tostring(password or ""))
   end

   function service.decryptPassword(encoded)
      return settingsModule.decrypt(encoded)
   end

   function service.templates(includeSource)
      local values = {}
      for _, row in ipairs(rows(ctx, [[
SELECT id,name,eml_source,revision,created_at,updated_at
FROM mailer_templates ORDER BY name
]])) do
         local value = {
            id = tonumber(row.id), name = row.name,
            revision = tonumber(row.revision), createdAt = tonumber(row.created_at),
            updatedAt = tonumber(row.updated_at)
         }
         if includeSource ~= false then value.source = row.eml_source end
         values[#values + 1] = value
      end
      return values
   end

   function service.saveTemplate(input)
      input = input or {}
      local id = input.id and integer(input.id, 1, 9007199254740991, "Template ID")
      local name, source = trim(input.name), tostring(input.source or "")
      if name == "" or #name > 160 then error("A valid template name is required", 2) end
      if source == "" or #source > 2097152 then error("A valid EML template is required", 2) end
      local parsed, parseErr = parseEml(source)
      if not parsed then error("EML template is invalid: " .. tostring(parseErr), 2) end
      local now = os.time()
      ctx.db.writeSync(function(conn)
         if id then
            execute(conn, string.format([[
UPDATE mailer_templates SET name=%s,eml_source=%s,revision=revision+1,updated_at=%d
WHERE id=%d
]], quote(name), quote(source), now, id))
         else
            execute(conn, string.format([[
INSERT INTO mailer_templates(name,eml_source,revision,created_at,updated_at)
VALUES(%s,%s,1,%d,%d)
]], quote(name), quote(source), now, now))
         end
      end)
      return true
   end

   function service.deleteTemplate(id)
      id = integer(id, 1, 9007199254740991, "Template ID")
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_templates WHERE id=" .. id)
      end)
      return true
   end

   function service.history(page, pageSize)
      page = integer(page or 1, 1, 1000000, "Page")
      pageSize = integer(pageSize or 50, 1, 200, "Page size")
      local count = one(ctx, "SELECT COUNT(*) AS count FROM mailer_jobs")
      local values = {}
      for _, row in ipairs(rows(ctx, string.format([[
SELECT j.id,j.sender,j.status,j.delivery_mode,j.job_type,j.subject,j.created_at,j.queued_at,
       j.completed_at,COUNT(r.id) AS recipients,
       SUM(CASE WHEN r.status='sent' THEN 1 ELSE 0 END) AS sent,
       SUM(CASE WHEN r.status='failed' THEN 1 ELSE 0 END) AS failed
FROM mailer_jobs j LEFT JOIN mailer_job_recipients r ON r.job_id=j.id
GROUP BY j.id ORDER BY j.id DESC LIMIT %d OFFSET %d
]], pageSize, (page - 1) * pageSize))) do
         values[#values + 1] = {
            id = tonumber(row.id), sender = row.sender, status = row.status,
            deliveryMode = row.delivery_mode, jobType = row.job_type,
            subject = row.subject,
            createdAt = tonumber(row.created_at), queuedAt = tonumber(row.queued_at),
            completedAt = tonumber(row.completed_at), recipients = tonumber(row.recipients),
            sent = tonumber(row.sent or 0), failed = tonumber(row.failed or 0)
         }
      end
      return { items = values, page = page, pageSize = pageSize,
         total = tonumber(count.count) }
   end

   function service.purgeHistory(olderThan)
      olderThan = integer(olderThan, 0, 4102444800, "Retention cutoff")
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
DELETE FROM mailer_jobs
WHERE status IN ('completed','failed','cancelled','revoked')
  AND COALESCE(completed_at,cancelled_at,created_at)<%d
]], olderThan))
         execute(conn, "DELETE FROM mailer_download_events WHERE grant_id IS NULL")
      end)
      return true
   end

   local function jobSummary(id)
      id = integer(id, 1, 9007199254740991, "Job ID")
      local row = one(ctx, string.format([[
SELECT j.id,j.sender,j.status,j.delivery_mode,j.job_type,
       j.require_contact_password,j.subject,j.created_at,j.queued_at,
       j.completed_at,j.cancelled_at,COUNT(r.id) AS recipient_count,
       SUM(CASE WHEN r.status='sent' THEN 1 ELSE 0 END) AS sent,
       SUM(CASE WHEN r.status='failed' THEN 1 ELSE 0 END) AS failed,
       SUM(CASE WHEN r.status IN ('pending','sending','retry') THEN 1 ELSE 0 END) AS active,
       SUM(CASE WHEN r.status='cancelled' THEN 1 ELSE 0 END) AS cancelled,
       SUM(CASE WHEN r.status='skipped' THEN 1 ELSE 0 END) AS skipped,
       (SELECT COUNT(*) FROM mailer_job_files f WHERE f.job_id=j.id) AS file_count
FROM mailer_jobs j
LEFT JOIN mailer_job_recipients r ON r.job_id=j.id
WHERE j.id=%d
GROUP BY j.id
]], id))
      if not row then return nil, "Job not found" end
      return {
         id = tonumber(row.id), sender = row.sender, status = row.status,
         deliveryMode = row.delivery_mode, jobType = row.job_type,
         requireContactPassword = tonumber(row.require_contact_password) == 1,
         subject = row.subject, createdAt = tonumber(row.created_at),
         queuedAt = tonumber(row.queued_at), completedAt = tonumber(row.completed_at),
         cancelledAt = tonumber(row.cancelled_at),
         recipientCount = tonumber(row.recipient_count or 0),
         sent = tonumber(row.sent or 0), failed = tonumber(row.failed or 0),
         active = tonumber(row.active or 0), cancelled = tonumber(row.cancelled or 0),
         skipped = tonumber(row.skipped or 0), fileCount = tonumber(row.file_count or 0)
      }
   end

   function service.createJob(input)
      input = input or {}
      if not settings.enabled then error("Large File Mailer is disabled", 2) end
      local sender = trim(input.sender)
      requireMailerSender(identity, sender)
      local mode = tostring(input.deliveryMode or "")
      if mode ~= "email" and mode ~= "attachment" and mode ~= "link" then
         error("Delivery mode must be email, attachment, or link", 2)
      end
      if mode ~= "email" and not files.isEnabled() then
         error("File Services is disabled", 2)
      end
      if mode == "link" and settings.publicBaseUrl == "" then
         error("Public base URL is required for link delivery", 2)
      end
      local requireContactPassword = input.requireContactPassword == true
      if requireContactPassword and mode ~= "link" then
         error("Recipient passwords require link delivery", 2)
      end
      local subject = trim(input.subject)
      local textBody = tostring(input.textBody or "")
      local htmlBody = tostring(input.htmlBody or "")
      if subject == "" or #subject > 500 then error("A valid subject is required", 2) end
      if #textBody > 1048576 or #htmlBody > 1048576 then
         error("Message body is too large", 2)
      end
      local messageMacroSource = subject .. "\n" .. textBody .. "\n" .. htmlBody
      if mode ~= "link" and
            messageMacroSource:find("{{DOWNLOAD_LINKS}}", 1, true) then
         error("{{DOWNLOAD_LINKS}} can only be used with Secure download links", 2)
      end
      local macroSource = messageMacroSource ..
         "\n" .. tostring(input.templateSnapshot or "")
      if input.recipients ~= nil and type(input.recipients) ~= "table" then
         error("Recipients must be a table", 2)
      end
      local usesUnsubscribe = macroSource:find("{{UNSUBSCRIBE_LINK}}", 1, true) ~= nil
      if usesUnsubscribe then
         if settings.publicBaseUrl == "" then
            error("Public base URL is required for unsubscribe links", 2)
         end
         for _, recipient in ipairs(input.recipients or {}) do
            if type(recipient) ~= "table" or not tonumber(recipient.contactId) then
               error("Unsubscribe links require saved contacts", 2)
            end
         end
      end

      local recipients, seen = {}, {}
      for _, value in ipairs(input.recipients or {}) do
         local recipient = type(value) == "table" and value or { email = value }
         local email = emailAddress(recipient.email)
         local key = email:lower()
         if seen[key] then error("Duplicate recipient: " .. email, 2) end
         seen[key] = true
         recipients[#recipients + 1] = {
            email = email,
            firstName = trim(recipient.firstName),
            lastName = trim(recipient.lastName),
            contactId = tonumber(recipient.contactId)
         }
      end
      local contactIds, contactSeen = {}, {}
      for _, value in ipairs(input.contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not contactSeen[contactId] then
            contactSeen[contactId] = true
            contactIds[#contactIds + 1] = contactId
         end
      end
      local listIds, listSeen = {}, {}
      for _, value in ipairs(input.listIds or {}) do
         local listId = integer(value, 1, 9007199254740991, "List ID")
         if not listSeen[listId] then
            listSeen[listId] = true
            listIds[#listIds + 1] = listId
         end
      end
      if #contactIds > 1000 then error("Too many individual contacts selected", 2) end
      if #listIds > 100 then error("Too many recipient lists selected", 2) end
      if #recipients == 0 and #contactIds == 0 and #listIds == 0 then
         error("At least one recipient or recipient list is required", 2)
      end

      local inputFiles = input.files or {}
      if type(inputFiles) ~= "table" then error("Files must be a table", 2) end
      if mode == "email" and #inputFiles > 0 then
         error("Email-only delivery cannot include files", 2)
      end
      if mode ~= "email" and (#inputFiles == 0 or #inputFiles > 100) then
         error("One to 100 files are required for file delivery", 2)
      end
      local snapshots, total = {}, 0
      for _, value in ipairs(inputFiles) do
         local path = type(value) == "table" and value.path or value
         local snapshot, snapshotErr = digestFile(files, sender, path)
         if not snapshot then
            error("Cannot use File Services path " .. tostring(path) .. " under " ..
               fileRootLabel(files) .. ": " .. tostring(snapshotErr), 2)
         end
         snapshot.name = type(value) == "table" and
            trim(value.name) or displayName(snapshot.path)
         if snapshot.name == "" then snapshot.name = displayName(snapshot.path) end
         snapshot.name = displayName(snapshot.name)
         total = total + snapshot.size
         snapshots[#snapshots + 1] = snapshot
      end
      if mode == "attachment" and total > settings.attachmentLimit then
         error("Attachments exceed the configured size limit; use link delivery", 2)
      end

      local passwordSalt, passwordHash, passwordIterations
      local linkPassword = tostring(input.linkPassword or "")
      if linkPassword ~= "" then
         if mode ~= "link" then error("Link passwords require link delivery", 2) end
         if requireContactPassword then
            error("Shared and recipient passwords cannot be combined", 2)
         end
         if #linkPassword > 1024 then error("Link password is too long", 2) end
         passwordIterations = 100000
         local salt = ba.rndbs(16)
         passwordSalt = ba.b64urlencode(salt)
         passwordHash = ba.b64urlencode(
            passwordDigest(linkPassword, salt, passwordIterations))
      end

      local now, jobId = os.time()
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
INSERT INTO mailer_jobs(
 sender,status,delivery_mode,subject,text_body,html_body,template_snapshot,
 job_type,require_contact_password,
 password_salt,password_hash,password_iterations,created_at
) VALUES(%s,'draft',%s,%s,%s,%s,%s,'delivery',%d,%s,%s,%s,%d)
]], quote(sender), quote(mode), quote(subject), quote(textBody), quote(htmlBody),
            input.templateSnapshot and quote(input.templateSnapshot) or "NULL",
            requireContactPassword and 1 or 0,
            passwordSalt and quote(passwordSalt) or "NULL",
            passwordHash and quote(passwordHash) or "NULL",
            passwordIterations and tostring(passwordIterations) or "NULL", now))
         jobId = insertId(conn)
         for _, recipient in ipairs(recipients) do
            if recipient.contactId then
               local contact = sqlRow(conn,
                  "SELECT unsubscribed_at FROM mailer_contacts WHERE id=" ..
                  recipient.contactId)
               if not contact then error("Contact not found: " .. recipient.contactId, 2) end
               if contact.unsubscribed_at then
                  error("Contact has unsubscribed: " .. recipient.email, 2)
               end
            end
            execute(conn, string.format([[
INSERT INTO mailer_job_recipients(
 job_id,contact_id,email,first_name,last_name,status
) VALUES(%d,%s,%s,%s,%s,'pending')
]], jobId, recipient.contactId and tostring(recipient.contactId) or "NULL",
               quote(recipient.email), quote(recipient.firstName),
               quote(recipient.lastName)))
         end
         local selectors = {}
         if #contactIds > 0 then
            selectors[#selectors + 1] = "id IN (" .. table.concat(contactIds, ",") .. ")"
         end
         if #listIds > 0 then
            selectors[#selectors + 1] = [[id IN (
 SELECT contact_id FROM mailer_list_members WHERE list_id IN (]] ..
               table.concat(listIds, ",") .. "))"
         end
         if #selectors > 0 then
            execute(conn, string.format([[
INSERT OR IGNORE INTO mailer_job_recipients(
 job_id,contact_id,email,first_name,last_name,status
)
SELECT %d,id,email,first_name,last_name,'pending'
FROM mailer_contacts WHERE (%s) AND unsubscribed_at IS NULL
]], jobId, table.concat(selectors, " OR ")))
         end
         local recipientCount = tonumber(sqlRow(conn,
            "SELECT COUNT(*) AS count FROM mailer_job_recipients WHERE job_id=" ..
            jobId).count)
         if recipientCount == 0 then error("No contacts matched the selection", 2) end
         if requireContactPassword then
            local unavailable = tonumber(sqlRow(conn, string.format([[
SELECT COUNT(*) AS count
FROM mailer_job_recipients recipients
LEFT JOIN mailer_contact_credentials credentials
  ON credentials.contact_id=recipients.contact_id
WHERE recipients.job_id=%d AND credentials.confirmed_at IS NULL
]], jobId)).count)
            if unavailable > 0 then
               error(string.format(
                  "%d selected contact%s must accept a password invitation first",
                  unavailable, unavailable == 1 and "" or "s"), 2)
            end
         end
         for _, file in ipairs(snapshots) do
            execute(conn, string.format([[
INSERT INTO mailer_job_files(
 job_id,relative_path,download_name,byte_length,modified_at,sha256
) VALUES(%d,%s,%s,%d,%d,%s)
]], jobId, quote(file.path), quote(file.name), file.size, file.mtime,
               quote(file.sha256)))
         end
      end)
      return jobSummary(jobId)
   end

   function service.createInvitationJob(input)
      input = input or {}
      if not settings.enabled then error("Large File Mailer is disabled", 2) end
      if settings.publicBaseUrl == "" then
         error("Public base URL is required for password invitations", 2)
      end
      local sender = trim(input.sender)
      requireMailerSender(identity, sender)
      local subject = trim(input.subject)
      local textBody = tostring(input.textBody or "")
      local htmlBody = tostring(input.htmlBody or "")
      if subject == "" or #subject > 500 then error("A valid subject is required", 2) end
      if #textBody > 1048576 or #htmlBody > 1048576 then
         error("Message body is too large", 2)
      end
      local contactIds, contactSeen = {}, {}
      for _, value in ipairs(input.contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not contactSeen[contactId] then
            contactSeen[contactId] = true
            contactIds[#contactIds + 1] = contactId
         end
      end
      local listIds, listSeen = {}, {}
      for _, value in ipairs(input.listIds or {}) do
         local listId = integer(value, 1, 9007199254740991, "List ID")
         if not listSeen[listId] then
            listSeen[listId] = true
            listIds[#listIds + 1] = listId
         end
      end
      if #contactIds > 1000 then error("Too many individual contacts selected", 2) end
      if #listIds > 100 then error("Too many recipient lists selected", 2) end
      if #contactIds == 0 and #listIds == 0 then
         error("Select contacts or recipient lists", 2)
      end

      local now, jobId = os.time()
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
INSERT INTO mailer_jobs(
 sender,status,delivery_mode,subject,text_body,html_body,job_type,
 require_contact_password,created_at
) VALUES(%s,'draft','link',%s,%s,%s,'invitation',0,%d)
]], quote(sender), quote(subject), quote(textBody), quote(htmlBody), now))
         jobId = insertId(conn)
         local selectors = {}
         if #contactIds > 0 then
            selectors[#selectors + 1] = "contacts.id IN (" ..
               table.concat(contactIds, ",") .. ")"
         end
         if #listIds > 0 then
            selectors[#selectors + 1] = [[contacts.id IN (
 SELECT contact_id FROM mailer_list_members WHERE list_id IN (]] ..
               table.concat(listIds, ",") .. "))"
         end
         execute(conn, string.format([[
INSERT OR IGNORE INTO mailer_job_recipients(
 job_id,contact_id,email,first_name,last_name,status
)
SELECT %d,contacts.id,contacts.email,contacts.first_name,contacts.last_name,'pending'
FROM mailer_contacts contacts
LEFT JOIN mailer_contact_credentials credentials
  ON credentials.contact_id=contacts.id
WHERE (%s) AND contacts.unsubscribed_at IS NULL
  AND credentials.confirmed_at IS NULL
]], jobId, table.concat(selectors, " OR ")))
         local count = tonumber(sqlRow(conn,
            "SELECT COUNT(*) AS count FROM mailer_job_recipients WHERE job_id=" ..
            jobId).count)
         if count == 0 then error("No unconfirmed contacts matched the selection", 2) end
      end)
      return jobSummary(jobId)
   end

   function service.confirmationStats(listId)
      local filters = { "contacts.unsubscribed_at IS NULL" }
      if listId ~= nil then
         listId = integer(listId, 1, 9007199254740991, "List ID")
         filters[#filters + 1] = "contacts.id IN (SELECT contact_id FROM " ..
            "mailer_list_members WHERE list_id=" .. listId .. ")"
      end
      local where = " WHERE " .. table.concat(filters, " AND ")
      local counts = one(ctx, [[
SELECT COUNT(*) AS total,
 SUM(CASE WHEN credentials.confirmed_at IS NOT NULL THEN 1 ELSE 0 END) AS confirmed,
 SUM(CASE WHEN credentials.confirmed_at IS NULL THEN 1 ELSE 0 END) AS unconfirmed,
 SUM(CASE WHEN credentials.confirmed_at IS NULL AND
               credentials.invitation_expires_at>=]] .. os.time() ..
         [[ THEN 1 ELSE 0 END) AS invited
FROM mailer_contacts contacts
LEFT JOIN mailer_contact_credentials credentials
  ON credentials.contact_id=contacts.id]] .. where)
      return {
         total = tonumber(counts.total or 0),
         confirmed = tonumber(counts.confirmed or 0),
         unconfirmed = tonumber(counts.unconfirmed or 0),
         invited = tonumber(counts.invited or 0)
      }
   end

   function service.job(id)
      return jobSummary(id)
   end

   function service.jobDetails(id)
      id = integer(id, 1, 9007199254740991, "Job ID")
      local job = one(ctx, [[
SELECT id,sender,status,delivery_mode,job_type,require_contact_password,subject,
       text_body,html_body,template_snapshot,created_at,queued_at,completed_at,cancelled_at
FROM mailer_jobs WHERE id=]] .. id)
      if not job then return nil, "Job not found" end
      local recipientCount = tonumber(one(ctx,
         "SELECT COUNT(*) AS count FROM mailer_job_recipients WHERE job_id=" .. id).count)
      local result = {
         id = tonumber(job.id), sender = job.sender, status = job.status,
         deliveryMode = job.delivery_mode, jobType = job.job_type,
         requireContactPassword = tonumber(job.require_contact_password) == 1,
         subject = job.subject, textBody = job.text_body, htmlBody = job.html_body,
         templateSnapshot = job.template_snapshot,
         createdAt = tonumber(job.created_at), queuedAt = tonumber(job.queued_at),
         completedAt = tonumber(job.completed_at), cancelledAt = tonumber(job.cancelled_at),
         recipientCount = recipientCount, recipientsTruncated = recipientCount > 100,
         recipients = {}, files = {}, downloads = {}
      }
      for _, row in ipairs(rows(ctx, [[
SELECT id,email,first_name,last_name,status,attempts,next_attempt_at,last_error,sent_at
FROM mailer_job_recipients WHERE job_id=]] .. id .. " ORDER BY id LIMIT 100")) do
         result.recipients[#result.recipients + 1] = {
            id = tonumber(row.id), email = row.email,
            firstName = row.first_name, lastName = row.last_name,
            status = row.status, attempts = tonumber(row.attempts),
            nextAttemptAt = tonumber(row.next_attempt_at), lastError = row.last_error,
            sentAt = tonumber(row.sent_at)
         }
      end
      for _, row in ipairs(rows(ctx, [[
SELECT id,relative_path,download_name,byte_length,modified_at,sha256
FROM mailer_job_files WHERE job_id=]] .. id .. " ORDER BY id")) do
         result.files[#result.files + 1] = {
            id = tonumber(row.id), path = row.relative_path,
            name = row.download_name, byteLength = tonumber(row.byte_length),
            modifiedAt = tonumber(row.modified_at), sha256 = row.sha256
         }
      end
      if job.delivery_mode == "link" then
         for _, row in ipairs(rows(ctx, string.format([[
SELECT r.id AS recipient_id,r.email,f.id AS file_id,f.download_name,
       COALESCE(s.successful_downloads,0) AS successful_downloads,s.last_downloaded_at
FROM (SELECT id,email FROM mailer_job_recipients WHERE job_id=%d ORDER BY id LIMIT 100) r
JOIN mailer_job_files f ON f.job_id=%d
LEFT JOIN mailer_download_stats s ON s.recipient_id=r.id AND s.file_id=f.id
ORDER BY r.id,f.id
]], id, id))) do
            result.downloads[#result.downloads + 1] = {
               recipientId = tonumber(row.recipient_id), email = row.email,
               fileId = tonumber(row.file_id), name = row.download_name,
               successfulDownloads = tonumber(row.successful_downloads),
               lastDownloadedAt = tonumber(row.last_downloaded_at)
            }
         end
      end
      return result
   end

   local function expand(value, recipient, links, unsubscribeLink, html)
      value = tostring(value or "")
      local values = {
         FIRST_NAME = recipient.first_name,
         LAST_NAME = recipient.last_name,
         NAME = recipient.first_name,
         CONTACT_ID = recipient.contact_id or "",
         DOWNLOAD_LINKS = links or "",
         INVITATION_LINK = links or "",
         UNSUBSCRIBE_LINK = unsubscribeLink or "",
         EXPIRY = os.date("!%Y-%m-%d %H:%M UTC", os.time() + settings.grantTtl)
      }
      return (value:gsub("{{([A-Z_]+)}}", function(key)
         local replacement = values[key]
         if replacement == nil then return "{{" .. key .. "}}" end
         if html and key ~= "DOWNLOAD_LINKS" and key ~= "INVITATION_LINK" and
            key ~= "UNSUBSCRIBE_LINK" then
            return tostring(replacement):gsub("&", "&amp;"):gsub("<", "&lt;"):
               gsub(">", "&gt;"):gsub('"', "&quot;")
         end
         return tostring(replacement)
      end))
   end

   local function appendGeneratedLinks(body, links, html, heading)
      body = tostring(body or "")
      if links == "" then return body end
      if html then
         local section = "<p><strong>" .. heading .. "</strong></p>" .. links
         return body ~= "" and (body .. section) or section
      end
      local section = heading .. "\n" .. links
      return body ~= "" and (body .. "\n\n" .. section) or section
   end

   local function smtpClient()
      local options = {
         server = settings.smtpServer,
         port = settings.smtpPort
      }
      if settings.smtpUsername ~= "" then options.user = settings.smtpUsername end
      if settings.encryptedPassword then
         local password, passwordErr = settingsModule.decrypt(settings.encryptedPassword)
         if password == nil then error(passwordErr, 2) end
         options.password = password
      end
      if settings.smtpSecurity == "tls" then
         options.shark = ba.sharkclient()
      elseif settings.smtpSecurity == "starttls" then
         options.shark = ba.sharkclient()
         options.starttls = true
      end
      return socket.mail(options)
   end

   function service.sendTest(recipient)
      if settings.smtpServer == "" then
         error("SMTP server is required before testing", 2)
      end
      if settings.fromAddress == "" then
         error("From address is required before testing", 2)
      end
      recipient = mailboxAddress(recipient, "test recipient")
      local ok, err = smtpClient():send {
         from = settings.fromAddress,
         replyto = settings.replyTo ~= "" and settings.replyTo or nil,
         to = recipient,
         subject = "FuguHub SMTP test",
         txtbody = "This message confirms that the FuguHub Large File Mailer SMTP settings work."
      }
      if not ok then error(tostring(err or "SMTP test failed"), 2) end
      return recipient
   end

   local function grantLinks(job, recipient, jobFiles)
      local textLinks, htmlLinks, now = {}, {}, os.time()
      local passwordSalt = job.password_salt
      local passwordHash = job.password_hash
      local passwordIterations = job.password_iterations
      if tonumber(job.require_contact_password) == 1 then
         local credential = recipient.contact_id and one(ctx, [[
SELECT password_salt,password_hash,password_iterations,confirmed_at
FROM mailer_contact_credentials WHERE contact_id=]] ..
            tonumber(recipient.contact_id)) or nil
         if not credential or not credential.confirmed_at or not credential.password_hash then
            error("Contact password is not configured for " .. recipient.email, 2)
         end
         passwordSalt, passwordHash, passwordIterations = nil, nil, nil
      end
      for _, file in ipairs(jobFiles) do
         local token = ba.b64urlencode(ba.rndbs(32))
         local tokenHash = ba.crypto.hash"sha256"(token)(true, "hex")
         ctx.db.writeSync(function(conn)
            execute(conn, "DELETE FROM mailer_download_grants WHERE recipient_id=" ..
               tonumber(recipient.id) .. " AND file_id=" .. tonumber(file.id))
            execute(conn, string.format([[
INSERT INTO mailer_download_grants(
 recipient_id,file_id,token_hash,password_salt,password_hash,
 password_iterations,expires_at,created_at
) VALUES(%d,%d,%s,%s,%s,%s,%d,%d)
]], tonumber(recipient.id), tonumber(file.id), quote(tokenHash),
               passwordSalt and quote(passwordSalt) or "NULL",
               passwordHash and quote(passwordHash) or "NULL",
               passwordIterations and tostring(passwordIterations) or "NULL",
               now + settings.grantTtl, now))
         end)
         local url = absoluteUrl(settings, pluginApp, "/mailer/d/" .. token)
         textLinks[#textLinks + 1] = file.download_name .. ": " .. url
         htmlLinks[#htmlLinks + 1] = "<a href=\"" ..
            url:gsub("&", "&amp;"):gsub('"', "&quot;") .. "\">" ..
            file.download_name:gsub("&", "&amp;"):gsub("<", "&lt;"):
               gsub(">", "&gt;") .. "</a>"
      end
      return table.concat(textLinks, "\n"), table.concat(htmlLinks, "<br>")
   end

   local function claimRecipient()
      local claimed
      local now = os.time()
      ctx.db.writeSync(function(conn)
         local row = sqlRow(conn, string.format([[
SELECT r.id,r.job_id,r.contact_id,r.email,r.first_name,r.last_name,
       r.attempts,j.sender,j.delivery_mode,j.subject,j.text_body,j.html_body,
       j.template_snapshot,j.password_salt,j.password_hash,j.password_iterations,
       j.job_type,j.require_contact_password
FROM mailer_job_recipients r
JOIN mailer_jobs j ON j.id=r.job_id
WHERE j.status IN ('queued','sending','retry')
  AND r.status IN ('pending','retry','sending')
  AND (r.next_attempt_at IS NULL OR r.next_attempt_at<=%d)
  AND (r.status!='sending' OR r.lease_until IS NULL OR r.lease_until<%d)
ORDER BY r.id LIMIT 1
]], now, now))
         if not row then return end
         execute(conn, string.format([[
UPDATE mailer_job_recipients
SET status='sending',attempts=attempts+1,lease_until=%d,last_error=NULL
WHERE id=%d
]], now + 300, tonumber(row.id)))
         execute(conn, "UPDATE mailer_jobs SET status='sending' WHERE id=" ..
            tonumber(row.job_id))
         row.attempts = tonumber(row.attempts) + 1
         claimed = row
      end)
      return claimed
   end

   local function refreshJob(jobId)
      local counts = one(ctx, string.format([[
SELECT
 SUM(CASE WHEN status IN ('pending','sending','retry') THEN 1 ELSE 0 END) AS active,
 SUM(CASE WHEN status='sent' THEN 1 ELSE 0 END) AS sent
FROM mailer_job_recipients WHERE job_id=%d
]], tonumber(jobId)))
      local active = tonumber(counts and counts.active or 0) or 0
      local sent = tonumber(counts and counts.sent or 0) or 0
      if active > 0 then return end
      ctx.db.writeSync(function(conn)
         execute(conn, string.format(
            "UPDATE mailer_jobs SET status=%s,completed_at=%d WHERE id=%d",
            quote(sent > 0 and "completed" or "failed"), os.time(), tonumber(jobId)))
      end)
   end

   local function finishRecipient(recipient, ok, err)
      local now = os.time()
      local errorText = tostring(err or "Delivery failed")
      if #errorText > 1000 then errorText = errorText:sub(1, 1000) end
      local permanent = errorText:match("%f[%d]5%d%d%f[%D]") ~= nil or
         errorText:find("File changed after the job was created", 1, true) ~= nil or
         errorText:find("Forbidden", 1, true) ~= nil
      local retry = not ok and not permanent and
         tonumber(recipient.attempts) < settings.maxAttempts
      ctx.db.writeSync(function(conn)
         if ok then
            execute(conn, string.format([[
UPDATE mailer_job_recipients
SET status='sent',lease_until=NULL,next_attempt_at=NULL,last_error=NULL,sent_at=%d
WHERE id=%d
]], now, tonumber(recipient.id)))
         elseif retry then
            local delay = settings.retryBase * 2 ^ math.max(0, recipient.attempts - 1)
            execute(conn, string.format([[
UPDATE mailer_job_recipients
SET status='retry',lease_until=NULL,next_attempt_at=%d,last_error=%s
WHERE id=%d
]], now + delay, quote(errorText), tonumber(recipient.id)))
            execute(conn, "UPDATE mailer_jobs SET status='retry' WHERE id=" ..
               tonumber(recipient.job_id))
         else
            execute(conn, string.format([[
UPDATE mailer_job_recipients
SET status='failed',lease_until=NULL,next_attempt_at=NULL,last_error=%s
WHERE id=%d
]], quote(errorText), tonumber(recipient.id)))
         end
      end)
      refreshJob(recipient.job_id)
   end

   local function createInvitationLink(recipient)
      if not recipient.contact_id then
         error("Password invitations require saved contacts", 2)
      end
      local token = ba.b64urlencode(ba.rndbs(32))
      local tokenHash = ba.crypto.hash"sha256"(token)(true, "hex")
      local now = os.time()
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
INSERT INTO mailer_contact_credentials(
 contact_id,invitation_token_hash,invitation_expires_at,invitation_sent_at,updated_at
) VALUES(%d,%s,%d,%d,%d)
ON CONFLICT(contact_id) DO UPDATE SET
 invitation_token_hash=excluded.invitation_token_hash,
 invitation_expires_at=excluded.invitation_expires_at,
 invitation_sent_at=excluded.invitation_sent_at,
 updated_at=excluded.updated_at
]], tonumber(recipient.contact_id), quote(tokenHash), now + settings.grantTtl,
            now, now))
      end)
      return absoluteUrl(settings, pluginApp, "/mailer/invite/" .. token)
   end

   local function createUnsubscribeLink(recipient)
      if not recipient.contact_id then
         error("Unsubscribe links require saved contacts", 2)
      end
      local token = ba.b64urlencode(ba.rndbs(32))
      local tokenHash = ba.crypto.hash"sha256"(token)(true, "hex")
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
INSERT INTO mailer_unsubscribe_tokens(contact_id,token_hash,created_at)
VALUES(%d,%s,%d)
]], tonumber(recipient.contact_id), quote(tokenHash), os.time()))
      end)
      return absoluteUrl(settings, pluginApp, "/mailer/unsubscribe/" .. token)
   end

   local function sendRecipient(recipient)
      local jobFiles = rows(ctx, "SELECT * FROM mailer_job_files WHERE job_id=" ..
         tonumber(recipient.job_id) .. " ORDER BY id")
      local opened, attachments = {}, {}
      local function closeFiles()
         for _, file in ipairs(opened) do pcall(function() file:close() end) end
      end
      local ok, result, sendErr = pcall(function()
         if recipient.job_type == "password-help" then
            -- Recovery notices contain literal contact data, not mail-merge templates.
            return smtpClient():send {
               from = settings.fromAddress, to = recipient.email,
               subject = recipient.subject, txtbody = recipient.text_body
            }
         end
         for _, saved in ipairs(jobFiles) do
            local current, currentErr = digestFile(files, recipient.sender,
               saved.relative_path)
            if not current then error(currentErr, 2) end
            if current.size ~= tonumber(saved.byte_length) or
               current.sha256 ~= saved.sha256 then
               error("File changed after the job was created: " ..
                  saved.relative_path, 2)
            end
         end

          local textLinks, htmlLinks = "", ""
          if recipient.job_type == "invitation" then
             textLinks = createInvitationLink(recipient)
             htmlLinks = "<a href=\"" ..
                textLinks:gsub("&", "&amp;"):gsub('"', "&quot;") ..
                "\">Set your password</a>"
          elseif recipient.delivery_mode == "link" then
             textLinks, htmlLinks = grantLinks(recipient, recipient, jobFiles)
         elseif recipient.delivery_mode == "attachment" then
            for _, saved in ipairs(jobFiles) do
               local file, openErr = files.openAuthorized(
                  recipient.sender, saved.relative_path, "rb")
               if not file then error(openErr, 2) end
               opened[#opened + 1] = file
               attachments[#attachments + 1] = {
                  source = file, name = saved.download_name
               }
            end
         end

         local message
         if recipient.template_snapshot then
            local parsed, parseErr = parseEml(recipient.template_snapshot)
            if not parsed then error(parseErr, 2) end
            message = parsed
         else
            message = {}
         end
         message.from = settings.fromAddress
         message.replyto = settings.replyTo ~= "" and settings.replyTo or nil
         local recipientName = trim(recipient.first_name .. " " .. recipient.last_name)
         message.to = recipientName ~= "" and
            (recipientName .. " <" .. recipient.email .. ">") or recipient.email
         local textSource = recipient.text_body
         if textSource == nil then textSource = message.txtbody or "" end
         local htmlSource = recipient.html_body
         if htmlSource == nil then htmlSource = message.htmlbody or "" end
         local usesUnsubscribe = recipient.subject:find(
            "{{UNSUBSCRIBE_LINK}}", 1, true) ~= nil or
            textSource:find("{{UNSUBSCRIBE_LINK}}", 1, true) ~= nil or
            htmlSource:find("{{UNSUBSCRIBE_LINK}}", 1, true) ~= nil
         local textUnsubscribe, htmlUnsubscribe = "", ""
         if usesUnsubscribe then
            textUnsubscribe = createUnsubscribeLink(recipient)
            htmlUnsubscribe = "<a href=\"" ..
               textUnsubscribe:gsub("&", "&amp;"):gsub('"', "&quot;") ..
               "\">Manage email preferences</a>"
         end
         message.subject = expand(recipient.subject, recipient, textLinks,
            textUnsubscribe, false)
         local linkMacro = recipient.job_type == "invitation" and
            "{{INVITATION_LINK}}" or "{{DOWNLOAD_LINKS}}"
         local linkHeading = recipient.job_type == "invitation" and
            "Set your password:" or "Download files:"
         local textHasMacro = textSource:find(linkMacro, 1, true) ~= nil
         local htmlHasMacro = htmlSource:find(linkMacro, 1, true) ~= nil
         message.txtbody = expand(textSource, recipient, textLinks,
            textUnsubscribe, false)
         message.htmlbody = expand(htmlSource, recipient, htmlLinks,
            htmlUnsubscribe, true)
         if not textHasMacro then
            message.txtbody = appendGeneratedLinks(message.txtbody, textLinks,
               false, linkHeading)
         end
         if htmlSource ~= "" and not htmlHasMacro then
            message.htmlbody = appendGeneratedLinks(message.htmlbody, htmlLinks,
               true, linkHeading)
         end
         if message.txtbody == "" then message.txtbody = nil end
         if message.htmlbody == "" then message.htmlbody = nil end
         if #attachments > 0 then message.attach = attachments end
         return smtpClient():send(message)
      end)
      closeFiles()
      if not ok then return nil, result end
      if not result then return nil, sendErr end
      return true
   end

   local function processOne()
      if stopped or not settings.enabled then return false end
      local recipient = claimRecipient()
      if not recipient then return false end
      local ok, err = sendRecipient(recipient)
      finishRecipient(recipient, ok == true, err)
      return true
   end

   schedule = function(delay)
      if stopped or not settings.enabled then return end
      if timer then timer:cancel() end
      timer = ba.timer(function()
         timer = nil
         if stopped or busy then return end
         busy = true
         worker:run(function()
            local ok, processedOrErr = pcall(processOne)
            if not ok then ctx:trace("Mailer worker failed:", tostring(processedOrErr)) end
            busy = false
            schedule((processedOrErr == true and settings.sendInterval or 1) * 1000)
         end)
      end)
      timer:set(delay or 1, true)
   end

   function service.queueJob(id)
      id = integer(id, 1, 9007199254740991, "Job ID")
      local job = one(ctx, "SELECT status FROM mailer_jobs WHERE id=" .. id)
      if not job then return nil, "Job not found" end
      if job.status ~= "draft" then return nil, "Only draft jobs can be queued" end
      ctx.db.writeSync(function(conn)
         execute(conn, string.format(
            "UPDATE mailer_jobs SET status='queued',queued_at=%d WHERE id=%d",
            os.time(), id))
      end)
      schedule(1)
      return jobSummary(id)
   end

   function service.cancelJob(id)
      id = integer(id, 1, 9007199254740991, "Job ID")
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
UPDATE mailer_jobs SET status='cancelled',cancelled_at=%d
WHERE id=%d AND status IN ('draft','queued','sending','retry')
]], os.time(), id))
         execute(conn, string.format([[
UPDATE mailer_job_recipients SET status='cancelled',lease_until=NULL,next_attempt_at=NULL
WHERE job_id=%d AND status IN ('pending','sending','retry')
]], id))
         execute(conn, "UPDATE mailer_download_grants SET revoked_at=" .. os.time() ..
            " WHERE recipient_id IN (SELECT id FROM mailer_job_recipients WHERE job_id=" ..
            id .. ") AND revoked_at IS NULL")
      end)
      return jobSummary(id)
   end

   function service.invitation(env, token)
      if not tostring(token or ""):match("^[A-Za-z0-9_%-]+$") then return false end
      local tokenHash = ba.crypto.hash"sha256"(token)(true, "hex")
      local credential = one(ctx, string.format([[
SELECT credentials.contact_id,credentials.invitation_expires_at,
       contacts.email,contacts.first_name
FROM mailer_contact_credentials credentials
JOIN mailer_contacts contacts ON contacts.id=credentials.contact_id
WHERE credentials.invitation_token_hash=%s
]], quote(tokenHash)))
      if not credential or tonumber(credential.invitation_expires_at or 0) < os.time() then
         env.response:senderror(404, "Invitation not found or expired")
         return true
      end

      local function page(message, complete)
         env.response:setcontenttype("text/html; charset=utf-8")
         env.response:setheader("cache-control", "no-store")
         env.response:setheader("x-content-type-options", "nosniff")
         env.response:write([[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Set download password</title><link rel="stylesheet" href="]],
            pluginApp.url("/mailer/public.css"),
            [["></head><body class="public-page"><main class="public-panel">]])
         if complete then
            env.response:write("<h1>Password saved</h1><p>Your email address is confirmed. You may now use password-protected file links sent to you.</p>")
         else
            env.response:write("<h1>Set download password</h1><p>Confirm ",
               htmlEscape(credential.email), " by creating your personal download password.</p>")
            if message then env.response:write("<p class='error'>", htmlEscape(message), "</p>") end
            local session = env.request:session(true)
            session.mailerInvitationCsrf = session.mailerInvitationCsrf or
               ba.b64urlencode(ba.rndbs(24))
            env.response:write("<form method='post'><input type='hidden' name='csrf' value='",
               session.mailerInvitationCsrf,
               "'><label>Password</label><input type='password' name='password' minlength='8' required autocomplete='new-password'>",
               "<label>Confirm password</label><input type='password' name='confirm' minlength='8' required autocomplete='new-password'>",
               "<button type='submit'>Save password</button></form>")
         end
         env.response:write("</main></body></html>")
         return true
      end

      if env.request:method() ~= "POST" then return page() end
      local data = env.request:data() or {}
      local session = env.request:session(true)
      if not session.mailerInvitationCsrf or
         not secureEqual(data.csrf, session.mailerInvitationCsrf) then
         env.response:setstatus(403)
         return page("The form expired. Reload the invitation and try again.")
      end
      local password = tostring(data.password or "")
      if #password < 8 then return page("Use at least eight characters.") end
      if #password > 1024 then return page("The password is too long.") end
      if password ~= tostring(data.confirm or "") then
         return page("The passwords do not match.")
      end
      local salt = ba.rndbs(16)
      local iterations = 100000
      local hash = ba.b64urlencode(passwordDigest(password, salt, iterations))
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
UPDATE mailer_contact_credentials SET
 password_salt=%s,password_hash=%s,password_iterations=%d,confirmed_at=%d,
 invitation_token_hash=NULL,invitation_expires_at=NULL,updated_at=%d
WHERE contact_id=%d AND invitation_token_hash=%s
]], quote(ba.b64urlencode(salt)), quote(hash), iterations, os.time(), os.time(),
            tonumber(credential.contact_id), quote(tokenHash)))
      end)
      session.mailerInvitationCsrf = nil
      return page(nil, true)
   end

   function service.unsubscribe(env, token)
      if not tostring(token or ""):match("^[A-Za-z0-9_%-]+$") then return false end
      local tokenHash = ba.crypto.hash"sha256"(token)(true, "hex")
      local contact = one(ctx, string.format([[
SELECT contacts.id,contacts.email,contacts.first_name,contacts.last_name,
       contacts.unsubscribed_at,tokens.used_at
FROM mailer_unsubscribe_tokens tokens
JOIN mailer_contacts contacts ON contacts.id=tokens.contact_id
WHERE tokens.token_hash=%s
]], quote(tokenHash)))
      if not contact then
         env.response:senderror(404, "Unsubscribe link not found")
         return true
      end

      local function page(message, tone, draft)
         draft = draft or contact
         env.response:setcontenttype("text/html; charset=utf-8")
         env.response:setheader("cache-control", "no-store")
         env.response:setheader("x-content-type-options", "nosniff")
         env.response:write([[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Email preferences</title><link rel="stylesheet" href="]],
            pluginApp.url("/mailer/public.css"),
            [["></head><body class="public-page"><main class="public-panel">]])
         env.response:write("<p class='eyebrow'>Email preferences</p>",
            "<h1>Manage your details</h1>",
            "<p>Update the name and email address used for future messages.</p>")
         if message then
            env.response:write("<p class='", tone == "success" and "success" or "error",
               "' role='status'>", htmlEscape(message), "</p>")
         end
         env.response:write("<p class='subscription-status'><strong>Status:</strong> ",
            contact.unsubscribed_at and "Unsubscribed" or "Subscribed", "</p>")
         local session = env.request:session(true)
         session.mailerUnsubscribeCsrf = session.mailerUnsubscribeCsrf or
            ba.b64urlencode(ba.rndbs(24))
         local csrf = session.mailerUnsubscribeCsrf
         env.response:write("<form method='post'><input type='hidden' name='csrf' value='",
            csrf, "'><input type='hidden' name='action' value='save'>",
            "<label for='preference-email'>Email address</label>",
            "<input id='preference-email' type='email' name='email' maxlength='254' required ",
            "autocomplete='email' value='", htmlEscape(draft.email), "'>",
            "<div class='field-grid'><div><label for='preference-first-name'>First name</label>",
            "<input id='preference-first-name' name='first_name' maxlength='160' ",
            "autocomplete='given-name' value='", htmlEscape(draft.first_name), "'></div>",
            "<div><label for='preference-last-name'>Last name</label>",
            "<input id='preference-last-name' name='last_name' maxlength='160' ",
            "autocomplete='family-name' value='", htmlEscape(draft.last_name), "'></div></div>",
            "<button type='submit'>Save changes</button></form>")
         if not contact.unsubscribed_at then
            env.response:write("<section class='preference-danger'><h2>Stop future email</h2>",
               "<p>You will be removed from all recipient lists.</p>",
               "<form method='post'><input type='hidden' name='csrf' value='", csrf,
               "'><input type='hidden' name='action' value='unsubscribe'>",
               "<button class='danger' type='submit'>Unsubscribe from emails</button>",
               "</form></section>")
         end
         env.response:write("</main></body></html>")
         return true
      end

      if env.request:method() ~= "POST" then return page() end
      local data = env.request:data() or {}
      local session = env.request:session(true)
      if not session.mailerUnsubscribeCsrf or
         not secureEqual(data.csrf, session.mailerUnsubscribeCsrf) then
         env.response:setstatus(403)
         return page("The form expired. Reload the page and try again.")
      end
      session.mailerUnsubscribeCsrf = nil
      if data.action == "save" then
         local draft = {
            email = trim(data.email), first_name = trim(data.first_name),
            last_name = trim(data.last_name)
         }
         local ok, err = pcall(function()
            draft.email = emailAddress(draft.email)
            if #draft.first_name > 160 or #draft.last_name > 160 then
               error("A name is too long", 2)
            end
            ctx.db.writeSync(function(conn)
               local duplicate = sqlRow(conn,
                  "SELECT id FROM mailer_contacts WHERE email=" .. quote(draft.email) ..
                  " AND id<>" .. tonumber(contact.id))
               if duplicate then error("That email address is already in use", 2) end
               execute(conn, string.format([[
UPDATE mailer_contacts SET email=%s,first_name=%s,last_name=%s,updated_at=%d
WHERE id=%d
]], quote(draft.email), quote(draft.first_name), quote(draft.last_name),
                  os.time(), tonumber(contact.id)))
            end)
         end)
         if not ok then
            env.response:setstatus(400)
            return page(cleanError(err), "error", draft)
         end
         contact.email, contact.first_name, contact.last_name =
            draft.email, draft.first_name, draft.last_name
         return page("Your contact details were updated.", "success")
      end
      if data.action ~= "unsubscribe" then
         env.response:setstatus(400)
         return page("Choose an email preference action.")
      end
      if contact.unsubscribed_at then
         return page("This address is already unsubscribed.", "success")
      end
      local now = os.time()
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
UPDATE mailer_contacts SET unsubscribed_at=%d,updated_at=%d WHERE id=%d
]], now, now, tonumber(contact.id)))
         execute(conn, "DELETE FROM mailer_list_members WHERE contact_id=" ..
            tonumber(contact.id))
         execute(conn, "UPDATE mailer_unsubscribe_tokens SET used_at=" .. now ..
            " WHERE contact_id=" .. tonumber(contact.id))
         execute(conn, string.format([[
UPDATE mailer_job_recipients
SET status='skipped',lease_until=NULL,next_attempt_at=NULL,
    last_error='Recipient unsubscribed'
WHERE contact_id=%d AND status IN ('pending','sending','retry')
]], tonumber(contact.id)))
         execute(conn, string.format([[
UPDATE mailer_jobs SET status='completed',completed_at=COALESCE(completed_at,%d)
WHERE status IN ('queued','sending','retry')
  AND NOT EXISTS (
     SELECT 1 FROM mailer_job_recipients recipients
     WHERE recipients.job_id=mailer_jobs.id
       AND recipients.status IN ('pending','sending','retry')
  )
]], now))
      end)
      contact.unsubscribed_at = now
      return page("You have been unsubscribed from future mailer deliveries.", "success")
   end

   local function logDownload(grant, eventType, detail)
      local now = os.time()
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
INSERT INTO mailer_download_events(grant_id,event_type,detail,created_at)
VALUES(%d,%s,%s,%d)
]], tonumber(grant.id), quote(eventType), quote(detail or ""), now))
         if eventType == "download-completed" then
            execute(conn, string.format([[
INSERT INTO mailer_download_stats(recipient_id,file_id,successful_downloads,last_downloaded_at)
VALUES(%d,%d,1,%d)
ON CONFLICT(recipient_id,file_id) DO UPDATE SET
 successful_downloads=successful_downloads+1,
 last_downloaded_at=MAX(last_downloaded_at,excluded.last_downloaded_at)
]], tonumber(grant.recipient_id), tonumber(grant.file_id), now))
         end
      end)
   end

   local function requestPasswordHelp(grant)
      if not settings.enabled or settings.smtpServer == "" or settings.fromAddress == "" then
         error("Mailer is not configured to send password help", 2)
      end
      return ctx.db.writeSync(function(conn)
         local now = os.time()
         -- Recheck inside the transaction: another link/tab may have revoked this one.
         if not sqlRow(conn, string.format([[
SELECT g.id FROM mailer_download_grants g
JOIN mailer_job_recipients r ON r.id=g.recipient_id
JOIN mailer_jobs j ON j.id=r.job_id
WHERE g.id=%d AND g.revoked_at IS NULL AND g.expires_at>=%d
 AND j.status NOT IN ('cancelled','revoked')
]], tonumber(grant.id), now)) then return false end
         local recipient = "lower(email)=lower(" .. quote(grant.email) .. ")"
         if grant.contact_id then recipient = recipient .. " OR contact_id=" .. tonumber(grant.contact_id) end
         execute(conn, string.format([[
UPDATE mailer_download_grants SET revoked_at=%d
WHERE revoked_at IS NULL AND expires_at>=%d AND recipient_id IN
 (SELECT id FROM mailer_job_recipients WHERE %s)
]], now, now, recipient))
         local count = tonumber(sqlRow(conn, "SELECT changes() AS count").count)
         local body = "Password help was requested from a download link for " .. grant.email ..
            ".\nOriginal sender: " .. grant.sender .. ".\n" ..
            count .. " unexpired download links were invalidated. The password was not changed.\n" ..
            "Possession of a download link does not verify the recipient's identity. " ..
            "Verify the recipient independently before resetting their password and sending new links."
         execute(conn, string.format([[
INSERT INTO mailer_jobs(sender,status,delivery_mode,subject,text_body,job_type,created_at,queued_at)
VALUES(%s,'queued','email','FuguHub password help requested',%s,'password-help',%d,%d)
]], quote(grant.sender), quote(body), now, now))
         local jobId = insertId(conn)
         execute(conn, string.format([[
INSERT INTO mailer_job_recipients(job_id,email) VALUES(%d,%s)
]], jobId, quote(settings.fromAddress)))
         execute(conn, string.format([[
INSERT INTO mailer_download_events(grant_id,event_type,detail,created_at)
VALUES(%d,'password-help-requested',%s,%d)
]], tonumber(grant.id), quote("Notification job " .. jobId), now))
         return true
      end)
   end

   function service.download(env, token)
      if not tostring(token or ""):match("^[A-Za-z0-9_%-]+$") then return false end
      local tokenHash = ba.crypto.hash"sha256"(token)(true, "hex")
      local grant = one(ctx, string.format([[
SELECT g.*,f.relative_path,f.download_name,f.byte_length,f.sha256,
       j.sender,j.status AS job_status,j.require_contact_password,r.contact_id,r.email
FROM mailer_download_grants g
JOIN mailer_job_files f ON f.id=g.file_id
JOIN mailer_job_recipients r ON r.id=g.recipient_id
JOIN mailer_jobs j ON j.id=r.job_id
WHERE g.token_hash=%s
]], quote(tokenHash)))
      if not grant or grant.revoked_at or tonumber(grant.expires_at) < os.time() or
         grant.job_status == "cancelled" or grant.job_status == "revoked" then
         env.response:senderror(404, "Download not found")
         return true
      end
      if settings.requireHttps and not env.request:issecure() then
         env.response:senderror(403, "HTTPS is required")
         return true
      end
      local session = env.request:session(true)
      local protected = tonumber(grant.require_contact_password) == 1 or grant.password_hash ~= nil
      local data = env.request:method() == "POST" and (env.request:data() or {}) or nil
      if protected and data and (not session.mailerDownloadCsrf or
         not secureEqual(data.csrf, session.mailerDownloadCsrf)) then
         env.response:senderror(403, "Forbidden")
         return true
      end
      local function page(message, requested, locked)
         session.mailerDownloadCsrf = not requested and ba.b64urlencode(ba.rndbs(24)) or nil
         env.response:setcontenttype("text/html; charset=utf-8")
         env.response:setheader("cache-control", "no-store")
         env.response:write("<!doctype html><html lang='en'><head><meta charset='utf-8'>",
            "<meta name='viewport' content='width=device-width,initial-scale=1'>",
            "<title>", requested and "Password help requested" or "Protected download",
            "</title><link rel='stylesheet' href='", pluginApp.url("/mailer/public.css"),
            "'></head><body class='public-page'><main class='public-panel'>",
            "<h1>", requested and "Password help requested" or "Protected download", "</h1>")
         if message then
            env.response:write("<p id='download-message' class='", requested and "success" or "error",
               "' role='", requested and "status" or "alert", "'>", htmlEscape(message), "</p>")
         end
         if not requested then
            env.response:write("<div class='file-summary'><strong>", htmlEscape(grant.download_name),
               "</strong><span>Enter your password to download this file.</span></div>",
               "<form method='post'><input type='hidden' name='csrf' value='", session.mailerDownloadCsrf,
               "'><label for='download-password'>Password</label>",
               "<input id='download-password' type='password' name='password' required autocomplete='current-password'",
               message and " aria-describedby='download-message'" or "",
               locked and " disabled>" or " autofocus>",
               "<button type='submit'", locked and " disabled" or "", ">Download file</button></form>",
               "<section class='preference-danger'><p id='password-help-warning'>Requesting help notifies the mailer administrator and invalidates all your unexpired download links. Your password stays the same.</p>",
               "<form method='post'><input type='hidden' name='csrf' value='", session.mailerDownloadCsrf,
               "'><button class='danger' type='submit' name='action' value='password-help' aria-describedby='password-help-warning'>Forgot your password?</button></form></section>")
         end
         env.response:write("</main></body></html>")
         return true
      end
      if protected and data and data.action == "password-help" then
         local ok, requested = pcall(requestPasswordHelp, grant)
         if not ok then
            ctx:trace("Password help failed:", tostring(requested))
            env.response:setstatus(503)
            return page("Help could not be requested. Your download links are unchanged. Please contact the sender.")
         end
         if not requested then
            env.response:senderror(404, "Download not found")
            return true
         end
         local scheduled, err = pcall(schedule, 1)
         if not scheduled then ctx:trace("Password help scheduling failed:", tostring(err)) end
         return page("Your help request has been queued for the mailer administrator. All your unexpired download links have been invalidated. Your password has not changed. The administrator will need to verify your identity and send new links.", true)
      end
      if tonumber(grant.require_contact_password) == 1 then
         local current = grant.contact_id and one(ctx, [[
SELECT password_salt,password_hash,password_iterations,confirmed_at
FROM mailer_contact_credentials WHERE contact_id=]] ..
            tonumber(grant.contact_id)) or nil
         if not current or not current.confirmed_at or not current.password_hash then
            env.response:setstatus(403)
            return page("The recipient password is unavailable. You can request help below.", false, true)
         end
         grant.password_salt = current.password_salt
         grant.password_hash = current.password_hash
         grant.password_iterations = current.password_iterations
      end

      local grantKey = "mailerGrant" .. grant.id
      local passwordError = false
      if grant.password_hash and
         not secureEqual(session[grantKey], grant.password_hash) then
         if tonumber(grant.failed_attempts) >= 5 then
            env.response:setstatus(429)
            return page("Too many failed attempts. You can request help below.", false, true)
         end
         if data then
            local salt = ba.b64decode(grant.password_salt)
            local candidate = passwordDigest(tostring(data.password or ""), salt,
               tonumber(grant.password_iterations))
            if secureEqual(ba.b64urlencode(candidate), grant.password_hash) then
               session[grantKey] = grant.password_hash
               session.mailerDownloadCsrf = nil
            else
               ctx.db.writeSync(function(conn)
                  execute(conn, "UPDATE mailer_download_grants SET failed_attempts=" ..
                     "failed_attempts+1 WHERE id=" .. tonumber(grant.id))
               end)
                logDownload(grant, "password-failed", "")
                passwordError = true
               if tonumber(grant.failed_attempts) + 1 >= 5 then
                  env.response:setstatus(429)
                  return page("Too many failed attempts. You can request help below.", false, true)
               end
            end
         end
         if not secureEqual(session[grantKey], grant.password_hash) then
            return page(passwordError and "The password is incorrect. Try again." or nil)
         end
      end

      local current, currentErr = digestFile(files, grant.sender, grant.relative_path)
      if not current or current.size ~= tonumber(grant.byte_length) or
         current.sha256 ~= grant.sha256 then
         logDownload(grant, "file-invalid", tostring(currentErr or "changed"))
         env.response:senderror(410, "File is no longer available")
         return true
      end
      local file, openErr = files.openAuthorized(grant.sender, grant.relative_path, "rb")
      if not file then
         env.response:senderror(404, tostring(openErr or "File not found"))
         return true
      end
      env.response:setcontenttype("application/octet-stream")
      env.response:setheader("cache-control", "no-store")
      env.response:setheader("content-length", tostring(current.size))
      env.response:setheader("content-disposition", 'attachment; filename="' ..
         displayName(grant.download_name) .. '"')
      if env.request:method() == "HEAD" then file:close() return true end
      local ok, completed, err = pcall(function()
         local sent, hash = 0, ba.crypto.hash"sha256"
         while true do
            local chunk, readErr = file:read(16384)
            if readErr then return nil, readErr end
            if not chunk or #chunk == 0 then break end
            sent = sent + #chunk
            if sent > current.size then return nil, "File changed during download" end
            hash(chunk)
            local written, writeErr = env.response:write(chunk)
            if written ~= #chunk then return nil, writeErr or "Download write failed" end
         end
         if sent ~= current.size or hash(true, "hex") ~= grant.sha256 then
            return nil, "File changed during download"
         end
         return env.response:flush(), "Download flush failed"
      end)
      file:close()
      if not ok or not completed then
         ctx:trace("Download failed:", tostring(ok and err or completed))
         env.response:clearkeepalive()
         if not env.response:committed() then env.response:senderror(500, "Download failed") end
         return true
      end
      local recorded, recordErr = pcall(logDownload, grant, "download-completed", "")
      if not recorded then ctx:trace("Download statistics failed:", tostring(recordErr)) end
      return true
   end

   if settings.enabled then schedule(1) end

   runtime = {
      service = service,
      stop = function()
         stopped = true
         if timer then timer:cancel() timer = nil end
      end
   }
   return service
end

function M.stop()
   if runtime and runtime.stop then runtime.stop() end
   runtime = nil
end

return M
