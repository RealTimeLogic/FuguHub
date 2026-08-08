<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local data = admin.requestData(_ENV)
local row
for _, candidate in ipairs(admin.menuTreeItems(app)) do
   if tonumber(candidate.id) == tonumber(data.id) then
      row = candidate
      break
   end
end
if not row then
   response:senderror(404, "Menu item not found")
   return
end
response:include(app.url("/admin/menus/item-template.lsp"), true)
adminRenderMenuItem(row)
?>
