<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local data = admin.requestData(_ENV)
local row = admin.contentRow(app, data.id)
if not row then
   response:senderror(404, "Content not found")
   return
end
response:include(app.url("/admin/content/row-template.lsp"), true)
adminRenderContentRow(row)
?>
