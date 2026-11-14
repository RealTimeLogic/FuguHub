<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local model, esc = adminDashboard, admin.html
if not model then response:senderror(404, "Not found"); return end
?>
<section class='grid'>
   <?lsp for _, stat in ipairs({ {"content", "Content"}, {"pages", "Pages"},
      {"posts", "Posts"}, {"lsp", "LSP Content"}, {"redirects", "Redirects"}, {"menuItems", "Menu Items"} }) do ?>
   <div class='stat'><span class='value'><?lsp= esc(model[stat[1]]) ?></span><span class='label'><?lsp= esc(stat[2]) ?></span></div>
   <?lsp end ?>
   <div class='stat'><span class='text-value'><?lsp= esc(model.theme) ?></span><span class='label'>Theme</span></div>
</section>
