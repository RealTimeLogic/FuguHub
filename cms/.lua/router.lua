local content = appreq "content"
local menus = appreq "menus"
local renderer = appreq "renderer"
local settings = appreq "settings"
local terms = appreq "terms"
local loadModule = appreq

local M = {}

local function acceptsDeflate(_ENV)
   local ae = _ENV.request:header("Accept-Encoding")
   if not ae then return false end
   for token in ae:gmatch("[^,]+") do
      local name = token:match("^%s*([^;%s]+)")
      if name and name:lower() == "deflate" then
         local q = token:match("[;%s]q%s*=%s*([%d%.]+)")
         return not q or tonumber(q) ~= 0
      end
   end
   return false
end

local function setVariantHeaders(_ENV, app)
   local vary = "Accept-Encoding"
   if settings.isHtmxEnabled(app) then
      vary = vary .. ", HX-Request, HX-History-Restore-Request"
   end
   _ENV.response:setheader("Vary", vary)
   return vary
end

local function normalizedCachePolicy(row)
   local policy = row.cache_policy or "default"
   if policy == "revalidate" or policy == "no-cache" or policy == "no-store" then
      return policy
   end
   return row.render_mode == "html" and "revalidate" or "no-cache"
end

local function cacheVariant(_ENV, app)
   local isFragment = settings.isHtmxEnabled(app) and
      _ENV.request:header("hx-request") and
      not _ENV.request:header("hx-history-restore-request")
   return isFragment and "fragment" or "full"
end

local function contentEtag(_ENV, app, row, updated)
   local id = tostring(row.id or row.path or "0"):gsub("[^%w%._%-]", "_")
   local presentation = tostring(app.presentationRevision or "0"):gsub("[^%w%._%-]", "_")
   return 'W/"cms-' .. id .. "-" .. tostring(updated) .. "-" .. presentation ..
      "-" .. cacheVariant(_ENV, app) .. '"'
end

local function etagMatches(_ENV, etag)
   local inm = _ENV.request:header("If-None-Match")
   return inm == "*" or (inm and inm:find(etag, 1, true) ~= nil)
end

local function setResponseHeaders(response, headers)
   for name, value in pairs(headers or {}) do
      if name == "Last-Modified-Time" then
         response:setdateheader("Last-Modified", value)
      else
         response:setheader(name, value)
      end
   end
end

local function contentCacheHeaders(_ENV, app, row, policy, updated)
   local headers = {
      ["Vary"] = setVariantHeaders(_ENV, app),
      ["Cache-Control"] = policy == "revalidate" and "private, max-age=0, must-revalidate" or "no-cache",
   }
   if policy == "revalidate" and updated then
      headers["ETag"] = contentEtag(_ENV, app, row, updated)
   end
   return headers
end

local function applyContentCachePolicy(_ENV, app, row)
   local response = _ENV.response

   local policy = normalizedCachePolicy(row)
   if policy == "no-store" then
      local headers = {
         ["Vary"] = setVariantHeaders(_ENV, app),
         ["Cache-Control"] = "no-store",
      }
      setResponseHeaders(response, headers)
      return false, headers
   end

   local updated = row.updated_at and tonumber(row.updated_at)
   local headers = contentCacheHeaders(_ENV, app, row, policy, updated)
   setResponseHeaders(response, headers)
   if policy ~= "revalidate" or not row.updated_at then
      return false, headers
   end

   if not updated then
      return false, headers
   end
   local ifNoneMatch = _ENV.request:header("If-None-Match")
   if ifNoneMatch then
      if etagMatches(_ENV, headers["ETag"]) then
         response:setstatus(304)
         return true, headers
      end
      return false, headers
   end
   return false, headers
end

local function renderWithOptionalCompression(_ENV, app, templateName, model)
   local response = _ENV.response
   if not response:initial() then trace"PATCH not initial" return false end
   local function render()
      setResponseHeaders(response, model.responseHeaders)
      response:setcontenttype("text/html; charset=utf-8")
      return renderer.renderTemplate(_ENV, app, templateName, model)
   end
   if acceptsDeflate(_ENV) then
      local xrsp = response:setresponse()
      local ok, err = render()
      if ok then
         setResponseHeaders(response, model.responseHeaders)
         response:setcontenttype("text/html; charset=utf-8")
         xrsp:finalize(true)
         return true
      end
      xrsp:abort()
      response:reset()
      response:senderror(500, err or "CMS rendering failed")
      return true
   end
   local ok, err = render()
   if ok then return true end
   if response:initial() then response:reset() end
   response:senderror(500, err or "CMS rendering failed")
   return true
end

local function isHtmxFragmentRequest(_ENV, htmxEnabled)
   return htmxEnabled and
      _ENV.request:header("hx-request") and
      not _ENV.request:header("hx-history-restore-request")
end

local function accessContext(_ENV, route, row)
   local handled = false
   local request = _ENV.request
   local ctx = {
      event = "access",
      path = row and row.path or request:uri(),
      uri = request:uri(),
      method = request:method(),
      route = route,
      content = row,
      isHtmx = request:header("hx-request") and true or false,
   }
   function ctx:handle()
      handled = true
   end
   function ctx:isHandled()
      return handled
   end
   function ctx:isAdmin()
      return false
   end
   function ctx:isStatic()
      return false
   end
   function ctx:isCmsRoute()
      return true
   end
   return ctx
end

