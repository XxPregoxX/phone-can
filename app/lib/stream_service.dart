import 'dart:io';
import 'dart:typed_data';

class StreamService {
  RawDatagramSocket? _socket;
  final String serverIp;
  final int serverPort;

  StreamService({required this.serverIp, required this.serverPort});

  // Inicializa a conexão UDP na rede local
  Future<void> connect() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      print("Socket UDP conectado e pronto.");
    } catch (e) {
      print("Erro ao abrir socket: $e");
    }
  }

  // Envia os bytes de uma imagem direto para o servidor Python
  void sendFrame(Uint8List imageBytes) {
    if (_socket == null) return;

    try {
      _socket!.send(
        imageBytes,
        InternetAddress(serverIp),
        serverPort,
      );
    } catch (e) {
      print("Erro ao enviar frame: $e");
    }
  }

  // Fecha o socket quando o app parar
  void dispose() {
    _socket?.close();
  }
}
