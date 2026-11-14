local M = {}
local publicError = app.appreq "publicerror"

local function serveFile(env, ctx, path, contentType)
   local file, err = ctx.io:open(path, "rb")
   if not file then env.response:senderror(404, tostring(err or "Not found")) return true end
   local body = file:read("*a")
   file:close()
   env.response:setcontenttype(contentType)
   env.response:setheader("cache-control", "no-cache")
   env.response:setheader("x-content-type-options", "nosniff")
   env.response:write(body)
   return true
end

local function html(value)
   return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):
      gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;")
end

local function loginResponse(pluginApp, env, authinfo)
   authinfo = authinfo or {}
   env.response:setcontenttype("text/html; charset=utf-8")
   env.response:setheader("cache-control", "no-store")
   env.response:write("<!doctype html><html lang='en'><head><meta charset='utf-8'>",
      "<meta name='viewport' content='width=device-width,initial-scale=1'>",
      "<title>Mailer Login</title><link rel='stylesheet' href='",
      pluginApp.url("/mailer/app.css"), "'><script src='/rtl/jquery.js'></script>",
      "<script src='/rtl/sha1.js'></script></head><body><main class='mailer-login'>",
      "<section><h1>Large File Mailer</h1>")
   if authinfo.username then
      env.response:write("<p class='error' id='mailer-login-error' role='alert'>Login failed for ", html(authinfo.username), ".</p>")
   end
   env.response:write("<form method='post'><label>Username<input name='ba_username' autocomplete='username' value='",
      html(authinfo.username), "' required autofocus", authinfo.username and " aria-describedby='mailer-login-error'" or "", "></label>",
      "<label>Password<input name='ba_password' type='password' autocomplete='current-password' required></label>",
      "<input type='hidden' name='ba_seed' value='", html(authinfo.seed), "'>",
      "<input type='hidden' name='ba_seedkey' value='", html(authinfo.seedkey), "'>",
      "<button type='submit' id='ba_loginbut'>Login</button></form></section></main></body></html>")
   return true
end

local function hasRole(identity, env, role)
   if #identity.users() == 0 then return true end
   return identity.hasRole(env, role) or identity.hasRole(env, "cms-admin")
end

local function decodeArray(value, label)
   if value == nil or value == "" then return {} end
   local ok, decoded = pcall(ba.json.decode, value)
   if not ok or type(decoded) ~= "table" then error("Invalid " .. label, 3) end
   return decoded
end

local function decodeObject(value, label)
   if value == nil or value == "" then return {} end
   local ok, decoded = pcall(ba.json.decode, value)
   if not ok or type(decoded) ~= "table" then error("Invalid " .. label, 3) end
   return decoded
end

local function requestData(env)
   local contentType = env.request:header("Content-Type") or ""
   if not contentType:find("multipart/form-data", 1, true) then
      return env.request:data() or {}
   end
   local maximum = 3 * 1024 * 1024
   local contentLength = tonumber(env.request:header("Content-Length"))
   if contentLength and contentLength > maximum then error("Request exceeds 3 MiB", 2) end
   local data, parseErr = {}, nil
   env.request:multipart({
      formdata = function(name, value)
         data[name] = value
      end,
      beginfile = function()
         parseErr = "File uploads require a dedicated upload endpoint"
      end,
      filedata = function()
      end,
      error = function(message)
         if message ~= nil then parseErr = message end
      end
   }, contentLength or maximum)
   if parseErr then error("Multipart form parse failed: " .. tostring(parseErr), 2) end
   return data
end

