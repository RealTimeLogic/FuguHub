local M = {}

local deniedTags = {
   applet = true,
   base = true,
   embed = true,
   iframe = true,
   link = true,
   math = true,
   meta = true,
   object = true,
   script = true,
   style = true,
   svg = true
}

local urlAttributes = {
   action = true,
   background = true,
   cite = true,
   data = true,
   formaction = true,
   href = true,
   longdesc = true,
   poster = true,
   src = true,
   usemap = true,
   ["xlink:href"] = true
}

local allowedSchemes = {
   http = true,
   https = true,
   mailto = true,
   tel = true
}

local function decodeEntity(entity)
   local number = entity:match("^#(%d+)$")
   if not number then
      local hex = entity:match("^#[xX]([%da-fA-F]+)$")
      if hex then number = tonumber(hex, 16) end
   else
      number = tonumber(number)
   end
   if number and number >= 0 and number <= 255 then
      return string.char(number)
   end
   local named = {
      amp = "&",
      apos = "'",
      colon = ":",
      gt = ">",
      lt = "<",
      nbsp = " ",
      quot = '"',
      tab = "\t",
      newline = "\n"
   }
   return named[entity:lower()]
end

local function normalizedUrl(value)
   value = tostring(value or ""):gsub("&([^;]+);", function(entity)
      return decodeEntity(entity) or "&" .. entity .. ";"
   end)
   return value:gsub("[%z\1-\32\127]", ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
end

local function unsafeUrl(value)
   local normalized = normalizedUrl(value)
   local scheme = normalized:match("^([a-z][a-z0-9+%.%-]*):")
   if scheme and not allowedSchemes[scheme] then
      return scheme
   end
end

local function parseStartTag(body, startAt)
   local length = #body
   local index = startAt + 1
   local first = body:sub(index, index)
   if first == "/" or first == "!" or first == "?" then return nil end
   local nameStart = index
   while index <= length and body:sub(index, index):match("[%w:_%-]") do
      index = index + 1
   end
   if index == nameStart then return nil end
   local tag = body:sub(nameStart, index - 1):lower()
   local attributes = {}

   while index <= length do
      local char = body:sub(index, index)
      if char:match("%s") then
         index = index + 1
      elseif char == ">" then
         return { tag = tag, attributes = attributes, nextAt = index + 1 }
      elseif char == "/" and body:sub(index + 1, index + 1) == ">" then
         return { tag = tag, attributes = attributes, nextAt = index + 2 }
      else
         local attrStart = index
         while index <= length and not body:sub(index, index):match("[%s=/>]") do
            index = index + 1
         end
         if index == attrStart then return nil, "Malformed attribute on <" .. tag .. ">" end
         local attrName = body:sub(attrStart, index - 1):lower()
         while index <= length and body:sub(index, index):match("%s") do index = index + 1 end
         local value = ""
         if body:sub(index, index) == "=" then
            index = index + 1
            while index <= length and body:sub(index, index):match("%s") do index = index + 1 end
            local quote = body:sub(index, index)
            if quote == '"' or quote == "'" then
               local valueStart = index + 1
               index = valueStart
               while index <= length and body:sub(index, index) ~= quote do index = index + 1 end
               if index > length then return nil, "Unterminated attribute value on <" .. tag .. ">" end
               value = body:sub(valueStart, index - 1)
               index = index + 1
            else
               local valueStart = index
               while index <= length and not body:sub(index, index):match("[%s>]") do index = index + 1 end
               value = body:sub(valueStart, index - 1)
               if value == "" then return nil, "Missing attribute value on <" .. tag .. ">" end
            end
         end
         attributes[#attributes + 1] = { name = attrName, value = value }
      end
   end
   return nil, "Unterminated <" .. tag .. "> element"
end

function M.inspect(body)
   body = tostring(body or "")
   local tags, urls = {}, {}
   local index, length = 1, #body
   while index <= length do
      local open = body:find("<", index, true)
      if not open then break end
      if body:sub(open, open + 8):lower():match("^<!doctype") then
         return nil, "Content must be an HTML fragment, not a complete HTML document"
      elseif body:sub(open, open + 3) == "<!--" then
         local close = body:find("-->", open + 4, true)
         if not close then return nil, "Unterminated HTML comment" end
         index = close + 3
      elseif body:sub(open, open + 4):lower() == "<?lsp" then
         local close = body:find("?>", open + 5, true)
         if not close then return nil, "Unterminated LSP tag" end
         index = close + 2
      else
         local parsed, err = parseStartTag(body, open)
         if err then return nil, err end
         if not parsed then
            local close = body:find(">", open + 1, true)
            if not close then return nil, "Unterminated HTML markup" end
            index = close + 1
         else
            tags[#tags + 1] = parsed.tag
            if parsed.tag == "html" or parsed.tag == "head" or parsed.tag == "body" then
               return nil, "Content must be an HTML fragment, not a complete HTML document"
            end
            if deniedTags[parsed.tag] then
               return nil, "<" .. parsed.tag .. "> elements are not allowed in CMS content"
            end
            for _, attribute in ipairs(parsed.attributes) do
               if attribute.name:match("^on[%w_:%-]*$") then
                  return nil, "Inline event-handler attribute " .. attribute.name ..
                     " is not allowed on <" .. parsed.tag .. ">"
               end
               if attribute.name == "srcdoc" then
                  return nil, "Embedded srcdoc content is not allowed on <" .. parsed.tag .. ">"
               end
               if urlAttributes[attribute.name] then
                  local scheme = unsafeUrl(attribute.value)
                  if scheme then
                     return nil, "Unsafe " .. attribute.name .. " URL scheme " ..
                        scheme .. " on <" .. parsed.tag .. ">"
                  end
                  urls[#urls + 1] = {
                     attribute = attribute.name,
                     value = attribute.value,
                     tag = parsed.tag
                  }
               end
            end
            index = parsed.nextAt
         end
      end
   end
   return { tags = tags, urls = urls }
end

return M
