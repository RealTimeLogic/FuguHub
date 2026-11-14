--------------------------------------------------------------------------------
-- MIMEHeader
--------------------------------------------------------------------------------

local _M={}

local self = setmetatable( _M, {} )
local meta = getmetatable( self )

local function Trim( aString )
    if aString ~= nil then
        aString = aString:gsub( '^[%c%s]*', '' )
        aString = aString:gsub( '[%s%c]*$', '' )
    end
    
    return aString
end

local function ReadKey( aValue )
    local anIndex = aValue:find( ':', 1, true ) or ( aValue:len() + 1 )
    local aKey = aValue:sub( 1, anIndex - 1 ):lower()
    
    return Trim( aKey )
end

local function ReadParameter( aValue )
    local aParameter = {}
    local pos = aValue:find(';', 1, true)
    while pos do
        local first, last, key = aValue:find('^;%s*([^%s=;]+)%s*=%s*', pos)
        if not first then error('invalid MIME parameter', 0) end
        pos = last + 1
        local value
        if aValue:sub(pos, pos) == '"' then
            last = pos
            repeat
                last = aValue:find('[\\"]', last + 1)
                if not last then error('unterminated MIME parameter', 0) end
                if aValue:sub(last, last) == '"' then break end
                last = last + 1 -- Skip a quoted-pair, including an escaped quote.
            until false
            value = aValue:sub(pos + 1, last - 1):gsub('\\(.)', '%1')
            pos = last + 1
        else
            last = aValue:find(';', pos, true) or (#aValue + 1)
            value = Trim(aValue:sub(pos, last - 1))
            pos = last
        end
        aParameter[key:lower()] = value
        pos = aValue:find(';', pos, true)
    end
    
    return aParameter
end

local function ReadHeader( aValue )
    local aHeaderKey = ReadKey( aValue )
    local aHeaderValue = Trim(aValue:match('^[^:]*:(.*)$') or '')
    local aHeaderParameter = {}
    if aHeaderKey == 'content-type' or aHeaderKey == 'content-disposition' then
        aHeaderParameter = ReadParameter(aHeaderValue)
        aHeaderValue = Trim(aHeaderValue:match('^[^;]*'))
    end
    local aHeader = { key = aHeaderKey, value = aHeaderValue, parameter = aHeaderParameter }

    return aHeader
end

local function NewHeader( aValue )
    local aHeader = nil
    
    if type( aValue ) == 'table' then
        aHeader = ReadHeader( WriteHeader( aValue ) )
    else
        aHeader = ReadHeader( tostring( aValue or '' ) )
    end
    
    setmetatable( aHeader, self )
    
    return aHeader
end

function meta:__call( aValue )
    return NewHeader( aValue )
end

function self:__concat( aValue )
    return tostring( self ) .. tostring( aValue )
end

function self:__eq( aValue )
    return tostring( self ) == tostring( aValue )
end

function self:__lt( aValue )
    return tostring( self ) < tostring( aValue )
end

function self:__tostring()
    return 'WriteHeader' --WriteHeader( self )
end

return _M
