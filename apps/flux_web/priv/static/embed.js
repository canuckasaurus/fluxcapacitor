/*
 * FluxCapacitor site embed: floating chat bubble that opens the published
 * site in an iframe panel.
 *
 * Usage:
 *   <script src="https://your-host/embed.js"
 *           data-flux-site="https://your-host/site/site_..." defer></script>
 */
(function () {
  var script = document.currentScript;
  var siteUrl = script && script.getAttribute("data-flux-site");
  if (!siteUrl) return;

  var open = false;

  var panel = document.createElement("iframe");
  panel.src = siteUrl;
  panel.setAttribute("allow", "clipboard-write");
  panel.style.cssText =
    "position:fixed;bottom:88px;right:20px;width:380px;max-width:calc(100vw - 40px);" +
    "height:600px;max-height:calc(100vh - 120px);border:0;border-radius:16px;" +
    "box-shadow:0 12px 40px rgba(0,0,0,.24);z-index:2147483646;display:none;" +
    "background:#fff;";

  var bubble = document.createElement("button");
  bubble.type = "button";
  bubble.setAttribute("aria-label", "Open chat");
  bubble.style.cssText =
    "position:fixed;bottom:20px;right:20px;width:56px;height:56px;border:0;" +
    "border-radius:50%;cursor:pointer;z-index:2147483647;background:#4f46e5;" +
    "color:#fff;box-shadow:0 6px 20px rgba(0,0,0,.28);font-size:24px;line-height:1;";
  bubble.textContent = "✨";

  bubble.addEventListener("click", function () {
    open = !open;
    panel.style.display = open ? "block" : "none";
    bubble.textContent = open ? "✕" : "✨";
    bubble.setAttribute("aria-label", open ? "Close chat" : "Open chat");
  });

  document.body.appendChild(panel);
  document.body.appendChild(bubble);
})();
