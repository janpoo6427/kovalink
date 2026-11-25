// kovapilot `kova_params` document as served by the KovaLink gateway
// (`GET /v1/kova-params`). The app never hard-codes the setting list,
// groups or translations: everything shown comes from this document.
//
// Parsing rules (see docs/PROTOCOL.md "Settings HTTP"):
// - Unknown fields are ignored so newer gateways stay readable.
// - An unknown major `schemaVersion` closes the document (fail closed).
// - Unknown type/access/applyPolicy values make that setting read-only.
// - `hidden: true` (or `visibility: "hidden"`) settings are never drawn.

/// The `kova_params` major schema this app understands.
const int supportedKovaParamsSchema = 1;

/// KovaLink's own UI language is Korean, so Korean text is preferred and
/// English is the fallback; then the document's default locale.
const List<String> kovaAppLocales = ['ko', 'en'];

class KovaParamsFormatException implements Exception {
  const KovaParamsFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The gateway speaks a newer major schema than this app.
class KovaParamsSchemaUnsupported extends KovaParamsFormatException {
  const KovaParamsSchemaUnsupported(this.schemaVersion)
    : super('차의 설정 형식이 이 앱과 맞지 않아요. 앱을 업데이트해 주세요.');
  final Object? schemaVersion;
}

/// Reads the major version from `1`, `1.2` or `"1.2"`.
int? kovaSchemaMajor(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite) return value.floor();
  if (value is String) return int.tryParse(value.split('.').first);
  return null;
}

class LocalizedText {
  const LocalizedText(this.values);

  final Map<String, String> values;

  static LocalizedText? tryParse(Object? json) {
    if (json is String && json.isNotEmpty) return LocalizedText({'': json});
    if (json is! Map) return null;
    final values = <String, String>{
      for (final entry in json.entries)
        if (entry.key is String &&
            entry.value is String &&
            (entry.value as String).isNotEmpty)
          entry.key as String: entry.value as String,
    };
    return values.isEmpty ? null : LocalizedText(values);
  }

  String resolve({
    List<String> preferred = kovaAppLocales,
    String? defaultLocale,
  }) {
    for (final locale in preferred) {
      final text = values[locale];
      if (text != null) return text;
    }
    if (defaultLocale != null && values[defaultLocale] != null) {
      return values[defaultLocale]!;
    }
    return values.values.first;
  }
}

enum KovaParamType { boolean, integer, number, string, choice, unknown }

enum KovaParamAccess { readOnly, readWrite, unknown }

enum KovaApplyPolicy { immediate, offroad, parked, restart, unknown }

enum KovaAvailability { available, pendingConsumer, unsupported, unknown }

enum KovaRisk { display, behavior, control, unknown }

/// Which widget draws a setting.
enum KovaParamControl { toggle, slider, numberField, choice, readOnly, hidden }

T _pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.firstWhere((v) => v.name == name, orElse: () => fallback);

KovaParamType _type(Object? name) => switch (name) {
  'boolean' => KovaParamType.boolean,
  'integer' => KovaParamType.integer,
  'number' => KovaParamType.number,
  'string' => KovaParamType.string,
  'enum' => KovaParamType.choice,
  _ => KovaParamType.unknown,
};

num? _finite(Object? value) =>
    value is num && value.isFinite && value is! bool ? value : null;

class KovaParamOption {
  const KovaParamOption(this.value, this.title);

  /// String or int, matched with the exact JSON type (as the gateway does).
  final Object value;
  final LocalizedText? title;

  /// Exact JSON type match: `1` never matches `"1"`, `true` or `1.0`.
  bool matches(Object? candidate) =>
      ((value is int && candidate is int) ||
          (value is String && candidate is String)) &&
      value == candidate;

  String label({String? defaultLocale}) =>
      title?.resolve(defaultLocale: defaultLocale) ?? '$value';
}

class KovaParamSetting {
  const KovaParamSetting({
    required this.key,
    required this.groupId,
    required this.order,
    required this.type,
    required this.access,
    required this.applyPolicy,
    required this.availability,
    required this.risk,
    required this.title,
    required this.description,
    required this.value,
    required this.defaultValue,
    this.applyStatus,
    this.minimum,
    this.maximum,
    this.step,
    this.unit,
    this.options = const [],
    this.hidden = false,
    this.requiredCapabilities = const [],
  });

  final String key;
  final String groupId;
  final int order;
  final KovaParamType type;
  final KovaParamAccess access;
  final KovaApplyPolicy applyPolicy;
  final KovaAvailability availability;
  final String? applyStatus;
  final KovaRisk risk;
  final LocalizedText title;
  final LocalizedText? description;
  final Object? value;
  final Object? defaultValue;
  final num? minimum;
  final num? maximum;
  final num? step;
  final LocalizedText? unit;
  final List<KovaParamOption> options;
  final bool hidden;
  final List<String> requiredCapabilities;

