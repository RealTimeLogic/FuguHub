<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html
local data = admin.requestData(_ENV)
local rows, filter, paging = admin.contentRows(app, adminFilter or data.type, data.q, data.page)
local function listUrl(path, selectedType, pageNumber)
   local params = {}
   if selectedType ~= "" then params[#params + 1] = "type=" .. app.urlEncode(selectedType) end
   if paging.query ~= "" then params[#params + 1] = "q=" .. app.urlEncode(paging.query) end
   if pageNumber > 1 then params[#params + 1] = "page=" .. pageNumber end
   return app.url(path) .. (#params > 0 and ("?" .. table.concat(params, "&")) or "")
end
if admin.isHtmx(_ENV) then
   response:setheader("HX-Push-Url", listUrl("/admin/content/", filter, paging.page))
end
local function active(value)
   return filter == value and " active" or ""
end
response:include(app.url("/admin/content/row-template.lsp"), true)
?>
<div id="content-list">
   <section class="panel">
      <div class="panel-body">
         <form method="get" action="<?lsp= esc(app.url('/admin/content/')) ?>" class="content-search"
               hx-get="<?lsp= esc(app.url('/admin/content/list.lsp')) ?>"
               hx-target="#content-list" hx-swap="outerHTML">
            <input type="hidden" name="type" value="<?lsp= esc(filter) ?>">
            <label for="content-query">Search titles and paths</label>
            <div class="actions">
               <input id="content-query" type="search" name="q" maxlength="200" value="<?lsp= esc(paging.query) ?>">
               <button type="submit">Search</button>
            </div>
         </form>
         <div class="toolbar">
            <div class="tabs">
               <?lsp for _, tab in ipairs({{"", "All"}, {"page", "Pages"}, {"post", "Posts"}}) do ?>
               <a class="button secondary<?lsp= active(tab[1]) ?>"
                  href="<?lsp= esc(listUrl('/admin/content/', tab[1], 1)) ?>"
                  hx-get="<?lsp= esc(listUrl('/admin/content/list.lsp', tab[1], 1)) ?>"
                  hx-target="#content-list" hx-swap="outerHTML"
                  hx-push-url="<?lsp= esc(listUrl('/admin/content/', tab[1], 1)) ?>"><?lsp= tab[2] ?></a>
               <?lsp end ?>
            </div>
            <a class="button" href="<?lsp= esc(app.url('/admin/content/new')) ?>">New Content</a>
         </div>
      </div>
   </section>
   <section class="panel admin-table-scroll">
      <table>
         <thead><tr>
            <th>ID</th><th>Type</th><th>Title</th><th>Path</th>
            <th>Render</th><th>Cache</th><th>Status</th><th></th>
         </tr></thead>
         <tbody>
         <?lsp for _, row in ipairs(rows) do adminRenderContentRow(row) end ?>
         </tbody>
      </table>
   </section>
   <nav class="content-pager actions" aria-label="Content pages">
      <span><?lsp= paging.total ?> results · Page <?lsp= paging.page ?> of <?lsp= paging.pages ?></span>
      <?lsp for _, target in ipairs({{paging.page - 1, "Previous"}, {paging.page + 1, "Next"}}) do
         if target[1] >= 1 and target[1] <= paging.pages then ?>
      <a class="button secondary" href="<?lsp= esc(listUrl('/admin/content/', filter, target[1])) ?>"
         hx-get="<?lsp= esc(listUrl('/admin/content/list.lsp', filter, target[1])) ?>"
         hx-target="#content-list" hx-swap="outerHTML"><?lsp= target[2] ?></a>
      <?lsp end end ?>
   </nav>
</div>
