import 'dart:async';

import 'package:chokro/controllers/scan_controller.dart';
import 'package:chokro/models/bin_model.dart';
import 'package:chokro/services/bin_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DeferredBinService extends BinService {
  final Map<String, Completer<BinModel?>> _requests = {};

  @override
  Future<BinModel?> resolveByPayload(String payload) {
    final request = Completer<BinModel?>();
    _requests[payload] = request;
    return request.future;
  }

  void complete(String payload, BinModel? bin) =>
      _requests[payload]!.complete(bin);
}

const _secondBin = BinModel(
  id: 'bin-2',
  label: 'Second bin',
  lat: 23.78,
  lng: 90.4,
  radiusMeters: 50,
  qrPayload: 'chokro:bin:second_bin',
  active: false,
  createdBy: 'admin-1',
);

void main() {
  test('a late first lookup cannot overwrite a newer bin link', () async {
    final service = _DeferredBinService();
    final container = ProviderContainer(
      overrides: [binServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    final controller = container.read(scanControllerProvider.notifier);
    final first = controller.resolve('chokro:bin:first_bin');
    final second = controller.resolve('chokro:bin:second_bin');

    service.complete('chokro:bin:second_bin', _secondBin);
    await second;
    expect(
      container.read(scanControllerProvider).outcome,
      ScanOutcome.binClosed,
    );
    expect(
      container.read(scanControllerProvider).bin?.qrPayload,
      _secondBin.qrPayload,
    );

    service.complete('chokro:bin:first_bin', null);
    await first;
    expect(
      container.read(scanControllerProvider).outcome,
      ScanOutcome.binClosed,
    );
    expect(
      container.read(scanControllerProvider).bin?.qrPayload,
      _secondBin.qrPayload,
    );
  });
}
