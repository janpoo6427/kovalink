import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/features/connect/connect_screen.dart';
import 'package:kovalink/src/features/kovapilot_git/kovapilot_version_screen.dart';
import 'package:kovalink/src/features/settings/renderer_diagnostics_card.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/features/settings/vehicle_model_import.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

/// Builds every [KovaRoutes] route from the app's shared objects. The app
/// uses it as `onGenerateRoute` (so the initial route and deep links work)
/// and the drive screen pushes the same routes from its buttons, so the
/// drive screen also works inside a plain MaterialApp (tests, captures).
@immutable
class KovaLinkPages {
  const KovaLinkPages({
    required this.controller,
    this.vehicleModel,
    this.settings,
    this.library,
    this.modelPicker = pickModelFileWithSystemPicker,
    this.kovaParams,
    this.autoConnect,
    this.link,
    this.drive,
  });

  final GatewayController controller;
  final ValueListenable<VehicleModelLoadResult>? vehicleModel;
  final SettingsController? settings;
  final VehicleModelLibrary? library;
  final ModelFilePicker modelPicker;
  final KovaParamsController? kovaParams;
  final AutoConnectController? autoConnect;

  /// Registered comma and its session (connect screen, registration).
  final CommaLink? link;

  /// The drive screen for [KovaRoutes.drive]; only the app sets it.
  final WidgetBuilder? drive;

  static String settingsRoute(SettingsTab tab) => switch (tab) {
    SettingsTab.app => KovaRoutes.settingsApp,
    SettingsTab.session => KovaRoutes.settingsSession,
    SettingsTab.kovapilot => KovaRoutes.settingsKovapilot,
  };

  static SettingsTab? _tabOf(String? name) => switch (name) {
    KovaRoutes.settingsApp => SettingsTab.app,
    KovaRoutes.settingsSession => SettingsTab.session,
    KovaRoutes.settingsKovapilot => SettingsTab.kovapilot,
    _ => null,
  };

  Route<void>? onGenerateRoute(RouteSettings route) => this.route(route.name);

  /// The route called [name], or null for an unknown name. [instant] shows
  /// it without the slide-in (settings tabs).
  Route<void>? route(String? name, {bool instant = false}) {
    if (_tabOf(name) case final tab?) {
      return settingsPage(tab, instant: instant);
    }
    return switch (name) {
      KovaRoutes.drive => switch (drive) {
        final drive? => KovaPageRoute(name: KovaRoutes.drive, builder: drive),
        null => null,
      },
      KovaRoutes.connect => connectPage(),
      KovaRoutes.diagnostics => RendererDiagnosticsPage.route(),
      KovaRoutes.kovapilotVersion => KovapilotVersionScreen.route(
        endpoint: kovaParams?.endpoint ?? settings?.value.settingsEndpoint,
        sessionFor: link?.sessionFor ?? kovaParams?.sessionFor,
      ),
      _ => null,
    };
  }

  Route<void> connectPage() => KovaPageRoute(
    name: KovaRoutes.connect,
    builder: (context) => KovaPage(
      child: ConnectScreen(
        controller: controller,
        settings: settings,
        autoConnect: autoConnect,
        link: link,
      ),
    ),
  );

  Route<void> settingsPage(SettingsTab tab, {bool instant = false}) =>
      KovaPageRoute(
        name: settingsRoute(tab),
        instant: instant,
        builder: (context) => KovaPage(
          child: SettingsScreen(
            controller: controller,
            vehicleModel: vehicleModel,
            settings: settings,
            library: library,
            modelPicker: modelPicker,
            kovaParams: kovaParams,
            initialTab: tab,
            // Tabs replace each other: back from any tab is the drive screen.
            onTabSelected: (next) =>
                KovaRoutes.replace(context, settingsPage(next, instant: true)),
          ),
        ),
      );
}
