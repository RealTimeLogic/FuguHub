local M = {}
local runtime
local wfsModule = require "wfs"

local READ_METHODS = {
   "OPTIONS", "HEAD", "GET", "PROPFIND", "LOCK", "UNLOCK"
}
local WRITE_METHODS = {
   "POST", "PUT", "DELETE", "MKCOL", "COPY", "MOVE", "PROPPATCH"
}
local NON_FILE_ROLES = {
   authenticated = true,
   ["cms-admin"] = true,
   ["identity-admin"] = true,
   ["mailer-manager"] = true,
   ["mailer-user"] = true
}

local function trim(value)
   return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function quote(value)
   return luasql.quotestr(tostring(value or ""))
end

local function execute(conn, sql)
   local result, err = conn:execute(sql)
   if result == nil then error(tostring(err or "SQL execution failed"), 2) end
   if type(result) == "userdata" and result.close then result:close() end
   return result
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

local function tableExists(conn, name)
   local cursor, err = conn:execute(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name=" .. quote(name))
   if not cursor then error(tostring(err or "SQL query failed"), 2) end
   local exists = cursor:fetch() ~= nil
   cursor:close()
   return exists
end

local function ensureSchema(ctx)
   ctx.db.writeSync(function(conn)
      local createDefaultAcl = not tableExists(conn, "file_service_acl")
      execute(conn, [[
CREATE TABLE IF NOT EXISTS file_service_settings (
   singleton INTEGER PRIMARY KEY CHECK(singleton=1),
   enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
   max_uploads INTEGER NOT NULL DEFAULT 20 CHECK(max_uploads > 0),
   max_locks INTEGER NOT NULL DEFAULT 100 CHECK(max_locks > 0),
   session_timeout INTEGER NOT NULL DEFAULT 900 CHECK(session_timeout > 0),
   case_sensitive INTEGER NOT NULL DEFAULT 1 CHECK(case_sensitive IN (0,1))
)]])
      execute(conn, [[
CREATE TABLE IF NOT EXISTS file_service_acl (
   id INTEGER PRIMARY KEY,
   name TEXT NOT NULL UNIQUE,
   role_name TEXT NOT NULL REFERENCES identity_roles(name) ON DELETE RESTRICT,
   path_pattern TEXT NOT NULL,
   permission TEXT NOT NULL CHECK(permission IN ('read','write')),
   enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
   UNIQUE(role_name,path_pattern)
)]])
      execute(conn, [[
INSERT OR IGNORE INTO file_service_settings(singleton) VALUES(1)
]])
      if createDefaultAcl then
         execute(conn, [[
INSERT INTO file_service_acl(name,role_name,path_pattern,permission,enabled)
VALUES('File administrators','file-admin','/*','write',1)
]])
      end
   end)
end

local function loadState(ctx, config)
   local setting = rows(ctx, [[
SELECT enabled,max_uploads,max_locks,session_timeout,case_sensitive
FROM file_service_settings WHERE singleton=1
]])[1]
   local result = {
      settings = {
         enabled = tonumber(setting.enabled) == 1,
         mountName = config.mountName,
         baseUrl = config.baseUrl,
         maxUploads = tonumber(setting.max_uploads),
         maxLocks = tonumber(setting.max_locks),
         sessionTimeout = tonumber(setting.session_timeout),
         caseSensitive = tonumber(setting.case_sensitive) == 1
      },
      acls = {}
   }
   for _, row in ipairs(rows(ctx, [[
SELECT id,name,role_name,path_pattern,permission,enabled
FROM file_service_acl ORDER BY name,id
]])) do
      result.acls[#result.acls + 1] = {
         id = tonumber(row.id),
         name = row.name,
         role = row.role_name,
         path = row.path_pattern,
         permission = row.permission,
         enabled = tonumber(row.enabled) == 1
      }
   end
   return result
end

local function normalizePath(value)
   value = trim(value):gsub("/+", "/")
   if value == "" then value = "/" end
   if value:sub(1, 1) ~= "/" then
      error("File Services paths must start with / and are relative to the configured File Services root", 3)
   end
   if value:find("\\", 1, true) then
      error("File Services paths must use forward slashes, not backslashes", 3)
   end
   if value:find("%z") then error("File Services paths cannot contain NUL bytes", 3) end
   if value:lower():find("%%2f", 1, true) or
      value:lower():find("%%5c", 1, true) then
      error("File Services paths cannot contain encoded path separators", 3)
   end
   for segment in value:gmatch("[^/]+") do
      if segment == "." or segment == ".." then
         error("File Services paths cannot contain . or .. segments", 3)
      end
   end
   if value ~= "/" then
      value = value:gsub("/%*$", ""):gsub("/$", "") .. "/*"
   else
      value = "/*"
   end
   return value
end

local function positiveInteger(value, maximum, label)
   value = tonumber(value)
   if not value or value % 1 ~= 0 or value < 1 or value > maximum then
      error(label .. " must be an integer from 1 to " .. maximum, 3)
   end
   return value
end

local function roleExists(identity, name)
   for _, role in ipairs(identity.roles()) do
      if role.name == name then return true end
   end
   return false
end

local function methods(permission)
   local result = {}
   for _, method in ipairs(READ_METHODS) do result[#result + 1] = method end
   if permission == "write" then
      for _, method in ipairs(WRITE_METHODS) do result[#result + 1] = method end
   end
   return result
end

local function compileAcls(state)
   local constraints = {}
   local active = 0
   for _, acl in ipairs(state.acls) do
      if acl.enabled then
         active = active + 1
         constraints["acl-" .. acl.id] = {
            urls = { acl.path },
            methods = methods(acl.permission),
            roles = { acl.role }
         }
      end
   end
   return constraints, active
end

local function normalizeBaseUrl(value)
   value = trim(value)
   if value == "" then value = "/fs/" end
   if value:sub(1, 1) ~= "/" then value = "/" .. value end
   if value:sub(-1) ~= "/" then value = value .. "/" end
   local name = value:match("^/([a-z0-9][a-z0-9%-]*)/$")
   if not name then
      error("wfs.baseurl must contain one URL segment, for example /fs/", 3)
   end
   return value, name
end

local function normalizeLockDir(value)
   value = trim(value)
   if value == "" then value = ".locks" end
   if value:find("\\", 1, true) or value:find("%z") then
      error("wfs.lockdir must use an IO path with forward slashes", 3)
   end
   for segment in value:gmatch("[^/]+") do
      if segment == "." or segment == ".." then
         error("wfs.lockdir cannot contain . or .. path segments", 3)
      end
   end
   return value
end

local function resolveConfig(pluginApp)
   local input = pluginApp.wfsConfig or {}
   local ioName = trim(input.io)
   local rootIo
   if ioName == "" or ioName == "home" then
      ioName = "home"
      rootIo = pluginApp.homeIo
   else
      rootIo = ba.openio(ioName)
   end
   if not rootIo then error("Cannot open WFS IO: " .. ioName, 2) end

   local path = trim(input.path)
   if path == "" then path = "/" end
   local storageIo = rootIo
   if path ~= "/" then
      local openErr
      storageIo, openErr = ba.mkio(rootIo, path)
      if not storageIo then error("Cannot open WFS path " .. path .. ": " ..
         tostring(openErr or "unknown error"), 2) end
   end
   local baseUrl, name = normalizeBaseUrl(input.baseurl)
   local lockDir = normalizeLockDir(input.lockdir)
   return {
      ioName = ioName,
      path = path,
      baseUrl = baseUrl,
      mountName = name,
      lockDir = lockDir,
      storageIo = storageIo
   }
end

local function ensureStorage(config)
   local storageIo = config.storageIo
   if not storageIo:stat(config.lockDir) then
      local ok, err = storageIo:mkdir(config.lockDir)
      if not ok then error("Cannot create WebDAV lock directory: " ..
         config.lockDir .. ": " .. tostring(err), 2) end
   end
   return storageIo
end

local function publicPath(pluginApp, baseUrl)
   return pluginApp.url(baseUrl)
end

local function userRoles(identity, username)
   for _, user in ipairs(identity.users()) do
      if user.username == username and not user.disabled then
         local result = {}
         for _, role in ipairs(user.roles) do result[role] = true end
         return result
      end
   end
   return {}
end

local function accessibleRoots(state, identity, username)
   local roles = userRoles(identity, username)
   local byPath = {}
   for _, acl in ipairs(state.acls) do
      if acl.enabled and roles[acl.role] then
         local path = acl.path == "/*" and "/" or acl.path:sub(1, -2)
         local current = byPath[path]
         if not current or acl.permission == "write" then
            byPath[path] = {
               path = path,
               permission = acl.permission
            }
         end
      end
   end
   local result = {}
   for _, grant in pairs(byPath) do result[#result + 1] = grant end
   table.sort(result, function(a, b) return a.path < b.path end)
   return result
end

local function pageAccessDenied(pluginApp, identity, state, html, env)
   local response = env.response
   local cmsAdmin = identity.hasRole(env, "cms-admin")
   local username = identity.currentUser(env)
   local roots = username and accessibleRoots(state, identity, username) or {}
   local mountUrl = publicPath(pluginApp, state.settings.baseUrl)
   response:setcontenttype("text/html; charset=utf-8")
   response:setheader("cache-control", "no-store")
   response:setheader("x-content-type-options", "nosniff")
   response:setheader("content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
   response:write([[
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>File access unavailable</title><style>
:root{color-scheme:dark;font-family:Inter,ui-sans-serif,system-ui,sans-serif}
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;
background:#252526;color:#f4f4f4;padding:24px}.message{width:min(640px,100%);background:#333;
border:1px solid #606070;padding:30px;border-radius:8px;box-shadow:0 18px 48px #0006}
 h1{margin:0 0 16px;font-size:28px;letter-spacing:0}h2{margin:22px 0 10px;font-size:18px;
 letter-spacing:0}p{margin:0 0 16px;color:#d4d4d4;line-height:1.55}.access-list{display:grid;
 gap:8px;margin:0;padding:0;list-style:none}.access-list a{display:flex;align-items:center;
 justify-content:space-between;gap:18px;padding:11px 13px;border:1px solid #606070;border-radius:6px;
 color:#fff;text-decoration:none}.access-list a:hover{border-color:#69c575;background:#293b2d}
 .path{font-weight:700;overflow-wrap:anywhere}.permission{color:#b8c1cc;font-size:14px;white-space:nowrap}
 .actions{display:flex;flex-wrap:wrap;gap:10px;margin-top:24px}.actions a{display:inline-flex;
 align-items:center;min-height:40px;padding:9px 14px;border-radius:6px;border:1px solid #696c75;
 color:#fff;text-decoration:none;font-weight:700}.actions a.primary{background:#69c575;border-color:#69c575;
 color:#102315}a:focus-visible{outline:3px solid #ffd12e;outline-offset:3px}
 </style></head><body><main class="message"><h1>File access unavailable</h1>
 <p>Your account is signed in, but it does not have permission to browse this location.</p>]])
   if #roots > 0 then
      response:write([[<h2>Available locations</h2><ul class="access-list">]])
      for _, grant in ipairs(roots) do
         local relative = grant.path == "/" and "" or grant.path:sub(2)
         local url = response:encodeurl(mountUrl .. relative)
         local permission = grant.permission == "write" and
            "Read &amp; write" or "Read only"
         response:write('<li><a href="', html(url), '"><span class="path">',
            html(grant.path), '</span><span class="permission">', permission,
            '</span></a></li>')
      end
      response:write([[</ul>]])
   end
   if cmsAdmin then
      response:write([[<p>File access is controlled separately from CMS administration. ]],
         [[Assign this user a dedicated file role with a matching enabled access rule.</p>]])
   end
   response:write([[<div class="actions">]])
   if cmsAdmin then
      response:write("<a class=\"primary\" href=\"",
         pluginApp.url("/admin/plugins/file-services/"),
         "\">Configure file access</a>")
   end
   response:write("<a href=\"", pluginApp.url("/"),
      "\">Return to site</a></div></main></body></html>")
end

local function pathMatches(pattern, path)
   local prefix = pattern == "/*" and "/" or pattern:sub(1, -2)
   return pattern == "/*" or path == prefix:sub(1, -2) or
      path:sub(1, #prefix) == prefix
end

local function createWfmPage(ctx, extensions)
   return function(env, relpath)
      local modules = {}
      local ids = {}
      for id in pairs(extensions) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
         local extension = extensions[id]
         local allowed = true
         if extension.allowed then
            local ok, result = pcall(extension.allowed, env)
            if not ok then
               allowed = false
               ctx:trace("WFM plugin authorization failed:", id, tostring(result))
            else
               allowed = result == true
            end
         end
         if allowed then modules[#modules + 1] = extension.module end
      end

      local config = ba.json.encode {
         rel = relpath or "",
         modules = modules
      }:gsub("<", "\\u003c")
      env.response:setdefaultheaders()
      env.response:setcontenttype("text/html; charset=utf-8")
      env.response:setheader("cache-control", "no-store")
      env.response:write([[<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Files</title>
<link rel="stylesheet" href="/rtl/wfm/wfm.css"><style>body{margin:0;background:#252526;
--wfm-height:100vh}.wfm{border:0;border-radius:0}</style></head><body><div id="files"></div>
<script type="module">import{mount,search,text}from"/rtl/wfm/wfm.js";
const{rel,modules}=]], config, [[,plugins=[search,text];
for(const url of modules){try{const module=await import(url),plugin=module.default||module.plugin;
if(typeof plugin!=="function")throw new TypeError("WFM plugin has no exported function");
plugins.push(plugin)}catch(error){console.error("WFM plugin failed",url,error)}}
const l=location;l.pathname.endsWith("/")||history.replaceState(0,"",l.pathname+"/"+l.search+l.hash);
const url=new URL("../".repeat(rel.split("/").filter(Boolean).length),l.href);
url.search=url.hash="";const manager=mount(document.getElementById("files"),
{url:url,path:"/"+rel,history:true,plugins:plugins});manager.ready.catch(console.error)
</script></body></html>]])
      return true
   end
end

function M.start(ctx, identity, pluginApp)
   ensureSchema(ctx)
   local config = resolveConfig(pluginApp)
   local storageIo = ensureStorage(config)
   local state = loadState(ctx, config)
   local wfmExtensions = {}
   local active = {
      dir = nil,
      unmount = nil,
      error = nil
   }

   local function stopRuntime()
      if active.unmount then active.unmount() end
      active.dir = nil
      active.unmount = nil
   end

   local function startRuntime()
      stopRuntime()
      active.error = nil
      if not state.settings.enabled then return true end

      local constraints, count = compileAcls(state)
      if count == 0 then
         active.error = "File Services requires at least one enabled ACL"
         return nil, active.error
      end
      local authenticator = identity.newDavAuthenticator {
         realm = "FuguHub Files"
      }
      local authorizer = identity.newAuthorizer(constraints, {
         caseSensitive = state.settings.caseSensitive
      })
       local wfs, createErr = wfsModule.create(
          state.settings.mountName,
          0,
          storageIo,
          config.lockDir,
          state.settings.maxUploads,
          state.settings.maxLocks,
          createWfmPage(ctx, wfmExtensions))
      if not wfs then
         active.error = "Cannot create Web File Server: " ..
            tostring(createErr or "unknown error")
         return nil, active.error
      end
      wfs:configure {
          tmo = state.settings.sessionTimeout,
          pageaccessdenied = function(env)
             pageAccessDenied(pluginApp, identity, state, ctx.admin.html, env)
          end
       }
      local authOk, authErr = wfs:setauth(authenticator, authorizer)
      if not authOk then
         active.error = "Cannot protect Web File Server: " ..
            tostring(authErr or "unknown error")
         return nil, active.error
      end
      local _, unmount = ctx:mount(state.settings.mountName, wfs)
      active.dir = wfs
      active.unmount = unmount
      return true
   end

   local function restartFailClosed()
      local ok, err = pcall(startRuntime)
      if not ok then
         stopRuntime()
         active.error = tostring(err)
         ctx:trace("File Services disabled:", active.error)
         return nil, active.error
      end
      if not err and active.error then
         ctx:trace("File Services disabled:", active.error)
         return nil, active.error
      end
      return true
   end

   local identityListener = identity.onChange(function()
      restartFailClosed()
   end)
   ctx:own(identityListener)
   restartFailClosed()

   local service = {}

   function service.state()
      local assigned = {}
      local enabled = {}
      for _, user in ipairs(identity.users()) do
         for _, roleName in ipairs(user.roles or {}) do
            assigned[roleName] = (assigned[roleName] or 0) + 1
            if not user.disabled then enabled[roleName] = (enabled[roleName] or 0) + 1 end
         end
      end
      local snapshot = {
         settings = {
            enabled = state.settings.enabled,
            mountName = state.settings.mountName,
            baseUrl = state.settings.baseUrl,
            io = config.ioName,
            path = config.path,
            lockDir = config.lockDir,
            maxUploads = state.settings.maxUploads,
            maxLocks = state.settings.maxLocks,
            sessionTimeout = state.settings.sessionTimeout,
            caseSensitive = state.settings.caseSensitive
         },
         acls = {},
         roles = {},
         active = active.dir ~= nil,
         runtimeError = active.error,
         mountUrl = publicPath(pluginApp, state.settings.baseUrl),
         usersUrl = pluginApp.url("/admin/plugins/identity-access/")
      }
      for index, acl in ipairs(state.acls) do
         snapshot.acls[index] = {
            id = acl.id,
            name = acl.name,
            role = acl.role,
            path = acl.path,
            permission = acl.permission,
            enabled = acl.enabled
         }
      end
      local fileRoles = { ["file-admin"] = true }
      for _, acl in ipairs(state.acls) do fileRoles[acl.role] = true end
      for _, role in ipairs(identity.roles()) do
         if fileRoles[role.name] or not NON_FILE_ROLES[role.name] then
            snapshot.roles[#snapshot.roles + 1] = {
               name = role.name,
               description = role.description,
               assignedUsers = assigned[role.name] or 0,
               enabledUsers = enabled[role.name] or 0
            }
         end
      end
      return snapshot
   end

   function service.isEnabled()
      return state.settings.enabled and active.dir ~= nil
   end

   function service.mountUrl()
      return publicPath(pluginApp, state.settings.baseUrl)
   end

   function service.location()
      return {
         enabled = service.isEnabled(),
         io = config.ioName,
         path = config.path,
         mountUrl = service.mountUrl()
      }
   end

   function service.normalizeRelativePath(path)
      local normalized = normalizePath(path)
      return normalized == "/*" and "/" or normalized:sub(1, -3)
   end

   function service.authorizeUser(username, method, path)
      method = tostring(method or ""):upper()
      path = service.normalizeRelativePath(path)
      local roles = userRoles(identity, username)
      for _, acl in ipairs(state.acls) do
         if acl.enabled and roles[acl.role] and pathMatches(acl.path, path) then
            for _, allowed in ipairs(methods(acl.permission)) do
               if method == allowed then return true end
            end
         end
      end
      return false
   end

   function service.authorize(env, method, path)
      local username = identity.currentUser(env)
      return username and service.authorizeUser(username, method, path) or false
   end

   function service.statAuthorized(username, path)
      if not service.authorizeUser(username, "GET", path) then
         return nil, "Forbidden"
      end
      return storageIo:stat(service.normalizeRelativePath(path))
   end

   function service.openAuthorized(username, path, mode)
      mode = mode or "rb"
      local method = mode:find("[wa+]") and "PUT" or "GET"
      if not service.authorizeUser(username, method, path) then
         return nil, "Forbidden"
      end
      return storageIo:open(service.normalizeRelativePath(path), mode)
   end

   function service.describeGrant(username, method, path)
      return {
         username = username,
         method = tostring(method or ""):upper(),
         path = service.normalizeRelativePath(path),
         allowed = service.authorizeUser(username, method, path)
      }
   end

   function service.addWfmPlugin(spec)
      if type(spec) ~= "table" then error("WFM plugin specification is required", 2) end
      local id = trim(spec.id)
      local module = trim(spec.module)
      if not id:match("^[a-z0-9][a-z0-9%-]*$") then
         error("Invalid WFM plugin ID", 2)
      end
      if module:sub(1, 1) ~= "/" then
         error("WFM plugin module must use a local absolute URL", 2)
      end
      if spec.allowed ~= nil and type(spec.allowed) ~= "function" then
         error("WFM plugin allowed callback must be a function", 2)
      end
      if wfmExtensions[id] then error("WFM plugin already registered: " .. id, 2) end
      local record = {
         module = module,
         allowed = spec.allowed
      }
      wfmExtensions[id] = record
      local removed = false
      return function()
         if not removed and wfmExtensions[id] == record then
            wfmExtensions[id] = nil
         end
         removed = true
      end
   end

   function service.saveSettings(input)
      input = input or {}
      local nextSettings = {
         enabled = input.enabled == true,
         mountName = config.mountName,
         baseUrl = config.baseUrl,
         maxUploads = positiveInteger(input.maxUploads, 10000, "Maximum uploads"),
         maxLocks = positiveInteger(input.maxLocks, 100000, "Maximum locks"),
         sessionTimeout = positiveInteger(
            input.sessionTimeout, 86400, "Session URL timeout"),
         caseSensitive = input.caseSensitive == true
      }
      if nextSettings.enabled then
         local _, count = compileAcls(state)
         if count == 0 then error(
            "At least one enabled ACL is required before enabling File Services", 2)
         end
      end
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
UPDATE file_service_settings SET
 enabled=%d,max_uploads=%d,max_locks=%d,
 session_timeout=%d,case_sensitive=%d
WHERE singleton=1
]], nextSettings.enabled and 1 or 0, nextSettings.maxUploads, nextSettings.maxLocks,
            nextSettings.sessionTimeout, nextSettings.caseSensitive and 1 or 0))
      end)
      state.settings = nextSettings
      local ok, err = restartFailClosed()
      if nextSettings.enabled and not ok then error(err, 2) end
      return true
   end

   function service.saveAcl(input)
      input = input or {}
      local id = input.id and tonumber(input.id)
      if id and (id < 1 or id % 1 ~= 0) then error("Invalid ACL ID", 2) end
      local role = trim(input.role)
      if not roleExists(identity, role) then error("Unknown role: " .. role, 2) end
      local path = normalizePath(input.path)
      local permission = input.permission == "write" and "write" or
         input.permission == "read" and "read" or nil
      if not permission then error("Permission must be read or write", 2) end
      local enabled = input.enabled ~= false
      local existing
      for _, acl in ipairs(state.acls) do
         if acl.id == id then existing = acl end
         if acl.id ~= id and acl.role == role and acl.path == path then
            error("This role already has an access rule for that path", 2)
         end
      end
      if id and not existing then error("ACL does not exist", 2) end
      ctx.db.writeSync(function(conn)
         if id then
            execute(conn, string.format([[
UPDATE file_service_acl SET role_name=%s,path_pattern=%s,
 permission=%s,enabled=%d WHERE id=%d
]], quote(role), quote(path), quote(permission),
               enabled and 1 or 0, id))
         else
            local cursor, queryErr = conn:execute(
               "SELECT COALESCE(MAX(id),0)+1 FROM file_service_acl")
            if not cursor then error(tostring(queryErr or "SQL query failed"), 2) end
            local row = cursor:fetch({})
            cursor:close()
            local nextId = tonumber(row and row[1])
            if not nextId then error("Cannot allocate ACL ID", 2) end
            execute(conn, string.format([[
INSERT INTO file_service_acl(id,name,role_name,path_pattern,permission,enabled)
VALUES(%d,%s,%s,%s,%s,%d)
]], nextId, quote("Access rule " .. nextId), quote(role), quote(path),
               quote(permission),
               enabled and 1 or 0))
         end
      end)
      state = loadState(ctx, config)
      restartFailClosed()
      return true
   end

   function service.deleteAcl(id)
      id = tonumber(id)
      if not id or id < 1 or id % 1 ~= 0 then error("Invalid ACL ID", 2) end
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM file_service_acl WHERE id=" .. id)
      end)
      state = loadState(ctx, config)
      restartFailClosed()
      return true
   end

   runtime = {
      stop = stopRuntime
   }
   return service
end

function M.stop()
   if runtime then runtime.stop() end
   runtime = nil
end

return M
