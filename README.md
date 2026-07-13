# Phone Can

Streaming de vídeo **4K @ 30 fps** ponto-a-ponto (P2P) via **WebRTC** por rede
local. Um app Flutter (Android) captura a câmera do celular e transmite vídeo
**H.264** direto para um receiver Python que decodifica e exibe o stream com
OpenCV — sem servidor de mídia no meio, sem nuvem, sem STUN/TURN.

O nome vem do velho "telefone de lata": dois pontos ligados por um fio direto.
Aqui o "fio" é a sua rede Wi-Fi/LAN.

```
┌─────────────────────────┐        Wi-Fi / LAN         ┌──────────────────────────┐
│      App Flutter        │                            │     Receiver Python      │
│      (Android)          │                            │    (Linux/PC/notebook)   │
│                         │                            │                          │
│  getUserMedia →         │  ── sinalização WS :8765 ─▶ │  websockets (SDP)        │
│  flutter_webrtc         │  ◀── SDP answer ──────────  │  aiortc (RTCPeerConn.)   │
│  encoder H.264          │                            │       │                  │
│                         │  ═══ RTP/UDP (vídeo) ═════▶ │       ▼                  │
│                         │                            │  decode H.264 → OpenCV   │
└─────────────────────────┘                            └──────────────────────────┘
```

## Estrutura do repositório

```
.
├── app/          # App Flutter (Android) — captura e transmite a câmera
│   └── lib/
│       ├── main.dart            # UI + pipeline WebRTC (getUserMedia → sender)
│       └── stream_service.dart  # helper UDP legado (não usado no fluxo WebRTC)
├── receiver/     # Receiver Python — recebe, decodifica e exibe
│   ├── receiver.py
│   └── requirements.txt
└── README.md
```

## Como funciona (arquitetura)

### App (`app/`)
- Abre a câmera **uma única vez** via `getUserMedia`/`flutter_webrtc`, já na
  resolução escolhida (UHD/QHD/FHD/HD). O preview na tela **é** o mesmo stream
  enviado — o que você vê é o que vai.
- Força o encoder a manter a resolução (`MAINTAIN_RESOLUTION`), sem downscale
  automático, e libera bitrate suficiente para 4K (rede local aguenta).
- Faz a sinalização SDP (offer/answer) por **WebSocket** com o receiver e então
  o vídeo flui direto por **RTP/UDP** (WebRTC P2P).
- Um logger imprime a cada 2 s um diagnóstico separando câmera / encoder / rede.

### Receiver (`receiver/`)
Arquitetura de **duas threads** para não deixar o processamento de imagem
travar a rede:

- **Thread de rede** — roda todo o mundo `asyncio` (aiortc + websockets). O
  event loop **nunca** toca em pixel: só faz rede, RTCP e joga cada frame
  decodificado numa fila.
- **Main thread** — roda o OpenCV (`to_ndarray` + `imshow`), porque alguns
  backends de GUI exigem a thread principal.
- **Ponte** — uma fila de tamanho 1 **com descarte**: se a exibição atrasar, o
  frame velho é jogado fora e mostra-se o mais novo. A rede nunca fica represada.

A janela de exibição só existe enquanto há vídeo: nasce no primeiro frame e
fecha sozinha após ~2 s sem receber nada. A exibição é escalada para caber em
~1300×700 (economiza ~85% do custo de desenho num stream 4K); o stream continua
chegando em resolução cheia.

## Como rodar

### 1. Receiver (Python)

Requer Python 3 e as dependências em `receiver/requirements.txt`
(`aiortc`, `websockets`, `opencv-python`, `numpy`).

```bash
cd receiver
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

#### ⚠️ Pré-requisito no Linux: buffer de recepção UDP

O vídeo 4K chega em rajadas de RTP/UDP que estouram o buffer de socket padrão
do kernel, causando perda de pacotes e artefatos no decode. **Antes de rodar o
receiver**, aumente o buffer de recepção UDP para 25 MB:

```bash
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.rmem_default=26214400
```

Para tornar permanente (persistir após reboot):

```bash
echo -e "net.core.rmem_max=26214400\nnet.core.rmem_default=26214400" | \
  sudo tee /etc/sysctl.d/99-phone-can.conf
sudo sysctl --system
```

Agora inicie o receiver:

```bash
python receiver.py
```

Ele imprime o endereço de sinalização, por exemplo:

```
=== PHONE CAN PROJECT - RECEPTOR P2P ===
[SERVER] Sinalização em: ws://192.168.3.4:8765
```

Anote esse **IP** — você vai colocá-lo no app. Pressione `q` na janela de vídeo
(ou `Ctrl+C` no terminal) para sair.

### 2. App (Flutter)

Requer o [Flutter SDK](https://docs.flutter.dev/get-started/install) e um
dispositivo Android (a câmera exige hardware real).

1. Abra `app/lib/main.dart` e ajuste a constante do IP no topo do arquivo para o
   endereço que o receiver imprimiu:

   ```dart
   const String kReceiverIp = '192.168.3.4';
   ```

   A porta de sinalização é a `8765` (a mesma que o receiver escuta).

2. Compile e instale no celular:

   ```bash
   cd app
   flutter pub get
   flutter run
   ```

3. No app, escolha resolução/FPS e toque no botão verde para iniciar a
   transmissão. A janela de vídeo abre automaticamente no receiver.

> **Ambos precisam estar na mesma rede local.** Não há STUN/TURN: a conexão é
> direta entre celular e receiver.

## Requisitos

| Lado     | Requisitos |
|----------|------------|
| App      | Flutter SDK, Android (câmera real) |
| Receiver | Python 3, deps de `receiver/requirements.txt`, Linux com buffer UDP ajustado |
