local M = {}

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

local function readRows(ctx, sql)
   local env, conn = ctx.db.openRead()
   local ok, result = pcall(function()
      local cursor, err = conn:execute(sql)
      if not cursor then error(tostring(err or "SQL query failed"), 2) end
      local rows = {}
      while true do
         local row = cursor:fetch({}, "a")
         if not row then break end
         rows[#rows + 1] = row
      end
      cursor:close()
      return rows
   end)
   conn:close()
   env:close()
   if not ok then error(result, 2) end
   return result
end

local function copyArray(values)
   local result = {}
   for index, value in ipairs(values or {}) do result[index] = value end
   return result
end

local function sameArray(a, b)
   if #a ~= #b then return false end
   for index = 1, #a do
      if a[index] ~= b[index] then return false end
   end
   return true
end

local function arrayRemoved(oldValues, newValues)
   local retained = {}
   for _, value in ipairs(newValues) do retained[value] = true end
   for _, value in ipairs(oldValues) do
      if not retained[value] then return true end
   end
   return false
end

local function loadCatalog(ctx)
   local catalog = {
      roles = {},
      roleMap = {},
      users = {},
      userMap = {}
   }

   for _, row in ipairs(readRows(ctx,
      "SELECT name,description,system_role FROM identity_roles ORDER BY name")) do
      local role = {
         name = row.name,
         description = row.description or "",
         systemRole = tonumber(row.system_role) == 1
      }
      catalog.roles[#catalog.roles + 1] = role
      catalog.roleMap[role.name] = role
   end

   for _, row in ipairs(readRows(ctx, [[
SELECT username,display_name,email,disabled,max_users,recycle,inactive,
       created_at,updated_at
FROM identity_profiles ORDER BY username
]])) do
      local user = {
         username = row.username,
         displayName = row.display_name or "",
         email = row.email or "",
         disabled = tonumber(row.disabled) == 1,
         maxUsers = tonumber(row.max_users) or 3,
         recycle = tonumber(row.recycle) == 1,
         inactive = tonumber(row.inactive) or 1200,
         createdAt = tonumber(row.created_at),
         updatedAt = tonumber(row.updated_at),
         roles = {}
      }
      catalog.users[#catalog.users + 1] = user
      catalog.userMap[user.username] = user
   end

   for _, row in ipairs(readRows(ctx, [[
SELECT username,role_name FROM identity_user_roles ORDER BY username,role_name
]])) do
      local user = catalog.userMap[row.username]
      if user then user.roles[#user.roles + 1] = row.role_name end
   end
   return catalog
end

local function validateName(value, pattern, label)
   value = trim(value)
   if value == "" then error(label .. " is required", 3) end
   if #value > 64 or not value:match(pattern) then
      error("Invalid " .. label:lower(), 3)
   end
   return value
end

local function validateUsername(value)
   return validateName(value, "^[%w][%w%._%-]*$", "Username")
end

local function validateRoleName(value)
   return validateName(value, "^[a-z0-9][a-z0-9%-]*$", "Role name")
end

local function boundedInteger(value, minimum, maximum, label)
   value = tonumber(value)
   if not value or value % 1 ~= 0 or value < minimum or value > maximum then
      error(label .. " must be an integer from " .. minimum .. " to " .. maximum, 3)
   end
   return value
end

local function serialize(thread, fn)
   local done = false
   local result
   thread:run(function()
      result = table.pack(pcall(fn))
      done = true
   end)
   while not done do ba.sleep(10) end
   if not result[1] then error(result[2], 3) end
   return table.unpack(result, 2, result.n)
end

local function actorName(value)
   value = trim(value)
   return value ~= "" and value or "cms-admin"
end

local function randomPassword()
   return (ba.rndbs(32):gsub(".", function(character)
      return string.format("%02x", string.byte(character))
   end))
end

local function terminateSessions(username)
   for _, sessionId in ipairs(ba.sessions(username)) do
      local session = ba.session(sessionId)
      if session then session:terminate() end
   end
end

function M.start(ctx, store)
   local mutationThread = ba.thread.create()
   local catalog = loadCatalog(ctx)
   local listeners = {}

   local function checkConsistency()
      local encrypted = {}
      for _, username in ipairs(store.users()) do encrypted[username] = true end
      for username in pairs(encrypted) do
         local profile = catalog.userMap[username]
         if not profile then
            error("CMS identity database is inconsistent: credentials exist " ..
               "without a profile for user " .. username, 2)
         end
      end
      for _, profile in ipairs(catalog.users) do
         if not encrypted[profile.username] then
            error("CMS identity database is inconsistent: profile exists " ..
               "without credentials for user " .. profile.username, 2)
         end
      end
   end
   checkConsistency()

   local service = {}

   local function notify(change)
      local snapshot = {}
      for listener in pairs(listeners) do snapshot[#snapshot + 1] = listener end
      for _, listener in ipairs(snapshot) do
         local ok, err = pcall(listener, change)
         if not ok then
            ctx:trace("Identity change listener failed:", tostring(err))
         end
      end
   end

   local function refresh()
      catalog = loadCatalog(ctx)
      checkConsistency()
   end

   local function userHasRole(user, role)
      for _, assigned in ipairs(user and user.roles or {}) do
         if assigned == role then return true end
      end
      return false
   end

   local function enabledCmsAdminCount(exceptUsername)
      local count = 0
      for _, user in ipairs(catalog.users) do
         if user.username ~= exceptUsername and not user.disabled and
            userHasRole(user, "cms-admin") then
            count = count + 1
         end
      end
      return count
   end

   function service.users()
      local result = {}
      for index, user in ipairs(catalog.users) do
         result[index] = {
            username = user.username,
            displayName = user.displayName,
            email = user.email,
            disabled = user.disabled,
            maxUsers = user.maxUsers,
            recycle = user.recycle,
            inactive = user.inactive,
            createdAt = user.createdAt,
            updatedAt = user.updatedAt,
            roles = copyArray(user.roles)
         }
      end
      return result
   end

   function service.roles()
      local result = {}
      for index, role in ipairs(catalog.roles) do
         result[index] = {
            name = role.name,
            description = role.description,
            systemRole = role.systemRole
         }
      end
      return result
   end

   function service.cmsAdminCount()
      return enabledCmsAdminCount()
   end

   function service.onChange(listener)
      if type(listener) ~= "function" then
         error("Identity change listener must be a function", 2)
      end
      listeners[listener] = true
      local active = true
      return function()
         if not active then return end
         active = false
         listeners[listener] = nil
      end
   end

   function service.currentUser(env)
      local username = env and env.request and env.request:user()
      if type(username) ~= "string" then return nil end
      local user = catalog.userMap[username]
      return user and not user.disabled and username or nil
   end

   function service.hasRole(env, role)
      local username = service.currentUser(env)
      local user = username and catalog.userMap[username]
      if not user then return false end
      for _, assigned in ipairs(user.roles) do
         if assigned == role then return true end
      end
      return false
   end

   function service.requireRole(env, role)
      if service.hasRole(env, role) then return true end
      env.response:senderror(403, "Forbidden")
      return false
   end

   local function authenticator(kind, options)
      local copy = {}
      for key, value in pairs(options or {}) do copy[key] = value end
      copy.type = kind
      copy.realm = copy.realm or
         (kind == "dav" and "FuguHub Files" or "FuguHub")
      return ba.create.authenticator(store.authuser(), copy)
   end

   function service.newFormAuthenticator(options)
      return authenticator("form", options)
   end

   function service.newDavAuthenticator(options)
      return authenticator("dav", options)
   end

   function service.newAuthorizer(constraints, options)
      local authorizer = store.authuser():authorizer()
      local ok, err = authorizer:set(constraints or {})
      if not ok then error("Invalid authorization constraints: " ..
         tostring(err or "unknown error"), 2) end
      if options and options.caseSensitive ~= nil then
         authorizer:casesensitive(options.caseSensitive == true)
      end
      return authorizer
   end

   function service.verifyCredentials(username, password, requiredRole)
      username = tostring(username or "")
      password = tostring(password or "")
      local user = catalog.userMap[username]
      if not user or user.disabled then
         return false, "The CMS administrator credentials are invalid"
      end
      if requiredRole then
         local assigned = false
         for _, role in ipairs(user.roles) do
            if role == requiredRole then assigned = true break end
         end
         if not assigned then
            return false, "The user does not have the " .. requiredRole .. " role"
         end
      end
      local stored = store.authuser():getpwd(username)
      if type(stored) ~= "string" or stored ~= password then
         return false, "The CMS administrator credentials are invalid"
      end
      return true
   end

   function service.saveUser(input, actor)
      input = input or {}
      local change = serialize(mutationThread, function()
         local username = validateUsername(input.username)
         local old = catalog.userMap[username]
         local disabled = input.disabled == true
         local displayName = trim(input.displayName ~= nil and
            input.displayName or old and old.displayName)
         local email = trim(input.email ~= nil and input.email or old and old.email)
         if #displayName > 160 then error("Display name is too long", 2) end
         if #email > 254 then error("Email address is too long", 2) end
         local maxUsers = boundedInteger(
            input.maxUsers ~= nil and input.maxUsers or old and old.maxUsers or 3,
            1, 1000, "Maximum sessions")
         local inactive = boundedInteger(
            input.inactive ~= nil and input.inactive or old and old.inactive or 1200,
            0, 31536000, "Inactive timeout")
         local recycle = input.recycle == true
         local password = tostring(input.password or "")
         if #password > 1024 then error("Password is too long", 2) end

         local roleSet = { authenticated = true }
         for _, roleName in ipairs(input.roles or old and old.roles or {}) do
            roleName = validateRoleName(roleName)
            if not catalog.roleMap[roleName] then
               error("Unknown role: " .. roleName, 2)
            end
            roleSet[roleName] = true
         end
         local roles = {}
         for roleName in pairs(roleSet) do roles[#roles + 1] = roleName end
         table.sort(roles)

         local nextCmsAdmin = not disabled
         if nextCmsAdmin then
            nextCmsAdmin = false
            for _, roleName in ipairs(roles) do
               if roleName == "cms-admin" then nextCmsAdmin = true break end
            end
         end
         if old and not old.disabled and userHasRole(old, "cms-admin") and
            not nextCmsAdmin and enabledCmsAdminCount(username) == 0 then
            error("The final enabled cms-admin cannot be disabled or demoted. " ..
               "Use the explicit authentication reset to return to bootstrap mode", 2)
         end

         local rolesChanged = old and not sameArray(old.roles, roles)
         local credentialsChanged = not old or password ~= "" or
            (old.disabled and not disabled) or
            (not old.disabled and disabled) or
            (old and not old.disabled and (
               old.maxUsers ~= maxUsers or old.recycle ~= recycle or
               old.inactive ~= inactive or rolesChanged))
         local invalidateSessions = not old or password ~= "" or
            (old.disabled ~= disabled) or
            (old and not old.disabled and (
               old.maxUsers ~= maxUsers or old.recycle ~= recycle or
               old.inactive ~= inactive or arrayRemoved(old.roles, roles)))

         if disabled and password ~= "" then
            error("A disabled user cannot be assigned a password", 2)
         end
         if not disabled and credentialsChanged and password == "" then
            if not old or old.disabled then
               error("A new password is required for a new or re-enabled user", 2)
            end
            password = store.authuser():getpwd(username)
            if type(password) ~= "string" then
               error("The existing user credential cannot be loaded", 2)
            end
         end

         local staged
         if credentialsChanged then
            local userRecord = disabled and {
               pwd = randomPassword(),
               roles = {},
               maxUsers = 0,
               recycle = false,
               inactive = inactive
            } or {
                  pwd = password,
                  roles = roles,
                  maxUsers = maxUsers,
                  recycle = recycle,
                  inactive = inactive
               }
            local stagedOrNil, storeErr = store.stage(username, userRecord)
            if not stagedOrNil then error("Credential update failed: " ..
               tostring(storeErr), 2) end
            staged = stagedOrNil
         end

         local now = os.time()
         ctx.db.writeSync(function(conn)
               if staged then store.persist(conn, staged) end
               execute(conn, string.format([[
INSERT INTO identity_profiles(
   username,display_name,email,disabled,max_users,recycle,inactive,created_at,updated_at
) VALUES(%s,%s,%s,%d,%d,%d,%d,%d,%d)
ON CONFLICT(username) DO UPDATE SET
   display_name=excluded.display_name,
   email=excluded.email,
   disabled=excluded.disabled,
   max_users=excluded.max_users,
   recycle=excluded.recycle,
   inactive=excluded.inactive,
   updated_at=excluded.updated_at
]], quote(username), quote(displayName), quote(email), disabled and 1 or 0,
                  maxUsers, recycle and 1 or 0, inactive,
                  old and old.createdAt or now, now))
               execute(conn, "DELETE FROM identity_user_roles WHERE username=" ..
                  quote(username))
               for _, roleName in ipairs(roles) do
                  execute(conn, string.format(
                     "INSERT INTO identity_user_roles(username,role_name) VALUES(%s,%s)",
                     quote(username), quote(roleName)))
               end
               execute(conn, string.format([[
INSERT INTO identity_audit(actor,action,target,detail_json,created_at)
VALUES(%s,%s,%s,'{}',%d)
]], quote(actorName(actor)), quote(old and "user.updated" or "user.created"),
                  quote(username), now))
         end)
         if staged then store.activate(staged) end
         refresh()
         return {
            type = old and "user-updated" or "user-created",
            username = username,
            credentialsChanged = credentialsChanged,
            invalidateSessions = invalidateSessions
         }
      end)
      if change.invalidateSessions then terminateSessions(change.username) end
      notify(change)
      return true
   end

   function service.deleteUser(username, actor)
      local change = serialize(mutationThread, function()
         username = validateUsername(username)
         local old = catalog.userMap[username]
         if not old then error("User does not exist", 2) end
         if not old.disabled and userHasRole(old, "cms-admin") and
            enabledCmsAdminCount(username) == 0 then
            error("The final enabled cms-admin cannot be deleted. Use the " ..
               "explicit authentication reset to return to bootstrap mode", 2)
         end
         local staged, storeErr = store.stage(username, nil)
         if not staged then error("Credential removal failed: " ..
            tostring(storeErr), 2) end
         ctx.db.writeSync(function(conn)
               store.persist(conn, staged)
               execute(conn, "DELETE FROM identity_profiles WHERE username=" ..
                  quote(username))
               execute(conn, string.format([[
INSERT INTO identity_audit(actor,action,target,detail_json,created_at)
VALUES(%s,'user.deleted',%s,'{}',%d)
]], quote(actorName(actor)), quote(username), os.time()))
         end)
         store.activate(staged)
         refresh()
         return { type = "user-deleted", username = username }
      end)
      terminateSessions(change.username)
      notify(change)
      return true
   end

   function service.reset(actor)
      local usernames = {}
      local change = serialize(mutationThread, function()
         for _, user in ipairs(catalog.users) do
            usernames[#usernames + 1] = user.username
         end
         local staged = store.emptyStage()
         ctx.db.writeSync(function(conn)
            store.persist(conn, staged)
            execute(conn, "DELETE FROM identity_profiles")
            execute(conn, string.format([[
INSERT INTO identity_audit(actor,action,target,detail_json,created_at)
VALUES(%s,'identity.reset','*','{}',%d)
]], quote(actorName(actor)), os.time()))
         end)
         store.activate(staged)
         refresh()
         return { type = "identity-reset" }
      end)
      for _, username in ipairs(usernames) do terminateSessions(username) end
      notify(change)
      return true
   end

   function service.saveRole(input, actor)
      input = input or {}
      local change = serialize(mutationThread, function()
         local name = validateRoleName(input.name)
         local description = trim(input.description)
         if #description > 500 then error("Role description is too long", 2) end
         local old = catalog.roleMap[name]
         ctx.db.writeSync(function(conn)
            execute(conn, string.format([[
INSERT INTO identity_roles(name,description,system_role) VALUES(%s,%s,0)
ON CONFLICT(name) DO UPDATE SET description=excluded.description
]], quote(name), quote(description)))
            execute(conn, string.format([[
INSERT INTO identity_audit(actor,action,target,detail_json,created_at)
VALUES(%s,%s,%s,'{}',%d)
]], quote(actorName(actor)), quote(old and "role.updated" or "role.created"),
               quote(name), os.time()))
         end)
         refresh()
         return { type = old and "role-updated" or "role-created", role = name }
      end)
      notify(change)
      return true
   end

   function service.deleteRole(name, actor)
      local change = serialize(mutationThread, function()
         name = validateRoleName(name)
         local role = catalog.roleMap[name]
         if not role then error("Role does not exist", 2) end
         if role.systemRole then error("System roles cannot be deleted", 2) end
         for _, user in ipairs(catalog.users) do
            for _, assigned in ipairs(user.roles) do
               if assigned == name then
                  error("Role is assigned to user " .. user.username, 2)
               end
            end
         end
         ctx.db.writeSync(function(conn)
            execute(conn, "DELETE FROM identity_roles WHERE name=" .. quote(name))
            execute(conn, string.format([[
INSERT INTO identity_audit(actor,action,target,detail_json,created_at)
VALUES(%s,'role.deleted',%s,'{}',%d)
]], quote(actorName(actor)), quote(name), os.time()))
         end)
         refresh()
         return { type = "role-deleted", role = name }
      end)
      notify(change)
      return true
   end

   return service
end

return M
