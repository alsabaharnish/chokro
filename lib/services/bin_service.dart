import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/bin_model.dart';

/// Firestore access for registered disposal bins (F2.1, F2.2).
///
/// Bins are read-only from the client. Registration goes through the trusted
/// server, because a bin's coordinates and radius are inputs the server relies
/// on when deciding a payout — see §5.1 of the project brief and the `bins`
/// block in `firestore.rules`.
///
/// This service also owns the Firestore-to-model conversion. [BinModel] is plain
/// Dart with no Firebase imports, so it does not know what a `Timestamp` is;
/// converting here is what keeps the model unit-testable without an emulator.
class BinService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _bins => _db.collection('bins');

  /// Resolves a scanned QR payload to a bin.
  ///
  /// Returns null if no bin carries that payload — either the code belongs to
  /// another system, or it was printed for a bin that has since been removed.
  ///
  /// The lookup is by `qrPayload` rather than by document ID because the payload
  /// is the opaque identifier the printed code carries (§6). Nothing about the
  /// bin's location or the user is encoded in it, so a photographed code
  /// discloses nothing and possessing one proves nothing.
  Future<BinModel?> resolveByPayload(String payload) async {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) return null;

    final snapshot =
        await _bins.where('qrPayload', isEqualTo: trimmed).limit(1).get();

    if (snapshot.docs.isEmpty) return null;
    return _fromDoc(snapshot.docs.first);
  }

  /// Fetches a bin by document ID.
  Future<BinModel?> getBin(String binId) async {
    final doc = await _bins.doc(binId).get();
    if (!doc.exists) return null;
    return _fromDoc(doc);
  }

  /// All bins currently accepting submissions, for the admin bin list.
  Stream<List<BinModel>> watchActiveBins() => _bins
      .where('active', isEqualTo: true)
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

  /// Every bin including inactive ones, for administration.
  Stream<List<BinModel>> watchAllBins() =>
      _bins.snapshots().map((snap) => snap.docs.map(_fromDoc).toList());

  BinModel _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.from(doc.data() ?? <String, dynamic>{});

    // Timestamp is a Firebase type; the model deals in DateTime.
    final createdAt = data['createdAt'];
    data['createdAt'] = createdAt is Timestamp ? createdAt.toDate() : null;

    return BinModel.fromJson(data, id: doc.id);
  }
}