local function emitAccess(_ENV, app, route, row)
   if not app.cms or type(app.cms.emit) ~= "function" then
      return false
   end
   local ctx = accessContext(_ENV, route, row)
   app.cms:emit("access", _ENV, ctx)
   return ctx:isHandled() or _ENV.response:committed()
end

local function modelBase(_ENV, app, pageState)
   local htmxEnabled = settings.isHtmxEnabled(app)
   return {
      site = {
         title = "FuguHub",
         htmxEnabled = htmxEnabled,
         baseUri = app.baseUri or "/",
      },
      url = app.url,
      pathFromUri = app.pathFromUri,
      menu = menus.tree(app, "primary"),
      themeAssetVersion = app.theme and app.theme.assetVersion or app.runtimeId,
      pageState = pageState or {},
      htmxEnabled = htmxEnabled,
      smqEnabled = htmxEnabled and settings.isSmqEnabled(app),
      smqEndpoint = app.url("/SMQ/"),
      htmxFragment = isHtmxFragmentRequest(_ENV, htmxEnabled),
   }
end

local function renderContentRow(_ENV, app, row, responseHeaders, templateName)
   local pageState = app.pageTable and app.pageTable("content", row.id or row.path or _ENV.request:uri()) or {}
   local model = modelBase(_ENV, app, pageState)
   local categories = row.type == "post" and
      terms.forContent(app, row.id, "category") or {}
   row.categories = categories
   model.content = row
   model.categories = categories
   model.responseHeaders = responseHeaders
   model.renderBody = function()
      renderer.renderBody(_ENV, app, row, model.pageState)
   end

   local template = templateName or (row.type == "post" and "post" or "page")
   return renderWithOptionalCompression(_ENV, app, template, model)
end

local function categorySlugForPath(blogBasePath, path)
   local prefix = blogBasePath .. "category/"
   if path:sub(1, #prefix) ~= prefix then return nil end
   local slug = path:sub(#prefix + 1):gsub("/$", "")
   if slug == "" or slug:find("/", 1, true) then return nil end
   return slug
end

local function renderArchive(_ENV, app, path, title, posts, category)
   local headers = {
      ["Vary"] = setVariantHeaders(_ENV, app),
      ["Cache-Control"] = "no-cache",
   }
   setResponseHeaders(_ENV.response, headers)
   local route = category and "category" or "archive"
   local archiveRow = {
      type = "archive",
      archive_type = category and "category" or "blog",
      title = title,
      path = path,
      meta_description = category and category.description or "",
      head_html = "",
   }
   if emitAccess(_ENV, app, route, archiveRow) then
      return true
   end
   local model = modelBase(_ENV, app,
      app.pageTable and app.pageTable("route", path) or {})
   model.responseHeaders = headers
   model.content = archiveRow
   model.posts = posts
   model.category = category
   local template = category and app.theme.hasTemplate and
      app.theme.hasTemplate("taxonomy") and "taxonomy" or "archive"
   return renderWithOptionalCompression(_ENV, app, template, model)
end

function M.renderContentPath(_ENV, app, path, routeName, statusCode)
   local row = content.byPath(app, path)
   if not row then
      return false
   end
   if emitAccess(_ENV, app, routeName or "content", row) then
      return true
   end
   if statusCode then
      _ENV.response:setstatus(statusCode)
   end
   local handled, headers = applyContentCachePolicy(_ENV, app, row)
   if handled then
      return true
   end
   if statusCode then
      _ENV.response:setstatus(statusCode)
   end
   local template = routeName == "not-found" and "not-found" or nil
   return renderContentRow(_ENV, app, row, headers, template)
end

function M.new(app)
   return function(_ENV, relpath)
      if response:committed() then return end

      response:setheader("x-content-type-options", "nosniff")

      local request = _ENV.request
      local uri = request:uri()
      local path = app.pathFromUri and app.pathFromUri(uri) or uri:gsub("[?#].*$", "")

      local previewId = tonumber(request:data"cms-preview")
      if previewId then
         local admin = loadModule "admin"
         if not admin.isAdmin(_ENV, app) then
            response:senderror(403, "Admin access required")
            return true
         end
         local row = content.byId(app, previewId)
         if not row then
            response:senderror(404, "Preview content not found")
            return true
         end
         if row.path ~= path then
            response:sendredirect(app.url(row.path .. "?cms-preview=" .. previewId))
            return true
         end
         local headers = {
            ["Vary"] = setVariantHeaders(_ENV, app),
            ["Cache-Control"] = "no-store",
         }
         setResponseHeaders(response, headers)
         if emitAccess(_ENV, app, "preview", row) then
            return true
         end
         return renderContentRow(_ENV, app, row, headers)
      end

      local redir = content.redirectByPath(app, path)
      if redir then
         response:sendredirect(app.url(redir.to_path), tonumber(redir.status_code) == 301)
         return true
      end

      local blogBasePath = settings.blogBasePath(app)
      if path == blogBasePath then
         return renderArchive(_ENV, app, path, "Blog", content.recentPosts(app, 10))
      end

      local categorySlug = categorySlugForPath(blogBasePath, path)
      if categorySlug then
         local category = terms.category(app, categorySlug)
         if category then
            local posts = terms.postsByCategory(app, category.id, { limit = 20 })
            return renderArchive(_ENV, app, path, category.name, posts, category)
         end
      end

      return M.renderContentPath(_ENV, app, path, "content")
   end
end

return M
