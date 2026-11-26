// phoenix_kit_sync JS — folded into the host's page by core's
// :phoenix_kit_js_sources compiler (see PhoenixKitSync.js_sources/0).
//
// DECLARATIVE HANDLERS
//
// The module's markup carries no inline event handler (`onclick="…"`): a
// Content-Security-Policy that allows inline code by nonce only blocks every
// one of them, since no nonce can cover an attribute. The markup names what it
// wants with a `data-pks-*` attribute and ONE document listener here does it.
// Delegated rather than a LiveView hook, so nothing depends on the host's
// LiveSocket having been built with a hook of this module, and a button that
// LiveView patches in later works too.
//
//   data-pks-copy="text"   a click copies the text. While the copy is fresh
//                          (two seconds) the button's `.copy-icon` is hidden
//                          and its `.check-icon` shown.
//
// The attribute prefix is the module's own (`data-pks-`), not core's
// `data-pk-`: core's listeners exist only in cores newer than this module's
// core floor.
(function () {
  "use strict";

  // The global `js_sources/0` declares. The module has no LiveView hooks; the
  // compiler folds this (empty) map into window.PhoenixKitHooks.
  window.PhoenixKitSyncHooks = window.PhoenixKitSyncHooks || {};

  // The bundle may be evaluated twice (the compiled modules file and a host
  // import): one listener only.
  if (window.__pksDeclaredHandlers) return;
  window.__pksDeclaredHandlers = true;

  var COPIED_MS = 2000;

  function closest(target, selector) {
    return target && typeof target.closest === "function" ? target.closest(selector) : null;
  }

  function swap(button, copied) {
    var copy = button.querySelector(".copy-icon");
    var check = button.querySelector(".check-icon");
    if (copy) copy.classList.toggle("hidden", copied);
    if (check) check.classList.toggle("hidden", !copied);
  }

  function onClick(e) {
    var button = closest(e.target, "[data-pks-copy]");
    if (!button || !navigator.clipboard) return;

    navigator.clipboard
      .writeText(button.getAttribute("data-pks-copy"))
      .then(function () {
        swap(button, true);
        setTimeout(function () { swap(button, false); }, COPIED_MS);
      })
      .catch(function () {});
  }

  document.addEventListener("click", onClick);
})();
