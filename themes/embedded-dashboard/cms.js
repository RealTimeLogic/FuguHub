
(function(){
"use strict";
var mobileNav=window.matchMedia("(max-width: 860px)"),contrastKey="dashboard-contrast";
function own(item,selector){return item&&item.querySelector(":scope > "+selector)}
function hasSubmenu(item){return!!own(item,"ul")}
function setClosed(item){item.classList.remove("submenu-open");var b=own(item,".menu-item-entry > .submenu-toggle");if(b)b.setAttribute("aria-expanded","false")}
function close(item){item.querySelectorAll("li.submenu-open").forEach(setClosed);setClosed(item)}
function closeAll(nav){(nav||document).querySelectorAll(".site-nav li.submenu-open").forEach(close)}
function dismiss(nav){if(!nav)return;closeAll(nav);nav.classList.add("submenus-dismissed")}
function toggle(item,event){if(!item)return;var nav=item.closest(".site-nav");if(nav)nav.classList.remove("submenus-dismissed");var opening=!item.classList.contains("submenu-open"),list=item.parentElement;if(list)list.querySelectorAll(":scope > li.submenu-open").forEach(function(other){if(other!==item)close(other)});item.classList.toggle("submenu-open",opening);var b=own(item,".menu-item-entry > .submenu-toggle");if(b)b.setAttribute("aria-expanded",opening?"true":"false");if(event){event.preventDefault();event.stopPropagation()}}
function setNavOpen(open){var active=!!open&&mobileNav.matches;document.body.classList.toggle("nav-open",active);document.querySelectorAll("[data-nav-open]").forEach(function(b){b.setAttribute("aria-expanded",active?"true":"false")});var sidebar=document.getElementById("dashboard-sidebar");if(sidebar){if(mobileNav.matches)sidebar.setAttribute("aria-hidden",active?"false":"true");else sidebar.removeAttribute("aria-hidden")}var backdrop=document.querySelector("[data-nav-backdrop]");if(backdrop)backdrop.hidden=!active}
function setContrast(high,remember){if(high)document.documentElement.setAttribute("data-contrast","high");else document.documentElement.removeAttribute("data-contrast");document.querySelectorAll("[data-contrast-toggle]").forEach(function(b){b.setAttribute("aria-pressed",high?"true":"false");b.textContent=high?"Standard contrast":"High contrast"});if(remember)try{localStorage.setItem(contrastKey,high?"high":"standard")}catch(_){}}
function setStatus(state,label){document.querySelectorAll("[data-system-status]").forEach(function(status){status.setAttribute("data-state",state);var text=status.querySelector("[data-system-status-text]");if(text)text.textContent=label})}
function setBusy(active){document.body.classList.toggle("cms-requesting",active);var main=document.getElementById("cms-main");if(main)main.setAttribute("aria-busy",active?"true":"false")}
document.addEventListener("click",function(event){
if(event.target.closest("[data-nav-open]")){setNavOpen(true);return}
if(event.target.closest("[data-nav-close], [data-nav-backdrop]")){setNavOpen(false);return}
var contrast=event.target.closest("[data-contrast-toggle]");if(contrast){setContrast(document.documentElement.getAttribute("data-contrast")!=="high",true);return}
var button=event.target.closest(".submenu-toggle");if(button){toggle(button.closest("li"),event);return}
var nav=event.target.closest(".site-nav"),link=event.target.closest(".site-nav a[href]");
if(nav&&link&&hasSubmenu(link.closest("li"))){toggle(link.closest("li"),event);return}
if(nav&&link){dismiss(nav);setNavOpen(false)}else closeAll()
},true);
document.addEventListener("keydown",function(event){if(event.key!=="Escape")return;if(document.body.classList.contains("nav-open")){setNavOpen(false);var opener=document.querySelector("[data-nav-open]");if(opener)opener.focus();return}var item=event.target.closest(".site-nav li.submenu-open");if(!item)return;var b=own(item,".menu-item-entry > .submenu-toggle");close(item);if(b)b.focus()});
document.addEventListener("htmx:beforeRequest",function(event){setBusy(true);setStatus("busy","Updating…");var el=event.detail&&event.detail.elt,nav=el&&el.closest&&el.closest(".site-nav");if(nav)dismiss(nav);setNavOpen(false)},true);
document.addEventListener("htmx:afterRequest",function(event){setBusy(false);if(event.detail&&event.detail.successful)setStatus("online","CMS connected");else setStatus("warning","Request failed")},true);
document.addEventListener("htmx:sendError",function(){setBusy(false);setStatus("offline","Connection issue")},true);
document.addEventListener("htmx:timeout",function(){setBusy(false);setStatus("warning","Request timed out")},true);
document.addEventListener("htmx:responseError",function(){setBusy(false);setStatus("warning","Server error")},true);
document.addEventListener("htmx:historyRestore",function(){setNavOpen(false)},true);
window.addEventListener("offline",function(){setBusy(false);setStatus("offline","Browser offline")});
window.addEventListener("online",function(){setStatus("online","CMS connected")});
if(mobileNav.addEventListener)mobileNav.addEventListener("change",function(){setNavOpen(false)});else mobileNav.addListener(function(){setNavOpen(false)});
function init(){var high=false;try{high=localStorage.getItem(contrastKey)==="high"}catch(_){}setContrast(high,false);setNavOpen(false);setStatus(navigator.onLine===false?"offline":"online",navigator.onLine===false?"Browser offline":"CMS connected")}
if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",init,{once:true});else init()
}());

