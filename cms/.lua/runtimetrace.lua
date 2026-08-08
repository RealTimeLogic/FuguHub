local M = {}

function M.create(defaultBufferSize)
   local segments = {}
   local head, tail, bytes = 1, 0, 0
   local limit = math.max(0, math.floor(tonumber(defaultBufferSize) or 0))
   local overflowed, droppedBytes = false, 0
   local traceBuffer = {}

   local function clear()
      segments = {}
      head, tail, bytes = 1, 0, 0
      overflowed, droppedBytes = false, 0
   end

   local function count()
      return tail >= head and tail - head + 1 or 0
   end

   local function trim()
      if limit <= 0 then clear() return end
      while bytes > limit and head <= tail do
         local oldest = segments[head] or ""
         local remaining = bytes - #oldest
         if remaining >= limit or #oldest == 0 then
            segments[head] = nil
            head = head + 1
            bytes = remaining
            overflowed = true
            droppedBytes = droppedBytes + #oldest
         else
            local keep = limit - remaining
            segments[head] = oldest:sub(#oldest - keep + 1)
            bytes = remaining + keep
            overflowed = true
            droppedBytes = droppedBytes + #oldest - keep
            break
         end
      end
   end

   function traceBuffer.record(data)
      if limit <= 0 then return false end
      data = tostring(data or "")
      if data == "" then return true end
      if #data > limit then
         overflowed = true
         droppedBytes = droppedBytes + #data - limit
         data = data:sub(#data - limit + 1)
      end
      tail = tail + 1
      segments[tail] = data
      bytes = bytes + #data
      trim()
      return true
   end

   function traceBuffer.read()
      local data = {
         trace = count() > 0 and table.concat(segments, "", head, tail) or "",
         bytes = bytes,
         messageCount = count(),
         bufferSize = limit,
         overflowed = overflowed,
         truncated = overflowed,
         droppedBytes = droppedBytes,
         enabled = limit > 0,
         cleared = true,
         scope = "server-global",
         cmsAttributionReliable = false
      }
      clear()
      return data
   end

   function traceBuffer.setBufferSize(size)
      limit = math.max(0, math.floor(tonumber(size) or 0))
      if limit <= 0 then clear() else trim() end
      return limit
   end

   return traceBuffer
end

return M
