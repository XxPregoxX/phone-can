import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config/streaming_config.dart';
import '../services/streaming_service.dart';

/// Tela do streaming — UI PURA. Nenhum WebRTC, nenhum socket,
/// nenhuma lógica de negócio: lê estado do StreamingService e
/// chama as ações dele. Toda a inteligência mora no service.
class StreamingScreen extends StatelessWidget {
  final StreamingService service;

  const StreamingScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (!service.cameraReady) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return Scaffold(
          body: Stack(
            children: [
              // Preview: o MESMO stream que vai pra rede
              Positioned.fill(
                child: RTCVideoView(
                  service.localRenderer,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
              _buildControlPanel(),
              _buildReceiverStatus(context),
              _buildStreamButton(),
            ],
          ),
        );
      },
    );
  }

  /// Painel superior estilo Samsung Camera (com scroll horizontal)
  Widget _buildControlPanel() {
    return Positioned(
      top: 50,
      left: 15,
      right: 15,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.75),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildChipRow(
              label: 'Tam:',
              options: StreamingConfig.resolutions.keys.toList(),
              isSelected: (size) => service.selectedSize == size,
              display: (size) => size,
              onSelected: service.selectResolution,
            ),
            const SizedBox(height: 8),
            _buildChipRow(
              label: 'FPS:',
              options: service.availableFps,
              isSelected: (fps) => service.selectedFps == fps,
              display: (fps) => '$fps',
              onSelected: service.selectFps,
            ),
          ],
        ),
      ),
    );
  }

  /// Linha genérica de ChoiceChips com scroll horizontal — serve
  /// tanto pra resolução quanto pra FPS (e o que mais vier).
  Widget _buildChipRow<T>({
    required String label,
    required List<T> options,
    required bool Function(T) isSelected,
    required String Function(T) display,
    required Future<void> Function(T) onSelected,
  }) {
    return Row(
      children: [
        Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.grey)),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: options.map((option) {
                final selected = isSelected(option);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: ChoiceChip(
                    label: Text(display(option),
                        style: TextStyle(
                            color:
                                selected ? Colors.black : Colors.white,
                            fontSize: 12)),
                    selected: selected,
                    selectedColor: Colors.amber,
                    backgroundColor: Colors.grey[900],
                    onSelected: service.isStreaming
                        ? null
                        : (sel) {
                            if (sel) onSelected(option);
                          },
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  /// Barra de status do receiver: descoberta em andamento, IP achado,
  /// ou não-encontrado (com retry no toque). A engrenagem abre o
  /// diálogo de IP manual.
  Widget _buildReceiverStatus(BuildContext context) {
    final Widget conteudo;
    if (service.discovering) {
      conteudo = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Procurando receiver...',
              style: TextStyle(color: Colors.white, fontSize: 12)),
        ],
      );
    } else if (service.receiverIp != null) {
      conteudo = Text('Receiver: ${service.receiverIp}',
          style: const TextStyle(color: Colors.greenAccent, fontSize: 12));
    } else {
      conteudo = const Text('Receiver não encontrado — toque p/ buscar',
          style: TextStyle(color: Colors.orangeAccent, fontSize: 12));
    }

    return Positioned(
      bottom: 120,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: (service.discovering || service.isStreaming)
              ? null
              : service.discoverReceiver,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.75),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                conteudo,
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: service.isStreaming
                      ? null
                      : () => _showManualIpDialog(context),
                  child: const Icon(Icons.settings,
                      size: 16, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showManualIpDialog(BuildContext context) {
    final controller = TextEditingController(
        text: service.receiverIp ?? StreamingConfig.fallbackReceiverIp);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('IP manual do receiver'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'ex: 192.168.3.6'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              service.setManualIp(controller.text);
              Navigator.pop(ctx);
            },
            child: const Text('Usar'),
          ),
        ],
      ),
    );
  }

  /// Botão inferior de transmissão
  Widget _buildStreamButton() {
    final semReceiver = service.receiverIp == null && !service.isStreaming;
    return Positioned(
      bottom: 40,
      left: 0,
      right: 0,
      child: Center(
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: semReceiver
                ? Colors.grey
                : (service.isStreaming ? Colors.red : Colors.green),
            shape: const CircleBorder(),
            padding: const EdgeInsets.all(20),
          ),
          onPressed: semReceiver ? null : service.toggleStreaming,
          child: Icon(
            service.isStreaming ? Icons.stop : Icons.videocam,
            size: 30,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