(function () {
   var overlayId = "cms-htmx-error-overlay";

   function pathname(value) {
      try {
         return new URL(value, window.location.origin).pathname;
      } catch (_) {
         return value || "";
      }
   }

   function revealSelectedTrail() {
      document.querySelectorAll(".site-nav").forEach(function (nav) {
         nav.classList.remove("submenus-dismissed");
         nav.querySelectorAll("li.selected").forEach(function (selected) {
            var list = selected.parentElement;
            var item = list && list.closest("li");
            while (item && nav.contains(item)) {
               var submenu = item.querySelector(":scope > ul");
               if (submenu) {
                  item.classList.add("submenu-open");
                  var button = item.querySelector(":scope > .menu-item-entry > .submenu-toggle, :scope > .nav-entry > .submenu-toggle");
                  if (button) button.setAttribute("aria-expanded", "true");
               }
               list = item.parentElement;
               item = list && list.closest("li");
            }
         });
      });
   }

   function updateChrome(root) {
      var meta = root && root.querySelector ? root.querySelector("[data-cms-title]") : null;
      if (!meta) meta = document.querySelector("[data-cms-title]");
      if (!meta) return;
      var title = meta.getAttribute("data-cms-title");
      var path = meta.getAttribute("data-cms-path");
      if (title) document.title = title;
      if (!path) return;
      var activePath = pathname(path);
      document.querySelectorAll(".site-nav li").forEach(function (item) {
         var link = item.querySelector("a[href]");
         var menuPath = link && pathname(link.getAttribute("href"));
         var selected = !!menuPath && (menuPath === activePath ||
            (menuPath !== "/" && activePath.indexOf(menuPath.endsWith("/") ? menuPath : menuPath + "/") === 0));
         item.classList.toggle("selected", selected);
      });
      revealSelectedTrail();
   }

   function overlayStyles() {
      return [
         "position:fixed",
         "inset:0",
         "z-index:2147483647",
         "display:flex",
         "align-items:center",
         "justify-content:center",
         "padding:24px",
         "background:rgba(0,0,0,.58)",
         "font:15px/1.5 system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif",
         "color:#f8f9fa"
      ].join(";");
   }

   function panelStyles() {
      return [
         "width:min(520px,100%)",
         "background:#303134",
         "border:1px solid #5f6368",
         "border-radius:8px",
         "box-shadow:0 20px 60px rgba(0,0,0,.4)",
         "padding:22px"
      ].join(";");
   }

   function buttonStyles(primary) {
      return [
         "appearance:none",
         "border:1px solid " + (primary ? "#63d471" : "#747775"),
         "border-radius:6px",
         "background:" + (primary ? "#63d471" : "transparent"),
         "color:" + (primary ? "#101213" : "#f8f9fa"),
         "font:700 14px system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif",
         "padding:9px 13px",
         "cursor:pointer"
      ].join(";");
   }

   function showError(message, detail) {
      var existing = document.getElementById(overlayId);
      if (existing) existing.remove();

      var overlay = document.createElement("div");
      overlay.id = overlayId;
      overlay.setAttribute("role", "alertdialog");
      overlay.setAttribute("aria-modal", "true");
      overlay.setAttribute("aria-labelledby", overlayId + "-title");
      overlay.style.cssText = overlayStyles();

      var panel = document.createElement("div");
      panel.style.cssText = panelStyles();

      var title = document.createElement("h2");
      title.id = overlayId + "-title";
      title.textContent = "Server connection lost";
      title.style.cssText = "margin:0 0 10px;font-size:22px;line-height:1.2";

      var body = document.createElement("p");
      body.textContent = message || "The page could not be updated because the server did not respond.";
      body.style.cssText = "margin:0 0 8px;color:#e8eaed";

      var hint = document.createElement("p");
      hint.textContent = detail || "Check that the server is running, then retry.";
      hint.style.cssText = "margin:0 0 18px;color:#bdc1c6";

      var actions = document.createElement("div");
      actions.style.cssText = "display:flex;gap:10px;flex-wrap:wrap";

      var retry = document.createElement("button");
      retry.type = "button";
      retry.textContent = "Retry";
      retry.style.cssText = buttonStyles(true);
      retry.addEventListener("click", function () {
         window.location.reload();
      });

      var dismiss = document.createElement("button");
      dismiss.type = "button";
      dismiss.textContent = "Dismiss";
      dismiss.style.cssText = buttonStyles(false);
      dismiss.addEventListener("click", hideError);

      actions.appendChild(retry);
      actions.appendChild(dismiss);
      panel.appendChild(title);
      panel.appendChild(body);
      panel.appendChild(hint);
      panel.appendChild(actions);
      overlay.appendChild(panel);
      document.body.appendChild(overlay);
      retry.focus();
   }

   function hideError() {
      var overlay = document.getElementById(overlayId);
      if (overlay) overlay.remove();
   }

   function requestUrl(event) {
      var detail = event && event.detail;
      var elt = detail && detail.elt;
      if (detail && detail.pathInfo && detail.pathInfo.requestPath) return detail.pathInfo.requestPath;
      if (detail && detail.requestConfig && detail.requestConfig.path) return detail.requestConfig.path;
      if (elt && elt.getAttribute) {
         return elt.getAttribute("href") || elt.getAttribute("action") || elt.getAttribute("hx-get") || elt.getAttribute("hx-post");
      }
      return "";
   }

   function connectionDetail(event) {
      var url = requestUrl(event);
      return url ? "The request to " + url + " failed. Check that the server is running, then retry." :
         "Check that the server is running, then retry.";
   }

   function listen(name, handler) {
      document.addEventListener(name, handler, true);
      if (document.body) document.body.addEventListener(name, handler);
   }

   function afterRequest(event) {
      var detail = event.detail || {};
      var xhr = detail.xhr;
      if (detail.successful) {
         hideError();
      } else if (detail.failed || (xhr && xhr.status === 0)) {
         showError("The server could not be reached.", connectionDetail(event));
      }
   }

   listen("htmx:afterSwap", function (event) {
      updateChrome(event.detail && event.detail.target);
   });
   listen("htmx:afterSettle", function () {
      updateChrome(document);
   });
   listen("htmx:historyRestore", function () {
      updateChrome(document);
   });
   listen("htmx:beforeRequest", hideError);
   listen("htmx:afterRequest", afterRequest);
   listen("htmx:sendError", function (event) {
      showError("The server could not be reached.", connectionDetail(event));
   });
   listen("htmx:timeout", function (event) {
      showError("The server request timed out.", connectionDetail(event));
   });
   listen("htmx:responseError", function (event) {
      var xhr = event.detail && event.detail.xhr;
      var status = xhr && xhr.status ? " HTTP " + xhr.status + "." : ".";
      showError("The server returned an error" + status, connectionDetail(event));
   });
   if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", function () {
         updateChrome(document);
      }, { once: true });
   } else {
      updateChrome(document);
   }

   window.cmsHtmxConnectionOverlay = {
      show: showError,
      hide: hideError
   };
   window.addEventListener("offline", function () {
      showError("The browser is offline.", "Reconnect to the network, then retry.");
   });
   window.addEventListener("online", hideError);
}());
