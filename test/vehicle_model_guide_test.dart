import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/settings/vehicle_model_guide.dart';
import 'package:kovalink/src/vehicle_pack/model_pack_validator.dart';
import 'package:kovalink/src/vehicle_pack/zip_writer.dart';

void main() {
  test('guide manifest is accepted with the reference GLB', () {
    final pack = ZipWriter.build([
      ZipWriterEntry(
        'vehicle.json',
        utf8.encode(VehicleModelGuideScreen.manifestExample),
      ),
      ZipWriterEntry(
        'vehicle.glb',
        File('assets/vehicles/kovalink_basic/vehicle.glb').readAsBytesSync(),
      ),
      ZipWriterEntry('LICENSE.md', utf8.encode('CC0-1.0')),
    ]);
    final result = ModelPackValidator.validate(pack);
    expect(result.rejection, isNull);
    expect(result.manifest!.id, 'my-car');
  });
  for (final size in [const Size(360, 640), const Size(640, 360)]) {
    for (final brightness in Brightness.values) {
      testWidgets('guide scroll/copy/back $size $brightness with large text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const VehicleModelGuideScreen(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('.kovamodel은 ZIP 패키지예요'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('model-guide-copy-json')),
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('model-guide-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byKey(const ValueKey('model-guide-copy-json')));
        await tester.pumpAndSettle();
        expect(copied, VehicleModelGuideScreen.manifestExample);
        await tester.scrollUntilVisible(
          find.text('dart run tool/kovamodel.dart check my-car.kovamodel'),
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('model-guide-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(tester.takeException(), isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('open'), findsOneWidget);
      });
    }
  }
}
