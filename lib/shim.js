// PortKit compatibility shim.
// Injected first into content scripts and every extension HTML page so that
// chrome.* APIs Safari lacks degrade quietly instead of throwing and blanking
// the page. Our own code; safe to run twice; never throws.
(function () {
  "use strict";

  // Safari exposes both `chrome` and `browser`; patch whichever exist.
  var targets = [];
  if (typeof chrome !== "undefined" && chrome) targets.push(chrome);
  if (typeof browser !== "undefined" && browser && browser !== (typeof chrome !== "undefined" ? chrome : null)) {
    targets.push(browser);
  }
  if (!targets.length) return;

  // A no-op that returns a resolved promise, so `await api.foo()` never hangs
  // and callback-style `api.foo(cb)` still fires.
  function noop() {
    var cb = arguments[arguments.length - 1];
    if (typeof cb === "function") { try { cb(); } catch (e) {} }
    return Promise.resolve();
  }

  // An event-like object so `api.onFoo.addListener(...)` doesn't throw.
  function fakeEvent() {
    return { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } };
  }

  function ensure(obj, name, factory) {
    if (!obj[name]) {
      try { obj[name] = factory(); } catch (e) {}
    }
  }

  targets.forEach(function (api) {
    // storage.sync -> storage.local (Safari has no iCloud extension sync)
    if (api.storage && api.storage.local && !api.storage.sync) {
      try { api.storage.sync = api.storage.local; } catch (e) {}
    }

    // Namespaces Safari does not implement — stub so evaluation survives.
    ensure(api, "sidePanel", function () {
      return { open: noop, setOptions: noop, getOptions: noop, setPanelBehavior: noop };
    });
    ensure(api, "identity", function () {
      return {
        getRedirectURL: function () { return ""; },
        getAuthToken: noop,
        removeCachedAuthToken: noop,
        launchWebAuthFlow: noop,
        onSignInChanged: fakeEvent(),
      };
    });
    ensure(api, "notifications", function () {
      return {
        create: noop, update: noop, clear: noop, getAll: noop,
        onClicked: fakeEvent(), onClosed: fakeEvent(), onButtonClicked: fakeEvent(),
      };
    });
    ensure(api, "tabGroups", function () {
      return { get: noop, query: noop, update: noop, move: noop,
               onCreated: fakeEvent(), onUpdated: fakeEvent(), onRemoved: fakeEvent() };
    });
    ensure(api, "offscreen", function () {
      return { createDocument: noop, closeDocument: noop, hasDocument: function () { return Promise.resolve(false); } };
    });
    ensure(api, "debugger", function () {
      return { attach: noop, detach: noop, sendCommand: noop,
               onEvent: fakeEvent(), onDetach: fakeEvent() };
    });
  });
})();
