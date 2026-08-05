import CoreLocation
import MapKit
import WebKit

/// Beantwortet die Nominatim-Suchanfragen der Web-Seite (via native-geocoding-bridge.js)
/// mit Apples eigener Ortssuche. Antwortet im Nominatim-JSON-Format, damit index.html
/// unverändert bleibt.
///
/// Für Vorschläge wird bewusst MKLocalSearchCompleter statt MKLocalSearch verwendet:
/// MKLocalSearch(naturalLanguageQuery:) ist eine allgemeine Suche und rankt bei kurzen,
/// unvollständigen Eingaben ("Base") oft unpassende Strassennamen vor dem naheliegenden
/// Ortsnamen ("Basel"). MKLocalSearchCompleter ist Apples Tippvervollständigungs-Engine
/// (dieselbe wie in der Maps-App-Suchleiste) und liefert dafür deutlich bessere Treffer.
final class NativeGeocoder: NSObject, MKLocalSearchCompleterDelegate {
    private weak var webView: WKWebView?
    private let diagnostics: DiagnosticsLog
    private let completer = MKLocalSearchCompleter()
    private var completionHandler: (([MKLocalSearchCompletion]) -> Void)?

    private let switzerlandRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.8, longitude: 8.2),
        span: MKCoordinateSpan(latitudeDelta: 3.2, longitudeDelta: 5.5)
    )

    init(diagnostics: DiagnosticsLog) {
        self.diagnostics = diagnostics
        super.init()
        completer.region = switzerlandRegion
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func handle(id: Int, urlString: String) {
        guard let comps = URLComponents(string: urlString) else {
            reject(id: id, message: "Ungültige Such-URL")
            return
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        if comps.path.hasSuffix("/reverse") {
            guard let latStr = value("lat"), let lonStr = value("lon"),
                  let lat = Double(latStr), let lon = Double(lonStr) else {
                reject(id: id, message: "Koordinaten fehlen"); return
            }
            reverseGeocode(id: id, lat: lat, lon: lon)
        } else {
            let query = value("q") ?? ""
            let limit = Int(value("limit") ?? "6") ?? 6
            search(id: id, query: query, limit: limit)
        }
    }

    private func search(id: Int, query: String, limit: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resolve(id: id, json: [])
            return
        }
        completionHandler = { [weak self] completions in
            self?.resolveCompletions(id: id, completions: completions, limit: limit)
        }
        completer.queryFragment = trimmed
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completionHandler?(completer.results)
        completionHandler = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        diagnostics.log(.info, source: "Geocoding", "Vorschläge ohne Treffer: \(error.localizedDescription)")
        completionHandler?([])
        completionHandler = nil
    }

    /// Jede Vervollständigung (nur Titel/Untertitel) braucht noch eine echte Koordinate –
    /// dafür pro Vorschlag eine gezielte MKLocalSearch, parallel, danach in Original-
    /// Reihenfolge wieder zusammengesetzt.
    private func resolveCompletions(id: Int, completions: [MKLocalSearchCompletion], limit: Int) {
        let candidates = Array(completions.prefix(limit))
        guard !candidates.isEmpty else {
            resolve(id: id, json: [])
            return
        }
        var resultsByIndex: [Int: [String: Any]] = [:]
        let group = DispatchGroup()
        for (index, completion) in candidates.enumerated() {
            group.enter()
            MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start { response, _ in
                if let item = response?.mapItems.first, item.placemark.isoCountryCode == "CH" {
                    resultsByIndex[index] = self.nominatimStyleResult(for: item)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let ordered = candidates.indices.compactMap { resultsByIndex[$0] }
            self.resolve(id: id, json: ordered)
        }
    }

    private func reverseGeocode(id: Int, lat: Double, lon: Double) {
        let location = CLLocation(latitude: lat, longitude: lon)
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self else { return }
            guard let placemark = placemarks?.first, error == nil else {
                self.resolve(id: id, json: ["address": [String: String]()])
                return
            }
            self.resolve(id: id, json: ["address": self.addressDict(for: placemark)])
        }
    }

    private func addressDict(for placemark: CLPlacemark) -> [String: String] {
        var dict: [String: String] = [:]
        if let road = placemark.thoroughfare { dict["road"] = road }
        if let houseNumber = placemark.subThoroughfare { dict["house_number"] = houseNumber }
        if let city = placemark.locality { dict["city"] = city }
        if let suburb = placemark.subLocality { dict["suburb"] = suburb }
        return dict
    }

    private func nominatimStyleResult(for item: MKMapItem) -> [String: Any] {
        let placemark = item.placemark
        var address = addressDict(for: placemark)
        if address["city"] == nil, let name = item.name { address["city"] = name }
        let nameParts = [item.name, placemark.locality, placemark.country].compactMap { $0 }
        let displayName = nameParts.isEmpty ? "Unbekannter Ort" : nameParts.joined(separator: ", ")
        return [
            "lat": placemark.coordinate.latitude,
            "lon": placemark.coordinate.longitude,
            "display_name": displayName,
            "address": address
        ]
    }

    private func resolve(id: Int, json: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            reject(id: id, message: "Antwort konnte nicht kodiert werden")
            return
        }
        let base64 = data.base64EncodedString()
        evaluate("window.__geocodeBridgeResolve && window.__geocodeBridgeResolve(\(id), '\(base64)');")
    }

    private func reject(id: Int, message: String) {
        diagnostics.log(.warning, source: "Geocoding", message)
        let escaped = message.replacingOccurrences(of: "'", with: "\\'")
        evaluate("window.__geocodeBridgeReject && window.__geocodeBridgeReject(\(id), '\(escaped)');")
    }

    private func evaluate(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
