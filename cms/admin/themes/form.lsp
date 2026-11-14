<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local model, esc = adminThemes, admin.html
if not model then response:senderror(404, "Not found"); return end
?>
<section class='panel'><div class='panel-body'><h2>Active Theme</h2>
   <form method='post' action='<?lsp= esc(app.url("/admin/themes/")) ?>'>
      <?lsp admin.csrfField(_ENV) ?>
      <div class='form-grid'><div class='field'><label for='field-theme'>Theme</label><select id='field-theme' name='theme'>
         <?lsp for _, item in ipairs(model.items) do ?>
         <option value='<?lsp= esc(item.name) ?>'<?lsp if model.active == item.name then ?> selected<?lsp end ?>><?lsp= esc(item.name) ?><?lsp if item.source == "zip" then ?> (zip)<?lsp elseif item.source == "built-in" then ?> (built-in fallback)<?lsp end ?></option>
         <?lsp end ?>
      </select></div></div>
      <div class='actions'><button type='submit'>Activate Theme</button></div>
   </form>
   <p class='muted'>Current runtime theme: <?lsp= esc(app.theme and app.theme.name or model.active) ?><?lsp if app.theme and app.theme.source then ?> from <?lsp= esc(app.theme.source) ?><?lsp end ?></p>
</div></section>
