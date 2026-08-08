(function () {
   var desktopMenu = window.matchMedia("(min-width: 721px)");

   function isNested(item) {
      var list = item && item.parentElement;
      var parent = list && list.parentElement;
      return !!(parent && parent.matches(".site-nav li"));
   }

   function positionSubmenu(item) {
      if (!item || !isNested(item)) return;
      item.classList.remove("submenu-opens-left");
      if (!desktopMenu.matches) return;
      var submenu = item.querySelector(":scope > ul");
      var entry = item.querySelector(":scope > .nav-entry");
      if (!submenu || !entry) return;
      var menuWidth = submenu.getBoundingClientRect().width;
      if (!menuWidth) return;
      var entryRect = entry.getBoundingClientRect();
      var viewportWidth = document.documentElement.clientWidth;
      var spaceRight = viewportWidth - entryRect.right;
      var spaceLeft = entryRect.left;
      item.classList.toggle(
         "submenu-opens-left",
         spaceRight < menuWidth - 1 && spaceLeft > spaceRight
      );
   }

   function setClosed(item) {
      var button = item.querySelector(":scope > .nav-entry > .submenu-toggle");
      item.classList.remove("submenu-open");
      item.classList.remove("submenu-opens-left");
      if (button) button.setAttribute("aria-expanded", "false");
   }

   function close(item) {
      item.querySelectorAll("li.submenu-open").forEach(setClosed);
      setClosed(item);
   }

   function closeAll(nav) {
      (nav || document).querySelectorAll(".site-nav li.submenu-open").forEach(close);
   }

   function dismiss(nav) {
      closeAll(nav);
      nav.classList.add("submenus-dismissed");
      if (nav.contains(document.activeElement)) document.activeElement.blur();
   }

   document.addEventListener("click", function (event) {
      var button = event.target.closest(".submenu-toggle");
      if (!button) {
         var nav = event.target.closest(".site-nav");
         var link = event.target.closest(".site-nav a[href]");
         if (nav && link) dismiss(nav);
         else closeAll();
         return;
      }
      var item = button.closest("li");
      var nav = button.closest(".site-nav");
      if (nav) nav.classList.remove("submenus-dismissed");
      var opening = !item.classList.contains("submenu-open");
      var list = item.parentElement;
      if (list) {
         list.querySelectorAll(":scope > li.submenu-open").forEach(function (other) {
            if (other !== item) close(other);
         });
      }
      item.classList.toggle("submenu-open", opening);
      button.setAttribute("aria-expanded", opening ? "true" : "false");
      if (opening) positionSubmenu(item);
      event.preventDefault();
      event.stopPropagation();
   });

   document.addEventListener("pointerover", function (event) {
      var item = event.target.closest && event.target.closest(".site-nav li");
      if (item) positionSubmenu(item);
   });

   document.addEventListener("pointerout", function (event) {
      var nav = event.target.closest && event.target.closest(".site-nav.submenus-dismissed");
      if (nav && !nav.contains(event.relatedTarget)) {
         nav.classList.remove("submenus-dismissed");
      }
   });

   document.addEventListener("focusin", function (event) {
      var nav = event.target.closest && event.target.closest(".site-nav.submenus-dismissed");
      if (nav) nav.classList.remove("submenus-dismissed");
      var item = event.target.closest && event.target.closest(".site-nav li");
      if (item) positionSubmenu(item);
   });

   window.addEventListener("resize", function () {
      document.querySelectorAll(".site-nav li.submenu-opens-left").forEach(function (item) {
         item.classList.remove("submenu-opens-left");
      });
      document.querySelectorAll(".site-nav li.submenu-open, .site-nav li:hover").forEach(positionSubmenu);
   });

   document.addEventListener("htmx:beforeRequest", function (event) {
      var element = event.detail && event.detail.elt;
      var nav = element && element.closest && element.closest(".site-nav");
      if (nav) dismiss(nav);
   }, true);

   document.addEventListener("htmx:historyRestore", function () {
      document.querySelectorAll(".site-nav").forEach(dismiss);
   }, true);

   document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape") return;
      var item = event.target.closest(".site-nav li.submenu-open");
      if (!item) return;
      var button = item.querySelector(":scope > .nav-entry > .submenu-toggle");
      close(item);
      if (button) button.focus();
   });
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
   }

   function cloneHeadNode(node) {
      if (node.tagName.toLowerCase() !== "script") return node.cloneNode(true);
      var script = document.createElement("script");
      Array.prototype.forEach.call(node.attributes, function (attribute) {
         script.setAttribute(attribute.name, attribute.value);
      });
      script.textContent = node.textContent || "";
      return script;
   }

   function adoptInitialPageHead() {
      var start = document.head.querySelector("[data-cms-page-head-start]");
      var end = document.head.querySelector("[data-cms-page-head-end]");
      if (!start || !end) return false;
      var node = start.nextSibling;
      while (node && node !== end) {
         if (node.nodeType === 1) node.setAttribute("data-cms-page-head", "true");
         node = node.nextSibling;
      }
      start.remove();
      end.remove();
      return true;
   }

   function updatePageHead(root) {
      var marker = root && root.querySelector ? root.querySelector(".cms-page-head") : null;
      if (!marker && root && root.matches && root.matches(".cms-page-head")) marker = root;
      if (!marker) marker = document.querySelector(".cms-page-head");
      if (!marker || !document.head) return;

      var initialHead = adoptInitialPageHead();
      if (!initialHead) {
         document.head.querySelectorAll("[data-cms-page-head]").forEach(function (node) {
            node.remove();
         });
      }

      var description = marker.getAttribute("data-cms-meta-description") || "";
      var descriptionNode = document.head.querySelector("meta[name='description']");
      if (description) {
         if (!descriptionNode) {
            descriptionNode = document.createElement("meta");
            descriptionNode.setAttribute("name", "description");
            document.head.appendChild(descriptionNode);
         }
         descriptionNode.setAttribute("content", description);
      } else if (descriptionNode) {
         descriptionNode.remove();
      }

      if (initialHead) return;
      var template = document.createElement("template");
      template.innerHTML = marker.getAttribute("data-cms-head-html") || "";
      Array.prototype.forEach.call(template.content.childNodes, function (node) {
         if (!node.tagName) return;
         var tag = node.tagName.toLowerCase();
         if (tag !== "script" && tag !== "link" && tag !== "meta" && tag !== "style") return;
         var target = cloneHeadNode(node);
         target.setAttribute("data-cms-page-head", "true");
         document.head.appendChild(target);
      });
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
      var target = event.detail && event.detail.target;
      updateChrome(target);
      updatePageHead(target);
   });
   listen("htmx:afterSettle", function () {
      updateChrome(document);
   });
   listen("htmx:historyRestore", function () {
      updateChrome(document);
      updatePageHead(document);
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
   window.cmsHtmxConnectionOverlay = {
      show: showError,
      hide: hideError
   };
   window.addEventListener("offline", function () {
      showError("The browser is offline.", "Reconnect to the network, then retry.");
   });
   window.addEventListener("online", hideError);
   updatePageHead(document);
}());
