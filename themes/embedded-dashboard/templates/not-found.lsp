<?lsp
local model = select(6, ...)
return app.theme.getTemplate(model.htmxFragment and "fragment" or "layout")(_ENV, pathname, io, page, app, model)
?>
