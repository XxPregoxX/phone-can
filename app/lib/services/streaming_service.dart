import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/streaming_config.dart';

/// Backend completo do Phone Can: câmera, conexão WebRTC, sinalização
/// WebSocket e telemetria. Não conhece NADA de UI — expõe estado via
/// ChangeNotifier e a tela escuta.
class StreamingService extends ChangeNotifier {
  // ==================== ESTADO PÚBLICO (a UI lê daqui) ====================

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  bool cameraReady = false;
  bool isStreaming = false;
  String selectedSize = 'FHD (1080p)';
  int selectedFps = 30;

  /// IP do receiver: preenchido pela descoberta automática ou
  /// manualmente pelo usuário. null = ainda não sabemos onde ele mora.
  String? receiverIp;
  bool discovering = false;

  List<int> get availableFps => StreamingConfig.fpsFor(selectedSize);

  // ==================== INTERNOS ====================

  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  WebSocketChannel? _wsChannel;
  Timer? _statsTimer;

  // Acumuladores do logger de diagnóstico
  int _lastBytesSent = 0;
  int _lastFramesEncoded = 0;
  double _lastEncodeTime = 0;

  // ==================== CICLO DE VIDA ====================

  /// Chamar uma vez no boot do app.
  Future<void> init() async {
    await localRenderer.initialize();
    await [Permission.camera, Permission.microphone].request();
    await _startCapture();
    discoverReceiver(); // roda em paralelo, sem travar o boot
  }

  // ==================== DESCOBERTA DO RECEIVER ====================

  /// Escuta a porta de broadcast por alguns segundos esperando o
  /// anúncio do receiver ("phone-can"). O IP vem de brinde no
  /// remetente do pacote UDP — não precisa estar no payload.
  Future<void> discoverReceiver() async {
    discovering = true;
    receiverIp = null;
    notifyListeners();

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, StreamingConfig.discoveryPort);

