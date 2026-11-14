<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local id = tonumber(request:data("id") or admin.requestData(_ENV).id)
local fullPage = adminCategoryDelete ~= nil
local row = adminCategoryDelete or id and admin.categoryRow(app, id)
if not row then
   response:senderror(404, "Category not found")
   return
end
if request:method() == "POST" then
   local data = admin.requestData(_ENV)
   if tostring(data.confirmed) ~= "true" then
      response:senderror(400, "Deletion was not confirmed")
      return
   end
   admin.deleteCategory(app, id)
   adminCategoriesOob = false
   response:include(app.url("/admin/categories/list.lsp"), true)
   return
end
local esc = admin.html
?>
<?lsp if fullPage then ?>
<section class="panel danger-zone"><div class="panel-body"><h2>Delete Category</h2>
<?lsp else ?>
<section class="inline-confirmation" role="alert">
<?lsp end ?>
   <strong>Delete <?lsp= esc(row.name) ?>?</strong>
   <p><?lsp= esc(row.assignmentCount) ?> content assignments will be removed. Posts are not deleted.</p>
   <form method="post" action="<?lsp= esc(app.url('/admin/categories/delete?id=' .. id)) ?>"
         <?lsp if not fullPage then ?>
         hx-post="<?lsp= esc(app.url('/admin/categories/delete.lsp')) ?>"
         hx-target="#categories-list" hx-swap="outerHTML"<?lsp end ?>>
      <?lsp admin.csrfField(_ENV) ?>
      <input type="hidden" name="id" value="<?lsp= esc(id) ?>">
      <input type="hidden" name="confirmed" value="true">
      <div class="actions">
         <button class="danger" type="submit">Delete Category</button>
         <a class="button secondary" href="<?lsp= esc(app.url('/admin/categories/')) ?>"
            <?lsp if not fullPage then ?>
            hx-get="<?lsp= esc(app.url('/admin/categories/list.lsp')) ?>"
            hx-target="#categories-list" hx-swap="outerHTML"<?lsp end ?>>Cancel</a>
      </div>
   </form>
<?lsp if fullPage then ?></div><?lsp end ?>
</section>
