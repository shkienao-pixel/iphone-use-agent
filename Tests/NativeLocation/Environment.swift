import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
enum CLAuthorizationStatus { case notDetermined, authorizedWhenInUse, authorizedAlways, denied, restricted }
struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double }
struct CLLocation {
    var coordinate = CLLocationCoordinate2D(latitude: 10.1234, longitude: 20.5678)
    var horizontalAccuracy: Double = 200
    var timestamp = Date()
}
let kCLLocationAccuracyHundredMeters: Double = 100
@MainActor protocol CLLocationManagerDelegate: AnyObject {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager)
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error)
}
@MainActor final class CLLocationManager {
    static var latest: CLLocationManager!
    weak var delegate: (any CLLocationManagerDelegate)?
    var desiredAccuracy: Double = 0
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var permissionRequests = 0, locationRequests = 0, stops = 0
    init() { Self.latest = self }
    func requestWhenInUseAuthorization() { permissionRequests += 1 }
    func requestLocation() { locationRequests += 1 }
    func stopUpdatingLocation() { stops += 1 }
    func grant() { authorizationStatus = .authorizedWhenInUse; delegate?.locationManagerDidChangeAuthorization(self) }
    func deliver(_ location: CLLocation = CLLocation()) { delegate?.locationManager(self, didUpdateLocations: [location]) }
}
