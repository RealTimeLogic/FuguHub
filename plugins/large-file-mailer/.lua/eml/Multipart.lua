
--------------------------------------------------------------------------------
-- MIMEMultipart
--------------------------------------------------------------------------------

local _M={}

local self = setmetatable( _M, {} )
local meta = getmetatable( self )

local function ReadBoundary( aHeader )
   local aType = aHeader[ 'content-type' ] or {}
   local aParameter = aType.parameter or {}
   local aBoundary = aParameter[ 'boundary' ]
   
   return aBoundary
end

local function ReadMultipart( aValue, aBoundary )
   local MIME = require( 'eml/Decoder' )
   local aMultipart = { boundary = aBoundary }
   if not aBoundary or aBoundary == '' then error('missing MIME boundary', 0) end
   local aBoundary = '--' .. aBoundary
   local aStart = 1
   local partStart
   
   while true do
      local anEnd = aValue:find('\n', aStart, true) or (#aValue + 1)
      local line = aValue:sub(aStart, anEnd - 1)
      local suffix = line:sub(#aBoundary + 1)
      if line:sub(1, #aBoundary) == aBoundary and
         (suffix:match('^[ \t]*$') or suffix:match('^%-%-[ \t]*$')) then
         if partStart then
            -- The LF before a delimiter belongs to the delimiter, not the part.
            aMultipart[#aMultipart + 1] = MIME(aValue:sub(partStart, aStart - 2))
         end
         if suffix:sub(1, 2) == '--' then return aMultipart end
         partStart = anEnd + 1
      end
      if anEnd > #aValue then break end
      aStart = anEnd + 1
   end
   error('incomplete MIME multipart', 0)
end

local function NewMultipart( aValue, aHeader )
   local aMultipart = nil
   
   if type( aValue ) == 'table' then
      aMultipart = ReadMultipart( WriteMultipart( aValue ), aValue.boundary )
   else
      aMultipart = ReadMultipart( tostring( aValue or '' ), ReadBoundary( aHeader ) )
   end
   
   setmetatable( aMultipart, self )
   
   return aMultipart
end

function meta:__call( aValue, aHeader )
   return NewMultipart( aValue, aHeader )
end

function self:__concat( aValue )
   return tostring( self ) .. tostring( aValue )
end

function self:__tostring()
   return 'WriteMultipart' --WriteMultipart( self )
end

return _M
