-- Strip internal Lua locations before displaying validation or service errors.
return function(value)
   local message = tostring(value or "Request failed")
   while true do
      local cleaned = message:match("^.-%.lua:%d+:%s*(.*)$")
      if not cleaned or cleaned == message then return message end
      message = cleaned
   end
end
