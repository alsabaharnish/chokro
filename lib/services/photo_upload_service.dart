import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';

import '../core/network_errors.dart';

/// Uploads disposal photographs through the trusted service.
///
/// The image does not go to a storage bucket directly. It goes to the Node
/// service, which holds the image-host credentials and which needs the raw bytes
/// anyway — to compute the perceptual hash and to send the image for screening.
/// One transfer instead of two, and the hash describes exactly the bytes that
/// were stored.
///
/// The user's identity is taken from the Firebase ID token sent with the
/// request, never from anything in the body. A caller cannot upload into someone
/// else's folder by claiming a different uid.
class PhotoUploadService {
  final http.Client _client;

  PhotoUploadService({http.Client? client}) : _client = client ?? http.Client();

  /// Uploads [file] and returns its URL and Cloudinary public id.
  ///
  /// The public id is needed by the verification pipeline: the perceptual hash
  /// is computed from an 8x8 grayscale transform of the stored image, and that
  /// transform URL is built from the public id. The server has always returned
  /// it; it was previously discarded here.
  ///
  /// Throws [PhotoUploadException] with a message fit to show a user.
  Future<UploadedPhoto> uploadDisposalPhoto(File file) =>
      _upload(file, endpoint: '/photos/disposal');

  /// Uploads evidence for a self-reported eco-action.
  ///
  /// Claims previously used the disposal endpoint, mixing two evidence types in
  /// one server folder and making provenance checks unable to distinguish them.
  Future<UploadedPhoto> uploadClaimPhoto(File file) =>
      _upload(file, endpoint: '/photos/claim');

  Future<UploadedPhoto> _upload(File file, {required String endpoint}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const PhotoUploadException('You are not signed in.');
    }

    final token = await user.getIdToken();
    final bytes = await file.readAsBytes();

    http.Response response;
    try {
      response = await _client
          .post(
            ApiConfig.path(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'imageBase64': base64Encode(bytes)}),
          )
          .timeout(ApiConfig.coldStartTimeout);
    } on TimeoutException catch (error) {
      // The genuine cold start: the free instance sleeps after ~15 minutes and
      // the first request back takes 30-60 seconds. Only this clause should
      // produce the "took too long" message.
      _log('timed out after ${ApiConfig.coldStartTimeout}', error);
      throw PhotoUploadException(slowServerMessage);
    } on SocketException catch (error) {
      _log('socket failure — no route to the host', error);
      throw PhotoUploadException(unreachableServerMessage);
    } on http.ClientException catch (error) {
      // On the web build this is the CORS signature: the browser refuses the
      // request and `package:http` reports "XMLHttpRequest error" with no
      // detail. It is not a socket failure, so it used to fall through to the
      // generic clause and read as a timeout. Check the origin against
      // ALLOWED_ORIGINS on the server before suspecting the network.
      _log('client exception — on web, check CORS and the origin', error);
      throw PhotoUploadException(unreachableServerMessage);
    } catch (error, stackTrace) {
      _log('unexpected failure sending the photo', error, stackTrace);
      throw const PhotoUploadException(
        'Something went wrong sending the photo. Try again.',
      );
    }

    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final url = body['photoUrl'] as String?;
      if (url == null || url.isEmpty) {
        throw const PhotoUploadException(
          'The server did not return a photo URL.',
        );
      }
      return UploadedPhoto(
        url: url,
        // Absent only from an older server build.
        //
        // An empty id means `verifyDisposal` skips the hash step entirely. That
        // now routes to review rather than approving: it leaves
        // `duplicateChecked` false, `decide()` raises `hashUnavailable`, and a
        // flagged submission cannot take the auto-approve lane.
        //
        // This comment previously asserted the same outcome while nothing
        // implemented it — the skipped check produced no flag at all, so an
        // empty id auto-approved with the duplicate defence never having run.
        publicId: (body['publicId'] as String?) ?? '',
      );
    }

    // The server sends a user-safe message for anything it considers the
    // caller's fault; everything else gets a generic one.
    String message = 'The photo could not be uploaded.';
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final serverMessage = body['message'] as String?;
      if (serverMessage != null && serverMessage.isNotEmpty) {
        message = serverMessage;
      }
    } catch (error) {
      // Non-JSON response — keep the generic message, but say so in debug.
      _log('response body was not JSON (${response.statusCode})', error);
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const PhotoUploadException(
        'Your session has expired. Sign in again.',
      );
    }

    throw PhotoUploadException(message);
  }
}

/// Writes the underlying failure to the debug console without changing what the
/// user is told. Stripped from release builds.
void _log(String context, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('[PhotoUploadService] $context: $error');
  if (stackTrace != null) debugPrint('$stackTrace');
}

/// A stored photograph: where it lives, and how the server can address it.
class UploadedPhoto {
  const UploadedPhoto({required this.url, required this.publicId});

  final String url;
  final String publicId;
}

class PhotoUploadException implements Exception {
  final String message;
  const PhotoUploadException(this.message);

  @override
  String toString() => message;
}
