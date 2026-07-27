import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ChokroApp());
}

class ChokroApp extends StatelessWidget {
  const ChokroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chokro',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(
          child: Text('Chokro — Firebase connected, By AL SABAH ARNISH'),
        ),
      ),
    );
  }
}
