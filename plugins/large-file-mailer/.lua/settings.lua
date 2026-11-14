local util = pluginreq "util"
local trim = util.trim
local quote = util.quote
local execute = util.execute
local integer = util.integer
local rows = util.rows
local mailboxAddress = util.mailboxAddress

local KEY_NAME = "FuguHub-Large-File-Mailer-SMTP"

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

local function publicSettings(settings)
   return {
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
   }
end

local function saveSettings(ctx, input)
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
      nextSettings.publicBaseUrl = nextSettings.publicBaseUrl:gsub("/+$", "")
      if not nextSettings.publicBaseUrl:match("^https?://[^/%s?#@]+$") then
         error("Public base URL must be an HTTP or HTTPS origin, such as https://example.com, without a path", 2)
      end
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
   return loadSettings(ctx)
end

return {
   load = loadSettings,
   public = publicSettings,
   save = saveSettings,
   encrypt = encryptSecret,
   decrypt = decryptSecret
}
