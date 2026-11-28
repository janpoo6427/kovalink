// kovapilot `kova_params` document as served by the KovaLink gateway
// (`GET /v1/kova-params`). The app never hard-codes the setting list,
// groups or translations: everything shown comes from this document.
//
// Parsing rules (see docs/PROTOCOL.md "Settings HTTP"):
// - Unknown fields are ignored so newer gateways stay readable.
// - An unknown major `schemaVersion` closes the document (fail closed).
// - Unknown type/access/applyPolicy values make that setting read-only.
// - `hidden: true` (or `visibility: "hidden"`) settings are never drawn.
// - `bundles` (optional) draw the settings that name them in `bundleId` as
//   one item of their group; each setting keeps its own key and value. An
//   unknown or malformed bundle leaves its settings as single items, and
//   older apps that do not read `bundles` show every setting on its own.

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

class KovaParamDependency {
  const KovaParamDependency({
    required this.title,
    required this.state,
    this.condition,
  });

  final LocalizedText title;
  final String state;

  /// Gateway vehicle condition id (e.g. `openpilotLongitudinalApplied`);
  /// null for a dependency on another setting's value.
  final String? condition;

  static KovaParamDependency? tryParse(Object? json) {
    if (json is! Map) return null;
    final title = LocalizedText.tryParse(json['title']);
    if (title == null) return null;
    final state = json['state'];
    final condition = json['condition'];
    return KovaParamDependency(
      title: title,
      state: state is String ? state : 'unknown',
      condition: condition is String ? condition : null,
    );
  }

  static List<KovaParamDependency> parseList(Object? json) => [
    if (json is List)
      for (final raw in json) ?tryParse(raw),
  ];
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
    this.bundleId,
    this.applyStatus,
    this.saveAnytime = false,
    this.saveParkedOnly = false,
    this.applyState,
    this.appliedValue,
    this.minimum,
    this.maximum,
    this.step,
    this.unit,
    this.options = const [],
    this.numericSwitch = false,
    this.hidden = false,
    this.requiredCapabilities = const [],
    this.dependencies = const [],
    this.runtimeStates = const [],
  });

  final String key;
  final String groupId;

  /// Catalog bundle this setting is drawn in; null for a single item.
  final String? bundleId;
  final int order;
  final KovaParamType type;
  final KovaParamAccess access;
  final KovaApplyPolicy applyPolicy;
  final KovaAvailability availability;
  final String? applyStatus;
  final bool saveAnytime;
  final bool saveParkedOnly;
  final String? applyState;
  final Object? appliedValue;
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
  final bool numericSwitch;
  final bool hidden;
  final List<String> requiredCapabilities;
  final List<KovaParamDependency> dependencies;
  final List<KovaParamDependency> runtimeStates;

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
      bundleId: json['bundleId'] is String ? json['bundleId'] as String : null,
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
      saveAnytime: json['savePolicy'] == 'anytime',
      saveParkedOnly: json['savePolicy'] == 'parked',
      applyState: json['applyState'] is String
          ? json['applyState'] as String
          : null,
      appliedValue: json['appliedValue'],
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
      numericSwitch:
          type == KovaParamType.choice &&
          json['control'] == 'switch' &&
          options.length == 2 &&
          options.any((option) => option.matches(0)) &&
          options.any((option) => option.matches(1)),
      hidden: json['hidden'] == true || json['visibility'] == 'hidden',
      requiredCapabilities: [
        if (capabilities is List)
          for (final c in capabilities)
            if (c is String) c,
      ],
      dependencies: KovaParamDependency.parseList(json['dependencies']),
      runtimeStates: KovaParamDependency.parseList(json['runtimeStates']),
    );
  }

  bool get hasRange =>
      minimum != null && maximum != null && minimum! <= maximum!;

  /// Gateway condition that openpilot longitudinal control runs now.
  static const longitudinalCondition = 'openpilotLongitudinalApplied';

  /// Why this setting is out of reach without openpilot longitudinal
  /// control, from the gateway's evaluated condition: `unmet` (off),
  /// `pendingRestart` (saved, runs from the next start) or `unsupported`
  /// (this vehicle). Null when it does not need longitudinal control, when
  /// longitudinal control runs, or while the vehicle is not known yet.
  String? get longitudinalBlock {
    for (final dependency in dependencies) {
      if (dependency.condition == longitudinalCondition) {
        return const {
              'unmet',
              'pendingRestart',
              'unsupported',
            }.contains(dependency.state)
            ? dependency.state
            : null;
      }
    }
    return null;
  }

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
        numericSwitch
            ? KovaParamControl.toggle
            : options.isEmpty
            ? KovaParamControl.readOnly
            : KovaParamControl.choice,
      // The contract has no string constraints yet, so strings are shown
      // but not edited.
      KovaParamType.string ||
      KovaParamType.unknown => KovaParamControl.readOnly,
    };
  }

  Object toggleValue(bool enabled) =>
      numericSwitch ? (enabled ? 1 : 0) : enabled;

  bool isToggleOn(Object? value) => numericSwitch ? value == 1 : value == true;

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

