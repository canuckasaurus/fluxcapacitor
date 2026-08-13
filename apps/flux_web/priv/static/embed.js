/*
 * FluxCapacitor site embed: floating chat bubble that opens the published
 * site in an iframe panel.
 *
 * Usage:
 *   <script src="https://your-host/embed.js"
 *           data-flux-site="https://your-host/site/site_..." defer></script>
 *
 * Optional theming attributes:
 *   data-flux-color="#0ea5e9"     bubble background
 *   data-flux-position="left"     bubble corner (default right)
 *   data-flux-icon="💬"           closed-state bubble glyph
 *   data-flux-greeting="Hi!"      one-time tooltip beside the bubble
 */
(function () {
  var script = document.currentScript;
  var siteUrl = script && script.getAttribute("data-flux-site");
  if (!siteUrl) return;

  var color = script.getAttribute("data-flux-color") || "#4f46e5";
  var side = script.getAttribute("data-flux-position") === "left" ? "left" : "right";
  var icon = script.getAttribute("data-flux-icon") || "✨";
  var greeting = script.getAttribute("data-flux-greeting");

  var open = false;

  var panel = document.createElement("iframe");
  panel.src = siteUrl;
  panel.setAttribute("allow", "clipboard-write");
  panel.style.cssText =
    "position:fixed;bottom:88px;" + side + ":20px;width:380px;max-width:calc(100vw - 40px);" +
    "height:600px;max-height:calc(100vh - 120px);border:0;border-radius:16px;" +
    "box-shadow:0 12px 40px rgba(0,0,0,.24);z-index:2147483646;display:none;" +
    "background:#fff;";

  var bubble = document.createElement("button");
  bubble.type = "button";
  bubble.setAttribute("aria-label", "Open chat");
  bubble.style.cssText =
    "position:fixed;bottom:20px;" + side + ":20px;width:56px;height:56px;border:0;" +
    "border-radius:50%;cursor:pointer;z-index:2147483647;background:" + color + ";" +
    "color:#fff;box-shadow:0 6px 20px rgba(0,0,0,.28);font-size:24px;line-height:1;";
  bubble.textContent = icon;

  var tip = null;
  if (greeting) {
    tip = document.createElement("div");
    tip.textContent = greeting;
    tip.style.cssText =
      "position:fixed;bottom:32px;" + side + ":88px;max-width:240px;padding:8px 12px;" +
      "border-radius:12px;background:#fff;color:#1f2937;font:14px/1.4 sans-serif;" +
      "box-shadow:0 6px 20px rgba(0,0,0,.18);z-index:2147483647;";
    document.body.appendChild(tip);
  }

  bubble.addEventListener("click", function () {
    open = !open;
    panel.style.display = open ? "block" : "none";
    bubble.textContent = open ? "✕" : icon;
    bubble.setAttribute("aria-label", open ? "Close chat" : "Open chat");
    if (tip) {
      tip.remove();
      tip = null;
    }
  });

  document.body.appendChild(panel);
  document.body.appendChild(bubble);
})();
