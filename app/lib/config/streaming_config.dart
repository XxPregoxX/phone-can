/// Configuração central do Phone Can.
/// Tudo que é "número mágico" do streaming mora aqui — um lugar só
/// pra mexer quando trocar de rede, calibrar bitrate ou adicionar
/// resoluções.
class StreamingConfig {
  StreamingConfig._(); // não instanciável, só constantes

  // ==================== REDE ====================

  /// Porta do WebSocket de sinalização (tem que bater com o receiver).
  static const int signalingPort = 8765;

  /// Porta onde o receiver anuncia presença via broadcast UDP.
  static const int discoveryPort = 8766;

  /// Quanto tempo o app escuta pelo anúncio antes de desistir
  /// (o receiver grita a cada 2s, então 5s = ~2 chances).
  static const Duration discoveryTimeout = Duration(seconds: 5);

  /// Fallback: valor inicial do campo de IP manual, usado só se a
  /// descoberta automática falhar e o usuário quiser digitar.
  static const String fallbackReceiverIp = '192.168.3.6';

  static Uri signalingUriFor(String ip) =>
      Uri.parse('ws://$ip:$signalingPort');

  // ==================== BITRATE ====================
  // Zona de conforto medida em campo (AX3, 5 GHz):
  // - perda zero até ~27 Mbps sustentados, perda pinga a partir de ~28
  // - teto operacional com ~10% de margem: 25 Mbps
  // - piso baixo DE PROPÓSITO: keyframes (inicial e de recuperação
  //   pós-perda) nascem magros e atravessam a rede; o BWE rampa depois.

  static const int maxBitrate = 25 * 1000 * 1000; // 25 Mbps
  static const int minBitrate = 8 * 1000 * 1000; //  8 Mbps

  // ==================== CAPTURA ====================

  /// Resoluções oferecidas na UI → (largura, altura) passadas como
  /// constraints reais pro getUserMedia.
  static const Map<String, (int, int)> resolutions = {
    'UHD (4K)': (3840, 2160),
    'QHD (1440p)': (2560, 1440),
    'FHD (1080p)': (1920, 1080),
    'HD (720p)': (1280, 720),
  };

  /// FPS disponíveis por resolução.
  /// Nota de campo: 4K@60 é aceito pela UI mas a captura via
  /// libwebrtc abre em 30 (limitação do pipeline getUserMedia —
  /// ver backlog "arquitetura nova" pra 4K60 real).
  static List<int> fpsFor(String sizeName) {
    if (sizeName.contains('UHD')) return const [24, 30, 60];
    return const [30, 60];
  }

  // ==================== STATS ====================

  /// Intervalo do logger de diagnóstico.
  static const Duration statsInterval = Duration(seconds: 2);
}
