<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local rows, esc = adminRedirects, admin.html
if not rows then response:senderror(404, "Not found"); return end
local action = esc(app.url("/admin/redirects/"))
?>
<section class='panel'><div class='panel-body'><h2>Add Redirect</h2>
   <form method='post' action='<?lsp= action ?>'>
      <input type='hidden' name='action' value='add'><?lsp admin.csrfField(_ENV) ?>
      <div class='form-grid'>
         <div class='field'><label for='field-from_path'>From</label><input id='field-from_path' name='from_path' required></div>
         <div class='field'><label for='field-to_path'>To</label><input id='field-to_path' name='to_path' required></div>
         <div class='field'><label for='field-status_code'>Status</label><select id='field-status_code' name='status_code'>
            <option value='302'>302 - Temporary</option><option value='301'>301 - Permanent</option>
         </select></div>
      </div><div class='actions'><button type='submit'>Add</button></div>
   </form>
</div></section>
<section class='panel admin-table-scroll' tabindex='0' role='region' aria-label='Redirects'>
   <table><thead><tr><th>ID</th><th>From</th><th>To</th><th>Status</th><th></th></tr></thead><tbody>
   <?lsp if #rows == 0 then ?><tr><td colspan='5' class='muted'>No redirects configured.</td></tr><?lsp end ?>
   <?lsp for _, row in ipairs(rows) do ?>
      <tr><td><?lsp= esc(row.id) ?></td><td><?lsp= esc(row.from_path) ?></td><td><?lsp= esc(row.to_path) ?></td><td><?lsp= esc(row.status_code) ?></td>
         <td><form class='inline' method='post' action='<?lsp= action ?>'>
            <input type='hidden' name='action' value='delete'><input type='hidden' name='id' value='<?lsp= esc(row.id) ?>'><?lsp admin.csrfField(_ENV) ?>
            <button class='danger' type='submit'>Delete</button>
         </form></td></tr>
   <?lsp end ?>
   </tbody></table>
</section>
