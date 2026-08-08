<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local categories = admin.categoryRows(app)
response:include(app.url("/admin/categories/row-template.lsp"), true)
?>
<div id="categories-list"<?lsp if adminCategoriesOob then ?> hx-swap-oob="outerHTML"<?lsp end ?>>
<?lsp if #categories == 0 then ?>
   <div class="empty-state">No blog categories have been created.</div>
<?lsp else ?>
   <?lsp
   for _, row in ipairs(categories) do
      local message = tonumber(adminCategoryMessageId) == tonumber(row.id) and adminCategoryMessage or nil
      adminRenderCategory(row, message)
   end
   ?>
<?lsp end ?>
</div>
