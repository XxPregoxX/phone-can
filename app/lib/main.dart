import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ===================== CONFIGURAÇÃO DE REDE =====================
// IP da máquina que roda o receiver Python (receiver/receiver.py) na rede
// local. O celular e o receiver PRECISAM estar na mesma rede (Wi-Fi/LAN).
//
// Ao iniciar, o receiver imprime o próprio endereço:
//     [SERVER] Sinalização em: ws://<IP>:8765
// Copie esse <IP> para cá antes de compilar o app. A sinalização WebSocket
// usa a porta 8765 (a mesma que o receiver escuta).
const String kReceiverIp = '192.168.3.4';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: const WebRTCStreamingScreen(),
    );
  }
}

class WebRTCStreamingScreen extends StatefulWidget {
  const WebRTCStreamingScreen({super.key});

  @override
  State<WebRTCStreamingScreen> createState() => _WebRTCStreamingScreenState();
}

class _WebRTCStreamingScreenState extends State<WebRTCStreamingScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  WebSocketChannel? _wsChannel;
  Timer? _statsTimer;
  bool _isStreaming = false;
  bool _cameraReady = false;

  // Acumuladores pra calcular taxas reais entre um tick e outro do logger
  int _lastBytesSent = 0;
  int _lastFramesEncoded = 0;
  double _lastEncodeTime = 0;

  // Agora o mapa contém resoluções REAIS (largura x altura) que serão
  // passadas como constraints diretamente pro getUserMedia do WebRTC.
  final Map<String, List<int>> _resolutionMap = {
    'UHD (4K)': [3840, 2160],
    'QHD (1440p)': [2560, 1440],
    'FHD (1080p)': [1920, 1080],
    'HD (720p)': [1280, 720],
  };

  String _selectedSize = 'FHD (1080p)';
  int _selectedFps = 30;

  List<int> _getAvailableFps(String size) {
    if (size.contains('UHD')) {
      return [24, 30, 60];   // <- 60 liberado pro teste de fogo
    } else if (size.contains('QHD') || size.contains('FHD')) {
      return [30, 60];
    }
    return [30, 60];
  }

  @override
  void initState() {
    super.initState();
    _initRenderer();
  }

  Future<void> _initRenderer() async {
    await _localRenderer.initialize();
    await _requestPermissionsAndStartCamera();
  }

  Future<void> _requestPermissionsAndStartCamera() async {
    await [Permission.camera, Permission.microphone].request();
    await _startCapture();
  }

  // Abre a câmera UMA VEZ só, direto pelo WebRTC, já na resolução escolhida.
  // O preview na tela é o mesmo stream que será enviado — o que você vê é o que vai.
  Future<void> _startCapture() async {
    // Fecha a captura anterior antes de reabrir com nova config
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    final res = _resolutionMap[_selectedSize]!;
    final width = res[0];
    final height = res[1];

    final Map<String, dynamic> mediaConstraints = {
      'audio': false,
      'video': {
        'mandatory': {
          'minWidth': '$width',
          'minHeight': '$height',
          'maxWidth': '$width',
          'maxHeight': '$height',
          'minFrameRate': '$_selectedFps',
          'maxFrameRate': '$_selectedFps',
        },
        'facingMode': 'environment',
      },
    };

    try {
      _localStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _localRenderer.srcObject = _localStream;

      // Loga o que a câmera efetivamente entregou (pode diferir do pedido
      // se o hardware não suportar a combinação resolução+fps)
      try {
        final settings = _localStream!.getVideoTracks().first.getSettings();
        print('[CAPTURA] Câmera abriu em: '
            '${settings['width']}x${settings['height']} '
            '@ ${settings['frameRate']} fps');
      } catch (_) {
        print('[CAPTURA] getSettings não suportado nessa versão do plugin');
      }

      setState(() => _cameraReady = true);
    } catch (e) {
      print('[CAPTURA] Erro ao abrir câmera em ${width}x$height'
          '@$_selectedFps: $e');
      setState(() => _cameraReady = false);
    }
  }

  Future<void> _toggleStreaming() async {
    if (_isStreaming) {
      _stopStreaming();
      return;
    }

    if (_localStream == null) {
      print('[WebRTC] Câmera ainda não está pronta.');
      return;
    }

    try {
      final Map<String, dynamic> configuration = {
        'iceServers': [], // rede local direta, sem STUN/TURN
        'sdpSemantics': 'unified-plan',
      };

      _peerConnection = await createPeerConnection(configuration);

      // Adiciona a track de vídeo JÁ CAPTURADA (mesma do preview)
      for (var track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // ================== PARTE CRÍTICA PRA RESOLUÇÃO ==================
      // Por padrão o WebRTC REDUZ a resolução sozinho quando acha que não
      // tem banda/CPU. Aqui forçamos ele a manter a resolução e liberamos
      // bitrate suficiente pra 4K (rede local aguenta tranquilo).
      final senders = await _peerConnection!.getSenders();
      for (var sender in senders) {
        if (sender.track?.kind == 'video') {
          final params = sender.parameters;
          params.degradationPreference =
              RTCDegradationPreference.MAINTAIN_RESOLUTION;
          if (params.encodings == null || params.encodings!.isEmpty) {
            params.encodings = [RTCRtpEncoding()];
          }
          params.encodings![0].maxBitrate = 25 * 1000 * 1000; // 30 Mbps
          // EXPERIMENTO DIAGNÓSTICO: força o encoder a nunca descer de 10 Mbps,
          // ignorando o estimador de banda (BWE). Se o fps subir pra 30 com isso,
          // o problema era o BWE travado, não o hardware do celular.
          params.encodings![0].minBitrate = 8 * 1000 * 1000; // 20 Mbps
          params.encodings![0].maxFramerate = _selectedFps;
          params.encodings![0].scaleResolutionDownBy = 1.0; // sem downscale
          await sender.setParameters(params);
          print('[WebRTC] Sender configurado: maintain-resolution, '
              '30 Mbps, scale 1.0');
        }
      }
      // =================================================================

      _wsChannel =
          WebSocketChannel.connect(Uri.parse('ws://$kReceiverIp:8765'));

      _wsChannel!.stream.listen((message) async {
        var data = jsonDecode(message);
        if (data['type'] == 'answer') {
          print('[WebRTC] SDP Answer recebida do Python! Conectando mídia...');
          RTCSessionDescription answer =
              RTCSessionDescription(data['sdp'], data['type']);
          await _peerConnection!.setRemoteDescription(answer);
          setState(() => _isStreaming = true);
          _startStatsLogger();
        }
      });

      RTCSessionDescription offer = await _peerConnection!.createOffer({
        'offerToReceiveVideo': 0,
        'offerToReceiveAudio': 0,
      });
      await _peerConnection!.setLocalDescription(offer);

      _wsChannel!.sink.add(jsonEncode({
        'type': offer.type,
        'sdp': offer.sdp,
      }));
      print('[WebRTC] SDP Offer enviada para o Python. Aguardando resposta...');
    } catch (e) {
      print('Erro na conexão P2P WebRTC: $e');
      _stopStreaming();
    }
  }

  // Diagnóstico completo a cada 2s, separando os 3 suspeitos:
  //   CÂMERA  -> fps que o sensor está entregando pro pipeline
  //   ENCODER -> quanto tempo o hardware leva pra codificar cada frame
  //   REDE    -> bitrate real na rede, estimativa do BWE, RTT e perda
  void _startStatsLogger() {
    _statsTimer?.cancel();
    _lastBytesSent = 0;
    _lastFramesEncoded = 0;
    _lastEncodeTime = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
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

          // ---------- CÂMERA: o que o sensor entrega ----------
          if (report.type == 'media-source' && v['kind'] == 'video') {
            camera = '${v['width']}x${v['height']} @ ${v['framesPerSecond']} fps';
          }

          // ---------- ENCODER + SAÍDA ----------
          if (report.type == 'outbound-rtp' && v['kind'] == 'video') {
            final fpsOut = v['framesPerSecond'];
            final target = v['targetBitrate']; // o que o BWE mandou o encoder usar
            final limit = v['qualityLimitationReason'];

            // Tempo médio de encode por frame nesse intervalo
            final framesEnc = (v['framesEncoded'] as num?)?.toInt() ?? 0;
            final encTime = (v['totalEncodeTime'] as num?)?.toDouble() ?? 0;
            final dFrames = framesEnc - _lastFramesEncoded;
            final dTime = encTime - _lastEncodeTime;
            final msPorFrame =
                dFrames > 0 ? (dTime / dFrames * 1000).toStringAsFixed(1) : '?';
            _lastFramesEncoded = framesEnc;
            _lastEncodeTime = encTime;

            final targetMbps = target is num
                ? (target / 1e6).toStringAsFixed(2)
                : '?';
            encoder =
                '$fpsOut fps saindo | $msPorFrame ms/frame de encode | '
                'alvo do BWE: $targetMbps Mbps | limitação: $limit';

            // Bitrate REAL enviado na rede nesse intervalo
            final bytes = (v['bytesSent'] as num?)?.toInt() ?? 0;
            if (_lastBytesSent > 0) {
              final mbps = ((bytes - _lastBytesSent) * 8 / 2 / 1e6)
                  .toStringAsFixed(2);
              rede = '$mbps Mbps reais na rede';
            }
            _lastBytesSent = bytes;
          }

          // ---------- REDE: o que o BWE acha que a rede aguenta ----------
          if (report.type == 'candidate-pair' &&
              (v['state'] == 'succeeded' || v['nominated'] == true)) {
            final avail = v['availableOutgoingBitrate'];
            if (avail is num) {
              bwe = '${(avail / 1e6).toStringAsFixed(2)} Mbps';
            }
            final r = v['currentRoundTripTime'];
            if (r is num) rtt = '${(r * 1000).toStringAsFixed(1)} ms';
          }

          // ---------- PERDA: o que o Python reporta de volta ----------
          if (report.type == 'remote-inbound-rtp' && v['kind'] == 'video') {
            perda = 'packetsLost=${v['packetsLost']} '
                'jitter=${v['jitter']}';
          }
        }

        print('==================== DIAGNÓSTICO ====================');
        print('[CÂMERA ] $camera');
        print('[ENCODER] $encoder');
        print('[REDE   ] $rede | BWE estima: $bwe | RTT: $rtt');
        print('[PERDA  ] $perda');
        print('=====================================================');
      } catch (e) {
        print('[STATS] Erro ao ler stats: $e');
      }
    });
  }

  void _stopStreaming() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _peerConnection?.close();
    _peerConnection = null;
    _wsChannel?.sink.close();
    _wsChannel = null;
    setState(() => _isStreaming = false);
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _peerConnection?.close();
    _wsChannel?.sink.close();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_cameraReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final availableFpsList = _getAvailableFps(_selectedSize);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: RTCVideoView(
              _localRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),

          // Painel Superior estilo Samsung Camera (Com Scroll Horizontal)
          Positioned(
            top: 50,
            left: 15,
            right: 15,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Text('Tam:',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.grey)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: Row(
                            children: _resolutionMap.keys.map((size) {
                              bool isSelected = _selectedSize == size;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4.0),
                                child: ChoiceChip(
                                  label: Text(size,
                                      style: TextStyle(
                                          color: isSelected
                                              ? Colors.black
                                              : Colors.white,
                                          fontSize: 12)),
                                  selected: isSelected,
                                  selectedColor: Colors.amber,
                                  backgroundColor: Colors.grey[900],
                                  onSelected: _isStreaming
                                      ? null
                                      : (selected) {
                                          if (selected) {
                                            setState(() {
                                              _selectedSize = size;
                                              final newFpsList =
                                                  _getAvailableFps(size);
                                              if (!newFpsList
                                                  .contains(_selectedFps)) {
                                                _selectedFps =
                                                    newFpsList.first;
                                              }
                                            });
                                            _startCapture();
                                          }
                                        },
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('FPS:',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.grey)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: Row(
                            children: availableFpsList.map((fps) {
                              bool isSelected = _selectedFps == fps;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4.0),
                                child: ChoiceChip(
                                  label: Text('$fps',
                                      style: TextStyle(
                                          color: isSelected
                                              ? Colors.black
                                              : Colors.white,
                                          fontSize: 12)),
                                  selected: isSelected,
                                  selectedColor: Colors.amber,
                                  backgroundColor: Colors.grey[900],
                                  onSelected: _isStreaming
                                      ? null
                                      : (selected) {
                                          if (selected) {
                                            setState(
                                                () => _selectedFps = fps);
                                            _startCapture();
                                          }
                                        },
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Botão Inferior de Transmissão
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isStreaming ? Colors.red : Colors.green,
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(20),
                ),
                onPressed: _toggleStreaming,
                child: Icon(_isStreaming ? Icons.stop : Icons.videocam,
                    size: 30, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
