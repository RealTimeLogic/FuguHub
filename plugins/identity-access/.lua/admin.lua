local M = {}
local publicError = app.appreq "publicerror"

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

local function state(ctx, identity)
   return {
      ok = true,
      users = identity.users(),
      roles = identity.roles(),
      cmsAdmin = { enabled = identity.cmsAdminCount() > 0 }
   }
end

local function roleSelection(data, roles)
   local selected = {}
   for _, role in ipairs(roles) do
      if data["role_" .. role.name] == "1" then
         selected[#selected + 1] = role.name
      end
   end
   return selected
end

local function api(env, ctx, identity)
   env.response:setheader("cache-control", "no-store")
   env.response:setheader("x-content-type-options", "nosniff")
   if env.request:method() == "GET" then
      env.response:json(state(ctx, identity))
      return true
   end

   local data = ctx.admin:postData(env)
   local actor = env.request:user()
   if type(actor) ~= "string" then actor = "cms-admin" end
   local ok, err = pcall(function()
      if data.action == "save-user" then
         identity.saveUser({
            username = data.username,
            displayName = data.display_name,
            email = data.email,
            password = data.password,
            disabled = data.disabled == "1",
            maxUsers = data.max_users,
            recycle = data.recycle == "1",
            inactive = data.inactive,
            roles = roleSelection(data, identity.roles())
         }, actor)
      elseif data.action == "delete-user" then
         identity.deleteUser(data.username, actor)
      elseif data.action == "save-role" then
         identity.saveRole({
            name = data.name,
            description = data.description
         }, actor)
      elseif data.action == "delete-role" then
         identity.deleteRole(data.name, actor)
      elseif data.action == "bootstrap-cms-admin" then
         if #identity.users() ~= 0 then
            error("The first CMS administrator can only be created when no identity users exist", 2)
         end
         identity.saveUser({
            username = data.username,
            password = data.password,
            roles = { "authenticated", "cms-admin" }
         }, actor)
      elseif data.action == "reset-identity" then
         identity.reset(actor)
      else
         error("Unknown identity action", 2)
      end
   end)
   if not ok then
      env.response:setstatus(400)
      env.response:json({ ok = false, error = publicError(err) })
      return true
   end
   env.response:json(state(ctx, identity))
   return true
end

function M.install(ctx, identity)
   ctx.admin:addPage {
      id = "identity",
      label = "Users & Access",
      path = "",
      order = 650,
      handler = function(env)
         return ctx.admin:layout(env, "Identity and Access", function()
            env.response:write(
               "<link rel='stylesheet' href='admin.css'>",
               "<section class='panel identity-shell'>",
               "<div class='panel-body'>")
            ctx.admin:csrfField(env)
            env.response:write(
               "<div id='identity-app'>Loading identity data...</div>",
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
      return api(env, ctx, identity)
   end)
end

return M
