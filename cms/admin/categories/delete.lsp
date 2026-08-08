<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local id = tonumber(request:data("id") or admin.requestData(_ENV).id)
local row = id and admin.categoryRow(app, id)
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
<section class="inline-confirmation" role="alert">
   <strong>Delete <?lsp= esc(row.name) ?>?</strong>
   <p><?lsp= esc(row.assignmentCount) ?> content assignments will be removed. Posts are not deleted.</p>
   <form method="post" action="<?lsp= esc(app.url('/admin/categories/delete?id=' .. id)) ?>"
         hx-post="<?lsp= esc(app.url('/admin/categories/delete.lsp')) ?>"
         hx-target="#categories-list" hx-swap="outerHTML">
      <?lsp admin.csrfField(_ENV) ?>
      <input type="hidden" name="id" value="<?lsp= esc(id) ?>">
      <input type="hidden" name="confirmed" value="true">
      <div class="actions">
         <button class="danger" type="submit">Delete Category</button>
         <a class="button secondary" href="<?lsp= esc(app.url('/admin/categories/')) ?>"
            hx-get="<?lsp= esc(app.url('/admin/categories/list.lsp')) ?>"
            hx-target="#categories-list" hx-swap="outerHTML">Cancel</a>
      </div>
   </form>
</section>
