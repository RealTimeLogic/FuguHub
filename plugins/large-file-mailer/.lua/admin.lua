local M = {}

local function serveFile(env, ctx, path, contentType)
   local file, err = ctx.io:open(path, "rb")
   if not file then
      env.response:senderror(404, tostring(err or "Not found"))
      return true
   end
   local body = file:read("*a")
   file:close()
   env.response:setcontenttype(contentType)
   env.response:setheader("cache-control", "no-cache")
   env.response:setheader("x-content-type-options", "nosniff")
   env.response:write(body)
   return true
end

local function responseState(mailer)
   local result = mailer.state()
   result.ok = true
   return result
end

local function api(env, ctx, mailer)
   env.response:setheader("cache-control", "no-store")
   env.response:setheader("x-content-type-options", "nosniff")
   if env.request:method() == "GET" then
      env.response:json(responseState(mailer))
      return true
   end
   local data = ctx.admin:postData(env)
   local testedRecipient
   local ok, err = pcall(function()
      if data.action ~= "save-settings" and data.action ~= "save-and-test" then
         error("Unknown mailer action", 2)
      end
      mailer.saveSettings {
         enabled = data.enabled == "1",
         smtpServer = data.smtp_server,
         smtpPort = data.smtp_port,
         smtpSecurity = data.smtp_security,
         smtpUsername = data.smtp_username,
         fromAddress = data.from_address,
         replyTo = data.reply_to,
         publicBaseUrl = data.public_base_url,
         attachmentLimit = data.attachment_limit,
         grantTtl = data.grant_ttl,
         maxAttempts = data.max_attempts,
         retryBase = data.retry_base,
         sendInterval = data.send_interval,
         requireHttps = data.require_https == "1",
         password = data.password ~= "" and data.password or nil,
         clearPassword = data.clear_password == "1"
      }
      if data.action == "save-and-test" then
         testedRecipient = mailer.sendTest(data.test_recipient)
      end
   end)
   if not ok then
      env.response:setstatus(400)
      env.response:json({ ok = false, error = tostring(err) })
      return true
   end
   local result = responseState(mailer)
   if testedRecipient then result.testRecipient = testedRecipient end
   env.response:json(result)
   return true
end

local function tabs(env, pluginApp)
   env.response:write([[<nav class="mailer-admin-tabs" aria-label="Mailer sections">
<a class="active" aria-current="page" href="">Settings</a>]],
      "<a href='", pluginApp.url("/mailer/compose/"), "'>Compose</a>",
      "<a href='", pluginApp.url("/mailer/contacts/"), "'>Contacts</a>",
      "<a href='", pluginApp.url("/mailer/lists/"), "'>Lists</a>",
      "<a href='", pluginApp.url("/mailer/invitations/"), "'>Invitations</a>",
      "<a href='", pluginApp.url("/mailer/remove/"), "'>Remove</a>",
      "<a href='", pluginApp.url("/mailer/templates/"), "'>Templates</a>",
      "<a href='", pluginApp.url("/mailer/jobs/"), "'>Jobs</a></nav>")
end

function M.install(ctx, mailer, pluginApp)
   ctx.admin:addPage {
      id = "mailer",
      label = "Mailer",
      path = "",
      order = 670,
      handler = function(env)
         return ctx.admin:layout(env, "Large File Mailer", function()
            env.response:write(
               "<link rel='stylesheet' href='admin.css'>")
            tabs(env, pluginApp)
            env.response:write(
               "<section class='panel mailer-shell'><div class='panel-body'>")
            ctx.admin:csrfField(env)
            env.response:write(
               "<div id='mailer-app' aria-live='polite'>Loading mailer settings...</div>",
               "</div></section><script src='admin.js' defer></script>")
         end)
      end
   }
   ctx.admin:addRoute("admin.js", function(env)
      return serveFile(env, ctx, "public/admin.js",
         "text/javascript; charset=utf-8")
   end)
   ctx.admin:addRoute("admin.css", function(env)
      return serveFile(env, ctx, "public/admin.css",
         "text/css; charset=utf-8")
   end)
   ctx.admin:addRoute("api/", function(env)
      return api(env, ctx, mailer)
   end)
end

return M
