local http = appreq "cmshttp"

local M = {}
local ADMIN_CSS_VERSION = "20260702-1"

local function esc(value)
   return http.html(value)
end

local function state(app)
   return app.adminAuth
end

local function loginResponse(app, env, authinfo)
   authinfo = authinfo or {}
   env.response:setcontenttype("text/html; charset=utf-8")
   env.response:setheader("x-content-type-options", "nosniff")
   env.response:write("<!doctype html><html><head><meta charset='utf-8'>")
   env.response:write("<meta name='viewport' content='width=device-width, initial-scale=1'>")
   env.response:write("<title>Admin Login - CMS Admin</title>")
   env.response:write("<link rel='stylesheet' href='",
      app.url("/admin/admin.css?v=" .. ADMIN_CSS_VERSION), "'>")
   env.response:write("<script src='/rtl/jquery.js'></script>")
   env.response:write("<script src='/rtl/sha1.js'></script>")
   env.response:write("</head><body><main class='login-shell'>")
   env.response:write("<section class='login-panel'><h1>CMS Admin</h1>")
   env.response:write("<p class='muted'>Sign in to manage content, themes, and settings.</p>")
   if authinfo.username then
      env.response:write("<div class='notice'>Login failed for ",
         esc(authinfo.username), ".</div>")
   end
   env.response:write("<form method='post'>")
   env.response:write("<div class='field'><label>Username</label><input name='ba_username' autocomplete='username' autofocus required></div>")
   env.response:write("<div class='field'><label>Password</label><input name='ba_password' type='password' autocomplete='current-password' required></div>")
   env.response:write("<input type='hidden' name='ba_seed' value='",
      esc(authinfo.seed), "'>")
   env.response:write("<input type='hidden' name='ba_seedkey' value='",
      esc(authinfo.seedkey), "'>")
   env.response:write("<div class='actions'><input class='button' type='button' id='ba_loginbut' value='Login'></div>")
   env.response:write("</form></section></main></body></html>")
   return true
end

local function constraints()
   return {
      cmsAdmin = {
         urls = { "/*" },
         methods = {},
         roles = { "cms-admin" }
      }
   }
end

local function clear(auth)
   auth.authenticator = nil
   auth.authorizer = nil
   auth.installed = false
   if auth.adminDir then auth.adminDir:setauth() end
end

local function configure(app)
   local auth = state(app)
   if not auth or auth.closed then return false end
   clear(auth)
   if app.identity.cmsAdminCount() == 0 then
      auth.status = "unconfigured"
      trace("CMS admin authentication disabled: no enabled cms-admin user")
      return true
   end

   local authenticator = app.identity.newFormAuthenticator {
      response = function(env, authinfo)
         return loginResponse(app, env, authinfo)
      end,
      realm = auth.realm
   }
   local authorizer = app.identity.newAuthorizer(constraints())
   local ok, err = auth.adminDir:setauth(authenticator, authorizer)
   if not ok then
      error("Installing CMS admin authentication failed: " ..
         tostring(err or "unknown error"), 2)
   end
   auth.authenticator = authenticator
   auth.authorizer = authorizer
   auth.installed = true
   auth.status = "configured"
   return true
end

function M.install(app, adminDir)
   app.adminAuth = {
      available = true,
      installed = false,
      status = "unconfigured",
      adminDir = adminDir,
      realm = "FuguHub Admin",
      providerId = "cms",
      borrowed = app.identityProvider ~= nil
   }
   local auth = app.adminAuth
   auth.removeListener = app.identity.onChange(function()
      local ok, err = pcall(configure, app)
      if not ok then
         clear(auth)
         auth.status = "failed"
         auth.reason = tostring(err)
         trace("Refreshing CMS admin authentication failed:", auth.reason)
      end
   end)
   return configure(app)
end

function M.refresh(app)
   return configure(app)
end

function M.close(app)
   local auth = state(app)
   if not auth then return end
   auth.closed = true
   if auth.removeListener then
      pcall(auth.removeListener)
      auth.removeListener = nil
   end
   clear(auth)
end

function M.info(app)
   local auth = state(app) or {}
   local identityUi = app.identityAccessUi
   return {
      providerId = "cms",
      borrowed = auth.borrowed == true,
      managementUrl = identityUi and identityUi.managementUrl or
         app.identityManagementUrl,
      status = auth.status or "unconfigured",
      enabled = auth.installed == true,
      reason = auth.reason
   }
