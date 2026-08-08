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
               throw new Error(payload.error || fallbackMessage || "Admin request failed");
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

   window.FuguHubAdmin = {
      readJson: readJson
   };
}());
