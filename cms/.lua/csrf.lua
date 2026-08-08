local http = appreq "cmshttp"

local M = {}
local TOKEN_KEY = "fuguhubCsrfToken"

local function randomToken()
   return (ba.rndbs(32):gsub(".", function(ch)
      return string.format("%02x", string.byte(ch))
   end))
end

local function constantTimeEqual(a, b)
   a = tostring(a or "")
   b = tostring(b or "")
   if #a ~= #b then return false end
   local diff = 0
   for i = 1, #a do
      if a:byte(i) ~= b:byte(i) then
         diff = diff + 1
      end
   end
   return diff == 0
end

function M.token(_ENV)
   local session = _ENV.request:session(true)
   if not session[TOKEN_KEY] then
      session[TOKEN_KEY] = randomToken()
   end
   return session[TOKEN_KEY]
end

function M.field(_ENV)
   _ENV.response:write("<input type='hidden' name='_csrf' value='",
      http.htmlAttr(M.token(_ENV)), "'>")
end

function M.validate(_ENV, data)
   local session = _ENV.request:session()
   return session and constantTimeEqual(session[TOKEN_KEY], data and data._csrf)
end

return M