local function rawInput(env, label)
   local maximum = 2 * 1024 * 1024
   local contentLength = tonumber(env.request:header("Content-Length"))
   if contentLength and contentLength > maximum then
      return nil, label .. " exceeds 2 MiB", 413
   end
   local chunks, size, tooLarge = {}, 0, false
   local ok, err = pcall(function()
      for chunk in env.request:rawrdr(8192) do
         size = size + #chunk
         if size > maximum then
            tooLarge = true
         elseif not tooLarge then
            chunks[#chunks + 1] = chunk
         end
      end
   end)
   if not ok then return nil, "Reading " .. label:lower() .. " failed: " ..
      publicError(err), 400 end
   if tooLarge then return nil, label .. " exceeds 2 MiB", 413 end
   if size == 0 then return nil, label .. " is empty", 400 end
   return table.concat(chunks)
end

local function rawCsv(env)
   return rawInput(env, "CSV input")
end

local function tab(env, pluginApp, view, current, label)
   env.response:write("<a", view == current and
      " class='active' aria-current='page'" or "", " href='",
      pluginApp.url("/mailer/" .. view .. "/"), "'>", label, "</a>")
end

local function shell(env, pluginApp, identity, view)
   local session = env.request:session(true)
   session.mailerCsrf = session.mailerCsrf or ba.b64urlencode(ba.rndbs(24))
   local manager = hasRole(identity, env, "mailer-manager")
   local cmsAdmin = hasRole(identity, env, "cms-admin")
   env.response:setcontenttype("text/html; charset=utf-8")
   env.response:setheader("cache-control", "no-store")
   env.response:write("<!doctype html><html lang='en'><head><meta charset='utf-8'>",
      "<meta name='viewport' content='width=device-width,initial-scale=1'>",
      "<title>Large File Mailer</title><link rel='stylesheet' href='",
      pluginApp.url("/mailer/app.css?v=20261114"), "'></head><body><div class='mailer-app' data-view='",
      view, "' data-csrf='", session.mailerCsrf, "' data-settings-url='",
      cmsAdmin and pluginApp.url("/admin/plugins/large-file-mailer/") or "",
      "'><a class='skip-link' href='#mailer-client'>Skip to main content</a><header><strong>Large File Mailer</strong>",
      "<nav class='mailer-tabs'>")
   if cmsAdmin then
      env.response:write("<a href='",
         pluginApp.url("/admin/plugins/large-file-mailer/"), "'>Settings</a>")
   end
   tab(env, pluginApp, "compose", view, "Compose")
   if manager then
      tab(env, pluginApp, "contacts", view, "Contacts")
      tab(env, pluginApp, "lists", view, "Lists")
      tab(env, pluginApp, "invitations", view, "Invitations")
      tab(env, pluginApp, "remove", view, "Remove")
      tab(env, pluginApp, "templates", view, "Templates")
      tab(env, pluginApp, "jobs", view, "Jobs")
   end
   env.response:write("</nav></header><main id='mailer-client' tabindex='-1'>Loading...</main></div>",
      "<script src='", pluginApp.url("/mailer/app.js?v=20261114"), "' defer></script></body></html>")
   return true
end

local function removalApi(env, mailer, identity, action)
   env.response:setheader("cache-control", "no-store")
   env.response:setheader("x-content-type-options", "nosniff")
   if env.request:method() ~= "POST" then
      env.response:setstatus(405)
      env.response:json { ok = false, error = "Contact removal endpoints require POST" }
      return true
   end
   if not hasRole(identity, env, "mailer-manager") then
      env.response:setstatus(403)
      env.response:json { ok = false, error = "Mailer manager role is required" }
      return true
   end
   local session = env.request:session()
   if not session or not session.mailerCsrf or
      env.request:header("X-FuguHub-CSRF") ~= session.mailerCsrf then
      env.response:setstatus(403)
      env.response:json { ok = false, error = "Invalid CSRF token" }
      return true
   end
   local source, readErr, status = rawInput(env, "Email input")
   if not source then
      env.response:setstatus(status)
      env.response:json { ok = false, error = readErr }
      return true
   end
   local ok, result = pcall(function()
      if action == "preview" then
         return { removalPreview = mailer.previewContactRemoval(source) }
      end
      return { removalResult = mailer.removeContactsFromText(source) }
   end)
   if not ok then
      env.response:setstatus(400)
      env.response:json { ok = false, error = publicError(result) }
      return true
   end
   result.ok = true
   result.manager = true
   env.response:json(result)
   return true
end

local function apiState(mailer, identity, env, query, page, scope, listId,
   contactFilter, jobId)
   local manager = hasRole(identity, env, "mailer-manager")
   local result = {
      ok = true,
      user = identity.currentUser(env),
      manager = manager
   }
   if scope == "contacts" then
      result.contacts = mailer.contacts(query or "", page or 1, 50, nil, nil,
         contactFilter)
      result.lists = mailer.lists(false)
   elseif scope == "recipient-search" then
      result.contacts = mailer.contacts(query or "", page or 1, 50, nil, false)
      result.lists = mailer.lists(false)
    elseif scope == "lists" then
       result.lists = mailer.lists(false)
       if listId and listId ~= "" then
          result.list = mailer.list(listId)
          result.contacts = mailer.contacts(query or "", page or 1, 50, listId)
       end
   elseif scope == "remove" then
      result.contactCount = mailer.contacts("", 1, 1).total
    elseif scope == "templates" then
      result.templates = mailer.templates(manager)
   elseif scope == "invitations" then
      result.settings = mailer.state().settings
      result.contacts = mailer.contacts("", 1, 1)
      result.contacts.items = {}
      result.lists = mailer.lists(false)
      result.templates = mailer.templates(false)
      result.confirmation = mailer.confirmationStats()
    elseif scope == "jobs" then
       result.history = manager and mailer.history(1, 100) or nil
    elseif scope == "job" then
       if not manager then error("Mailer manager access is required", 2) end
       local job, err = mailer.jobDetails(jobId)
       if not job then error(err, 2) end
       result.job = job
   elseif scope == "compose" then
      local mailerState = mailer.state()
      result.settings = mailerState.settings
      result.fileServices = mailerState.fileServices
      result.contacts = mailer.contacts("", 1, 1)
      result.contacts.items = {}
      result.lists = mailer.lists(false)
      result.templates = mailer.templates(false)
   else
      result.settings = mailer.state().settings
      result.contacts = mailer.contacts(query or "", page or 1, 50)
      result.lists = mailer.lists()
      result.templates = mailer.templates(manager)
      if result.manager then result.history = mailer.history(1, 100) end
   end
   return result
end

local function api(env, mailer, identity)
   env.response:setheader("cache-control", "no-store")
   env.response:setheader("x-content-type-options", "nosniff")
   if env.request:method() == "GET" then
      local query = env.request:data() or {}
      if query.scope == "job" and not hasRole(identity, env, "mailer-manager") then
         env.response:setstatus(403)
         env.response:json { ok = false, error = "Mailer manager access is required" }
         return true
      end
      local ok, result = pcall(apiState, mailer, identity, env, query.query, query.page,
         query.scope, query.list_id, query.contact_filter, query.id)
      if not ok then
         env.response:setstatus(400)
         env.response:json { ok = false, error = publicError(result) }
         return true
      end
      env.response:json(result)
      return true
   end
   local dataOk, data = pcall(requestData, env)
   if not dataOk then
      env.response:setstatus(400)
      env.response:json { ok = false, error = tostring(data) }
      return true
   end
   local session = env.request:session()
   if not session or not session.mailerCsrf or data.csrf ~= session.mailerCsrf then
      env.response:setstatus(403)
      env.response:json { ok = false, error = "Invalid CSRF token" }
      return true
   end
   local manager = hasRole(identity, env, "mailer-manager")
   local ok, result = pcall(function()
      if data.action == "create-job" then
         local contactIds = decodeArray(data.contact_ids, "contact selection")
         local listIds = decodeArray(data.list_ids, "list selection")
         local templateSource
         if data.template_id and data.template_id ~= "" then
            local wanted = tonumber(data.template_id)
            for _, template in ipairs(mailer.templates(true)) do
               if template.id == wanted then templateSource = template.source break end
            end
            if not templateSource then error("Template not found", 2) end
         end
         local job = mailer.createJob {
            sender = identity.currentUser(env), deliveryMode = data.delivery_mode,
            subject = data.subject, textBody = data.text_body, htmlBody = data.html_body,
            templateSnapshot = templateSource,
            requireContactPassword = data.require_contact_password == "1",
            contactIds = contactIds, listIds = listIds,
            files = decodeArray(data.files, "file selection")
         }
          if data.queue == "1" then job = mailer.queueJob(job.id) end
          return { job = job }
       end
       if data.action == "parse-eml" then
          local source = tostring(data.source or "")
          if source == "" and data.template_id and data.template_id ~= "" then
             local wanted = tonumber(data.template_id)
             for _, template in ipairs(mailer.templates(true)) do
                if template.id == wanted then source = template.source break end
             end
             if source == "" then error("Template not found", 2) end
          end
          if source == "" or #source > 2097152 then
             error("A valid EML message is required", 2)
          end
          local parsed, parseErr = mailer.parseTemplate(source)
          if not parsed then error("EML message is invalid: " .. tostring(parseErr), 2) end
          return {
             parsedMessage = {
                subject = parsed.subject or "",
                textBody = parsed.txtbody or "",
                htmlBody = parsed.htmlbody or ""
             }
          }
       end
       if not manager then error("Mailer manager role is required", 2) end
      if data.action == "create-invitation-job" then
         local job = mailer.createInvitationJob {
            sender = identity.currentUser(env), subject = data.subject,
            textBody = data.text_body, htmlBody = data.html_body,
            contactIds = decodeArray(data.contact_ids, "contact selection"),
            listIds = decodeArray(data.list_ids, "list selection")
         }
         return { job = mailer.queueJob(job.id) }
      elseif data.action == "save-contact" then
         mailer.saveContact { id = data.id ~= "" and data.id or nil,
            externalId = data.external_id, email = data.email,
            firstName = data.first_name, lastName = data.last_name,
            listIds = data.list_ids ~= nil and
               decodeArray(data.list_ids, "list selection") or nil }
      elseif data.action == "delete-contact" then mailer.deleteContact(data.id)
      elseif data.action == "reset-contact-password" then
         mailer.resetContactPassword(data.id)
      elseif data.action == "resubscribe-contact" then
         mailer.resubscribeContact(data.id)
      elseif data.action == "resubscribe-contacts" then
         return { restore = mailer.resubscribeContacts(
            decodeArray(data.contact_ids, "contact selection")) }
      elseif data.action == "delete-contacts" then
         return { transfer = mailer.deleteContacts(
            decodeArray(data.contact_ids, "contact selection")) }
      elseif data.action == "delete-all-contacts" then mailer.deleteAllContacts()
      elseif data.action == "save-list" then
         return { savedListId = mailer.saveList {
            id = data.id ~= "" and data.id or nil,
            name = data.name, description = data.description,
            contactIds = data.contact_ids ~= nil and
               decodeArray(data.contact_ids, "contact selection") or nil } }
      elseif data.action == "delete-list" then mailer.deleteList(data.id)
      elseif data.action == "delete-all-lists" then mailer.deleteAllLists()
      elseif data.action == "move-list-members" then
         return { transfer = mailer.transferListMembers(data.source_list_id,
            data.destination_list_id,
            decodeArray(data.contact_ids, "contact selection"), false) }
      elseif data.action == "move-all-list-members" then
         return { transfer = mailer.transferListMembers(data.source_list_id,
            data.destination_list_id, nil, false) }
      elseif data.action == "merge-list" then
         return { transfer = mailer.transferListMembers(data.source_list_id,
            data.destination_list_id, nil, true) }
      elseif data.action == "remove-list-members" then
         return { transfer = mailer.removeListMembers(data.source_list_id,
            decodeArray(data.contact_ids, "contact selection")) }
      elseif data.action == "add-list-members" then
         return { transfer = mailer.addListMembers(data.destination_list_id,
            decodeArray(data.contact_ids, "contact selection")) }
      elseif data.action == "save-template" then
         mailer.saveTemplate { id = data.id ~= "" and data.id or nil,
            name = data.name, source = data.source }
      elseif data.action == "delete-template" then mailer.deleteTemplate(data.id)
      elseif data.action == "cancel-job" then mailer.cancelJob(data.id)
      elseif data.action == "purge-history" then mailer.purgeHistory(data.older_than)
      else error("Unknown mailer action", 2) end
      return {}
   end)
   if not ok then
      env.response:setstatus(400)
      env.response:json { ok = false, error = publicError(result) }
      return true
   end
   local state = apiState(mailer, identity, env, data._query, data._page,
      data._scope, data._list_id, data._contact_filter, data._job_id)
   for key, value in pairs(result) do state[key] = value end
   env.response:json(state)
   return true
end

local function csvApi(env, mailer, identity, action)
   env.response:setheader("cache-control", "no-store")
   env.response:setheader("x-content-type-options", "nosniff")
   if env.request:method() ~= "POST" then
      env.response:setstatus(405)
      env.response:json { ok = false, error = "CSV endpoints require POST" }
      return true
   end
   local session = env.request:session()
   if not session or not session.mailerCsrf or
      env.request:header("X-FuguHub-CSRF") ~= session.mailerCsrf then
      env.response:setstatus(403)
      env.response:json { ok = false, error = "Invalid CSRF token" }
      return true
   end
   local query = env.request:data() or {}
   local source, readErr, status = rawCsv(env)
   if not source then
      env.response:setstatus(status)
      env.response:json { ok = false, error = readErr }
      return true
   end
   local ok, result = pcall(function()
      if action == "preview" then
         return { csvPreview = mailer.previewContactsCsv(source) }
      end
      local hasHeaderValue = env.request:header("X-FuguHub-CSV-Has-Header")
      local hasHeader
      if hasHeaderValue == "1" then hasHeader = true
      elseif hasHeaderValue == "0" then hasHeader = false
      elseif hasHeaderValue ~= nil then error("Invalid CSV header setting", 2) end
      return { importResult = mailer.importContactsCsv(source,
         decodeObject(env.request:header("X-FuguHub-CSV-Mapping"),
            "CSV column mapping"), env.request:header("X-FuguHub-List-ID"),
         env.request:header("X-FuguHub-Restore-Unsubscribed") == "1", hasHeader) }
   end)
   if not ok then
      env.response:setstatus(400)
      env.response:json { ok = false, error = publicError(result) }
      return true
   end
   local state = apiState(mailer, identity, env, query.query, query.page,
       query.scope, query.list_id, query.contact_filter, query.id)
   for key, value in pairs(result) do state[key] = value end
   env.response:json(state)
   return true
end

function M.install(ctx, mailer, identity, files, pluginApp)
   local authenticator
   local function rebuildAuthenticator()
      authenticator = identity.newFormAuthenticator {
         realm = "FuguHub Large File Mailer",
         response = function(env, authinfo)
            return loginResponse(pluginApp, env, authinfo)
         end
      }
   end
   rebuildAuthenticator()
   ctx:own(identity.onChange(rebuildAuthenticator))
   local dir = ba.create.dir "mailer"
   dir:setfunc(function(env, relpath)
      if relpath == "app.js" then return serveFile(env, ctx, "public/app.js", "text/javascript; charset=utf-8") end
      if relpath == "app.css" then return serveFile(env, ctx, "public/app.css", "text/css; charset=utf-8") end
      if relpath == "public.css" then return serveFile(env, ctx, "public/public.css", "text/css; charset=utf-8") end
      if relpath == "wfm.js" then return serveFile(env, ctx, "public/wfm.js", "text/javascript; charset=utf-8") end
      local token = relpath:match("^d/([^/]+)$")
      if token then
         local method = env.request:method()
         if method ~= "GET" and method ~= "HEAD" and method ~= "POST" then
            env.response:senderror(405, "Method Not Allowed") return true
         end
         return mailer.download(env, token)
      end
      local invitationToken = relpath:match("^invite/([^/]+)$")
      if invitationToken then
         local method = env.request:method()
         if method ~= "GET" and method ~= "HEAD" and method ~= "POST" then
            env.response:senderror(405, "Method Not Allowed") return true
         end
         return mailer.invitation(env, invitationToken)
      end
      local unsubscribeToken = relpath:match("^unsubscribe/([^/]+)$")
      if unsubscribeToken then
         local method = env.request:method()
         if method ~= "GET" and method ~= "HEAD" and method ~= "POST" then
            env.response:senderror(405, "Method Not Allowed") return true
         end
         return mailer.unsubscribe(env, unsubscribeToken)
      end
      if #identity.users() > 0 and
         not authenticator:authenticate(env.request, relpath) then return true end
      local csvAction = relpath:match("^csv/([^/]+)/?$")
      if csvAction == "preview" or csvAction == "import" then
         if not hasRole(identity, env, "mailer-manager") then
            env.response:setstatus(403)
            env.response:json { ok = false, error = "Mailer manager role is required" }
            return true
         end
         return csvApi(env, mailer, identity, csvAction)
      end
      local removalAction = relpath:match("^remove/([^/]+)/?$")
      if removalAction == "preview" or removalAction == "execute" then
         return removalApi(env, mailer, identity, removalAction)
      end
      local view = relpath:match("^([^/]+)/?$")
      if relpath == "" then view = "compose" end
      if view == "manage" then view = "jobs" end
      local compose = view == "compose"
      local manage = view == "contacts" or view == "lists" or
         view == "invitations" or
         view == "remove" or view == "templates" or view == "jobs"
      if relpath == "api" or relpath == "api/" then
         if not hasRole(identity, env, "mailer-user") and
            not hasRole(identity, env, "mailer-manager") then
            env.response:senderror(403, "Forbidden") return true
         end
         return api(env, mailer, identity)
      end
      if compose then
         if not hasRole(identity, env, "mailer-user") and
            not hasRole(identity, env, "mailer-manager") then
            env.response:senderror(403, "Forbidden") return true
         end
         return shell(env, pluginApp, identity, view)
      end
      if manage then
         if not hasRole(identity, env, "mailer-manager") then
            env.response:senderror(403, "Forbidden") return true
         end
         return shell(env, pluginApp, identity, view)
      end
      return false
   end)
   ctx:mount("mailer", dir)
   ctx:own(files.addWfmPlugin {
      id = "large-file-mailer",
      module = pluginApp.url("/mailer/wfm.js"),
      allowed = function(env)
         return hasRole(identity, env, "mailer-user") or
            hasRole(identity, env, "mailer-manager")
      end
   })
end

return M
