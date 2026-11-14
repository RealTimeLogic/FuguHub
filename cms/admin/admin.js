(function () {
   "use strict";

   function adminUrl() {
      var marker = "/admin/";
      var path = window.location.pathname;
      var index = path.indexOf(marker);
      return index >= 0 ? path.slice(0, index) + marker : "/";
   }

   function readJson(response, fallbackMessage) {
      var contentType = response.headers.get("Content-Type") || "";
      if (contentType.toLowerCase().indexOf("application/json") >= 0) {
         return response.json().then(function (payload) {
            if (response.status === 401 && payload.loginUrl) {
               window.location.assign(payload.loginUrl);
               return new Promise(function () {});
            }
            if (!response.ok || !payload.ok) {
               var error = new Error(payload.error || fallbackMessage || "Admin request failed");
               error.payload = payload;
               throw error;
            }
            return payload;
         });
      }

      return response.text().then(function (body) {
         var lowerType = contentType.toLowerCase();
         if (lowerType.indexOf("text/html") >= 0 &&
             (body.indexOf("Admin Login - CMS Admin") >= 0 ||
              body.indexOf("name='ba_seed'") >= 0 ||
              body.indexOf('name="ba_seed"') >= 0)) {
            window.location.assign(adminUrl());
            return new Promise(function () {});
         }
         var status = response.status ? " (HTTP " + response.status + ")" : "";
         throw new Error((fallbackMessage || "Admin request failed") + status);
      });
   }

   var fieldId = 0;
   function field(text, input, help) {
      var wrapper = document.createElement("div");
      wrapper.className = "field";
      input.id = input.id || "admin-field-" + (++fieldId);
      var caption = document.createElement("label");
      caption.className = "field-label";
      caption.htmlFor = input.id;
      caption.textContent = text;
      wrapper.append(caption, input);
      if (help) {
         var hint = document.createElement("small");
         hint.className = "muted";
         hint.id = input.id + "-help";
         hint.textContent = help;
         input.setAttribute("aria-describedby", hint.id);
         wrapper.appendChild(hint);
      }
      return wrapper;
   }

   window.FuguHubAdmin = { readJson: readJson, field: field };

   document.addEventListener("htmx:oobBeforeSwap", function (event) {
      if (event.detail.target.id !== "menu-add-parent_id") return;
      // Refresh choices without discarding a still-valid selection in the add form.
      var select = event.detail.fragment.querySelector("select");
      if (select && Array.from(select.options).some(function (option) {
         return option.value === event.detail.target.value;
      })) select.value = event.detail.target.value;
   });

   var sidebar = document.querySelector(".sidebar");
   var nav = sidebar && sidebar.querySelector(".nav");
   if (nav) {
      var toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = "nav-toggle secondary";
      toggle.textContent = "Menu";
      nav.id = "admin-navigation";
      toggle.setAttribute("aria-controls", nav.id);
      sidebar.insertBefore(toggle, nav);
      var compact = window.matchMedia("(max-width: 900px)");
      var expanded = false;
      function syncNav() {
         var focused = document.activeElement;
         nav.hidden = compact.matches && !expanded;
         toggle.hidden = !compact.matches;
         toggle.setAttribute("aria-expanded", String(!nav.hidden));
         if (nav.hidden && nav.contains(focused)) toggle.focus();
         if (!compact.matches && focused === toggle) nav.querySelector("a").focus();
      }
      toggle.addEventListener("click", function () { expanded = !expanded; syncNav(); });
      compact.addEventListener("change", syncNav);
      syncNav();
   }
   var endpoint = document.getElementById("mcp-endpoint");
   if (endpoint) {
      endpoint.value = new URL(endpoint.value, window.location.href).href;
      endpoint.addEventListener("focus", function () { endpoint.select(); });
   }
}());
