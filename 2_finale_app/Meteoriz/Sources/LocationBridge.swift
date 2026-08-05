import CoreLocation
import WebKit

/// Beantwortet Standortanfragen der Web-Seite (via geo-bridge.js) mit dem echten,
/// nativen CoreLocation-Standort. Die Berechtigung wird von iOS selbst dauerhaft in
/// Einstellungen > Datenschutz > Ortungsdienste gespeichert – anders als bei einer
/// Web-Geolocation-Abfrage im Browser, die pro Sitzung neu auftauchen kann.
final class LocationBridge: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private weak var webView: WKWebView?
    private var pendingRequestIds: [Int] = []
    private let diagnostics: DiagnosticsLog

    // Für eine Wetter-App reicht Strassen-/Quartier-Genauigkeit locker aus – die
    // höchste Genauigkeitsstufe (kCLLocationAccuracyBest) lässt CoreLocation auf
    // einen verfeinerten GPS-Fix warten und macht die Standortabfrage spürbar
    // langsamer als nötig.
    private static let timeout: TimeInterval = 8

    init(diagnostics: DiagnosticsLog) {
        self.diagnostics = diagnostics
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func handleRequest(id: Int) {
        pendingRequestIds.append(id)
        scheduleTimeout(for: id)
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            reject(ids: [id], code: 1, message: "Standortzugriff verweigert")
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        @unknown default:
            reject(ids: [id], code: 2, message: "Standort nicht verfügbar")
        }
    }

    private func scheduleTimeout(for id: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self, self.pendingRequestIds.contains(id) else { return }
            self.diagnostics.log(.info, source: "CoreLocation", "Standortabfrage \(id) nach \(Int(Self.timeout))s ohne Ergebnis abgebrochen")
            self.reject(ids: [id], code: 3, message: "Zeitüberschreitung – erneut versuchen")
        }
    }

    func clearWatch(id: Int) {
        pendingRequestIds.removeAll { $0 == id }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if !pendingRequestIds.isEmpty { manager.requestLocation() }
        case .denied, .restricted:
            rejectAllPending(code: 1, message: "Standortzugriff verweigert")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let ids = pendingRequestIds
        pendingRequestIds.removeAll()
        for id in ids {
            resolve(id: id, location: loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        diagnostics.log(.warning, source: "CoreLocation", error.localizedDescription)
        let clErr = error as? CLError
        let code = clErr?.code == .denied ? 1 : (clErr?.code == .network ? 2 : 3)
        rejectAllPending(code: code, message: error.localizedDescription)
    }

    // MARK: - JS callbacks

    private func resolve(id: Int, location: CLLocation) {
        let js = """
        window.__geoBridgeResolve && window.__geoBridgeResolve(\(id), {
          latitude: \(location.coordinate.latitude),
          longitude: \(location.coordinate.longitude),
          accuracy: \(location.horizontalAccuracy),
          altitude: \(location.altitude),
          altitudeAccuracy: \(location.verticalAccuracy),
          heading: \(location.course >= 0 ? location.course : -1),
          speed: \(location.speed >= 0 ? location.speed : -1)
        });
        """
        evaluate(js)
    }

    private func reject(ids: [Int], code: Int, message: String) {
        pendingRequestIds.removeAll { ids.contains($0) }
        for id in ids {
            let escaped = message.replacingOccurrences(of: "\"", with: "'")
            evaluate("window.__geoBridgeReject && window.__geoBridgeReject(\(id), \(code), \"\(escaped)\");")
        }
    }

    private func rejectAllPending(code: Int, message: String) {
        let ids = pendingRequestIds
        pendingRequestIds.removeAll()
        for id in ids {
            let escaped = message.replacingOccurrences(of: "\"", with: "'")
            evaluate("window.__geoBridgeReject && window.__geoBridgeReject(\(id), \(code), \"\(escaped)\");")
        }
    }

    private func evaluate(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
