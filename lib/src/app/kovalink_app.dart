import 'package:flutter/material.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

class KovaLinkApp extends StatefulWidget {
  const KovaLinkApp({super.key});

  @override
  State<KovaLinkApp> createState() => _KovaLinkAppState();
}

class _KovaLinkAppState extends State<KovaLinkApp> {
  late final GatewayController controller;

  @override
  void initState() {
    super.initState();
    controller = GatewayController()..startDemo();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const surface = Color(0xFF111820);
    const accent = Color(0xFF58F2C2);
    return MaterialApp(
      title: 'KovaLink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: Color(0xFF72A7FF),
          surface: surface,
          error: Color(0xFFFF6B72),
        ),
        scaffoldBackgroundColor: const Color(0xFF070B10),
        cardTheme: CardThemeData(
          color: surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF0C1219),
          indicatorColor: Color(0x3358F2C2),
          height: 72,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0A1016),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF27323D)),
          ),
        ),
        useMaterial3: true,
      ),
      home: KovaLinkHome(controller: controller),
    );
  }
}
