import SwiftUI
import MapKit
import CoreLocation

// MARK: - Coordenadas desde un link de Google Maps

/// Extrae (lat, lng) de un texto pegado: link largo/corto de Google Maps o un par "lat, lng".
/// Cubre los formatos directos; los links cortos (goo.gl / maps.app.goo.gl) se resuelven con
/// `resolveMapsLink` (una petición HTTP que sigue el redirect).
func googleMapsCoords(from text: String) -> (Double, Double)? {
    let patterns = [
        "@(-?\\d{1,3}\\.\\d+),(-?\\d{1,3}\\.\\d+)",                                    // /maps/@LAT,LNG,zoom
        "[?&](?:q|ll|sll|center|daddr|destination|saddr)=(-?\\d{1,3}\\.\\d+),(-?\\d{1,3}\\.\\d+)", // ?q=LAT,LNG
        "!3d(-?\\d{1,3}\\.\\d+)!4d(-?\\d{1,3}\\.\\d+)",                                // ...!3dLAT!4dLNG
        "^\\s*(-?\\d{1,3}\\.\\d+)\\s*,\\s*(-?\\d{1,3}\\.\\d+)\\s*$",                    // "LAT, LNG" pegado
        "(-?\\d{1,3}\\.\\d{4,}),(-?\\d{1,3}\\.\\d{4,})",                               // último recurso: par con 4+ decimales
    ]
    for p in patterns {
        guard let re = try? NSRegularExpression(pattern: p) else { continue }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges >= 3,
              let latR = Range(m.range(at: 1), in: text),
              let lngR = Range(m.range(at: 2), in: text),
              let lat = Double(text[latR]), let lng = Double(text[lngR]),
              (-90...90).contains(lat), (-180...180).contains(lng) else { continue }
        return (lat, lng)
    }
    return nil
}

/// Captura cada URL de la cadena de redirects (el link corto salta a la URL larga de Maps —con las
/// coords— antes de caer en la página de consentimiento de Google).
private final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
    var urls: [String] = []
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = request.url?.absoluteString { urls.append(u) }
        completionHandler(request)
    }
}

/// Saca una dirección legible de una URL de Maps que NO trae coordenadas: el `q=<dirección>`
/// (cuando no es un par de números) o el nombre en `/place/<nombre>/`.
private func addressFromMapsURL(_ s: String) -> String? {
    if let comps = URLComponents(string: s) {
        for name in ["q", "daddr", "destination"] {
            if let raw = comps.queryItems?.first(where: { $0.name == name })?.value {
                let v = raw.replacingOccurrences(of: "+", with: " ") // '+' en query = espacio
                if !v.isEmpty, googleMapsCoords(from: v) == nil { return v }
            }
        }
    }
    if let r = s.range(of: "/place/") {
        let after = s[r.upperBound...].prefix { $0 != "/" && $0 != "?" }
        let decoded = String(after).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        if let d = decoded, !d.isEmpty, !d.hasPrefix("@") { return d }
    }
    return nil
}

/// Geocodifica una dirección a coordenadas con el servicio de Apple (CLGeocoder): gratis, sin API
/// key ni permisos. Da un punto aproximado del lugar cuando el link solo trae la dirección.
private func geocodeAddress(_ address: String) async -> (Double, Double)? {
    let geo = CLGeocoder()
    if let marks = try? await geo.geocodeAddressString(address), let loc = marks.first?.location {
        return (loc.coordinate.latitude, loc.coordinate.longitude)
    }
    return nil
}

