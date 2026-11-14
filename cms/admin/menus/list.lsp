<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local items = adminMenuItems or admin.menuTreeItems(app)
response:include(app.url("/admin/menus/item-template.lsp"), true)
?>
<div id="menu-items"<?lsp if adminMenuOob then ?> hx-swap-oob="outerHTML"<?lsp end ?>>
<?lsp
for _, row in ipairs(items) do
   local message = tonumber(adminMenuMessageId) == tonumber(row.id) and adminMenuMessage or nil
   if message and adminMenuDraft then
      local draft = {}
      for key, value in pairs(row) do draft[key] = value end
      for _, key in ipairs({ "label", "url", "position" }) do
         draft[key] = adminMenuDraft[key] or row[key]
      end
      draft.parent_id = adminMenuDraft.parent_id
      row = draft
   end
   adminRenderMenuItem(row, message, items, message and adminMenuError)
end
?>
</div>
<?lsp if admin.isHtmx(_ENV) then adminRenderMenuParent(items, nil, true) end ?>