      final achado = Completer<String?>();
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagrama = socket!.receive();
        if (datagrama == null) return;
        try {
          final data = jsonDecode(utf8.decode(datagrama.data));
          if (data['service'] == 'phone-can' && !achado.isCompleted) {
            achado.complete(datagrama.address.address);
          }
        } catch (_) {
          // pacote alheio na porta, ignora
        }
      });

      receiverIp = await achado.future.timeout(
        StreamingConfig.discoveryTimeout,
        onTimeout: () => null,
      );
      await sub.cancel();

      if (receiverIp != null) {
        debugPrint('[DISCOVERY] Receiver encontrado em $receiverIp');
      } else {
        debugPrint('[DISCOVERY] Nenhum receiver anunciando na rede '
            '(timeout de ${StreamingConfig.discoveryTimeout.inSeconds}s)');
      }
    } catch (e) {
      debugPrint('[DISCOVERY] Erro na descoberta: $e');
      receiverIp = null;
    } finally {
      socket?.close();
      discovering = false;
      notifyListeners();
    }
  }

  /// Fallback manual: usuário digitou o IP na mão.
  void setManualIp(String ip) {
    receiverIp = ip.trim();
    debugPrint('[DISCOVERY] IP definido manualmente: $receiverIp');
    notifyListeners();
  }

  @override
  void dispose() {
    _teardownConnection();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    localRenderer.dispose();
    super.dispose();
  }

  // ==================== AÇÕES (a UI chama daqui) ====================

  Future<void> selectResolution(String size) async {
    if (isStreaming) return;
    selectedSize = size;
    final fpsList = availableFps;
    if (!fpsList.contains(selectedFps)) {
      selectedFps = fpsList.first;
    }
    notifyListeners();
    await _startCapture();
  }

  Future<void> selectFps(int fps) async {
    if (isStreaming) return;
    selectedFps = fps;
    notifyListeners();
    await _startCapture();
  }

  Future<void> toggleStreaming() async {
    if (isStreaming) {
      _teardownConnection();
      isStreaming = false;
      notifyListeners();
      return;
    }
    if (receiverIp == null) {
      debugPrint('[WebRTC] Sem receiver conhecido — rode a descoberta '
          'ou defina o IP manualmente.');
      return;
    }
    await _connect();
  }

  // ==================== CAPTURA ====================

  /// Abre a câmera UMA VEZ, direto pelo WebRTC, já na resolução
  /// escolhida. O preview é o mesmo stream que será enviado —
  /// o que você vê é o que vai.
  Future<void> _startCapture() async {
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    final (width, height) = StreamingConfig.resolutions[selectedSize]!;

    final mediaConstraints = <String, dynamic>{
      'audio': false,
      'video': {
        'mandatory': {
          'minWidth': '$width',
          'minHeight': '$height',
          'maxWidth': '$width',
          'maxHeight': '$height',
          'minFrameRate': '$selectedFps',
          'maxFrameRate': '$selectedFps',
        },
        'facingMode': 'environment',
      },
    };

    try {
      _localStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      localRenderer.srcObject = _localStream;

      try {
        final settings = _localStream!.getVideoTracks().first.getSettings();
        debugPrint('[CAPTURA] Câmera abriu em: '
            '${settings['width']}x${settings['height']} '
            '@ ${settings['frameRate']} fps');
      } catch (_) {
        debugPrint('[CAPTURA] getSettings não suportado nesta versão');
      }

      cameraReady = true;
    } catch (e) {
      debugPrint('[CAPTURA] Erro ao abrir ${width}x$height'
          '@$selectedFps: $e');
      cameraReady = false;
    }
    notifyListeners();
  }

  // ==================== CONEXÃO WEBRTC ====================

  Future<void> _connect() async {
    if (_localStream == null) {
      debugPrint('[WebRTC] Câmera ainda não está pronta.');
      return;
    }

    try {
      _peerConnection = await createPeerConnection({
        'iceServers': [], // rede local direta, sem STUN/TURN
        'sdpSemantics': 'unified-plan',
      });

      for (var track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      await _configureSender();
      await _signal();
    } catch (e) {
      debugPrint('Erro na conexão P2P WebRTC: $e');
      _teardownConnection();
      notifyListeners();
    }
  }

  /// Parte crítica pra resolução/qualidade: mantém a resolução,
  /// limita o bitrate à zona de conforto medida, e deixa o piso
  /// baixo pra keyframes de nascença/recuperação atravessarem.
  Future<void> _configureSender() async {
    final senders = await _peerConnection!.getSenders();
    for (var sender in senders) {
      if (sender.track?.kind != 'video') continue;

      final params = sender.parameters;
      params.degradationPreference =
          RTCDegradationPreference.MAINTAIN_RESOLUTION;
      if (params.encodings == null || params.encodings!.isEmpty) {
        params.encodings = [RTCRtpEncoding()];
      }
      params.encodings![0].maxBitrate = StreamingConfig.maxBitrate;
      params.encodings![0].minBitrate = StreamingConfig.minBitrate;
      params.encodings![0].maxFramerate = selectedFps;
      params.encodings![0].scaleResolutionDownBy = 1.0;
      await sender.setParameters(params);

      debugPrint('[WebRTC] Sender: maintain-resolution, '
          '${StreamingConfig.minBitrate ~/ 1000000}-'
          '${StreamingConfig.maxBitrate ~/ 1000000} Mbps');
    }
  }

  /// Aperto de mão via WebSocket: manda a Offer, espera a Answer.
  Future<void> _signal() async {
    _wsChannel = WebSocketChannel.connect(
        StreamingConfig.signalingUriFor(receiverIp!));

    _wsChannel!.stream.listen((message) async {
      final data = jsonDecode(message);
      if (data['type'] == 'answer') {
        debugPrint('[WebRTC] SDP Answer recebida! Conectando mídia...');
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(data['sdp'], data['type']),
        );
        isStreaming = true;
        notifyListeners();
        _startStatsLogger();
      }
    }, onError: (e) {
      debugPrint('[WEBSOCKET] Erro: $e');
      _teardownConnection();
      isStreaming = false;
      notifyListeners();
    });

    final offer = await _peerConnection!.createOffer({
      'offerToReceiveVideo': 0,
      'offerToReceiveAudio': 0,
    });
    await _peerConnection!.setLocalDescription(offer);
    _wsChannel!.sink.add(jsonEncode({
      'type': offer.type,
      'sdp': offer.sdp,
    }));
    debugPrint('[WebRTC] SDP Offer enviada. Aguardando resposta...');
  }

  void _teardownConnection() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _peerConnection?.close();
    _peerConnection = null;
    _wsChannel?.sink.close();
    _wsChannel = null;
    _lastBytesSent = 0;
    _lastFramesEncoded = 0;
    _lastEncodeTime = 0;
  }

  // ==================== TELEMETRIA ====================

  /// Diagnóstico periódico separando os 3 suspeitos de sempre:
  /// CÂMERA (o que o sensor entrega), ENCODER (custo por frame),
  /// REDE (bitrate real, estimativa do BWE, RTT, perda).
  void _startStatsLogger() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(StreamingConfig.statsInterval, (_) async {
      if (_peerConnection == null) return;
      try {
        final stats = await _peerConnection!.getStats();

        String camera = '?';
        String encoder = '?';
        String rede = '?';
        String bwe = '?';
        String rtt = '?';
        String perda = '?';

        for (var report in stats) {
          final v = report.values;

          if (report.type == 'media-source' && v['kind'] == 'video') {
            camera =
                '${v['width']}x${v['height']} @ ${v['framesPerSecond']} fps';
          }

          if (report.type == 'outbound-rtp' && v['kind'] == 'video') {
            final fpsOut = v['framesPerSecond'];
            final target = v['targetBitrate'];
            final limit = v['qualityLimitationReason'];

            final framesEnc = (v['framesEncoded'] as num?)?.toInt() ?? 0;
            final encTime = (v['totalEncodeTime'] as num?)?.toDouble() ?? 0;
            final dFrames = framesEnc - _lastFramesEncoded;
            final dTime = encTime - _lastEncodeTime;
            final msPorFrame = dFrames > 0
                ? (dTime / dFrames * 1000).toStringAsFixed(1)
                : '?';
            _lastFramesEncoded = framesEnc;
            _lastEncodeTime = encTime;

            final targetMbps =
                target is num ? (target / 1e6).toStringAsFixed(2) : '?';
            encoder = '$fpsOut fps saindo | $msPorFrame ms/frame de encode | '
                'alvo do BWE: $targetMbps Mbps | limitação: $limit';

            final bytes = (v['bytesSent'] as num?)?.toInt() ?? 0;
            if (_lastBytesSent > 0) {
              final mbps =
                  ((bytes - _lastBytesSent) * 8 / 2 / 1e6).toStringAsFixed(2);
              rede = '$mbps Mbps reais na rede';
            }
            _lastBytesSent = bytes;
          }

          if (report.type == 'candidate-pair' &&
              (v['state'] == 'succeeded' || v['nominated'] == true)) {
            final avail = v['availableOutgoingBitrate'];
            if (avail is num) {
              bwe = '${(avail / 1e6).toStringAsFixed(2)} Mbps';
            }
            final r = v['currentRoundTripTime'];
            if (r is num) rtt = '${(r * 1000).toStringAsFixed(1)} ms';
          }

          if (report.type == 'remote-inbound-rtp' && v['kind'] == 'video') {
            perda = 'packetsLost=${v['packetsLost']} jitter=${v['jitter']}';
          }
        }

        debugPrint('==================== DIAGNÓSTICO ====================');
        debugPrint('[CÂMERA ] $camera');
        debugPrint('[ENCODER] $encoder');
        debugPrint('[REDE   ] $rede | BWE estima: $bwe | RTT: $rtt');
        debugPrint('[PERDA  ] $perda');
        debugPrint('=====================================================');
      } catch (e) {
        debugPrint('[STATS] Erro ao ler stats: $e');
      }
    });
  }
}
