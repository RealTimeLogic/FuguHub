(function () {
   "use strict";

   var root = document.getElementById("file-service-app");
   var token = document.querySelector(
      ".file-service-shell input[name='_csrf']"
   );
   if (!root || !token) return;
   var csrf = token.value;
   var state;
   var selectedRoleName;

   function el(tag, options) {
      var node = document.createElement(tag);
      options = options || {};
      if (options.id) node.id = options.id;
      if (options.className) node.className = options.className;
      if (options.text !== undefined) node.textContent = options.text;
      if (options.name) node.name = options.name;
      if (options.type) node.type = options.type;
      if (options.value !== undefined) node.value = options.value;
      if (options.required) node.required = true;
      if (options.href) node.href = options.href;
      if (options.title) node.title = options.title;
      return node;
   }

   function add(parent) {
      for (var i = 1; i < arguments.length; i += 1) {
         parent.appendChild(arguments[i]);
      }
      return parent;
   }

   function field(label, input) {
      return add(el("div", { className: "field" }),
         el("label", { text: label }), input);
   }

   function button(text, className, fn) {
      var node = el("button", {
         type: "button", text: text, className: className || ""
      });
      node.addEventListener("click", fn);
      return node;
   }

   function normalize(payload) {
      payload.acls = Array.isArray(payload.acls) ? payload.acls : [];
      payload.roles = Array.isArray(payload.roles) ? payload.roles : [];
      if (!payload.roles.some(function (role) {
         return role.name === selectedRoleName;
      })) {
         var preferred = payload.roles.find(function (role) {
            return role.name === "file-admin";
         });
         selectedRoleName = preferred ? preferred.name :
            (payload.roles[0] ? payload.roles[0].name : "");
      }
      return payload;
   }

   function message(text, error) {
      var target = document.getElementById("file-service-message");
      if (!target) return;
      target.textContent = text || "";
      target.className = "file-service-message" + (error ? " error" : "");
   }

   function request(fields) {
      fields._csrf = csrf;
      var body = new URLSearchParams();
      Object.keys(fields).forEach(function (key) { body.set(key, fields[key]); });
      message("Saving...", false);
      return fetch("api/", {
         method: "POST",
         credentials: "same-origin",
         headers: { "Content-Type": "application/x-www-form-urlencoded" },
         body: body.toString()
      }).then(read);
   }

   function read(response) {
      return window.FuguHubAdmin.readJson(
         response, "File-service request failed"
      ).then(normalize);
   }

   function collect(form, action) {
      var result = { action: action };
      new FormData(form).forEach(function (value, name) {
         result[name] = String(value);
      });
      return result;
   }

   function settingsForm() {
      var settings = state.settings;
      var form = el("form", { className: "file-service-form" });
      var grid = el("div", { className: "file-service-grid" });
      var uploads = el("input", {
         name: "max_uploads", type: "number", value: settings.maxUploads
      });
      var locks = el("input", {
         name: "max_locks", type: "number", value: settings.maxLocks
      });
      var timeout = el("input", {
         name: "session_timeout", type: "number", value: settings.sessionTimeout
      });
      add(grid,
         field("Base URL (mako.conf)", el("output", {
            text: settings.baseUrl
         })),
         field("Lock directory (mako.conf)", el("output", {
            text: settings.lockDir
         })),
         field("Maximum uploads", uploads),
         field("Maximum locks", locks),
         field("Session URL timeout", timeout)
      );
      form.appendChild(grid);
      var flags = el("div", { className: "file-service-flags" });
      var enabled = el("input", { name: "enabled", type: "checkbox", value: "1" });
      enabled.checked = settings.enabled;
      var enabledLabel = add(el("label"), enabled,
         document.createTextNode("Enabled"));
      var sensitive = el("input", {
         name: "case_sensitive", type: "checkbox", value: "1"
      });
      sensitive.checked = settings.caseSensitive;
      var sensitiveLabel = add(el("label"), sensitive,
         document.createTextNode("Case-sensitive paths"));
      add(flags, enabledLabel, sensitiveLabel);
      form.appendChild(flags);
      form.appendChild(button("Save Settings", "", function () {
         request(collect(form, "save-settings")).then(function (payload) {
            state = payload;
            render();
            message("Settings saved.", false);
         }).catch(function (error) { message(error.message, true); });
      }));
      return form;
   }

   function pathInputValue(path) {
      if (!path || path === "/*") return "/";
      return path.replace(/\/\*$/, "/");
   }

   function pathLabel(path) {
      return path === "/*" ? "/ (all files)" : pathInputValue(path);
   }

   function permissionLabel(permission) {
      return permission === "write" ? "Read & write" : "Read only";
   }

   function aclForm(acl, roleName) {
      var form = el("form", { className: "file-service-form" });
      if (acl) form.appendChild(el("input", {
         name: "id", type: "hidden", value: acl.id
      }));
      form.appendChild(el("input", {
         name: "role", type: "hidden", value: roleName
      }));
      var path = el("input", {
         name: "path", value: acl ? pathInputValue(acl.path) : "/", required: true
      });
      var permission = el("select", { name: "permission" });
      ["read", "write"].forEach(function (value) {
         var option = el("option", {
            text: permissionLabel(value), value: value
         });
         option.selected = acl ? acl.permission === value : value === "read";
         permission.appendChild(option);
      });
      var grid = el("div", { className: "file-service-grid" });
      add(grid,
         field("Path", path),
         field("Permission", permission)
      );
      form.appendChild(grid);
      var flags = el("div", { className: "file-service-flags" });
      var enabled = el("input", {
         name: "enabled", type: "checkbox", value: "1"
      });
      enabled.checked = acl ? acl.enabled : true;
      add(flags, add(el("label"), enabled, document.createTextNode("Enabled")));
      form.appendChild(flags);
      var actions = el("div", { className: "file-service-actions" });
      actions.appendChild(button(acl ? "Save" : "Add path", "", function () {
         request(collect(form, "save-acl")).then(function (payload) {
            state = payload;
            render();
            message("File access saved.", false);
         }).catch(function (error) { message(error.message, true); });
      }));
      if (acl) {
         actions.appendChild(button("Delete", "danger", function () {
            if (!window.confirm("Remove access to " + pathLabel(acl.path) + "?")) return;
            request({ action: "delete-acl", id: String(acl.id) })
               .then(function (payload) {
                  state = payload;
                  render();
                  message("File access removed.", false);
               }).catch(function (error) { message(error.message, true); });
         }));
      }
      form.appendChild(actions);
      return form;
   }

   function roleAccessSection() {
      var access = el("section", { className: "file-service-section" });
      access.appendChild(el("h2", { text: "File Access" }));
      if (!state.roles.length) {
         access.appendChild(el("p", {
            className: "muted", text: "No identity roles are available."
         }));
         return access;
      }

      var role = state.roles.find(function (item) {
         return item.name === selectedRoleName;
      }) || state.roles[0];
      selectedRoleName = role.name;
      var roleSelect = el("select", { name: "selected_role" });
      state.roles.forEach(function (item) {
         var option = el("option", {
            text: item.name, value: item.name, title: item.description || ""
         });
         option.selected = item.name === selectedRoleName;
         roleSelect.appendChild(option);
      });
      roleSelect.addEventListener("change", function () {
         selectedRoleName = roleSelect.value;
         render();
      });
      var assignedText = role.assignedUsers === 1 ?
         "1 assigned user" : role.assignedUsers + " assigned users";
      var roleMeta = el("div", { className: "file-service-role-meta" });
      add(roleMeta,
         el("span", { text: role.description || "" }),
         el("a", { text: assignedText, href: state.usersUrl })
      );
      add(access,
         add(el("div", { className: "file-service-role-toolbar" }),
            field("Role", roleSelect), roleMeta),
         el("h3", { text: "Add file access" }),
         aclForm(null, selectedRoleName)
      );

      var grants = state.acls.filter(function (acl) {
         return acl.role === selectedRoleName;
      }).sort(function (left, right) {
         return left.path.localeCompare(right.path);
      });
      var list = el("div", { className: "file-service-grants" });
      list.appendChild(el("h3", { text: "Access paths" }));
      if (!grants.length) {
         list.appendChild(el("p", {
            className: "muted file-service-empty",
            text: "This role has no file access."
         }));
      }
      grants.forEach(function (acl) {
         var card = el("article", { className: "file-service-card" });
         add(card,
            add(el("div", { className: "file-service-grant-heading" }),
               el("h3", { text: pathLabel(acl.path) }),
               el("span", {
                  className: "file-service-permission",
                  text: permissionLabel(acl.permission)
               })),
            aclForm(acl, selectedRoleName)
         );
         list.appendChild(card);
      });
      access.appendChild(list);
      return access;
   }

   function render() {
      root.replaceChildren();
      root.appendChild(el("p", {
         id: "file-service-message",
         className: "file-service-message",
         text: state.runtimeError || (
            state.active ? "File Services is active at " + state.mountUrl :
               "File Services is disabled."
         )
      }));
      var columns = el("div", { className: "file-service-columns" });
      var settings = el("section", { className: "file-service-section" });
      add(settings, el("h2", { text: "Settings" }), settingsForm());
      add(columns, settings, roleAccessSection());
      root.appendChild(columns);
   }

   fetch("api/", { credentials: "same-origin" })
      .then(read)
      .then(function (payload) {
         state = payload;
         render();
      })
      .catch(function (error) {
         root.textContent = "File-service data could not be loaded: " + error.message;
      });
}());
