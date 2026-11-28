import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kova_params/kova_params_document.dart';

import 'support/fake_kova_gateway.dart';

Map<String, dynamic> _doc() => FakeKovaGateway().document();

Map<String, dynamic> _settingJson(Map<String, dynamic> doc, String key) =>
    (doc['settings'] as List).cast<Map<String, dynamic>>().firstWhere(
      (s) => s['key'] == key,
    );

void main() {
  group('kova_params document parsing', () {
    test('reads groups, settings and device state from the catalog', () {
      final doc = KovaParamsDocument.fromJson(_doc());
      expect(doc.schemaVersion, 1);
      expect(doc.revision, 0);
      expect(doc.deviceOffroad, isTrue);
      expect(doc.groups.map((g) => g.id), ['steering', 'e2e']);
      final steering = doc.setting('steering.always_on')!;
      expect(steering.title.resolve(), '항시 조향');
      expect(steering.applyPolicy, KovaApplyPolicy.offroad);
      expect(steering.status, KovaAvailability.pendingConsumer);
      expect(steering.risk, KovaRisk.control);
      expect(steering.requiredCapabilities, ['alwaysSteering']);
      expect(doc.groups[1].settings.map((s) => s.key), [
        'e2e.level',
        'e2e.gain',
        'e2e.mode',
        'e2e.build_label',
      ]);
    });

    test('ignores unknown fields and accepts a newer minor schema', () {
      final json = _doc()
        ..['schemaVersion'] = '1.7'
        ..['futureTopLevel'] = {'x': 1};
      _settingJson(json, 'e2e.level')['futureField'] = [1, 2, 3];
      final doc = KovaParamsDocument.fromJson(json);
      expect(doc.schemaVersion, 1);
      expect(doc.setting('e2e.level')!.control, KovaParamControl.slider);
    });

    test('closes on an unknown major schema', () {
      for (final version in [2, '2.0', 0]) {
        expect(
          () =>
              KovaParamsDocument.fromJson(_doc()..['schemaVersion'] = version),
          throwsA(isA<KovaParamsSchemaUnsupported>()),
          reason: '$version',
        );
      }
    });

    test('rejects documents without a usable revision or arrays', () {
      expect(
        () => KovaParamsDocument.fromJson(_doc()..remove('revision')),
        throwsA(isA<KovaParamsFormatException>()),
      );
      expect(
        () => KovaParamsDocument.fromJson(_doc()..['revision'] = -1),
        throwsA(isA<KovaParamsFormatException>()),
      );
      expect(
        () => KovaParamsDocument.fromJson(_doc()..['settings'] = {}),
        throwsA(isA<KovaParamsFormatException>()),
      );
      expect(
        () => KovaParamsDocument.fromJson([1, 2]),
        throwsA(isA<KovaParamsFormatException>()),
      );
    });

    test('hidden settings are parsed but never grouped for drawing', () {
      final doc = KovaParamsDocument.fromJson(_doc());
      expect(doc.setting('e2e.hidden_flag')!.control, KovaParamControl.hidden);
      expect(
        doc.groups.expand((g) => g.settings).map((s) => s.key),
        isNot(contains('e2e.hidden_flag')),
      );
      final json = _doc();
      _settingJson(json, 'e2e.mode')['visibility'] = 'hidden';
      expect(
        KovaParamsDocument.fromJson(json).groups[1].settings.map((s) => s.key),
        isNot(contains('e2e.mode')),
      );
    });

    test('settings of an unknown group go to a trailing other group', () {
      final json = _doc();
      _settingJson(json, 'e2e.mode')['groupId'] = 'nowhere';
      final doc = KovaParamsDocument.fromJson(json);
      expect(doc.groups.last.id, KovaParamsDocument.otherGroupId);
      expect(doc.groups.last.title, isNull);
      expect(doc.groups.last.settings.single.key, 'e2e.mode');
    });

    test('text prefers ko, then en, then the default locale', () {
      expect(const LocalizedText({'ko': '가', 'en': 'A'}).resolve(), '가');
      expect(const LocalizedText({'en': 'A', 'ja': 'ア'}).resolve(), 'A');
      expect(
        const LocalizedText({
          'ja': 'ア',
          'de': 'D',
        }).resolve(defaultLocale: 'de'),
        'D',
      );
      expect(
        const LocalizedText({'ja': 'ア'}).resolve(defaultLocale: 'fr'),
        'ア',
      );
      expect(LocalizedText.tryParse({'ko': ''}), isNull);
      expect(LocalizedText.tryParse('plain')!.resolve(), 'plain');
    });
  });

  group('widget mapping', () {
    KovaParamSetting setting(Map<String, Object?> overrides) {
      final json = _settingJson(_doc(), 'e2e.level')..addAll(overrides);
      return KovaParamSetting.parse(json);
    }

    test('maps each type to its control', () {
      final doc = KovaParamsDocument.fromJson(_doc());
      expect(
        doc.setting('steering.always_on')!.control,
        KovaParamControl.toggle,
      );
      expect(doc.setting('e2e.level')!.control, KovaParamControl.slider);
      expect(doc.setting('e2e.gain')!.control, KovaParamControl.slider);
      expect(doc.setting('e2e.mode')!.control, KovaParamControl.choice);
      expect(
        doc.setting('e2e.build_label')!.control,
        KovaParamControl.readOnly,
      );
    });

    test('three lane change modes are a choice, not a switch', () {
      final s = setting({
        'key': 'steering.lane_change_mode',
        'type': 'enum',
        'options': [0, 1, 2],
        'optionTitles': {
          '0': {'ko': '끔', 'en': 'Off'},
          '1': {'ko': '조향 개입 시', 'en': 'On steering input'},
          '2': {'ko': '자동', 'en': 'Automatic'},
        },
        'defaultValue': 1,
        'value': 2,
        'minimum': null,
        'maximum': null,
        'step': null,
      });
      expect(s.control, KovaParamControl.choice);
      expect(s.options.map((o) => o.label()), ['끔', '조향 개입 시', '자동']);
      expect(s.describe(2), '자동');
    });

    test('numbers without a range use a number field', () {
      final s = setting({'minimum': null, 'maximum': null});
      expect(s.hasRange, isFalse);
      expect(s.control, KovaParamControl.numberField);
    });

    test(
      'unknown type, access or policy and invalid current values are read-only',
      () {
        expect(setting({'type': 'color'}).control, KovaParamControl.readOnly);
        expect(
          setting({'access': 'adminOnly'}).control,
          KovaParamControl.readOnly,
        );
        expect(
          setting({'applyPolicy': 'whenever'}).control,
          KovaParamControl.readOnly,
        );
        expect(setting({'value': 'three'}).control, KovaParamControl.readOnly);
        expect(
          setting({
            'type': 'string',
            'value': 'x',
            'defaultValue': 'x',
          }).control,
          KovaParamControl.readOnly,
        );
      },
    );

    test('local check mirrors the gateway type, range and option rules', () {
      final doc = KovaParamsDocument.fromJson(_doc());
      final level = doc.setting('e2e.level')!;
      expect(level.check(4), isNull);
      expect(level.check(4.0), isNotNull);
      expect(level.check(11), contains('0–10'));
      expect(level.check(true), isNotNull);
      final gain = doc.setting('e2e.gain')!;
      expect(gain.check(1.5), isNull);
      expect(gain.check(2), isNull);
      expect(gain.check(double.nan), isNotNull);
      expect(gain.check(0.4), isNotNull);
      final mode = doc.setting('e2e.mode')!;
      expect(mode.check('calm'), isNull);
      expect(mode.check('turbo'), isNotNull);
      final steering = doc.setting('steering.always_on')!;
      expect(steering.check(1), isNotNull);
      expect(steering.check(false), isNull);
    });

    test('enum options match with the exact JSON type', () {
      final s = setting({
        'type': 'enum',
        'options': [0, 1],
        'value': 1,
        'minimum': null,
        'maximum': null,
      });
      expect(s.check(1), isNull);
      expect(s.check(true), isNotNull);
      expect(s.check(1.0), isNotNull);
      expect(s.check('1'), isNotNull);
    });

    test('values are described with option titles and units', () {
      final doc = KovaParamsDocument.fromJson(_doc());
      expect(doc.setting('e2e.mode')!.describe('lively'), '활발하게');
      expect(doc.setting('e2e.level')!.describe(7), '7 단계');
      expect(doc.setting('e2e.gain')!.describe(1.2), '1.2 배');
      expect(doc.setting('steering.always_on')!.describe(true), '켬');
    });
  });
}
