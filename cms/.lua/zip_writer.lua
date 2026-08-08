-- Emits bounded classic ZIP32 archives using method 0 (stored) or method 8 (DEFLATE).
local M={}

local function makeBitOps()
   local native=load([[
return {
  bxor=function(a,b) return (a ~ b) & 0xffffffff end,
  rshift=function(a,n) return (a >> n) & 0xffffffff end
}
]])
   if native then
      local ok,ops=pcall(native)
      if ok and ops then return ops end
   end
   if bit32 and bit32.bxor and bit32.rshift then return bit32 end
   if bit and bit.bxor and bit.rshift then return bit end
   local function bxor(a,b)
      local result,bitValue=0,1
      a,b=a%0x100000000,b%0x100000000
      for _=1,32 do
         if a%2 ~= b%2 then result=result+bitValue end
         a,b=math.floor(a/2),math.floor(b/2)
         bitValue=bitValue*2
      end
      return result
   end
   return {bxor=bxor,rshift=function(a,n) return math.floor((a%0x100000000)/(2^n)) end}
end

local bit=makeBitOps()
local function u16(value)
   value=value%0x10000
   return string.char(value%0x100,math.floor(value/0x100)%0x100)
end
local function u32(value)
   value=value%0x100000000
   return string.char(value%0x100,math.floor(value/0x100)%0x100,
      math.floor(value/0x10000)%0x100,math.floor(value/0x1000000)%0x100)
end

local function dosDateTime(mtime,fallback)
   local value=tonumber(mtime) or tonumber(fallback) or os.time()
   local ok,date=pcall(os.date,"*t",math.floor(value))
   if not ok or type(date) ~= "table" then date=nil end
   local sourceYear=date and tonumber(date.year) or nil
   if not sourceYear or sourceYear < 1980 then
      date={year=1980,month=1,day=1,hour=0,min=0,sec=0}
   elseif sourceYear > 2107 then
      date={year=2107,month=12,day=31,hour=23,min=59,sec=58}
   end
   local year=math.floor(tonumber(date.year) or 1980)
   local month=math.floor(tonumber(date.month) or 1)
   local day=math.floor(tonumber(date.day) or 1)
   local hour=math.floor(tonumber(date.hour) or 0)
   local minute=math.floor(tonumber(date.min) or 0)
   local second=math.floor(tonumber(date.sec) or 0)
   local dosTime=hour*0x800+minute*0x20+math.floor(second/2)
   local dosDate=(year-1980)*0x200+month*0x20+day
   return dosTime,dosDate
end

local crcTable
local function buildCrcTable()
   local table32={}
   for index=0,255 do
      local crc=index
      for _=1,8 do
         crc=crc%2 == 1 and bit.bxor(bit.rshift(crc,1),0xEDB88320) or bit.rshift(crc,1)
      end
      table32[index]=crc
   end
   return table32
end

local function crcUpdate(crc,data)
   crcTable=crcTable or buildCrcTable()
   for index=1,#data do
      local byte=string.byte(data,index)
      crc=bit.bxor(bit.rshift(crc,8),crcTable[bit.bxor(crc,byte)%256])
   end
   return crc
end

local function crc32(data)
   return bit.bxor(crcUpdate(0xFFFFFFFF,data),0xFFFFFFFF)%0x100000000
end

local function normalizedPath(path,directory)
   path=tostring(path or ""):gsub("\\","/")
   assert(not path:find("%z"),"ZIP entry path must not contain NUL bytes")
   assert(not path:match("^/"),"ZIP entry path must be relative")
   assert(not path:match("^[A-Za-z]:"),"ZIP entry path must not contain a drive prefix")
   assert(not path:match("^//"),"ZIP entry path must not contain a UNC prefix")
   directory=directory == true or path:sub(-1) == "/"
   path=path:gsub("/+$","")
   assert(path ~= "","ZIP entry path is required")
   local depth=0
   for part in path:gmatch("[^/]+") do
      assert(part ~= "..","ZIP entry path must not contain a parent segment")
      assert(part ~= ".","ZIP entry path must not contain a current-directory segment")
      assert(part ~= "","ZIP entry path must not contain an empty segment")
      depth=depth+1
   end
   return path,directory,depth
end

