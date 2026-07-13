import 'package:flutter/material.dart';

import 'services/streaming_service.dart';
import 'ui/streaming_screen.dart';

/// Phone Can — entry point.
/// Este arquivo só faz boot: cria o service (backend) e entrega
/// pra tela (frontend). Toda a lógica mora em services/, toda a
/// UI em ui/, toda a config em config/.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final service = StreamingService();
  await service.init();

  runApp(PhoneCanApp(service: service));
}

class PhoneCanApp extends StatelessWidget {
  final StreamingService service;

  const PhoneCanApp({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phone Can',
      theme: ThemeData.dark(),
      home: StreamingScreen(service: service),
    );
  }
}