  static KovaParamSetting parse(Map<dynamic, dynamic> json) {
    final key = json['key'];
    final groupId = json['groupId'];
    final title = LocalizedText.tryParse(json['title']);
    if (key is! String || key.isEmpty) {
      throw const KovaParamsFormatException('설정 항목에 key가 없습니다.');
    }
    if (groupId is! String || title == null) {
      throw KovaParamsFormatException('설정 항목 $key의 groupId·title이 올바르지 않습니다.');
    }
    final type = _type(json['type']);
    final options = <KovaParamOption>[];
    final optionTitles = json['optionTitles'];
    if (json['options'] case final List<dynamic> raw) {
      for (final option in raw) {
        if (option is String || (option is int)) {
          options.add(
            KovaParamOption(
              option as Object,
              optionTitles is Map
                  ? LocalizedText.tryParse(optionTitles['$option'])
                  : null,
            ),
          );
        }
      }
    }
    final order = json['order'];
    final capabilities = json['requiredCapabilities'];
    return KovaParamSetting(
      key: key,
      groupId: groupId,
      order: order is int ? order : 0,
      type: type,
      access: _pick(
        KovaParamAccess.values,
        json['access'],
        KovaParamAccess.unknown,
      ),
      applyPolicy: _pick(
        KovaApplyPolicy.values,
        json['applyPolicy'],
        KovaApplyPolicy.unknown,
      ),
      availability: _pick(
        KovaAvailability.values,
        json['availability'],
        KovaAvailability.unknown,
      ),
      applyStatus: json['applyStatus'] is String
          ? json['applyStatus'] as String
          : null,
      risk: _pick(KovaRisk.values, json['risk'], KovaRisk.unknown),
      title: title,
      description: LocalizedText.tryParse(json['description']),
      value: json['value'],
      defaultValue: json['defaultValue'],
      minimum: _finite(json['minimum']),
      maximum: _finite(json['maximum']),
      step: _finite(json['step']),
      unit: LocalizedText.tryParse(json['unit']),
      options: options,
      hidden: json['hidden'] == true || json['visibility'] == 'hidden',
      requiredCapabilities: [
        if (capabilities is List)
          for (final c in capabilities)
            if (c is String) c,
      ],
    );
  }

  bool get hasRange =>
      minimum != null && maximum != null && minimum! <= maximum!;

  /// Effective availability: the gateway's `applyStatus` wins when known.
  KovaAvailability get status => applyStatus == null
      ? availability
      : _pick(KovaAvailability.values, applyStatus, availability);

  /// Local pre-check before sending; the gateway validates again.
  /// Returns a Korean reason, or null when [candidate] fits the contract.
  String? check(Object? candidate) {
    final ok = switch (type) {
      KovaParamType.boolean => candidate is bool,
      KovaParamType.integer => candidate is int,
      KovaParamType.number => candidate is num && candidate.isFinite,
      KovaParamType.string => candidate is String,
      KovaParamType.choice => options.any((o) => o.matches(candidate)),
      KovaParamType.unknown => false,
    };
    if (!ok) return '이 항목에 맞지 않는 값이에요.';
    if (candidate is num) {
      if ((minimum != null && candidate < minimum!) ||
          (maximum != null && candidate > maximum!)) {
        return '${formatNumber(minimum)}–${formatNumber(maximum)} 사이로 골라 주세요.';
      }
    }
    return null;
  }

  KovaParamControl get control {
    if (hidden) return KovaParamControl.hidden;
    if (access != KovaParamAccess.readWrite) return KovaParamControl.readOnly;
    if (applyPolicy == KovaApplyPolicy.unknown) {
      return KovaParamControl.readOnly;
    }
    if (check(value) != null) return KovaParamControl.readOnly;
    return switch (type) {
      KovaParamType.boolean => KovaParamControl.toggle,
      KovaParamType.integer || KovaParamType.number =>
        hasRange ? KovaParamControl.slider : KovaParamControl.numberField,
      KovaParamType.choice =>
        options.isEmpty ? KovaParamControl.readOnly : KovaParamControl.choice,
      // The contract has no string constraints yet, so strings are shown
      // but not edited.
      KovaParamType.string ||
      KovaParamType.unknown => KovaParamControl.readOnly,
    };
  }

  String formatNumber(num? v) {
    if (v == null) return '';
    if (type == KovaParamType.integer) return v.round().toString();
    if ((step == null || step! >= 1) && v == v.roundToDouble()) {
      return v.round().toString();
    }
    final digits = step != null && step! < 1
        ? (step!.toString().split('.').last.length).clamp(1, 4)
        : 2;
    return v.toStringAsFixed(digits);
  }

  /// Human text for a value: option title, 켬/끔, number + unit.
  String describe(Object? v, {String? defaultLocale}) {
    if (v is bool && type == KovaParamType.boolean) return v ? '켬' : '끔';
    if (type == KovaParamType.choice) {
      for (final option in options) {
        if (option.matches(v)) {
          return option.label(defaultLocale: defaultLocale);
        }
      }
    }
    if (v is num) {
      final unitText = unit?.resolve(defaultLocale: defaultLocale);
      return unitText == null
          ? formatNumber(v)
          : '${formatNumber(v)} $unitText';
    }
    if (v == null) return '없음';
    return '$v';
  }
}

