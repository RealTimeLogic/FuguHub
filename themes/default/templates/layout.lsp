<?lsp
local model = select(6, ...)
local app = select(5, ...)
local http = app.appreq "cmshttp"
local esc = http.html
local attr = http.htmlAttr
local content = model.content or {}
local title = content.title or model.site.title or "FuguHub"
local current = content.path or request:uri():gsub("%?.*$", "")
local url = model.url or function(path) return path end

local function selected(item)
   local url = item.url or ""
   return url ~= "" and (url == current or (url ~= "/" and current:find(url, 1, true) == 1))
end

local function menu(items)
   if not items or #items == 0 then return end
   response:write("<ul>")
   for _, item in ipairs(items) do
      local hasChildren = item.children and #item.children > 0
      response:write("<li", selected(item) and " class='selected'" or "", "><div class='nav-entry'><a href='",
         attr(url(item.url)), "'>", esc(item.label), "</a>")
      if hasChildren then
         response:write("<button type='button' class='submenu-toggle' aria-expanded='false' aria-label='Toggle submenu for ",
            attr(item.label), "'><span aria-hidden='true'>&#9662;</span></button>")
      end
      response:write("</div>")
      menu(item.children)
      response:write("</li>")
   end
   response:write("</ul>")
end

local function body()
   response:write("<article class='content-card", content.type == "archive" and " wide" or "", "'>")
   if content.type == "archive" then
      response:write("<p class='eyebrow'>", model.category and "Category" or "Archive", "</p>")
   end
   response:write("<h1>", esc(title), "</h1>")
   if model.categories and #model.categories > 0 then
      response:write("<nav class='post-categories' aria-label='Article categories'>")
      for _, category in ipairs(model.categories) do
         response:write("<a href='", attr(url(category.path)), "'>", esc(category.name), "</a>")
      end
      response:write("</nav>")
   end
   response:write("<div class='cms-body'>")
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
   response:write("</div></article>")
end
?>
<!doctype html>
<html lang="en">
<head>
   <meta charset="utf-8">
   <meta name="viewport" content="width=device-width, initial-scale=1">
   <title><?lsp= esc(title) ?></title>
   <?lsp if content.meta_description and content.meta_description ~= "" then ?>
   <meta name="description" content="<?lsp= attr(content.meta_description) ?>">
   <?lsp end ?>
   <link rel="stylesheet" href="<?lsp= attr(url('/theme/style.css')) ?>">
   <meta data-cms-page-head-start>
   <?lsp if content.head_html and content.head_html ~= "" then response:write(content.head_html) end ?>
   <meta data-cms-page-head-end>
   <?lsp if model.smqEnabled then ?>
   <meta name="fuguhub-smq-endpoint" content="<?lsp= attr(model.smqEndpoint) ?>">
   <meta name="fuguhub-smq-target" content="#cms-main">
   <script src="/rtl/smq.js"></script>
   <script src="<?lsp= attr(url('/assets/smq/cms-smq.js')) ?>"></script>
   <?lsp end ?>
</head>
<body>
   <div id="cms-htmx-scope" class="site-shell"<?lsp if model.htmxEnabled then ?> hx-boost="true" hx-push-url="true" hx-target="#cms-main" hx-swap="outerHTML show:window:top" hx-history-elt<?lsp end ?>>
      <header class="site-header">
         <div class="header-inner">
            <a class="brand" href="<?lsp= attr(url('/')) ?>">FuguHub</a>
            <nav class="site-nav" aria-label="Primary"><?lsp menu(model.menu) ?></nav>
         </div>
      </header>
      <main id="cms-main" class="site-main">
         <?lsp body() ?>
         <div class="cms-page-head"
            data-cms-head-html="<?lsp= attr(content.head_html or "") ?>"
            data-cms-meta-description="<?lsp= attr(content.meta_description or "") ?>"
            hidden></div>
      </main>
      <footer class="site-footer">Powered by FuguHub</footer>
   </div>
   <script defer src="<?lsp= attr(url('/theme/cms.js')) ?>"></script>
   <?lsp if model.htmxEnabled then ?>
   <script defer src="<?lsp= attr(url('/assets/htmx/htmx.min.js')) ?>"></script>
   <?lsp end ?>
</body>
</html>
