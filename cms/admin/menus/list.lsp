<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local items = admin.menuTreeItems(app)
response:include(app.url("/admin/menus/item-template.lsp"), true)
?>
<div id="menu-items"<?lsp if adminMenuOob then ?> hx-swap-oob="outerHTML"<?lsp end ?>>
<?lsp
for _, row in ipairs(items) do
   local message = tonumber(adminMenuMessageId) == tonumber(row.id) and adminMenuMessage or nil
   adminRenderMenuItem(row, message)
end
?>
</div>
