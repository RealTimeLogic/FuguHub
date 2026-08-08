"use strict";

var socketUrl = process.argv[2];
var expression = Buffer.from(process.argv[3], "base64").toString("utf8");
var socket = new WebSocket(socketUrl);

function fail(message) {
   process.stderr.write(String(message) + "\n");
   process.exitCode = 1;
   try {
      socket.close();
   } catch (_) {
      process.exit();
   }
}

socket.addEventListener("open", function () {
   socket.send(JSON.stringify({
      id: 1,
      method: "Runtime.evaluate",
      params: {
         expression: expression,
         awaitPromise: true,
         returnByValue: true
      }
   }));
});

socket.addEventListener("message", function (event) {
   var message = JSON.parse(String(event.data));
   if (message.id !== 1) return;
   if (message.error) {
      fail(JSON.stringify(message.error));
      return;
   }
   var result = message.result && message.result.result;
   if (result && result.subtype === "error") {
      fail(result.description || "Runtime.evaluate failed");
      return;
   }
   process.stdout.write(JSON.stringify(result ? result.value : null));
   socket.close();
});

socket.addEventListener("error", function () {
   fail("DevTools WebSocket connection failed");
});
