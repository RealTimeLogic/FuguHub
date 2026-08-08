local mcpconfig = appreq "mcpconfig"

local M = {}

local ARGUMENTS = {
   ["-credentials"] = "credentials",
   ["-credentials-file"] = "credentialsFile",
   ["-token"] = "token",
   ["-token-file"] = "tokenFile"
}

local function arguments()
   local result = {}
   local argv = mako and mako.argv or {}
   local index = 1
   while index <= #argv do
      local field = ARGUMENTS[argv[index]]
      if field then
         if result[field] ~= nil then
            error("Duplicate FuguHub bootstrap option: " .. argv[index], 2)
         end
         local value = argv[index + 1]
         if type(value) ~= "string" or value == "" or value:sub(1, 1) == "-" then
            error("FuguHub bootstrap option " .. argv[index] .. " requires a value", 2)
         end
         result[field] = value
         index = index + 2
      else
         index = index + 1
      end
   end
   if result.credentials and result.credentialsFile then
      error("Use either -credentials or -credentials-file, not both", 2)
   end
   if result.token and result.tokenFile then
      error("Use either -token or -token-file, not both", 2)
   end
   return result
end

local function readSecret(path, label)
   local fp, err = _G.io.open(path, "rb")
   if not fp then
      error("Cannot read FuguHub " .. label .. " file " .. path .. ": " ..
         tostring(err), 2)
   end
   local value, readErr = fp:read("*a")
   fp:close()
   if not value then
      error("Cannot read FuguHub " .. label .. " file " .. path .. ": " ..
         tostring(readErr), 2)
   end
   if #value > 8192 then
      error("FuguHub " .. label .. " file is too large", 2)
   end
   if value:byte(1) == 0xEF and value:byte(2) == 0xBB and
      value:byte(3) == 0xBF then
      value = value:sub(4)
   end
   value = value:gsub("[\r\n]+$", "")
   if value:find("[\r\n]") then
      error("FuguHub " .. label .. " file must contain one line", 2)
   end
   return value
end

local function credentials(value)
   local separator = value:find(":", 1, true)
   if not separator then
      error("FuguHub bootstrap credentials must use username:password", 2)
   end
   local username = value:sub(1, separator - 1)
   local password = value:sub(separator + 1)
   if username == "" or password == "" then
      error("FuguHub bootstrap username and password must not be empty", 2)
   end
   return username, password
end

function M.run(app)
   local options = arguments()
   local requested = options.credentials or options.credentialsFile or
      options.token or options.tokenFile
   if not requested then return false end

   if #app.identity.users() ~= 0 then
      trace("FuguHub command-line bootstrap ignored: identity users already exist")
      return false
   end
   if not options.credentials and not options.credentialsFile then
      error("FuguHub command-line bootstrap requires -credentials or " ..
         "-credentials-file", 2)
   end

   local credentialValue = options.credentials or
      readSecret(options.credentialsFile, "credentials")
   local username, password = credentials(credentialValue)
   local token = options.token or
      (options.tokenFile and readSecret(options.tokenFile, "token"))
   if token then
      local valid, err = mcpconfig.validate(token)
      if not valid then error(err, 2) end
      token = valid
   end

   app.identity.saveUser({
      username = username,
      password = password,
      roles = { "authenticated", "cms-admin" }
   }, "command-line-bootstrap")
   trace("FuguHub command-line bootstrap created the first CMS administrator")

   if token then
      local ok, err = mcpconfig.set(app, token)
      if not ok then error("FuguHub MCP bootstrap failed: " .. tostring(err), 2) end
      trace("FuguHub command-line bootstrap enabled MCP")
   end
   return true
end

return M