local function sortedEntries(files,options)
   local sorted,seen={},{}
   local maxEntries=options.maxEntries or 4096
   assert(#(files or {}) <= maxEntries,"ZIP entry count exceeds limit of "..maxEntries)
   for _,file in ipairs(files or {}) do
      local path,directory,depth=normalizedPath(file.path,file.directory)
      assert(depth <= (options.maxDepth or 32),"ZIP entry nesting exceeds configured limit: "..path)
      local key=path:lower()
      assert(not seen[key],"duplicate ZIP entry path: "..path)
      seen[key]=true
      sorted[#sorted+1]={
         path=path,
         directory=directory,
         content=file.content,
         producer=file.producer,
         source=file.source,
         mtime=file.mtime
      }
   end
   table.sort(sorted,function(a,b) return a.path < b.path end)
   return sorted
end

local function emitEntry(entry,output)
   if entry.directory then return end
   if type(entry.producer) == "function" then return entry.producer(output) end
   if type(entry.source) == "table" then
      local source,err=entry.source.io:open(entry.source.path,"rb")
      assert(source,"cannot open ZIP source "..tostring(entry.source.path)..": "..tostring(err))
      local readOk,readErr=pcall(function()
         while true do
            local chunk,chunkErr=source:read(16384)
            if chunk and #chunk > 0 then
               output(chunk)
            elseif chunkErr then
               error("cannot read ZIP source "..tostring(entry.source.path)..": "..tostring(chunkErr),0)
            else
               break
            end
         end
      end)
      local closeOk,closeErr=source:close()
      if not readOk then error(readErr,0) end
      assert(closeOk,"cannot close ZIP source: "..tostring(closeErr))
      return
   end
   output(tostring(entry.content or ""))
end

local function measure(entry,maxEntryBytes,maxCompressionBytes)
   local crc,size=0xFFFFFFFF,0
   local chunks=maxCompressionBytes and {} or nil
   emitEntry(entry,function(chunk)
      assert(type(chunk) == "string","ZIP producer must emit string chunks")
      local nextSize=size+#chunk
      if chunks and nextSize <= maxCompressionBytes then
         chunks[#chunks+1]=chunk
      else
         chunks=nil
      end
      size=nextSize
      assert(size <= maxEntryBytes,"ZIP entry exceeds size limit: "..entry.path)
      crc=crcUpdate(crc,chunk)
   end)
   return bit.bxor(crc,0xFFFFFFFF)%0x100000000,size,chunks
end

local function writeInternal(files,output,options)
   assert(type(output) == "function","ZIP output callback is required")
   options=options or {}
   local maxEntryBytes=options.maxEntryBytes or 64*1024*1024
   local maxArchiveBytes=options.maxArchiveBytes or 64*1024*1024
   local compress=options.compress == true
   local maxCompressionBytes=options.maxCompressionBytes or maxEntryBytes
   local deflate
   if compress then
      deflate=type(ba) == "table" and ba.deflate or nil
      assert(type(deflate) == "function",
         "ZIP compression requires ba.deflate (BAS must include zlib support)")
   end
   local defaultMtime=tonumber(options.mtime) or os.time()
   local central,offset,total={},0,0
   local storedCount,compressedCount=0,0
   local function emit(data)
      total=total+#data
      assert(total <= maxArchiveBytes,"ZIP archive exceeds size limit of "..maxArchiveBytes.." bytes")
      local ok,err=output(data)
      assert(ok ~= false,"ZIP output failed: "..tostring(err))
   end

   local entries=sortedEntries(files,options)
   assert(#entries <= 65535,"ZIP32 entry limit exceeded")
   for _,entry in ipairs(entries) do
      local name=entry.path..(entry.directory and "/" or "")
      assert(#name <= 65535,"ZIP entry name is too long")
      local crc,size,chunks=measure(entry,maxEntryBytes,
         compress and not entry.directory and maxCompressionBytes or nil)
      local method,compressedSize,compressedData=0,size,nil
      if chunks then
         local candidate
         if size == 0 then
            candidate=deflate("",false)
         else
            candidate=deflate(chunks,false)
         end
         assert(type(candidate) == "string","ba.deflate did not return compressed data")
         assert(#candidate < 0x100000000,"ZIP32 compressed size limit exceeded")
         if #candidate < size then
            method,compressedSize,compressedData=8,#candidate,candidate
         end
      end
      local dosTime,dosDate=dosDateTime(entry.mtime,defaultMtime)
      assert(size < 0x100000000 and compressedSize < 0x100000000 and
         offset < 0x100000000,"ZIP32 size or offset limit exceeded")
      local header=table.concat({
         u32(0x04034B50),u16(20),u16(0),u16(method),u16(dosTime),u16(dosDate),
         u32(crc),u32(compressedSize),u32(size),u16(#name),u16(0),name
      })
      emit(header)
      if compressedData then
         emit(compressedData)
         compressedCount=compressedCount+1
      elseif chunks then
         for _,chunk in ipairs(chunks) do emit(chunk) end
         storedCount=storedCount+1
      else
         local emittedCrc,emittedSize=0xFFFFFFFF,0
         emitEntry(entry,function(chunk)
            assert(type(chunk) == "string","ZIP producer must emit string chunks")
            emittedCrc=crcUpdate(emittedCrc,chunk)
            emittedSize=emittedSize+#chunk
            emit(chunk)
         end)
         emittedCrc=bit.bxor(emittedCrc,0xFFFFFFFF)%0x100000000
         assert(emittedSize == size and emittedCrc == crc,"ZIP entry changed between reads: "..name)
         storedCount=storedCount+1
      end
      central[#central+1]=table.concat({
         u32(0x02014B50),u16(20),u16(20),u16(0),u16(method),u16(dosTime),u16(dosDate),
         u32(crc),u32(compressedSize),u32(size),u16(#name),u16(0),u16(0),u16(0),u16(0),
         u32(entry.directory and 0x10 or 0),u32(offset),name
      })
      offset=offset+#header+compressedSize
   end
   local centralBody=table.concat(central)
   emit(centralBody)
   emit(table.concat({
      u32(0x06054B50),u16(0),u16(0),u16(#central),u16(#central),
      u32(#centralBody),u32(offset),u16(0)
   }))
   return {
      entryCount=#entries,
      size=total,
      stored=compressedCount == 0,
      compressed=compressedCount > 0,
      storedCount=storedCount,
      compressedCount=compressedCount,
      zip64=false
   }
end

function M.write(files,output,options)
   local ok,result=pcall(writeInternal,files,output,options)
   if ok then return result end
   return nil,tostring(result)
end

function M.encode(files,options)
   local chunks={}
   local info,err=M.write(files,function(chunk) chunks[#chunks+1]=chunk return true end,options)
   if not info then return nil,err end
   return table.concat(chunks),info
end

M._crc32=crc32
M._normalizePath=normalizedPath
M._dosDateTime=dosDateTime

return M
