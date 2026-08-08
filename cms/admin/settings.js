(function () {
   "use strict";

   function install() {
      var htmx = document.getElementById("setting-htmx");
      var smq = document.getElementById("setting-smq");
      if (!htmx || !smq) return;

      function sync() {
         smq.disabled = !htmx.checked;
         if (!htmx.checked) smq.checked = false;
      }

      htmx.addEventListener("change", sync);
      sync();
   }

   if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", install, { once: true });
   } else {
      install();
   }
}());
