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

local function responseState(files)
   local state = files.state()
   state.ok = true
   return state
end

local function api(env, ctx, files)
   env.response:setheader("cache-control", "no-store")
   env.response:setheader("x-content-type-options", "nosniff")
   if env.request:method() == "GET" then
      env.response:json(responseState(files))
      return true
   end
   local data = ctx.admin:postData(env)
   local ok, err = pcall(function()
      if data.action == "save-settings" then
         files.saveSettings {
            enabled = data.enabled == "1",
            maxUploads = data.max_uploads,
            maxLocks = data.max_locks,
            sessionTimeout = data.session_timeout,
            caseSensitive = data.case_sensitive == "1"
         }
      elseif data.action == "save-acl" then
         files.saveAcl {
            id = data.id ~= "" and data.id or nil,
            name = data.name,
            role = data.role,
            path = data.path,
            permission = data.permission,
            enabled = data.enabled == "1"
         }
      elseif data.action == "delete-acl" then
         files.deleteAcl(data.id)
      else
         error("Unknown file-service action", 2)
      end
   end)
   if not ok then
      env.response:setstatus(400)
      env.response:json({ ok = false, error = tostring(err) })
      return true
   end
   env.response:json(responseState(files))
   return true
end

function M.install(ctx, files)
   ctx.admin:addPage {
      id = "files",
      label = "Files",
      path = "",
      order = 660,
      handler = function(env)
         return ctx.admin:layout(env, "File Services", function()
            env.response:write(
               "<link rel='stylesheet' href='admin.css'>",
               "<section class='panel file-service-shell'><div class='panel-body'>")
            ctx.admin:csrfField(env)
            env.response:write(
               "<div id='file-service-app' aria-live='polite'>",
               "Loading file-service data...</div>",
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
      return api(env, ctx, files)
   end)
end

return M
