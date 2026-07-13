import asyncio
import json
import logging
import queue
import socket
import threading
import time
import traceback

# Liga os ouvidos: o aiortc reporta falhas de decode e problemas de
# depacketização via logging, não via print. Sem isso a gente fica surdo.
logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s %(name)s: %(message)s",
)


class AntiSpamDecode(logging.Filter):
    """O decoder do aiortc reclama de CADA pacote indecifrável — no fim
    de uma transmissão isso vira uma cachoeira de warnings idênticos.
    Este filtro deixa passar 1 a cada 5s e conta os engolidos no meio,
    preservando a informação sem o spam."""

    def __init__(self, intervalo=5.0):
        super().__init__()
        self.intervalo = intervalo
        self.ultimo = 0.0
        self.suprimidos = 0

    def filter(self, record):
        agora = time.time()
        if agora - self.ultimo >= self.intervalo:
            if self.suprimidos:
                record.msg = f"{record.msg} [+{self.suprimidos} warnings iguais suprimidos]"
            self.ultimo = agora
            self.suprimidos = 0
            return True
        self.suprimidos += 1
        return False


logging.getLogger("aiortc.codecs.h264").addFilter(AntiSpamDecode())

import cv2
import numpy as np
import websockets
from aiortc import RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import MediaStreamError

# ============================================================
# ARQUITETURA:
#   - MAIN THREAD  -> OpenCV (to_ndarray + imshow), porque
#     alguns backends de GUI exigem rodar na thread principal.
#   - THREAD DE REDE -> asyncio + aiortc + websocket. O event
#     loop NUNCA toca em pixel, só faz rede e RTCP.
#   - A ponte entre as duas é uma fila de tamanho 1 com
#     descarte: se a exibição atrasar, joga o frame velho fora
#     e mostra o mais novo. A rede nunca fica represada.
# ============================================================

frame_queue = queue.Queue(maxsize=1)


def entregar_frame(frame):
    """Coloca o frame na fila descartando o antigo se ela estiver cheia.
    Custa microssegundos — é a única coisa que o event loop faz com o frame."""
    try:
        frame_queue.put_nowait(frame)
    except queue.Full:
        try:
            frame_queue.get_nowait()  # descarta o frame velho
        except queue.Empty:
            pass
        try:
            frame_queue.put_nowait(frame)
        except queue.Full:
            pass  # corrida rara, o próximo frame resolve


# ==================== LADO DA REDE (thread secundária) ====================

async def consumir_track(track):
    """Só puxa frames e joga na fila. Nada de trabalho pesado aqui.
    Termina sozinha quando a track morre (MediaStreamError) ou é cancelada."""
    print("[WebRTC] Track de vídeo ativa. Consumindo frames...")
    contador = 0
    t_janela = time.time()
    try:
        while True:
            frame = await track.recv()
            contador += 1
            if contador == 1:
                print("[WebRTC] >>> PRIMEIRO FRAME decodificado com sucesso! <<<")
            elif contador % 150 == 0:
                agora = time.time()
                fps_chegada = 150 / (agora - t_janela)
                t_janela = agora
                print(f"[WebRTC] {contador} frames | chegando da rede a {fps_chegada:.1f} fps")
            entregar_frame(frame)
    except MediaStreamError:
        print(f"[WebRTC] Track encerrada após {contador} frames.")
    except asyncio.CancelledError:
        print(f"[WebRTC] Consumo cancelado após {contador} frames.")
        raise
    except Exception:
        # O buraco onde o frame tava sumindo sem deixar bilhete:
        print(f"[WebRTC] !!! EXCEÇÃO INESPERADA no recv() após {contador} frames !!!")
        traceback.print_exc()


async def handler(websocket):
    print(f"[WEBSOCKET] Celular conectado de: {websocket.remote_address}")

    pc = RTCPeerConnection()
    track_tasks = set()

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        print(f"[WebRTC] Connection state: {pc.connectionState}")
        # Se o WebRTC cair (celular fechou o app, Wi-Fi caiu, etc),
        # cancela as tasks de consumo e fecha a conexão — sem isso o
        # loop antigo ficava vivo segurando o processo.
        if pc.connectionState in ("failed", "disconnected", "closed"):
            for t in list(track_tasks):
                t.cancel()
            await pc.close()

    @pc.on("track")
    def on_track(track):
        if track.kind == "video":
            task = asyncio.create_task(consumir_track(track))
            track_tasks.add(task)
            task.add_done_callback(track_tasks.discard)

    try:
        async for message in websocket:
            data = json.loads(message)

            if data["type"] == "offer":
                print("[WEBSOCKET] SDP Offer recebida. Processando...")
                offer = RTCSessionDescription(sdp=data["sdp"], type=data["type"])
                await pc.setRemoteDescription(offer)

                answer = await pc.createAnswer()
                await pc.setLocalDescription(answer)

                await websocket.send(json.dumps({
                    "type": pc.localDescription.type,
                    "sdp": pc.localDescription.sdp,
                }))
                print("[WEBSOCKET] SDP Answer enviada. Link WebRTC estabelecido!")

    except websockets.exceptions.ConnectionClosed:
        print("[WEBSOCKET] Conexão com o celular fechada.")
    finally:
        # Limpeza garantida da sessão, aconteça o que acontecer:
        # cancela os consumidores e fecha o peer connection. O servidor
        # continua vivo esperando a PRÓXIMA conexão — sem reiniciar nada.
        for t in list(track_tasks):
            t.cancel()
        await pc.close()
        print("[WEBSOCKET] Sessão limpa. Aguardando nova conexão do celular...")