class KovaParamGroup {
  const KovaParamGroup({
    required this.id,
    required this.order,
    required this.title,
    required this.description,
    required this.settings,
  });

  final String id;
  final int order;
  final LocalizedText? title;
  final LocalizedText? description;

  /// Visible settings, sorted by order then key.
  final List<KovaParamSetting> settings;
}

class KovaParamsDocument {
  const KovaParamsDocument({
    required this.schemaVersion,
    required this.revision,
    required this.defaultLocale,
    required this.locales,
    required this.groups,
    required this.settings,
    this.deviceOffroad,
    this.deviceParked,
  });

  final int schemaVersion;
  final int revision;
  final String? defaultLocale;
  final List<String> locales;

  /// Groups that have at least one visible setting, sorted by order then id.
  final List<KovaParamGroup> groups;

  /// Every setting by key, hidden ones included (they are never drawn).
  final Map<String, KovaParamSetting> settings;

  /// `device.offroad` from the gateway; null when the gateway did not say.
  final bool? deviceOffroad;

  /// True when the Gateway verified P, standstill and disengagement.
  final bool? deviceParked;

  KovaParamSetting? setting(String key) => settings[key];

  static const otherGroupId = '_other';

  factory KovaParamsDocument.fromJson(Object? json) {
    if (json is! Map) {
      throw const KovaParamsFormatException(
        'kova_params 응답이 JSON object가 아닙니다.',
      );
    }
    final major = kovaSchemaMajor(json['schemaVersion']);
    if (major == null) {
      throw const KovaParamsFormatException('kova_params schemaVersion이 없습니다.');
    }
    if (major != supportedKovaParamsSchema) {
      throw KovaParamsSchemaUnsupported(json['schemaVersion']);
    }
    final revision = json['revision'];
    if (revision is! int || revision < 0) {
      throw const KovaParamsFormatException('kova_params revision이 올바르지 않습니다.');
    }
    final rawGroups = json['groups'];
    final rawSettings = json['settings'];
    if (rawGroups is! List || rawSettings is! List) {
      throw const KovaParamsFormatException(
        'kova_params groups·settings가 배열이 아닙니다.',
      );
    }
    final defaultLocale = json['defaultLocale'] is String
        ? json['defaultLocale'] as String
        : null;
    final locales = [
      if (json['locales'] case final List<dynamic> list)
        for (final l in list)
          if (l is String) l,
    ];

    final settings = <String, KovaParamSetting>{};
    for (final raw in rawSettings) {
      if (raw is! Map) {
        throw const KovaParamsFormatException('설정 항목이 JSON object가 아닙니다.');
      }
      final setting = KovaParamSetting.parse(raw);
      if (settings.containsKey(setting.key)) {
        throw KovaParamsFormatException('설정 항목 ${setting.key}가 두 번 있습니다.');
      }
      settings[setting.key] = setting;
    }

    final groupMeta = <String, (int, LocalizedText?, LocalizedText?)>{};
    for (final raw in rawGroups) {
      if (raw is! Map || raw['id'] is! String) {
        throw const KovaParamsFormatException('설정 그룹에 id가 없습니다.');
      }
      final order = raw['order'];
      groupMeta[raw['id'] as String] = (
        order is int ? order : 0,
        LocalizedText.tryParse(raw['title']),
        LocalizedText.tryParse(raw['description']),
      );
    }

    final byGroup = <String, List<KovaParamSetting>>{};
    for (final setting in settings.values) {
      if (setting.hidden) continue;
      final groupId = groupMeta.containsKey(setting.groupId)
          ? setting.groupId
          : otherGroupId;
      byGroup.putIfAbsent(groupId, () => []).add(setting);
    }
    final groups =
        <KovaParamGroup>[
          for (final entry in byGroup.entries)
            KovaParamGroup(
              id: entry.key,
              order: groupMeta[entry.key]?.$1 ?? 1 << 30,
              title: groupMeta[entry.key]?.$2,
              description: groupMeta[entry.key]?.$3,
              settings: entry.value
                ..sort(
                  (a, b) => a.order != b.order
                      ? a.order.compareTo(b.order)
                      : a.key.compareTo(b.key),
                ),
            ),
        ]..sort(
          (a, b) => a.order != b.order
              ? a.order.compareTo(b.order)
              : a.id.compareTo(b.id),
        );

    final device = json['device'];
    final offroad = device is Map && device['offroad'] is bool
        ? device['offroad'] as bool
        : null;
    final parked = device is Map && device['parked'] is bool
        ? device['parked'] as bool
        : null;
    return KovaParamsDocument(
      schemaVersion: major,
      revision: revision,
      defaultLocale: defaultLocale,
      locales: locales,
      groups: groups,
      settings: settings,
      deviceOffroad: offroad,
      deviceParked: parked,
    );
  }
}
