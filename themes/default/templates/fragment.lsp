<?lsp
local model = select(6, ...)
local app = select(5, ...)
local http = app.appreq "cmshttp"
local esc = http.html
local attr = http.htmlAttr
local content = model.content or {}
local title = content.title or model.site.title or "FuguHub"
local url = model.url or function(path) return path end
local currentPath = content.path and url(content.path) or request:uri()
?>
<main id="cms-main" class="site-main" data-cms-title="<?lsp= attr(title) ?>" data-cms-path="<?lsp= attr(currentPath) ?>">
   <article class="content-card<?lsp if content.type == 'archive' then response:write(' wide') end ?>">
      <?lsp if content.type == "archive" then ?>
      <p class="eyebrow"><?lsp= model.category and "Category" or "Archive" ?></p>
      <?lsp end ?>
      <h1><?lsp= esc(title) ?></h1>
      <?lsp if model.categories and #model.categories > 0 then ?>
      <nav class="post-categories" aria-label="Article categories">
         <?lsp for _, category in ipairs(model.categories) do ?>
         <a href="<?lsp= attr(url(category.path)) ?>"><?lsp= esc(category.name) ?></a>
         <?lsp end ?>
      </nav>
      <?lsp end ?>
      <div class="cms-body">
      <?lsp
      if content.type == "archive" then
         if model.category and model.category.description and model.category.description ~= "" then
            response:write("<p class='archive-description'>", esc(model.category.description), "</p>")
         end
         if model.posts and #model.posts > 0 then
            response:write("<div class='post-list'>")
            for _, post in ipairs(model.posts) do
               response:write("<article class='post-item'><h2><a href='", attr(url(post.path)), "'>", esc(post.title), "</a></h2>")
               if post.meta_description and post.meta_description ~= "" then
                  response:write("<p>", esc(post.meta_description), "</p>")
               end
               response:write("</article>")
            end
            response:write("</div>")
         else
            response:write("<div class='empty-state'>No posts have been published yet.</div>")
         end
      elseif model.renderBody then
         model.renderBody()
      end
      ?>
      </div>
   </article>
   <div class="cms-page-head"
      data-cms-head-html="<?lsp= attr(content.head_html or "") ?>"
      data-cms-meta-description="<?lsp= attr(content.meta_description or "") ?>"
      hidden></div>
</main>