async def servidor():
    hostname = socket.gethostname()
    try:
        local_ip = socket.gethostbyname(hostname)
    except socket.gaierror:
        local_ip = "0.0.0.0"

    print("=== PHONE CAN PROJECT - RECEPTOR P2P ===")
    print(f"[SERVER] Sinalização em: ws://{local_ip}:8765")
    print("[SERVER] Aguardando o Flutter iniciar o aperto de mão...")

    async with websockets.serve(handler, "0.0.0.0", 8765):
        await asyncio.Future()  # roda pra sempre


def rede_em_thread():
    """Roda o mundo asyncio inteiro numa thread separada da GUI."""
    asyncio.run(servidor())


# ==================== LADO DA EXIBIÇÃO (main thread) ====================

# Auto-fit da EXIBIÇÃO: o frame é escalado pra caber nessas dimensões
# antes de converter/desenhar (economiza ~85% do custo de exibição num
# stream 4K). O stream continua chegando em resolução CHEIA — isso é só
# a vitrine. Pra inspeção 1:1, sobe os valores ou bota um número gigante.
EXIBICAO_MAX_LARGURA = 1300
EXIBICAO_MAX_ALTURA = 700


def loop_exibicao():
    """Consome frames da fila no ritmo que der. Se atrasar, a fila
    descarta os velhos — a rede nunca sente. A janela só existe
    enquanto tem vídeo: nasce no primeiro frame, morre após ~2s
    sem receber nada."""
    janela = "Stream do Flutter (com Stats)"
    janela_aberta = False
    last_frame_time = None
    fps_filter = 0.0
    cron_conv = 0.0
    cron_draw = 0.0
    cron_n = 0
    SEM_FRAME_TIMEOUT = 2.0  # segundos sem frame até fechar a janela

    print("[DISPLAY] Loop de exibição pronto (janela abre quando chegar vídeo). Ctrl+C ou 'q' pra sair.")

    while True:
        try:
            frame = frame_queue.get(timeout=0.5)
        except queue.Empty:
            if janela_aberta:
                # Stream parou? Fecha a janela e volta a esperar invisível
                if last_frame_time and (time.time() - last_frame_time) > SEM_FRAME_TIMEOUT:
                    print("[DISPLAY] Stream parado. Fechando a janela.")
                    cv2.destroyWindow(janela)
                    janela_aberta = False
                    last_frame_time = None
                    fps_filter = 0.0
                elif cv2.waitKey(1) & 0xFF == ord('q'):
                    break
            continue

        # Trabalho pesado acontece AQUI, longe do event loop:
        t0 = time.perf_counter()
        stream_w, stream_h = frame.width, frame.height
        escala = min(1.0,
                     EXIBICAO_MAX_LARGURA / frame.width,
                     EXIBICAO_MAX_ALTURA / frame.height)
        if escala < 1.0:
            # reformat faz escala + conversão de cor numa passada só (swscale)
            frame = frame.reformat(
                width=int(frame.width * escala) // 2 * 2,
                height=int(frame.height * escala) // 2 * 2,
            )
        img = frame.to_ndarray(format="bgr24")
        t1 = time.perf_counter()
        height, width, _ = img.shape

        if not janela_aberta:
            print(f"[DISPLAY] >>> Vídeo chegando! Abrindo janela 1:1 em {width}x{height} <<<")
            # WINDOW_AUTOSIZE: tamanho exato da imagem, sem escala.
            cv2.namedWindow(janela, cv2.WINDOW_AUTOSIZE)
            janela_aberta = True

        current_time = time.time()
        if last_frame_time is not None:
            time_delta = current_time - last_frame_time
            if time_delta > 0:
                fps = 1.0 / time_delta
                fps_filter = (0.9 * fps_filter) + (0.1 * fps)
        last_frame_time = current_time

        texto = f"stream {stream_w}x{stream_h} | exibindo {width}x{height} @ {fps_filter:.1f} FPS"
        cv2.rectangle(img, (10, 10), (460, 45), (0, 0, 0), -1)
        cv2.putText(
            img, texto, (20, 32),
            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1, cv2.LINE_AA
        )

        cv2.imshow(janela, img)
        t2 = time.perf_counter()

        # Relatório de custo a cada ~90 frames: onde o tempo da exibição vai
        cron_conv += (t1 - t0)
        cron_draw += (t2 - t1)
        cron_n += 1
        if cron_n >= 90:
            print(f"[DISPLAY] custo/frame: conversão {cron_conv/cron_n*1000:.1f} ms + "
                  f"desenho {cron_draw/cron_n*1000:.1f} ms = "
                  f"teto de exibição ~{1/((cron_conv+cron_draw)/cron_n):.1f} fps")
            cron_conv = cron_draw = 0.0
            cron_n = 0

        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cv2.destroyAllWindows()


if __name__ == "__main__":
    # Thread de rede como daemon: quando a main thread (GUI) sair,
    # ela morre junto. Ctrl+C ou 'q' na janela derruba tudo limpo.
    threading.Thread(target=rede_em_thread, daemon=True).start()

    try:
        loop_exibicao()
    except KeyboardInterrupt:
        pass
    finally:
        cv2.destroyAllWindows()
        print("\n[SERVER] Desligado pelo usuário.")
