<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html

function adminRenderContentRow(row)
   local id = tostring(row.id)
   local rowId = "content-row-" .. id
?>
<tr id="<?lsp= rowId ?>">
   <td><?lsp= esc(id) ?></td>
   <td><?lsp= esc(row.type) ?></td>
   <td><?lsp= esc(row.title) ?></td>
   <td><a href="<?lsp= esc(app.url(row.public_path)) ?>"><?lsp= esc(row.path) ?></a></td>
   <td><span class="tag"><?lsp= esc(row.render_mode) ?></span></td>
   <td><span class="tag"><?lsp= esc(row.cache_policy) ?></span></td>
   <td><span class="tag<?lsp if row.status ~= "published" then ?> warn<?lsp end ?>"><?lsp= esc(row.status) ?></span></td>
   <td class="row-actions">
      <?lsp if row.status ~= "published" then ?>
      <a href="<?lsp= esc(app.url('/admin/content/preview?id=' .. id)) ?>">Preview</a>
      <?lsp end ?>
      <a href="<?lsp= esc(app.url('/admin/content/edit?id=' .. id)) ?>">Edit</a>
      <a class="danger-link"
         href="<?lsp= esc(app.url('/admin/content/delete?id=' .. id)) ?>"
         hx-get="<?lsp= esc(app.url('/admin/content/delete.lsp?id=' .. id)) ?>"
         hx-target="closest tr"
         hx-swap="outerHTML">Delete</a>
   </td>
</tr>
<?lsp
end
?>
