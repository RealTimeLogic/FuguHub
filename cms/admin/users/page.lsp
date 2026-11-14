<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local model, esc = adminUsers, admin.html
if not model then response:senderror(404, "Not found"); return end
?>
<?lsp if model.message then ?><div class='notice error' role='alert'><?lsp= esc(model.message) ?></div><?lsp end ?>
<section class='panel'><div class='panel-body'><h2>Admin Users</h2>
   <?lsp if not model.available then ?>
   <p class='muted'>TPM-backed authentication is not available in this runtime.</p>
   <?lsp else ?>
   <p class='muted'>Create an administrator to protect the admin directory. Users and credentials are stored together in the CMS SQLite database.</p>
   <form method='post'><input type='hidden' name='action' value='save'><?lsp admin.csrfField(_ENV) ?>
      <div class='form-grid'>
         <div class='field'><label for='field-username'>Username</label><input id='field-username' name='username' value='<?lsp= esc(model.username) ?>' autocomplete='username' required></div>
         <div class='field'><label for='field-password'>Password</label><input id='field-password' name='password' type='password' autocomplete='new-password' required></div>
      </div><div class='actions'><button type='submit'>Save User</button></div>
   </form>
   <?lsp end ?>
</div></section>
<section class='panel admin-table-scroll' tabindex='0' role='region' aria-label='Admin users'>
   <table><thead><tr><th>Username</th><th>Status</th><th></th></tr></thead><tbody>
   <?lsp if #model.users == 0 then ?>
      <tr><td colspan='3'><span class='muted'>No admin users configured.</span></td></tr>
   <?lsp else for _, user in ipairs(model.users) do ?>
      <tr><td><?lsp= esc(user) ?></td><td><span class='tag'>active</span></td><td>
         <form class='inline-form' method='post'><input type='hidden' name='action' value='remove'><?lsp admin.csrfField(_ENV) ?>
            <input type='hidden' name='username' value='<?lsp= esc(user) ?>'><button class='danger' type='submit'>Remove Admin Access</button>
         </form>
      </td></tr>
   <?lsp end end ?>
   </tbody></table>
</section>
<?lsp if #model.users > 0 then ?>
<section class='panel'><div class='panel-body'><h2>Reset Authentication</h2>
   <p class='muted'>Explicitly remove all users and return the CMS to unprotected bootstrap mode.</p>
   <form method='post' onsubmit="return confirm('Remove every user and disable authentication?')"><?lsp admin.csrfField(_ENV) ?>
      <input type='hidden' name='action' value='reset'><button class='danger' type='submit'>Reset All Users</button>
   </form>
</div></section>
<?lsp end ?>
