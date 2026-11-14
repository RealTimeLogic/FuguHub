
local function textEncoding(txt, charset)
   charset=(charset or "utf-8"):lower()
   if charset~="utf-8" and charset~="us-ascii" then
      error("unsupported EML charset; re-save the template as UTF-8", 0)
   end
   if txt and not utf8.len(txt) then
      error("invalid UTF-8 text; re-save the template as UTF-8", 0)
   end
   return txt
end

local function decodeText(txt, cte, charset)
   local function noaction(txt) return txt end
   local function decodeQP(txt)
      -- The parser canonicalizes message structure to LF, but quoted-printable
      -- soft wraps are defined on CRLF. Rebuild canonical line endings only
      -- for transfer decoding, then convert back to LF for the rest of the code.
      local canonical = (txt or ""):gsub("\n", "\r\n")
      local decoded = mime.unqp(canonical)
      return decoded and decoded:gsub("\r\n", "\n")
   end
   local t={
      ["7bit"]=noaction,
      ["8bit"]=noaction,
      binary=noaction,
      ["utf-8"]=noaction,
      ["quoted-printable"]=decodeQP,
      base64=ba.b64decode
   }
   local decoder=t[cte]
   if decoder then
      return textEncoding(decoder(txt), charset)
   end
   error("unsupported Content-Transfer-Encoding", 0)
end

local function decodeSubject(subject)
   local parts,previous={},1
   for first,charset,encoding,value,last in subject:gmatch("()=%?([^?]+)%?([bBqQ])%?([^?]*)%?=()") do
      local between=subject:sub(previous,first-1)
      -- RFC 2047 ignores folding whitespace between adjacent encoded words.
      if previous==1 or not between:match("^%s*$") then parts[#parts+1]=between end
      if encoding:lower()=="q" then
         value=value:gsub("_"," ")
         value=mime.unqp(value)
      else
         value=ba.b64decode(value)
      end
      parts[#parts+1]=assert(textEncoding(value,charset),"invalid encoded subject")
      previous=last
   end
   parts[#parts+1]=subject:sub(previous)
   local decoded=table.concat(parts)
   if decoded:find('[%z\r\n]') then error("invalid encoded subject", 0) end
   return textEncoding(decoded)
end

local function emsg(data)
   -- Parse message structure using LF internally.
   local ok,m=pcall(require'eml/Decoder', (data:gsub("\r\n","\n")))
   if not ok then return nil,"invalid MIME structure" end
   local htmlbody,txtbody
   local htmlimg={}
   local subjectHeader=m.header["subject"]
   local subject=subjectHeader and subjectHeader.value or nil

   local function extract(m)
      local disposition=m.header["content-disposition"]
      if disposition and disposition.value:lower()=="attachment" then return end
      if type(m.content) == 'string' then
         local header={}
         for _,h in ipairs(m.header) do
            header[h.key]=h
         end
         local cte=header["content-transfer-encoding"]
         cte=(cte and cte.value or "7bit"):lower()
         local contentType=header["content-type"]
         local charset=contentType and contentType.parameter.charset
         local cid=header["content-id"]
         if cid and m.type~="text/html" and m.type~="text/plain" then
            cid=cid.value:gsub('<?([^>]-)>?','%1')
            if cte =="base64" then
               local content=ba.b64decode(m.content)
               if content then
                  table.insert(htmlimg,{id=cid,source=content,content=m.type})
               end
            end
         elseif m.type=="text/html" and not htmlbody then
            htmlbody=decodeText(m.content,cte,charset)
         elseif m.type=="text/plain" and not txtbody then
            txtbody=decodeText(m.content,cte,charset)
         end
      elseif type(m.content) == 'table' then
         for _,mm in ipairs(m.content) do
            extract(mm)
         end
      end
   end
   local ok,err=pcall(function()
      subject=decodeSubject(subject or "")
      extract(m)
   end)
   if ok then
      if not htmlbody and not txtbody then return nil,"no body" end
      return {
         subject=subject,
         htmlbody=htmlbody,
         txtbody=txtbody,
         htmlimg=#htmlimg > 0 and htmlimg or nil,
         charset="UTF-8"
      }
   end
   return nil,"invalid MIME content: "..tostring(err)
end

return emsg
