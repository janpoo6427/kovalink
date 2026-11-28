// Catalog bundles: the navigation speed limit item (camera, road speed limit,
// speed bump) and the curve slowdown item (vision curve, navigation turn) are
// drawn as one item each; every member keeps its own key, value and control.
import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:kovalink/src/features/settings/kova_params_panel.dart";
import "package:kovalink/src/kova_params/kova_params_client.dart";
import "package:kovalink/src/kova_params/kova_params_controller.dart";
import "package:kovalink/src/kova_params/kova_params_document.dart";

import "support/fake_kova_gateway.dart";

const camera = "navigation.speed_camera_profile";
const road = "navigation.road_speed_limit_profile";
const bump = "navigation.speed_bump_profile";
const curve = "cruise.curve_slowdown";
const turn = "cruise.nav_turn_slowdown";

Map<String, dynamic> bundleCatalog() =>
    jsonDecode(
          File(
            "test/fixtures/kova_params_bundle_catalog.json",
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

Map<String, dynamic> documentJson(Map<String, dynamic> catalog) {
  final doc = jsonDecode(jsonEncode(catalog)) as Map<String, dynamic>;
  doc["revision"] = 0;
  for (final s in (doc["settings"] as List).cast<Map<String, dynamic>>()) {
    s["value"] = s["defaultValue"];
  }
  return doc;
}

List<String> entryIds(KovaParamGroup group) => [
  for (final entry in group.entries) entry.id,
];

KovaParamGroup groupOf(KovaParamsDocument doc, String id) =>
    doc.groups.firstWhere((group) => group.id == id);

KovaParamsController controllerFor(FakeKovaGateway gateway) =>
    KovaParamsController(
      clientFactory: (endpoint, onError) => KovaParamsClient.tryCreate(
        endpoint,
        transport: gateway,
        onError: onError,
      ),
      pollInterval: null,
    );

Future<void> pumpPanel(WidgetTester tester, KovaParamsController kova) async {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            KovaParamsPanel(
              controller: kova,
              address: "http://127.0.0.1:18082",
            ),
          ],
        ),
      ),
    ),
  );
  for (final id in ["navigation", "cruise"]) {
    await tester.tap(find.byKey(PageStorageKey("kova-group-panel-$id")));
    await tester.pumpAndSettle();
  }
}