/// Resuelve un link de Google Maps a coordenadas. Directo (link largo con @LAT,LNG) → al toque.
/// Corto (maps.app.goo.gl) → con un User-Agent NO de navegador, Google hace 302 a la URL real.
/// Si esa URL trae coords, las usa; si solo trae la dirección (caso común de "compartir lugar"),
/// la geocodifica con Apple. (Con UA de navegador Google devuelve una página JS sin datos.)
func resolveMapsLink(_ raw: String) async -> (Double, Double)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let c = googleMapsCoords(from: trimmed) { return c }
    guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return nil }

    let catcher = RedirectCatcher()
    let session = URLSession(configuration: .ephemeral, delegate: catcher, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var req = URLRequest(url: url)
    req.setValue("Crona/1.0", forHTTPHeaderField: "User-Agent") // NO navegador → Google hace el 302 real
    req.timeoutInterval = 15
    do {
        let (data, resp) = try await session.data(for: req)
        var candidates = catcher.urls
        if let final = resp.url?.absoluteString { candidates.append(final) }
        if let html = String(data: data, encoding: .utf8) { candidates.append(html) }
        // 1) coordenadas directas en cualquier URL de la cadena o el HTML (crudo o decodificado)
        for c in candidates {
            if let hit = googleMapsCoords(from: c) { return hit }
            if let dec = c.removingPercentEncoding, let hit = googleMapsCoords(from: dec) { return hit }
        }
        // 2) sin coords → geocodifica la dirección del link (q=… o /place/…)
        for c in candidates {
            if let addr = addressFromMapsURL(c), let hit = await geocodeAddress(addr) { return hit }
        }
    } catch { }
    return nil
}

// MARK: - Ubicación actual (una sola lectura)

/// Envoltorio mínimo de CLLocationManager: pide permiso "cuando se usa" y una única lectura.
@Observable
final class LocationOneShot: NSObject, CLLocationManagerDelegate {
    var coordinate: CLLocationCoordinate2D?
    var denied = false
    private let mgr = CLLocationManager()

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        mgr.requestWhenInUseAuthorization()
        mgr.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .denied, .restricted: denied = true
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        if let c = locs.last?.coordinate { coordinate = c }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - Elegir un punto en el mapa (como WhatsApp)

/// Mapa a pantalla con un pin fijo en el centro. Al mover el mapa cambian las coordenadas del
/// centro; "Mandar esta ubicación" las devuelve. En iOS arranca centrado en tu ubicación real.
struct LocationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Devuelve (lat, lng). El nombre/dirección se completa aparte.
    let onPick: (Double, Double) -> Void

    @State private var camera: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    @State private var centered = false
    @State private var locator = LocationOneShot()

    var body: some View {
        NavigationStack {
            // La bolita va como overlay del propio Map: se centra en el FRAME del mapa, que es
            // exactamente lo que devuelve region.center. Sin ignoresSafeArea, la barra de abajo
            // encoge el mapa y el centro visible = centro real = coordenada que se envía.
            Map(position: $camera)
                .onMapCameraChange(frequency: .continuous) { ctx in
                    center = ctx.region.center
                }
                .overlay { LocationCenterDot().allowsHitTesting(false) }
                .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let c = center {
                        Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        if let c = center { onPick(c.latitude, c.longitude); dismiss() }
                    } label: {
                        Text("Mandar esta ubicación")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(center == nil)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .navigationTitle("Elegir ubicación")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button { locator.request() } label: { Image(systemName: "location.fill") }
                        .help("Centrar en mi ubicación")
                }
                #endif
            }
        }
        #if os(iOS)
        .onAppear { locator.request() }
        #endif
        // Cuando llega la ubicación real, centra el mapa (solo la 1ª vez, para no pisar el paneo).
        .onChange(of: locator.coordinate?.latitude) { _, _ in
            guard let c = locator.coordinate else { return }
            if !centered { centered = true }
            center = c   // habilita "Mandar" aunque el usuario no mueva el mapa
            withAnimation {
                camera = .region(MKCoordinateRegion(center: c,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))
            }
        }
    }
}

/// Marcador central: bolita blanca con una bolita verde que late (crece y se encoge) dentro.
/// Va centrado en el frame del mapa → coincide exactamente con region.center (la coord que se envía).
private struct LocationCenterDot: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            Circle().fill(Theme.accent)
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1.0 : 0.72)
                .opacity(pulse ? 1.0 : 0.82)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
