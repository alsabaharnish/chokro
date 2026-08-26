import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Device location, for the disposal geofence check (F2.4).
///
/// Wraps `geolocator` so the rest of the app deals in one result type instead of
/// a permission enum, a service-enabled boolean and a thrown timeout. Every way
/// this can fail needs a different message to the user, and several of them are
/// not errors at all — a denied permission is a choice, not a bug.
///
/// TRUST NOTE. Everything here runs on the user's device and reports what the
/// device claims. A modified client can report any coordinates it likes, and
/// Android's own developer options include a mock-location setting. The fix
/// obtained here is therefore for **user feedback**; the authoritative check
/// happens on the server against the coordinates stored on the submission
/// (§7.4, F2.5).
enum LocationOutcome {
  idle,
  locating,

  /// A usable fix was obtained.
  fixed,

  /// Location services are switched off device-wide.
  serviceDisabled,

  /// The user denied permission this time.
  denied,

  /// The user denied permission permanently; only Settings can restore it.
  deniedForever,

  /// A fix was requested but did not arrive in time.
  timedOut,

  /// Anything else.
  error,
}

class LocationResult {
  final LocationOutcome outcome;
  final double? latitude;
  final double? longitude;

  /// Reported horizontal accuracy in metres. Worth surfacing: a fix accurate to
  /// ±40 m against a 50 m geofence is not really evidence of anything.
  final double? accuracyMeters;

  final String? message;

  const LocationResult({
    required this.outcome,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.message,
  });

  bool get hasFix =>
      outcome == LocationOutcome.fixed && latitude != null && longitude != null;

  /// Message for the user. Distinguishes the cases the user can fix themselves
  /// from the ones they cannot.
  String get displayMessage {
    switch (outcome) {
      case LocationOutcome.idle:
        return 'Location not checked yet.';
      case LocationOutcome.locating:
        return 'Getting your location…';
      case LocationOutcome.fixed:
        return 'Location captured.';
      case LocationOutcome.serviceDisabled:
        return 'Location services are turned off. Switch them on and try again.';
      case LocationOutcome.denied:
        return 'Location permission is needed to prove you are at the bin.';
      case LocationOutcome.deniedForever:
        return 'Location permission was permanently denied. Enable it for '
            'Chokro in Settings, then try again.';
      case LocationOutcome.timedOut:
        return 'Could not get a location fix. Step outside or away from tall '
            'buildings and try again.';
      case LocationOutcome.error:
        return message ??
            'Could not get your location. Check that location is switched on, '
                'then try again.';
    }
  }
}

class LocationService {
  /// Requests a single high-accuracy fix, handling permission along the way.
  ///
  /// [timeout] bounds the wait. A GPS fix indoors can take a very long time or
  /// never arrive at all, and an endless spinner is worse than a message telling
  /// the user to step outside.
  Future<LocationResult> getCurrentLocation({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const LocationResult(outcome: LocationOutcome.serviceDisabled);
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        return const LocationResult(outcome: LocationOutcome.deniedForever);
      }

      if (permission == LocationPermission.denied) {
        return const LocationResult(outcome: LocationOutcome.denied);
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      );

      return LocationResult(
        outcome: LocationOutcome.fixed,
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
      );
    } on TimeoutException {
      return const LocationResult(outcome: LocationOutcome.timedOut);
    } on LocationServiceDisabledException {
      return const LocationResult(outcome: LocationOutcome.serviceDisabled);
    } catch (err) {
      final text = err.toString();
      // Some Android versions surface geolocator's timeout as a platform
      // exception rather than as TimeoutException.
      if (text.toLowerCase().contains('time')) {
        return const LocationResult(outcome: LocationOutcome.timedOut);
      }
      // Deliberately not `message: text`. That put a raw
      // `PlatformException(channel-error, ...)` dump in a red card in front of
      // a resident standing at a bin, on the screen that decides whether their
      // disposal counts — with no remedy, and leaking internal plugin detail
      // with it. `displayMessage` writes the sentence instead. `message` stays
      // on the model for callers that genuinely have one worth showing.
      return const LocationResult(outcome: LocationOutcome.error);
    }
  }

  /// Opens the OS settings page for this app, for the permanently-denied case.
  Future<void> openSettings() => Geolocator.openAppSettings();

  /// Opens the device location settings, for the service-disabled case.
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();
}
