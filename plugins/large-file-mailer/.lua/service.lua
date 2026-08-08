local parseEml = require "eml/EmailMessage"
require "socket.mail"

local M = {}
local runtime
local KEY_NAME = "FuguHub-Large-File-Mailer-SMTP"

local function trim(value)
   return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function htmlEscape(value)
   return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):
      gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function cleanError(value)
   local message = tostring(value or "Request failed")
   while true do
      local cleaned = message:match("^.-%.lua:%d+:%s*(.*)$")
      if not cleaned or cleaned == message then return message end
      message = cleaned
   end
end

local function fileRootLabel(files)
   local location = files.location and files.location() or {}
   if location.io == "home" then
      return "Mako home IO at " .. tostring(location.path or "/")
   end
   return tostring(location.io or "configured") .. " IO at " ..
      tostring(location.path or "/")
end

local function quote(value)
   return luasql.quotestr(tostring(value or ""))
end

local function execute(conn, sql)
   local result, err = conn:execute(sql)
   if result == nil then error(tostring(err or "SQL execution failed"), 2) end
   if type(result) == "userdata" and result.close then result:close() end
end

local function integer(value, minimum, maximum, label)
   value = tonumber(value)
   if not value or value % 1 ~= 0 or value < minimum or value > maximum then
      error(label .. " must be an integer from " .. minimum .. " to " .. maximum, 3)
   end
   return value
end

