local db = appreq "db"
local validation = appreq "validation"

local M = {}
local OPTION_KEY = "mcp_token_encrypted"
local KEY_NAME = "FuguHub-MCP-Token"

local function optionValue(app)
   local row = db.readOne(app, "SELECT value FROM options WHERE key=" .. db.quote(OPTION_KEY))
   return row and row.value or nil
end

local function encryptionKey()
   local unique = ba.tpm.uniquekey(KEY_NAME, 32)
   return ba.crypto.hash"sha256"(unique)(true)
end

local function encrypt(token)
   local iv = ba.rndbs(12)
   local cipher, tag = ba.crypto.symmetric("GCM", encryptionKey(), iv):encrypt(token)
   return table.concat({
      "v1",
      ba.b64urlencode(iv),
      ba.b64urlencode(tag),
      ba.b64urlencode(cipher)
   }, ":")
end

local function decrypt(encoded)
   if type(encoded) ~= "string" then return nil, "encrypted MCP token is missing" end
   local version, ivText, tagText, cipherText = encoded:match("^([^:]+):([^:]+):([^:]+):([^:]+)$")
   if version ~= "v1" then return nil, "encrypted MCP token has an unsupported format" end
   local iv = ba.b64decode(ivText)
   local tag = ba.b64decode(tagText)
   local cipher = ba.b64decode(cipherText)
   if not iv or #iv ~= 12 or not tag or not cipher then
      return nil, "encrypted MCP token is corrupt"
   end
   local token = ba.crypto.symmetric("GCM", encryptionKey(), iv):decrypt(cipher, tag)
   if not token or token == "" then return nil, "encrypted MCP token cannot be decrypted" end
   return token
end

local function validateToken(token)
   token = validation.trim(token)
   if #token < 16 then return nil, "MCP token must contain at least 16 characters" end
   if #token > 4096 then return nil, "MCP token is too long" end
   if token:find("[%z\r\n]") then return nil, "MCP token contains invalid characters" end
   return token
end

M.validate = validateToken

function M.secureEqual(a, b)
   a, b = tostring(a or ""), tostring(b or "")
   local length = math.max(#a, #b, 32)
   local different = (#a == #b) and 0 or 1
   for index = 1, length do
      if (a:byte(index) or 0) ~= (b:byte(index) or 0) then
         different = different + 1
      end
   end
   return different == 0
end

function M.load(app)
   local encoded = optionValue(app)
   if not encoded or encoded == "" then
      app.mcpToken = nil
      app.mcpTokenError = nil
      return nil
   end
   local ok, token, err = pcall(decrypt, encoded)
   if not ok then
      err = token
      token = nil
   end
   app.mcpToken = token
   app.mcpTokenError = err
   if not token then
      mako.log("FuguHub MCP token load failed: " .. tostring(err), "cms-mcp")
   end
   return token, err
end

function M.set(app, token)
   local valid, err = validateToken(token)
   if not valid then return nil, err end
   local ok, encoded = pcall(encrypt, valid)
   if not ok then return nil, tostring(encoded) end
   db.withWrite(app, function(conn)
      local saved, saveErr = conn:execute("INSERT OR REPLACE INTO options(key,value) VALUES(" ..
         db.quote(OPTION_KEY) .. "," .. db.quote(encoded) .. ")")
      if not saved then error("Saving MCP token failed: " .. tostring(saveErr), 2) end
   end)
   app.mcpToken = valid
   app.mcpTokenError = nil
   return true
end

function M.disable(app)
   db.withWrite(app, function(conn)
      local ok, err = conn:execute("DELETE FROM options WHERE key=" .. db.quote(OPTION_KEY))
      if not ok then error("Removing MCP token failed: " .. tostring(err), 2) end
   end)
   app.mcpToken = nil
   app.mcpTokenError = nil
   return true
end

function M.enabled(app)
   return type(app.mcpToken) == "string" and app.mcpToken ~= ""
end

return M
