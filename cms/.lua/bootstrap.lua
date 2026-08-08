local mcpconfig = appreq "mcpconfig"

local M = {}

local function option(name)
   local argv = mako.argv or {}
   for index = 1, #argv do
      if argv[index] == name then
         local value = argv[index + 1]
         if type(value) ~= "string" or value == "" or
            value:sub(1, 1) == "-" then
            error("FuguHub bootstrap option " .. name .. " requires a value", 2)
         end
         return value
      end
   end
end

function M.run(app)
   local value = option "-credentials"
   local token = option "-token"
   if not value and not token then return false end

   if #app.identity.users() ~= 0 then
      trace("FuguHub command-line bootstrap ignored: identity users already exist")
      return false
   end
   if not value then
      error("FuguHub command-line bootstrap requires -credentials", 2)
   end

   local separator = value:find(":", 1, true)
   local username = separator and value:sub(1, separator - 1) or ""
   local password = separator and value:sub(separator + 1) or ""
   if username == "" or password == "" then
      error("FuguHub bootstrap credentials must use username:password", 2)
   end

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
