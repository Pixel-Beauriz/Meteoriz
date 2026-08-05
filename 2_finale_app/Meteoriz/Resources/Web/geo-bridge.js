// geo-bridge.js
// WKWebView implementiert die Web-Geolocation-API (navigator.geolocation) nicht nativ.
// Dieses Skript wird VOR dem Seiten-Code injiziert und ersetzt navigator.geolocation
// durch eine Bridge zur nativen CoreLocation-Anfrage (LocationBridge.swift). Dadurch
// bleibt die Standortfreigabe wie bei jeder normalen iOS-App dauerhaft in den
// System-Einstellungen gespeichert, statt bei jedem Seitenaufruf neu gefragt zu werden.
(function () {
  if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.geoBridge) {
    return; // Bridge nicht verfügbar (z.B. Vorschau im normalen Browser) -> Original-API unangetastet lassen
  }

  const pending = {};
  const watchers = {};
  let nextId = 1;

  function send(payload) {
    window.webkit.messageHandlers.geoBridge.postMessage(payload);
  }

  window.__geoBridgeResolve = function (id, coords) {
    const cb = pending[id] || watchers[id];
    if (!cb) return;
    if (!watchers[id]) delete pending[id];
    cb.success({
      coords: {
        latitude: coords.latitude,
        longitude: coords.longitude,
        accuracy: coords.accuracy,
        altitude: coords.altitude,
        altitudeAccuracy: coords.altitudeAccuracy,
        heading: coords.heading,
        speed: coords.speed
      },
      timestamp: Date.now()
    });
  };

  window.__geoBridgeReject = function (id, code, message) {
    const cb = pending[id] || watchers[id];
    if (!cb) return;
    if (!watchers[id]) delete pending[id];
    if (cb.error) cb.error({ code: code, message: message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
  };

  const bridgeGeolocation = {
    getCurrentPosition: function (success, error, options) {
      const id = nextId++;
      pending[id] = { success: success, error: error };
      send({ type: 'getCurrentPosition', id: id });
    },
    watchPosition: function (success, error, options) {
      const id = nextId++;
      watchers[id] = { success: success, error: error };
      send({ type: 'watchPosition', id: id });
      return id;
    },
    clearWatch: function (id) {
      delete watchers[id];
      send({ type: 'clearWatch', id: id });
    }
  };

  // navigator.geolocation ist in WebKit eine schreibgeschützte accessor-Property
  // (nur ein Getter, kein Setter) – eine einfache Zuweisung ("navigator.geolocation = ...")
  // schlägt dadurch STILL fehl (kein Fehler, aber auch keine Wirkung), und die Seite
  // benutzt weiterhin WebKits eigene, eingebaute Geolocation-Implementierung samt
  // deren eigenem Freigabedialog statt unserer nativen Bridge. Object.defineProperty
  // kann eine konfigurierbare accessor-Property gezielt überschreiben und funktioniert
  // zuverlässig, wo eine reine Zuweisung es nicht tut.
  try {
    Object.defineProperty(navigator, 'geolocation', {
      value: bridgeGeolocation,
      configurable: true,
      writable: true,
      enumerable: true
    });
  } catch (e) {
    navigator.geolocation = bridgeGeolocation;
  }
})();
