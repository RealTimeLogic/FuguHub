local M = {}

function M.html(value)
   value = tostring(value or "")
   value = value:gsub("&", "&amp;")
   value = value:gsub("<", "&lt;")
   value = value:gsub(">", "&gt;")
   value = value:gsub('"', "&quot;")
   value = value:gsub("'", "&#39;")
   return value
end

M.htmlAttr = M.html

return M
