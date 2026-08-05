// diagnostics-bridge.js
// Leitet JavaScript-Fehler (console.error, unbehandelte Exceptions, fehlgeschlagene
// fetch-Requests) an die native Diagnose-Konsole weiter, damit sie im
// Fehlerbanner/Debug-Log der App sichtbar werden.
(function () {
  if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.diagBridge) {
    return;
  }

  function report(message) {
    try {
      window.webkit.messageHandlers.diagBridge.postMessage(String(message));
    } catch (e) { /* ignore */ }
  }

  const originalError = console.error;
  console.error = function () {
    report(Array.prototype.slice.call(arguments).join(' '));
    originalError.apply(console, arguments);
  };

  window.addEventListener('error', function (e) {
    report((e.message || 'Unbekannter Fehler') + ' (' + (e.filename || '') + ':' + (e.lineno || 0) + ')');
  });

  window.addEventListener('unhandledrejection', function (e) {
    report('Unhandled promise rejection: ' + (e.reason && e.reason.message ? e.reason.message : e.reason));
  });
})();
