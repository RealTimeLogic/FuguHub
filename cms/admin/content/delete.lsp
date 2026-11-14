<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html
local data = admin.requestData(_ENV)
local id = tonumber(data.id)
local fullPage = adminContentDelete ~= nil
local dependencies, dependencyErr = adminContentDelete
if not dependencies then dependencies, dependencyErr = admin.contentDependencies(app, id) end
if not dependencies then
   response:senderror(404, dependencyErr or "Content not found")
   return
end

if request:method() == "POST" then
   local ok, err = pcall(admin.deleteContent, app, data, dependencies)
   if ok then
      response:write("<!-- content deleted -->")
      return
   end
   local message
   if type(err) == "table" and err.cmsValidation then
      message = err.message
   else
      trace("admin content delete failed:", tostring(err))
      message = "Delete failed. See the server trace for details."
   end
?>
<tr id="content-row-<?lsp= esc(id) ?>"><td colspan="8"><div class="notice error"><?lsp= esc(message) ?></div></td></tr>
<?lsp return end ?>
<?lsp if fullPage then ?>
<section class="panel danger-zone"><div class="panel-body">
<?lsp else ?>
<tr id="content-row-<?lsp= esc(id) ?>">
   <td colspan="8">
      <div class="inline-confirmation">
<?lsp end ?>
         <h2>Delete Permanently</h2>
         <p>This will permanently delete <strong><?lsp= esc(dependencies.content.title) ?></strong>
            at <code><?lsp= esc(dependencies.content.path) ?></code>. There is no trash or restore feature.</p>
         <?lsp if dependencies.activeNotFoundPage then ?>
         <div class="notice error">The active editable 404 page cannot be deleted. Configure another 404 page or disable the editable 404 handler first.</div>
         <?lsp if fullPage then ?>
         <a class="button secondary" href="<?lsp= esc(app.url('/admin/content/edit?id=' .. id)) ?>">Back to Content</a>
         <?lsp end ?>
         <?lsp else ?>
         <form method="post"
               action="<?lsp= esc(app.url('/admin/content/delete?id=' .. id)) ?>"
               <?lsp if not fullPage then ?>
               hx-post="<?lsp= esc(app.url('/admin/content/delete.lsp')) ?>"
               hx-target="closest tr" hx-swap="outerHTML"<?lsp end ?>>
            <?lsp admin.csrfField(_ENV) ?>
            <input type="hidden" name="id" value="<?lsp= esc(id) ?>">
            <input type="hidden" name="confirmed" value="true">
            <?lsp if #dependencies.menuItems > 0 then ?>
            <fieldset>
               <legend>Linked Menu Items</legend>
               <ul class="dependency-list">
               <?lsp for _, item in ipairs(dependencies.menuItems) do ?>
                  <li><strong><?lsp= esc(item.label) ?></strong> in <?lsp= esc(item.menu_slug) ?> (<code><?lsp= esc(item.url) ?></code>)</li>
               <?lsp end ?>
               </ul>
               <label class="choice-row"><input type="radio" name="menu_items_action" value="preserve" checked> Preserve linked menu items</label>
               <label class="choice-row"><input type="radio" name="menu_items_action" value="delete"> Delete linked menu items</label>
            </fieldset>
            <?lsp end ?>
            <?lsp if #dependencies.redirects > 0 then ?>
            <fieldset>
               <legend>Related Redirects</legend>
               <ul class="dependency-list">
               <?lsp for _, item in ipairs(dependencies.redirects) do ?>
                  <li><code><?lsp= esc(item.from_path) ?></code> to <code><?lsp= esc(item.to_path) ?></code></li>
               <?lsp end ?>
               </ul>
               <label class="choice-row"><input type="radio" name="redirects_action" value="preserve" checked> Preserve related redirects</label>
               <label class="choice-row"><input type="radio" name="redirects_action" value="delete"> Delete related redirects</label>
            </fieldset>
            <?lsp end ?>
            <?lsp if #dependencies.childContent > 0 then ?>
            <div class="notice"><strong>Child paths will not be deleted.</strong>
               <ul class="dependency-list">
               <?lsp for _, child in ipairs(dependencies.childContent) do ?>
                  <li><?lsp= esc(child.title) ?> (<code><?lsp= esc(child.path) ?></code>)</li>
               <?lsp end ?>
               </ul>
            </div>
            <?lsp end ?>
            <div class="actions">
               <button class="danger" type="submit">Delete Permanently</button>
               <a class="button secondary" href="<?lsp= esc(app.url(fullPage and '/admin/content/edit?id=' .. id or '/admin/content/')) ?>"
                       <?lsp if not fullPage then ?>
                       hx-get="<?lsp= esc(app.url('/admin/content/row.lsp?id=' .. id)) ?>"
                       hx-target="closest tr" hx-swap="outerHTML"<?lsp end ?>>Cancel</a>
            </div>
         </form>
         <?lsp end ?>
<?lsp if fullPage then ?>
</div></section>
<?lsp else ?>
      </div>
   </td>
</tr>
<?lsp end ?>