void main() {
  group("document", () {
    test("bundles become one entry, members keep their own settings", () {
      final doc = KovaParamsDocument.fromJson(documentJson(bundleCatalog()));
      final navigation = groupOf(doc, "navigation");
      expect(entryIds(navigation), [
        "navigation.speed_limits",
        "navigation.auto_blinker",
      ]);
      expect(navigation.entries.first.bundle!.title.resolve(), "내비 속도 제한");
      expect(navigation.entries.first.settings.map((s) => s.key), [
        camera,
        road,
        bump,
      ]);
      final cruise = groupOf(doc, "cruise");
      expect(entryIds(cruise), [
        "cruise.accelerator_sync",
        "cruise.curve_slowdowns",
        "cruise.lead_restart_response",
        "cruise.accelerator_sync_stock_shadow",
      ]);
      expect(cruise.entries[1].bundle!.title.resolve(), "커브 감속");
      expect(cruise.entries[1].settings.map((s) => s.key), [curve, turn]);
      // Every setting is still listed and addressable by its own key.
      expect(navigation.settings.map((s) => s.key), [
        camera,
        road,
        bump,
        "navigation.auto_blinker",
      ]);
      expect(doc.setting(road)!.bundleId, "navigation.speed_limits");
      expect(doc.setting(road)!.options.map((o) => o.label()), [
        "사용 안 함",
        "여유",
        "균형",
        "근접",
      ]);
    });

    test("without bundles every setting is a single item", () {
      final catalog = bundleCatalog()..remove("bundles");
      final doc = KovaParamsDocument.fromJson(documentJson(catalog));
      expect(entryIds(groupOf(doc, "navigation")), [
        camera,
        road,
        bump,
        "navigation.auto_blinker",
      ]);
      expect(
        groupOf(doc, "cruise").entries.every((entry) => entry.bundle == null),
        isTrue,
      );
    });

    test("unknown, malformed or other-group bundles leave single items", () {
      final catalog = bundleCatalog();
      final bundles = (catalog["bundles"] as List).cast<Map<String, dynamic>>();
      bundles[0]["groupId"] = "cruise"; // navigation members, cruise bundle
      bundles[1].remove("title");
      bundles.add({"id": 7, "groupId": "cruise"});
      final settings = (catalog["settings"] as List)
          .cast<Map<String, dynamic>>();
      settings.firstWhere(
        (s) => s["key"] == "navigation.auto_blinker",
      )["bundleId"] = "missing";
      final doc = KovaParamsDocument.fromJson(documentJson(catalog));
      expect(entryIds(groupOf(doc, "navigation")), [
        camera,
        road,
        bump,
        "navigation.auto_blinker",
      ]);
      expect(entryIds(groupOf(doc, "cruise")), contains(turn));
      expect(entryIds(groupOf(doc, "cruise")), contains(curve));
    });
  });

  group("panel", () {
    late FakeKovaGateway gateway;
    late KovaParamsController kova;

    setUp(() {
      gateway = FakeKovaGateway(catalog: bundleCatalog());
      kova = controllerFor(gateway);
    });

    tearDown(() => kova.dispose());

    testWidgets("a bundle is one item until opened", (tester) async {
      await kova.connect("http://127.0.0.1:18082");
      await pumpPanel(tester, kova);
      expect(
        find.text("2개 항목"),
        findsOneWidget,
      ); // navigation: bundle + turn signal
      expect(find.text("4개 항목"), findsOneWidget); // cruise: 5 settings, 4 items
      expect(find.text("내비 속도 제한"), findsOneWidget);
      expect(find.text("커브 감속"), findsWidgets);
      final summary = tester.widget<Text>(
        find.byKey(
          const ValueKey("kova-bundle-summary-navigation.speed_limits"),
        ),
      );
      expect(
        summary.data,
        "카메라 감속 프로필 사용 안 함 · 도로 제한속도 프로필 사용 안 함 · 과속방지턱 감속 프로필 사용 안 함",
      );
      expect(find.byKey(const ValueKey("kova-choice-$road")), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey("kova-bundle-open-navigation.speed_limits")),
      );
      await tester.pumpAndSettle();
      for (final key in [camera, road, bump]) {
        expect(find.byKey(ValueKey("kova-choice-$key")), findsOneWidget);
      }
      expect(find.byKey(const ValueKey("kova-toggle-$turn")), findsNothing);
    });

    testWidgets("each member sends only its own key", (tester) async {
      await kova.connect("http://127.0.0.1:18082");
      await pumpPanel(tester, kova);
      await tester.tap(
        find.byKey(const ValueKey("kova-bundle-open-navigation.speed_limits")),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey("kova-choice-$road")));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey("kova-option-$road-2")));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey("kova-confirm-change")));
      await tester.pumpAndSettle();
      expect(gateway.posts.single["key"], road);
      expect(gateway.posts.single["value"], 2);
      expect(gateway.valueOf(camera), 0);
      expect(gateway.valueOf(bump), 0);
      final summary = tester.widget<Text>(
        find.byKey(
          const ValueKey("kova-bundle-summary-navigation.speed_limits"),
        ),
      );
      expect(summary.data, contains("도로 제한속도 프로필 균형"));

      await tester.tap(
        find.byKey(const ValueKey("kova-bundle-open-cruise.curve_slowdowns")),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey("kova-toggle-$curve")), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey("kova-toggle-$turn")));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey("kova-confirm-change")));
      await tester.pumpAndSettle();
      expect(gateway.posts.last["key"], turn);
      expect(gateway.posts.last["value"], 1);
      expect(gateway.valueOf(curve), 0);
    });

    testWidgets(
      "a bundle that needs longitudinal control is named in the note",
      (tester) async {
        final catalog = gateway.catalog;
        for (final s
            in (catalog["settings"] as List).cast<Map<String, dynamic>>()) {
          if (s["bundleId"] == "navigation.speed_limits") {
            for (final d
                in (s["dependencies"] as List).cast<Map<String, dynamic>>()) {
              if (d["condition"] == "openpilotLongitudinalApplied") {
                d["state"] = "unmet";
              }
            }
          }
        }
        await kova.connect("http://127.0.0.1:18082");
        await pumpPanel(tester, kova);
        expect(
          find.byKey(const ValueKey("kova-bundle-navigation.speed_limits")),
          findsNothing,
        );
        expect(find.text("종방향 제어를 켜면 사용할 수 있는 기능: 내비 속도 제한"), findsOneWidget);
        expect(find.text("1개 항목 · 종방향 제어 필요 1개"), findsOneWidget);
      },
    );
  });
}