/// Settings of one group drawn together as a single item (catalog
/// `bundles`); each keeps its own key, value and control.
class KovaParamBundle {
  const KovaParamBundle({
    required this.id,
    required this.order,
    required this.title,
    required this.description,
    required this.settings,
  });

  final String id;
  final int order;
  final LocalizedText title;
  final LocalizedText? description;

  /// Visible member settings, sorted by order then key.
  final List<KovaParamSetting> settings;
}

/// One item of a group: a single setting or a bundle of settings.
class KovaParamEntry {
  const KovaParamEntry.single(KovaParamSetting this.setting) : bundle = null;
  const KovaParamEntry.bundled(KovaParamBundle this.bundle) : setting = null;

  final KovaParamSetting? setting;
  final KovaParamBundle? bundle;

  int get order => bundle?.order ?? setting!.order;
  String get id => bundle?.id ?? setting!.key;
  List<KovaParamSetting> get settings => bundle?.settings ?? [setting!];
}

class KovaParamGroup {
  const KovaParamGroup({
    required this.id,
    required this.order,
    required this.title,
    required this.description,
    required this.settings,
    required this.entries,
  });

  final String id;
  final int order;
  final LocalizedText? title;
  final LocalizedText? description;

  /// Visible settings, sorted by order then key.
  final List<KovaParamSetting> settings;

  /// What the group draws: single settings and bundles, sorted by order
  /// then id. Every visible setting is in exactly one entry.
  final List<KovaParamEntry> entries;
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

    // Bundles: id -> (group, order, title, description); malformed ones are
    // skipped so their settings stay single items.
    final bundleMeta = <String, (String, int, LocalizedText, LocalizedText?)>{};
    if (json['bundles'] case final List<dynamic> rawBundles) {
      for (final raw in rawBundles) {
        if (raw is! Map) continue;
        final id = raw['id'];
        final groupId = raw['groupId'];
        final title = LocalizedText.tryParse(raw['title']);
        if (id is! String || groupId is! String || title == null) continue;
        if (bundleMeta.containsKey(id)) continue;
        final order = raw['order'];
        bundleMeta[id] = (
          groupId,
          order is int ? order : 0,
          title,
          LocalizedText.tryParse(raw['description']),
        );
      }
    }

    final byGroup = <String, List<KovaParamSetting>>{};
    for (final setting in settings.values) {
      if (setting.hidden) continue;
      final groupId = groupMeta.containsKey(setting.groupId)
          ? setting.groupId
          : otherGroupId;
      byGroup.putIfAbsent(groupId, () => []).add(setting);
    }
    int bySettingOrder(KovaParamSetting a, KovaParamSetting b) =>
        a.order != b.order
        ? a.order.compareTo(b.order)
        : a.key.compareTo(b.key);

    List<KovaParamEntry> entriesOf(
      String groupId,
      List<KovaParamSetting> sorted,
    ) {
      final members = <String, List<KovaParamSetting>>{};
      final entries = <KovaParamEntry>[];
      for (final setting in sorted) {
        final meta = bundleMeta[setting.bundleId];
        if (meta != null && meta.$1 == groupId) {
          members.putIfAbsent(setting.bundleId!, () => []).add(setting);
        } else {
          entries.add(KovaParamEntry.single(setting));
        }
      }
      for (final bundle in members.entries) {
        final meta = bundleMeta[bundle.key]!;
        entries.add(
          KovaParamEntry.bundled(
            KovaParamBundle(
              id: bundle.key,
              order: meta.$2,
              title: meta.$3,
              description: meta.$4,
              settings: bundle.value,
            ),
          ),
        );
      }
      return entries..sort(
        (a, b) => a.order != b.order
            ? a.order.compareTo(b.order)
            : a.id.compareTo(b.id),
      );
    }

    final groups =
        <KovaParamGroup>[
          for (final entry in byGroup.entries)
            KovaParamGroup(
              id: entry.key,
              order: groupMeta[entry.key]?.$1 ?? 1 << 30,
              title: groupMeta[entry.key]?.$2,
              description: groupMeta[entry.key]?.$3,
              settings: entry.value..sort(bySettingOrder),
              entries: entriesOf(entry.key, entry.value),
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