end

function M.available(app)
   return app.identity ~= nil and (not state(app) or state(app).status ~= "failed")
end

function M.enabled(app)
   local auth = state(app)
   return auth and auth.installed or false
end

local function authorizeAdmin(auth, request, path)
   return auth.authorizer and auth.authorizer:authorize(
      request, request:method(), path or "/index")
end

local function hasAdminSession(app, env, relpath)
   local auth = state(app)
   if not auth or not auth.installed then return true end
   local session = env.request:session()
   if not session or session.isCmsAdmin ~= true or not env.request:user() then
      return false
   end
   local path = "/" .. ((relpath and relpath ~= "") and relpath or "index")
   return authorizeAdmin(auth, env.request, path) == true
end

function M.newApiGate(app)
   return function(env, relpath)
      relpath = tostring(relpath or ""):gsub("%?.*$", "")
      if not relpath:match("^plugins/[a-z0-9][a-z0-9%-]*/api/") or
         hasAdminSession(app, env, relpath) then
         return false
      end
      env.response:setstatus(401)
      env.response:setheader("cache-control", "no-store")
      env.response:setheader("x-content-type-options", "nosniff")
      env.response:json {
         ok = false,
         error = "CMS admin login required",
         loginUrl = app.url("/admin/")
      }
      return true
   end
end

function M.authenticate(app, env, relpath)
   local auth = state(app)
   if not auth or not auth.installed then return true end
   if auth.authenticator:authenticate(env.request, relpath or "") then
      local authPath = "/" .. ((relpath and relpath ~= "") and relpath or "index")
      if not authorizeAdmin(auth, env.request, authPath) then
         env.response:senderror(403, "Forbidden")
         return false
      end
      env.request:session(true).isCmsAdmin = true
      return true
   end
   return false
end

function M.checkIfAuth(app, env)
   local auth = state(app)
   if not auth or not auth.installed then return true end
   local session = env.request:session()
   if session and session.isCmsAdmin == true then return true end
   if env.request:user() and authorizeAdmin(auth, env.request, env.request:uri()) then
      env.request:session(true).isCmsAdmin = true
      return true
   end
   local target = app.url("/admin/")
   if tostring(env.request:header("HX-Request") or ""):lower() == "true" then
      env.response:setstatus(200)
      env.response:setheader("HX-Redirect", target)
      env.response:setcontenttype("text/plain; charset=utf-8")
      env.response:write("")
      return false
   end
   env.response:sendredirect(target)
   return false
end

function M.reason(app)
   local auth = state(app)
   return auth and auth.reason or nil
end

local function hasRole(user, role)
   for _, assigned in ipairs(user.roles or {}) do
      if assigned == role then return true end
   end
   return false
end

function M.users(app)
   local users = {}
   for _, user in ipairs(app.identity.users()) do
      if not user.disabled and hasRole(user, "cms-admin") then
         users[#users + 1] = user.username
      end
   end
   table.sort(users)
   return users
end

function M.userCount(app)
   return #M.users(app)
end

function M.setUser(app, name, password)
   name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
   if name == "" then return false, "Username is required" end
   local existing
   for _, user in ipairs(app.identity.users()) do
      if user.username == name then existing = user break end
   end
   local ok, err = pcall(function()
      if password and password ~= "" then
         local roles = existing and existing.roles or {}
         local hasAdmin = false
         for _, role in ipairs(roles) do
            if role == "cms-admin" then hasAdmin = true break end
         end
         if not hasAdmin then roles[#roles + 1] = "cms-admin" end
         app.identity.saveUser({
            username = name,
            displayName = existing and existing.displayName or "",
            email = existing and existing.email or "",
            password = password,
            disabled = false,
            maxUsers = existing and existing.maxUsers or 3,
            recycle = existing and existing.recycle or false,
            inactive = existing and existing.inactive or 1200,
            roles = roles
         }, "cms-admin")
      elseif existing then
         local roles = {}
         for _, role in ipairs(existing.roles or {}) do
            if role ~= "cms-admin" then roles[#roles + 1] = role end
         end
         app.identity.saveUser({
            username = name,
            password = "",
            disabled = existing.disabled,
            roles = roles
         }, "cms-admin")
      end
   end)
   return ok, ok and nil or tostring(err)
end

function M.reset(app, actor)
   local ok, err = pcall(app.identity.reset, actor or "cms-admin")
   return ok, ok and nil or tostring(err)
end

return M
