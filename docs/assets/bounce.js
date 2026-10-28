// Hands the answer from a sign-in page (GitHub or OpenRouter) back to the MAIPA-G app.
//
// Those services can only send people back to a web address, so they send them here, and this
// page passes the same answer on to the app's own address (maipag://...). Only the query string
// is passed on, and only to the fixed address written into the page that loads this script.
(function () {
  var script = document.currentScript;
  var target = script && script.getAttribute("data-target");
  if (!target || target.indexOf("maipag://") !== 0) return;
  var destination = target + window.location.search;
  var link = document.getElementById("back");
  if (link) link.setAttribute("href", destination);
  window.location.replace(destination);
})();
