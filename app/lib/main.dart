import 'package:flutter/material.dart';

import 'ui/dashboard_screen.dart';

void main() {
  runApp(const FlashGuardApp());
}

class FlashGuardApp extends StatelessWidget {
  const FlashGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlashGuard • Sandisk AI Storage Companion',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(
          0xFFD71920,
        ), // Sandisk signature crimson accent
        brightness: Brightness.dark,
      ),
      home: const FlashGuardDashboard(),
    );
  }
}