local function rows(ctx, sql)
   local env, conn = ctx.db.openRead()
   local ok, result = pcall(function()
      local cursor, err = conn:execute(sql)
      if not cursor then error(tostring(err or "SQL query failed"), 2) end
      local values = {}
      while true do
         local row = cursor:fetch({}, "a")
         if not row then break end
         values[#values + 1] = row
      end
      cursor:close()
      return values
   end)
   conn:close()
   env:close()
   if not ok then error(result, 2) end
   return result
end

local function encryptionKey()
   local unique = ba.tpm.uniquekey(KEY_NAME, 32)
   return ba.crypto.hash"sha256"(unique)(true)
end

local function encryptSecret(secret)
   local iv = ba.rndbs(12)
   local cipher, tag = ba.crypto.symmetric("GCM", encryptionKey(), iv):encrypt(secret)
   return table.concat({
      "v1", ba.b64urlencode(iv), ba.b64urlencode(tag), ba.b64urlencode(cipher)
   }, ":")
end

local function decryptSecret(encoded)
   if type(encoded) ~= "string" then return nil, "SMTP password is missing" end
   local version, ivText, tagText, cipherText =
      encoded:match("^([^:]+):([^:]+):([^:]+):([^:]+)$")
   if version ~= "v1" then return nil, "SMTP password format is unsupported" end
   local iv, tag, cipher = ba.b64decode(ivText), ba.b64decode(tagText),
      ba.b64decode(cipherText)
   if not iv or #iv ~= 12 or not tag or not cipher then
      return nil, "SMTP password is corrupt"
   end
   local secret = ba.crypto.symmetric("GCM", encryptionKey(), iv):decrypt(cipher, tag)
   if secret == nil then return nil, "SMTP password cannot be decrypted" end
   return secret
end

local function loadSettings(ctx)
   local row = rows(ctx, [[
SELECT enabled,smtp_server,smtp_port,smtp_security,smtp_username,
       from_address,reply_to,public_base_url,attachment_limit,grant_ttl,max_attempts,
       retry_base,send_interval,require_https
FROM mailer_settings WHERE singleton=1
]])[1]
   local secret = rows(ctx,
      "SELECT encrypted_password FROM mailer_smtp_secret WHERE singleton=1")[1]
   return {
      enabled = tonumber(row.enabled) == 1,
      smtpServer = row.smtp_server,
      smtpPort = tonumber(row.smtp_port),
      smtpSecurity = row.smtp_security,
      smtpUsername = row.smtp_username,
      fromAddress = row.from_address,
      replyTo = row.reply_to,
      publicBaseUrl = row.public_base_url,
      attachmentLimit = tonumber(row.attachment_limit),
      grantTtl = tonumber(row.grant_ttl),
      maxAttempts = tonumber(row.max_attempts),
      retryBase = tonumber(row.retry_base),
      sendInterval = tonumber(row.send_interval),
      requireHttps = tonumber(row.require_https) == 1,
      passwordConfigured = secret ~= nil,
      encryptedPassword = secret and secret.encrypted_password or nil
   }
end

local function one(ctx, sql)
   return rows(ctx, sql)[1]
end

local function sqlRow(conn, sql)
   local cursor, err = conn:execute(sql)
   if not cursor then error(tostring(err or "SQL query failed"), 2) end
   local row = cursor:fetch({}, "a")
   cursor:close()
   return row
end

local function insertId(conn)
   return tonumber(sqlRow(conn, "SELECT last_insert_rowid() AS id").id)
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

local function emailAddress(value)
   value = trim(value)
   if #value > 254 or not value:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
      error("Invalid recipient email address", 3)
   end
   return value
end

local function mailboxAddress(value, field, optional)
   value = trim(value)
   field = field or "email address"
   if value == "" and optional then return "" end
   if value == "" or #value > 320 or value:find("[\r\n]") then
      error("Invalid " .. field, 3)
   end
   local display, address = value:match("^([^<>]*)<([^<>]+)>$")
   if not address then
      if value:find("[<>]") then error("Invalid " .. field, 3) end
      address = value
   end
   address = trim(address)
   if #address > 254 or not address:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
      error("Invalid " .. field, 3)
   end
   display = trim(display)
   return display ~= "" and (display .. " <" .. address .. ">") or address
end

local function extractEmailAddresses(source)
   source = tostring(source or "")
   if #source > 2 * 1024 * 1024 then error("Email input exceeds 2 MiB", 3) end
   local values, seen = {}, {}
   for extracted in source:gmatch("[%w!#$%%&'*+/=?^_`{|}~%.%-]+@[%w%.%-]+") do
      local candidate = extracted:gsub("^%.+", ""):gsub("%.+$", "")
      local localPart, domain = candidate:match("^([^@]+)@([^@]+)$")
      local valid = localPart and domain and #candidate <= 254 and
         localPart:sub(1, 1) ~= "." and localPart:sub(-1) ~= "." and
         not localPart:find("..", 1, true) and
         not domain:find("..", 1, true) and domain:find(".", 1, true) and
         domain:sub(1, 1) ~= "-" and domain:sub(-1) ~= "-"
      if valid then
         for label in domain:gmatch("[^.]+") do
            if label:sub(1, 1) == "-" or label:sub(-1) == "-" then
               valid = false
               break
            end
         end
      end
      if valid then
         local key = candidate:lower()
         if not seen[key] then
            seen[key] = true
            values[#values + 1] = candidate
            if #values > 10000 then
               error("Email input exceeds 10000 unique addresses", 3)
            end
         end
      end
   end
   if #values == 0 then error("No email addresses were found", 3) end
   return values
end

local cp1252 = {
   [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192,
   [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020,
   [0x87] = 0x2021, [0x88] = 0x02C6, [0x89] = 0x2030,
   [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
   [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019,
   [0x93] = 0x201C, [0x94] = 0x201D, [0x95] = 0x2022,
   [0x96] = 0x2013, [0x97] = 0x2014, [0x98] = 0x02DC,
   [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
   [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178
}

local function normalizeCsvEncoding(source)
   if source:sub(1, 2) == "\255\254" or source:sub(1, 2) == "\254\255" then
      error("UTF-16 CSV is not supported; export as UTF-8 or Windows-1252", 3)
   end
   if utf8.len(source) then return source end
   local converted = {}
   for index = 1, #source do
      local byte = source:byte(index)
      if byte < 0x80 then
         converted[#converted + 1] = string.char(byte)
      elseif byte >= 0xA0 then
         converted[#converted + 1] = utf8.char(byte)
      else
         local codepoint = cp1252[byte]
         if not codepoint then
            error("CSV is neither valid UTF-8 nor supported Windows-1252", 3)
         end
         converted[#converted + 1] = utf8.char(codepoint)
      end
   end
   return table.concat(converted)
end

local function parseCsv(source)
   source = tostring(source or "")
   if #source > 2097152 then error("CSV input exceeds 2 MiB", 3) end
   source = normalizeCsvEncoding(source)
   source = source:gsub("^\239\187\191", "")
   local records, record, field = {}, {}, {}
   local quoted, index, length = false, 1, #source
   local function finishField()
      record[#record + 1] = table.concat(field)
      field = {}
   end
   local function finishRecord()
      finishField()
      local nonempty = false
      for _, value in ipairs(record) do
         if value ~= "" then nonempty = true break end
      end
      if nonempty then
         records[#records + 1] = record
         if #records > 5001 then error("CSV input exceeds 5000 contacts", 3) end
      end
      record = {}
   end
   while index <= length do
      local char = source:sub(index, index)
      if quoted then
         if char == '"' then
            if source:sub(index + 1, index + 1) == '"' then
               field[#field + 1] = '"'
               index = index + 1
            else
               quoted = false
            end
         else
            field[#field + 1] = char
         end
      elseif char == '"' and #field == 0 then
         quoted = true
      elseif char == "," then
         finishField()
      elseif char == "\r" or char == "\n" then
         if char == "\r" and source:sub(index + 1, index + 1) == "\n" then
            index = index + 1
         end
         finishRecord()
      else
         field[#field + 1] = char
      end
      index = index + 1
   end
   if quoted then error("CSV input has an unterminated quoted field", 3) end
   if #field > 0 or #record > 0 then finishRecord() end
   if #records < 1 then error("CSV input must contain at least one row", 3) end
   return records
end

local function csvMapping(headers, requested, requireEmail)
   local aliases = {
      email = { email = true, emailaddress = true, primaryemail = true,
         primaryemailaddress = true, email1 = true, emailaddress1 = true },
      firstName = { firstname = true, first = true, givenname = true },
      lastName = { lastname = true, last = true, surname = true, familyname = true },
      externalId = { externalid = true, contactid = true, id = true }
   }
   local mapping = {}
   for fieldName, names in pairs(aliases) do
      local selected = requested and tonumber(requested[fieldName])
      if selected and selected >= 1 and selected <= #headers then
         mapping[fieldName] = selected
      elseif not requested then
         for column, heading in ipairs(headers) do
            local normalized = trim(heading):lower():gsub("[^a-z0-9]", "")
            if names[normalized] then mapping[fieldName] = column break end
         end
      end
   end
   if requireEmail and not mapping.email then error("Select an email column", 3) end
   return mapping
end

local function csvLayout(records, forcedHasHeader)
   local detected = csvMapping(records[1])
   local firstEmailColumn
   for column, value in ipairs(records[1]) do
      if pcall(emailAddress, value) then
         firstEmailColumn = column
         break
      end
   end
   local hasHeader = forcedHasHeader
   if hasHeader == nil then
      hasHeader = next(detected) ~= nil or firstEmailColumn == nil
   end
   if hasHeader then
      if #records < 2 then
         error("CSV input must contain at least one contact row", 3)
      end
      if #records - 1 > 5000 then error("CSV input exceeds 5000 contacts", 3) end
      return records[1], detected, 2, true
   end
   if #records > 5000 then error("CSV input exceeds 5000 contacts", 3) end
   local columnCount = 0
   for _, row in ipairs(records) do columnCount = math.max(columnCount, #row) end
   local headers = {}
   for column = 1, columnCount do headers[column] = "Column " .. column end
   return headers, { email = firstEmailColumn }, 1, false
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
   local settings = loadSettings(ctx)
   local service = {}
   local stopped, busy, timer = false, false, nil
   local worker = ba.thread.create()
   local schedule

   function service.state()
      local fileServices = files and files.location and files.location() or nil
      return {
         settings = {
            enabled = settings.enabled,
            smtpServer = settings.smtpServer,
            smtpPort = settings.smtpPort,
            smtpSecurity = settings.smtpSecurity,
            smtpUsername = settings.smtpUsername,
            fromAddress = settings.fromAddress,
            replyTo = settings.replyTo,
            publicBaseUrl = settings.publicBaseUrl,
            attachmentLimit = settings.attachmentLimit,
            grantTtl = settings.grantTtl,
            maxAttempts = settings.maxAttempts,
            retryBase = settings.retryBase,
            sendInterval = settings.sendInterval,
            requireHttps = settings.requireHttps,
            passwordConfigured = settings.passwordConfigured
         },
         identityReady = identity ~= nil,
         fileServicesReady = files ~= nil,
         fileServices = fileServices
      }
   end

   function service.parseTemplate(source)
      return parseEml(source)
   end

   function service.saveSettings(input)
      input = input or {}
      local nextSettings = {
         enabled = input.enabled == true,
         smtpServer = trim(input.smtpServer),
         smtpPort = integer(input.smtpPort, 1, 65535, "SMTP port"),
         smtpSecurity = tostring(input.smtpSecurity or ""),
         smtpUsername = trim(input.smtpUsername),
         fromAddress = trim(input.fromAddress),
         replyTo = trim(input.replyTo),
         publicBaseUrl = trim(input.publicBaseUrl),
         attachmentLimit = integer(input.attachmentLimit, 0, 1073741824,
            "Attachment limit"),
         grantTtl = integer(input.grantTtl, 60, 31536000, "Grant lifetime"),
         maxAttempts = integer(input.maxAttempts, 1, 20, "Maximum attempts"),
         retryBase = integer(input.retryBase, 1, 86400, "Retry delay"),
         sendInterval = integer(input.sendInterval, 1, 3600, "Send interval"),
         requireHttps = input.requireHttps == true
      }
      if nextSettings.smtpSecurity ~= "none" and
         nextSettings.smtpSecurity ~= "tls" and
         nextSettings.smtpSecurity ~= "starttls" then
         error("SMTP security must be none, tls, or starttls", 2)
      end
      if #nextSettings.smtpServer > 253 or #nextSettings.smtpUsername > 320 or
         #nextSettings.fromAddress > 320 or #nextSettings.replyTo > 320 or
         #nextSettings.publicBaseUrl > 2048 then
         error("An SMTP setting is too long", 2)
      end
      if nextSettings.enabled and (nextSettings.smtpServer == "" or
         nextSettings.fromAddress == "") then
         error("SMTP server and from address are required before enabling the mailer", 2)
      end
      if nextSettings.fromAddress ~= "" then
         nextSettings.fromAddress = mailboxAddress(nextSettings.fromAddress,
            "from address")
      end
      if nextSettings.replyTo ~= "" then
         nextSettings.replyTo = mailboxAddress(nextSettings.replyTo,
            "reply-to address")
      end
      if nextSettings.publicBaseUrl ~= "" then
         if not nextSettings.publicBaseUrl:match("^https?://[^/]+$") then
            error("Public base URL must be an absolute HTTP or HTTPS URL", 2)
         end
         nextSettings.publicBaseUrl = nextSettings.publicBaseUrl:gsub("/+$", "")
      end
      if nextSettings.requireHttps and nextSettings.publicBaseUrl ~= "" and
         not nextSettings.publicBaseUrl:match("^https://") then
         error("Public base URL must use HTTPS when secure downloads require HTTPS", 2)
      end

      local password = input.password
      if password ~= nil then
         password = tostring(password)
         if #password > 4096 then error("SMTP password is too long", 2) end
      end
      local encryptedPassword = password and password ~= "" and
         encryptSecret(password) or nil
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
UPDATE mailer_settings SET
 enabled=%d,smtp_server=%s,smtp_port=%d,smtp_security=%s,
 smtp_username=%s,from_address=%s,reply_to=%s,public_base_url=%s,attachment_limit=%d,
 grant_ttl=%d,max_attempts=%d,retry_base=%d,send_interval=%d,require_https=%d
WHERE singleton=1
]], nextSettings.enabled and 1 or 0, quote(nextSettings.smtpServer),
            nextSettings.smtpPort, quote(nextSettings.smtpSecurity),
            quote(nextSettings.smtpUsername), quote(nextSettings.fromAddress),
            quote(nextSettings.replyTo), quote(nextSettings.publicBaseUrl),
            nextSettings.attachmentLimit,
            nextSettings.grantTtl, nextSettings.maxAttempts,
            nextSettings.retryBase, nextSettings.sendInterval,
            nextSettings.requireHttps and 1 or 0))
         if input.clearPassword == true then
            execute(conn, "DELETE FROM mailer_smtp_secret WHERE singleton=1")
         elseif encryptedPassword then
            execute(conn, "INSERT OR REPLACE INTO mailer_smtp_secret" ..
               "(singleton,encrypted_password) VALUES(1," ..
               quote(encryptedPassword) .. ")")
         end
      end)
      settings = loadSettings(ctx)
      if settings.enabled and schedule then
         schedule(1)
      elseif not settings.enabled and timer then
         timer:cancel()
         timer = nil
      end
      return true
   end

   function service.encryptPassword(password)
      return encryptSecret(tostring(password or ""))
   end

   function service.decryptPassword(encoded)
      return decryptSecret(encoded)
   end

   function service.contacts(query, page, pageSize, listId, includeUnsubscribed,
      contactFilter)
      query = trim(query)
      page = integer(page or 1, 1, 1000000, "Page")
      pageSize = integer(pageSize or 50, 1, 200, "Page size")
      if listId ~= nil then
         listId = integer(listId, 1, 9007199254740991, "List ID")
      end
      local filters = {}
      if query ~= "" then
         local pattern = quote("%" .. query .. "%")
         filters[#filters + 1] = "(email LIKE " .. pattern ..
             " OR first_name LIKE " .. pattern ..
             " OR last_name LIKE " .. pattern ..
             " OR external_id LIKE " .. pattern .. ")"
      end
      if listId then
         filters[#filters + 1] = string.format([[EXISTS(
 SELECT 1 FROM mailer_list_members filter_members
 WHERE filter_members.contact_id=mailer_contacts.id AND filter_members.list_id=%d
)]], listId)
      end
      if includeUnsubscribed == false then
         filters[#filters + 1] = "mailer_contacts.unsubscribed_at IS NULL"
      end
      contactFilter = tostring(contactFilter or "all")
      if contactFilter == "unassigned" then
         filters[#filters + 1] = [[NOT EXISTS(
 SELECT 1 FROM mailer_list_members status_members
 WHERE status_members.contact_id=mailer_contacts.id
)]]
      elseif contactFilter == "unsubscribed" then
         filters[#filters + 1] = "mailer_contacts.unsubscribed_at IS NOT NULL"
      elseif contactFilter ~= "all" then
         error("Unknown contact filter", 2)
      end
      local where = #filters > 0 and " WHERE " .. table.concat(filters, " AND ") or ""
      local count = one(ctx, "SELECT COUNT(*) AS count FROM mailer_contacts" .. where)
      local values, byId, ids = {}, {}, {}
      for _, row in ipairs(rows(ctx, [[
SELECT mailer_contacts.id,external_id,email,first_name,last_name,
       mailer_contacts.unsubscribed_at,created_at,
       mailer_contacts.updated_at,credentials.confirmed_at,
       credentials.invitation_sent_at,credentials.invitation_expires_at
FROM mailer_contacts
LEFT JOIN mailer_contact_credentials credentials
  ON credentials.contact_id=mailer_contacts.id]] .. where ..
         " ORDER BY email LIMIT " .. pageSize ..
         " OFFSET " .. ((page - 1) * pageSize))) do
         local value = {
             id = tonumber(row.id), externalId = row.external_id,
             email = row.email, firstName = row.first_name,
              lastName = row.last_name,
              unsubscribed = row.unsubscribed_at ~= nil,
              unsubscribedAt = tonumber(row.unsubscribed_at),
             createdAt = tonumber(row.created_at), updatedAt = tonumber(row.updated_at),
             confirmed = row.confirmed_at ~= nil,
             confirmedAt = tonumber(row.confirmed_at),
             invitationSentAt = tonumber(row.invitation_sent_at),
             invitationExpiresAt = tonumber(row.invitation_expires_at),
             listIds = {}, listNames = {}
          }
         values[#values + 1] = value
         byId[value.id] = value
         ids[#ids + 1] = value.id
      end
      if #ids > 0 then
         for _, membership in ipairs(rows(ctx, string.format([[
SELECT m.contact_id,m.list_id,l.name
FROM mailer_list_members m JOIN mailer_lists l ON l.id=m.list_id
WHERE m.contact_id IN (%s) ORDER BY l.name
]], table.concat(ids, ",")))) do
            local contact = byId[tonumber(membership.contact_id)]
            contact.listIds[#contact.listIds + 1] = tonumber(membership.list_id)
            contact.listNames[#contact.listNames + 1] = membership.name
         end
      end
      return { items = values, page = page, pageSize = pageSize,
         total = tonumber(count.count) }
   end

   function service.previewContactsCsv(source)
      local records = parseCsv(source)
      local headers, mapping, firstRow, hasHeader = csvLayout(records)
      local preview, previewErrors = {}, {}
      for index = firstRow, math.min(#records, firstRow + 9) do
         preview[#preview + 1] = records[index]
         if mapping.email then
            local ok, err = pcall(emailAddress, records[index][mapping.email])
            if not ok then previewErrors[#previewErrors + 1] = {
               row = index, error = tostring(err)
            } end
         end
      end
      return {
         headers = headers,
         mapping = mapping,
         rows = preview,
         errors = previewErrors,
         totalRows = #records - firstRow + 1,
         hasHeader = hasHeader
      }
   end

   function service.importContactsCsv(source, requestedMapping, destinationListId,
      restoreUnsubscribed, hasHeader)
      destinationListId = integer(destinationListId, 1, 9007199254740991,
         "Destination list")
      if not one(ctx, "SELECT id FROM mailer_lists WHERE id=" .. destinationListId) then
         error("Destination list not found", 2)
      end
      local records = parseCsv(source)
      local headers, _, firstRow = csvLayout(records, hasHeader)
      local mapping = csvMapping(headers, requestedMapping, true)
      local candidates, sourceSeen, errors = {}, {}, {}
      for rowNumber = firstRow, #records do
         local row = records[rowNumber]
         local ok, email = pcall(emailAddress, row[mapping.email])
         if not ok then
            errors[#errors + 1] = { row = rowNumber, error = tostring(email) }
         else
            local key = email:lower()
            if sourceSeen[key] then
               errors[#errors + 1] = { row = rowNumber, error = "Duplicate email in CSV" }
            else
               sourceSeen[key] = true
               local candidate = {
                  row = rowNumber,
                  email = email,
                  firstName = trim(row[mapping.firstName]),
                  lastName = trim(row[mapping.lastName]),
                  externalId = trim(row[mapping.externalId])
               }
               if #candidate.externalId > 200 or #candidate.firstName > 160 or
                  #candidate.lastName > 160 then
                  errors[#errors + 1] = { row = rowNumber,
                     error = "A contact field is too long" }
               else
                  candidates[#candidates + 1] = candidate
               end
            end
         end
      end
      local imported, membersAdded, restored, duplicates, suppressed, now =
         0, 0, 0, {}, {}, os.time()
      for startIndex = 1, #candidates, 100 do
         ctx.db.writeSync(function(conn)
            for index = startIndex, math.min(startIndex + 99, #candidates) do
               local contact = candidates[index]
               execute(conn, string.format([[
INSERT OR IGNORE INTO mailer_contacts(
 external_id,email,first_name,last_name,created_at,updated_at
) VALUES(%s,%s,%s,%s,%d,%d)
]], contact.externalId ~= "" and quote(contact.externalId) or "NULL",
                  quote(contact.email), quote(contact.firstName), quote(contact.lastName),
                  now, now))
               if tonumber(sqlRow(conn, "SELECT changes() AS count").count) == 1 then
                  imported = imported + 1
               else
                  duplicates[#duplicates + 1] = {
                     row = contact.row, email = contact.email
                  }
               end
               local saved = sqlRow(conn,
                  "SELECT id,unsubscribed_at FROM mailer_contacts WHERE email=" ..
                  quote(contact.email))
                if saved.unsubscribed_at and restoreUnsubscribed == true then
                   execute(conn, "UPDATE mailer_contacts SET unsubscribed_at=NULL," ..
                      "updated_at=" .. now .. " WHERE id=" .. tonumber(saved.id))
                   execute(conn, "DELETE FROM mailer_unsubscribe_tokens WHERE contact_id=" ..
                      tonumber(saved.id))
                   restored = restored + 1
                   execute(conn, string.format(
                      "INSERT OR IGNORE INTO mailer_list_members(list_id,contact_id) " ..
                      "VALUES(%d,%d)", destinationListId, tonumber(saved.id)))
                   membersAdded = membersAdded +
                      tonumber(sqlRow(conn, "SELECT changes() AS count").count)
                elseif saved.unsubscribed_at then
                   suppressed[#suppressed + 1] = {
                      row = contact.row, email = contact.email
                  }
               else
                  execute(conn, string.format(
                     "INSERT OR IGNORE INTO mailer_list_members(list_id,contact_id) " ..
                     "VALUES(%d,%d)", destinationListId, tonumber(saved.id)))
                  membersAdded = membersAdded +
                     tonumber(sqlRow(conn, "SELECT changes() AS count").count)
               end
            end
         end)
      end
      return { imported = imported, membersAdded = membersAdded, restored = restored,
         listId = destinationListId, duplicates = duplicates,
         suppressed = suppressed, errors = errors,
         totalRows = #records - firstRow + 1 }
   end

   function service.saveContact(input)
      input = input or {}
      local id = input.id and integer(input.id, 1, 9007199254740991, "Contact ID")
      local email = emailAddress(input.email)
      local externalId = trim(input.externalId)
      local firstName, lastName = trim(input.firstName), trim(input.lastName)
      if #externalId > 200 or #firstName > 160 or #lastName > 160 then
         error("A contact field is too long", 2)
      end
      local listIds
      if input.listIds ~= nil then
         listIds = {}
         local seen = {}
         for _, value in ipairs(input.listIds) do
            local listId = integer(value, 1, 9007199254740991, "List ID")
            if not seen[listId] then
               seen[listId] = true
               listIds[#listIds + 1] = listId
            end
         end
      end
      local now, resultId = os.time()
      ctx.db.writeSync(function(conn)
         if id then
            execute(conn, string.format([[
UPDATE mailer_contacts SET external_id=%s,email=%s,first_name=%s,last_name=%s,
 updated_at=%d WHERE id=%d
]], externalId ~= "" and quote(externalId) or "NULL", quote(email),
               quote(firstName), quote(lastName), now, id))
            resultId = id
         else
            execute(conn, string.format([[
INSERT INTO mailer_contacts(
 external_id,email,first_name,last_name,created_at,updated_at
) VALUES(%s,%s,%s,%s,%d,%d)
]], externalId ~= "" and quote(externalId) or "NULL", quote(email),
               quote(firstName), quote(lastName), now, now))
            resultId = insertId(conn)
         end
         if listIds then
            execute(conn, "DELETE FROM mailer_list_members WHERE contact_id=" .. resultId)
            local saved = sqlRow(conn,
               "SELECT unsubscribed_at FROM mailer_contacts WHERE id=" .. resultId)
            if not saved.unsubscribed_at then
               for _, listId in ipairs(listIds) do
                  execute(conn, string.format(
                     "INSERT INTO mailer_list_members(list_id,contact_id) VALUES(%d,%d)",
                     listId, resultId))
               end
            end
         end
      end)
      return resultId
   end

   function service.resubscribeContact(id)
      id = integer(id, 1, 9007199254740991, "Contact ID")
      ctx.db.writeSync(function(conn)
         execute(conn, "UPDATE mailer_contacts SET unsubscribed_at=NULL,updated_at=" ..
            os.time() .. " WHERE id=" .. id)
         execute(conn, "DELETE FROM mailer_unsubscribe_tokens WHERE contact_id=" .. id)
      end)
      return true
   end

   function service.resubscribeContacts(contactIds)
      local selected, seen = {}, {}
      for _, value in ipairs(contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not seen[contactId] then
            seen[contactId] = true
            selected[#selected + 1] = contactId
         end
      end
      if #selected == 0 then error("Select at least one contact", 2) end
      local restored = 0
      ctx.db.writeSync(function(conn)
         local ids = table.concat(selected, ",")
         execute(conn, "UPDATE mailer_contacts SET unsubscribed_at=NULL,updated_at=" ..
            os.time() .. " WHERE unsubscribed_at IS NOT NULL AND id IN (" .. ids .. ")")
         restored = tonumber(sqlRow(conn, "SELECT changes() AS count").count)
         execute(conn, "DELETE FROM mailer_unsubscribe_tokens WHERE contact_id IN (" ..
            ids .. ")")
      end)
      return { restored = restored }
   end

   function service.deleteContact(id)
      id = integer(id, 1, 9007199254740991, "Contact ID")
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_contacts WHERE id=" .. id)
      end)
      return true
   end

   function service.resetContactPassword(id)
      id = integer(id, 1, 9007199254740991, "Contact ID")
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
INSERT INTO mailer_contact_credentials(contact_id,updated_at)
VALUES(%d,%d)
ON CONFLICT(contact_id) DO UPDATE SET
 password_salt=NULL,password_hash=NULL,password_iterations=NULL,confirmed_at=NULL,
 invitation_token_hash=NULL,invitation_expires_at=NULL,updated_at=excluded.updated_at
]], id, os.time()))
      end)
      return true
   end

   function service.deleteContacts(contactIds)
      local selected, seen = {}, {}
      for _, value in ipairs(contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not seen[contactId] then
            seen[contactId] = true
            selected[#selected + 1] = contactId
         end
      end
      if #selected == 0 then error("Select at least one contact", 2) end
      local removed = 0
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_contacts WHERE id IN (" ..
            table.concat(selected, ",") .. ")")
         removed = tonumber(sqlRow(conn, "SELECT changes() AS count").count)
      end)
      return { removed = removed }
   end

   local function contactRemovalMatches(source)
      local emails = extractEmailAddresses(source)
      local found = {}
      for startIndex = 1, #emails, 200 do
         local quoted = {}
         for index = startIndex, math.min(startIndex + 199, #emails) do
            quoted[#quoted + 1] = quote(emails[index])
         end
         for _, row in ipairs(rows(ctx, [[
SELECT id,email,first_name,last_name FROM mailer_contacts
WHERE email IN (]] .. table.concat(quoted, ",") .. ")")) do
            found[row.email:lower()] = {
               id = tonumber(row.id), email = row.email,
               firstName = row.first_name, lastName = row.last_name
            }
         end
      end
      local matches, notFound = {}, {}
      for _, email in ipairs(emails) do
         local contact = found[email:lower()]
         if contact then matches[#matches + 1] = contact
         else notFound[#notFound + 1] = email end
      end
      return emails, matches, notFound
   end

   function service.previewContactRemoval(source)
      local emails, matches, notFound = contactRemovalMatches(source)
      local shownMatches, shownMissing = {}, {}
      for index = 1, math.min(#matches, 200) do shownMatches[index] = matches[index] end
      for index = 1, math.min(#notFound, 100) do shownMissing[index] = notFound[index] end
      return {
         extractedCount = #emails,
         matchCount = #matches,
         notFoundCount = #notFound,
         matches = shownMatches,
         notFound = shownMissing,
         matchesTruncated = #matches > #shownMatches,
         notFoundTruncated = #notFound > #shownMissing
      }
   end

   function service.removeContactsFromText(source)
      local emails, matches, notFound = contactRemovalMatches(source)
      local removed = 0
      if #matches > 0 then
         ctx.db.writeSync(function(conn)
            for startIndex = 1, #matches, 200 do
               local ids = {}
               for index = startIndex, math.min(startIndex + 199, #matches) do
                  ids[#ids + 1] = matches[index].id
               end
               execute(conn, "DELETE FROM mailer_contacts WHERE id IN (" ..
                  table.concat(ids, ",") .. ")")
               removed = removed +
                  tonumber(sqlRow(conn, "SELECT changes() AS count").count)
            end
         end)
      end
      return {
         extractedCount = #emails,
         matchedCount = #matches,
         removed = removed,
         notFoundCount = #notFound
      }
   end

   function service.deleteAllContacts()
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_contacts")
      end)
      return true
   end

   function service.lists(includeMemberIds)
      local values, membersByList = {}, {}
      if includeMemberIds ~= false then
         for _, member in ipairs(rows(ctx, [[
SELECT m.list_id,m.contact_id
FROM mailer_list_members m
JOIN mailer_lists l ON l.id=m.list_id
JOIN mailer_contacts c ON c.id=m.contact_id
ORDER BY m.list_id,m.contact_id
]])) do
            local listId = tonumber(member.list_id)
            local memberIds = membersByList[listId] or {}
            memberIds[#memberIds + 1] = tonumber(member.contact_id)
            membersByList[listId] = memberIds
         end
      end
      for _, row in ipairs(rows(ctx, [[
SELECT l.id,l.name,l.description,l.created_at,l.updated_at,COUNT(c.id) AS members
FROM mailer_lists l
LEFT JOIN mailer_list_members m ON m.list_id=l.id
LEFT JOIN mailer_contacts c ON c.id=m.contact_id
GROUP BY l.id ORDER BY l.name
]])) do
         local listId = tonumber(row.id)
         values[#values + 1] = {
            id = listId, name = row.name, description = row.description,
            members = tonumber(row.members), createdAt = tonumber(row.created_at),
            updatedAt = tonumber(row.updated_at)
          }
         if includeMemberIds ~= false then
            values[#values].memberIds = membersByList[listId] or {}
         end
      end
      return values
   end

   function service.list(id)
      id = integer(id, 1, 9007199254740991, "List ID")
      local row = one(ctx, [[
SELECT l.id,l.name,l.description,l.created_at,l.updated_at,COUNT(c.id) AS members
FROM mailer_lists l
LEFT JOIN mailer_list_members m ON m.list_id=l.id
LEFT JOIN mailer_contacts c ON c.id=m.contact_id
WHERE l.id=]] .. id .. " GROUP BY l.id")
      if not row then return nil end
      return { id = tonumber(row.id), name = row.name, description = row.description,
         members = tonumber(row.members), createdAt = tonumber(row.created_at),
         updatedAt = tonumber(row.updated_at) }
   end

   function service.saveList(input)
      input = input or {}
      local id = input.id and integer(input.id, 1, 9007199254740991, "List ID")
      local name, description = trim(input.name), trim(input.description)
      if name == "" or #name > 160 then error("A valid list name is required", 2) end
      if #description > 1000 then error("List description is too long", 2) end
      local memberIds
      if input.contactIds ~= nil then
         memberIds = {}
         local seen = {}
         for _, value in ipairs(input.contactIds) do
            local contactId = integer(value, 1, 9007199254740991, "Contact ID")
            if not seen[contactId] then
               seen[contactId] = true
               memberIds[#memberIds + 1] = contactId
            end
         end
      end
      local now, resultId = os.time()
      ctx.db.writeSync(function(conn)
         if id then
            execute(conn, string.format(
               "UPDATE mailer_lists SET name=%s,description=%s,updated_at=%d WHERE id=%d",
               quote(name), quote(description), now, id))
            resultId = id
         else
            execute(conn, string.format([[
INSERT INTO mailer_lists(name,description,created_at,updated_at)
VALUES(%s,%s,%d,%d)
]], quote(name), quote(description), now, now))
            resultId = insertId(conn)
         end
         if memberIds then
            execute(conn, "DELETE FROM mailer_list_members WHERE list_id=" .. resultId)
            for _, contactId in ipairs(memberIds) do
               execute(conn, string.format(
                  "INSERT INTO mailer_list_members(list_id,contact_id) VALUES(%d,%d)",
                  resultId, contactId))
            end
         end
      end)
      return resultId
   end

   function service.transferListMembers(sourceListId, destinationListId,
                                         contactIds, deleteSource)
      sourceListId = integer(sourceListId, 1, 9007199254740991, "Source list")
      destinationListId = integer(destinationListId, 1, 9007199254740991,
         "Destination list")
      if sourceListId == destinationListId then
         error("Select a different destination list", 2)
      end
      if not service.list(sourceListId) then error("Source list not found", 2) end
      if not service.list(destinationListId) then error("Destination list not found", 2) end
      local selected
      if contactIds ~= nil then
         selected = {}
         local seen = {}
         for _, value in ipairs(contactIds) do
            local contactId = integer(value, 1, 9007199254740991, "Contact ID")
            if not seen[contactId] then
               seen[contactId] = true
               selected[#selected + 1] = contactId
            end
         end
         if #selected == 0 then error("Select at least one contact", 2) end
         if deleteSource then error("A partial transfer cannot delete the source list", 2) end
      end
      local filter = selected and
         " AND contact_id IN (" .. table.concat(selected, ",") .. ")" or ""
      local moved, added = 0, 0
      ctx.db.writeSync(function(conn)
         moved = tonumber(sqlRow(conn, string.format(
            "SELECT COUNT(*) AS count FROM mailer_list_members WHERE list_id=%d%s",
            sourceListId, filter)).count)
         execute(conn, string.format([[
INSERT OR IGNORE INTO mailer_list_members(list_id,contact_id)
SELECT %d,contact_id FROM mailer_list_members WHERE list_id=%d%s
]], destinationListId, sourceListId, filter))
         added = tonumber(sqlRow(conn, "SELECT changes() AS count").count)
         execute(conn, string.format(
            "DELETE FROM mailer_list_members WHERE list_id=%d%s", sourceListId, filter))
         if deleteSource then
            execute(conn, "DELETE FROM mailer_lists WHERE id=" .. sourceListId)
         end
      end)
      return { moved = moved, added = added, sourceListId = sourceListId,
         destinationListId = destinationListId, sourceDeleted = deleteSource == true }
   end

   function service.addListMembers(listId, contactIds)
      listId = integer(listId, 1, 9007199254740991, "List ID")
      if not service.list(listId) then error("Destination list not found", 2) end
      local selected, seen = {}, {}
      for _, value in ipairs(contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not seen[contactId] then
            seen[contactId] = true
            selected[#selected + 1] = contactId
         end
      end
      if #selected == 0 then error("Select at least one contact", 2) end
      local added = 0
      ctx.db.writeSync(function(conn)
         for _, contactId in ipairs(selected) do
            execute(conn, string.format(
               "INSERT OR IGNORE INTO mailer_list_members(list_id,contact_id) " ..
               "SELECT %d,id FROM mailer_contacts WHERE id=%d", listId, contactId))
            added = added + tonumber(sqlRow(conn, "SELECT changes() AS count").count)
         end
      end)
      return { added = added, listId = listId }
   end

   function service.removeListMembers(listId, contactIds)
      listId = integer(listId, 1, 9007199254740991, "List ID")
      local selected, seen = {}, {}
      for _, value in ipairs(contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not seen[contactId] then
            seen[contactId] = true
            selected[#selected + 1] = contactId
         end
      end
      if #selected == 0 then error("Select at least one contact", 2) end
      local removed = 0
      ctx.db.writeSync(function(conn)
         execute(conn, string.format(
            "DELETE FROM mailer_list_members WHERE list_id=%d AND contact_id IN (%s)",
            listId, table.concat(selected, ",")))
         removed = tonumber(sqlRow(conn, "SELECT changes() AS count").count)
      end)
      return { removed = removed, listId = listId }
   end

   function service.deleteList(id)
      id = integer(id, 1, 9007199254740991, "List ID")
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_lists WHERE id=" .. id)
      end)
      return true
   end

   function service.deleteAllLists()
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_lists")
      end)
      return true
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

   function service.resolveRecipients(contactIds, listIds)
      local selected = {}
      for _, value in ipairs(contactIds or {}) do
         selected[integer(value, 1, 9007199254740991, "Contact ID")] = true
      end
      local normalizedListIds = {}
      for _, value in ipairs(listIds or {}) do
         normalizedListIds[#normalizedListIds + 1] =
            integer(value, 1, 9007199254740991, "List ID")
      end
      if #normalizedListIds > 0 then
         for _, row in ipairs(rows(ctx,
            "SELECT contact_id FROM mailer_list_members WHERE list_id IN (" ..
            table.concat(normalizedListIds, ",") .. ")")) do
            selected[tonumber(row.contact_id)] = true
         end
      end
      local result = {}
      local selectedIds = {}
      for contactId in pairs(selected) do selectedIds[#selectedIds + 1] = contactId end
      table.sort(selectedIds)
      if #selectedIds > 0 then
         for _, row in ipairs(rows(ctx,
            "SELECT * FROM mailer_contacts WHERE id IN (" ..
            table.concat(selectedIds, ",") .. ")")) do
            result[#result + 1] = {
               contactId = tonumber(row.id), email = row.email,
               firstName = row.first_name, lastName = row.last_name
            }
         end
      end
      table.sort(result, function(a, b) return a.email:lower() < b.email:lower() end)
      return result
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
      if not hasMailerRole(identity, sender) then
         error("Sender does not have a mailer role", 2)
      end
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
      local macroSource = subject .. "\n" .. textBody .. "\n" .. htmlBody ..
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
      if not hasMailerRole(identity, sender) then
         error("Sender does not have a mailer role", 2)
      end
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
         recipients = {}, files = {}
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
         local password, passwordErr = decryptSecret(settings.encryptedPassword)
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

   local function logDownload(grantId, eventType, detail)
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
INSERT INTO mailer_download_events(grant_id,event_type,detail,created_at)
VALUES(%d,%s,%s,%d)
]], tonumber(grantId), quote(eventType), quote(detail or ""), os.time()))
      end)
   end

   function service.download(env, token)
      if not tostring(token or ""):match("^[A-Za-z0-9_%-]+$") then return false end
      local tokenHash = ba.crypto.hash"sha256"(token)(true, "hex")
      local grant = one(ctx, string.format([[
SELECT g.*,f.relative_path,f.download_name,f.byte_length,f.sha256,
       j.sender,j.status AS job_status,j.require_contact_password,r.contact_id
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
      if tonumber(grant.require_contact_password) == 1 then
         local current = grant.contact_id and one(ctx, [[
SELECT password_salt,password_hash,password_iterations,confirmed_at
FROM mailer_contact_credentials WHERE contact_id=]] ..
            tonumber(grant.contact_id)) or nil
         if not current or not current.confirmed_at or not current.password_hash then
            env.response:senderror(403, "The recipient password is unavailable")
            return true
         end
         grant.password_salt = current.password_salt
         grant.password_hash = current.password_hash
         grant.password_iterations = current.password_iterations
      end

      local session = env.request:session(true)
      local grantKey = "mailerGrant" .. grant.id
      local passwordError = false
      if grant.password_hash and
         not secureEqual(session[grantKey], grant.password_hash) then
         if tonumber(grant.failed_attempts) >= 5 then
            env.response:senderror(429, "Too many failed attempts")
            return true
         end
         if env.request:method() == "POST" then
            local data = env.request:data() or {}
            if not session.mailerDownloadCsrf or
               not secureEqual(data.csrf, session.mailerDownloadCsrf) then
               env.response:senderror(403, "Forbidden")
               return true
            end
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
                logDownload(grant.id, "password-failed", "")
                passwordError = true
               if tonumber(grant.failed_attempts) + 1 >= 5 then
                  env.response:senderror(429, "Too many failed attempts")
                  return true
               end
            end
         end
         if not secureEqual(session[grantKey], grant.password_hash) then
            session.mailerDownloadCsrf = ba.b64urlencode(ba.rndbs(24))
            env.response:setcontenttype("text/html; charset=utf-8")
            env.response:setheader("cache-control", "no-store")
            env.response:write("<!doctype html><html><head><meta charset='utf-8'>",
               "<meta name='viewport' content='width=device-width,initial-scale=1'>",
               "<title>Protected download</title><link rel='stylesheet' href='",
               pluginApp.url("/mailer/public.css"),
               "'></head><body class='public-page'><main class='public-panel'>",
               "<p class='eyebrow'>Secure file delivery</p>",
               "<h1>Protected download</h1>",
               "<div class='file-summary'><strong>", htmlEscape(grant.download_name),
               "</strong><span>Enter your personal password to download this file.</span></div>")
            if passwordError then
               env.response:write("<p class='error' role='alert'>The password is incorrect. Try again.</p>")
            end
            env.response:write("<form method='post'>",
               "<input type='hidden' name='csrf' value='", session.mailerDownloadCsrf,
               "'><label for='download-password'>Password</label>",
               "<input id='download-password' type='password' name='password' required ",
               "autocomplete='current-password' autofocus>",
               "<button type='submit'>Download file</button></form></main></body></html>")
            return true
         end
      end

      local current, currentErr = digestFile(files, grant.sender, grant.relative_path)
      if not current or current.size ~= tonumber(grant.byte_length) or
         current.sha256 ~= grant.sha256 then
         logDownload(grant.id, "file-invalid", tostring(currentErr or "changed"))
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
      if env.request:method() ~= "HEAD" then
         while true do
            local chunk = file:read(16384)
            if not chunk or #chunk == 0 then break end
            env.response:write(chunk)
         end
      end
      file:close()
      logDownload(grant.id, "downloaded", "")
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
