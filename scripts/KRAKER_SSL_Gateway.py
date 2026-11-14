#!/usr/bin/python3
# -*- coding: utf-8 -*-
# KRAKER VPS - SSL GATEWAY (DUAL MODE: WS + DIRECT)  [VERSIÓN CORREGIDA]
#
# Bugs corregidos respecto al original:
#  1) context.wrap_socket() se ejecutaba EN EL BUCLE accept(): un solo cliente con
#     handshake lento BLOQUEABA a todos los demás (el puerto 443 parecía caído).
#     Ahora el handshake TLS ocurre dentro del hilo del cliente.
#  2) En cada excepción había un time.sleep(1) GLOBAL: un cliente malo congelaba
#     el servidor entero 1 segundo. Eliminado.
#  3) El proceso moría sin log claro. Ahora registra en stdout/stderr con flush
#     (systemd lo captura en el journal).
#  4) Si el destino (Dropbear) está caído, se responde y se cierra limpio, y se
#     cuenta en el log. Antes el cliente veía "conectado" y luego caía sin pista.
#  5) Límite de conexiones simultáneas para no agotar el VPS.
#  6) Compatibilidad TLS configurable (algunos inyectores viejos usan TLS 1.0/1.1).

import socket, ssl, threading, sys, os, signal, time, warnings

# Silenciar el aviso de TLSv1 obsoleto: es intencional por compatibilidad
# con inyectores antiguos (se desactiva con KRAKER_ALLOW_OLD_TLS=0)
warnings.filterwarnings("ignore", category=DeprecationWarning)

BUFFER_SIZE = 65536
WS_RESPONSE = (b"HTTP/1.1 101 Switching Protocols\r\n"
               b"Upgrade: websocket\r\n"
               b"Connection: Upgrade\r\n\r\n")
MAX_CONNS = int(os.environ.get("KRAKER_MAX_CONNS", "800"))
ALLOW_OLD_TLS = os.environ.get("KRAKER_ALLOW_OLD_TLS", "1") == "1"

LOG_LEVEL = int(os.environ.get("KRAKER_LOG_LEVEL", "2"))  # 0=nada 1=errores 2=info
_conns = 0
_lock = threading.Lock()

def log(lvl, msg):
    if lvl <= LOG_LEVEL:
        print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def build_context(cert, key):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=cert, keyfile=key)
    if ALLOW_OLD_TLS:
        try:
            ctx.minimum_version = ssl.TLSVersion.TLSv1
        except Exception:
            pass
        try:
            ctx.set_ciphers("DEFAULT:@SECLEVEL=1")
        except Exception:
            pass
    ctx.options |= ssl.OP_NO_COMPRESSION
    return ctx

def transfer(src, dst):
    try:
        while True:
            data = src.recv(BUFFER_SIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            try: s.close()
            except Exception: pass

def handler(raw_sock, ctx, target_addr, target_port, peer):
    global _conns
    client = None
    try:
        # 1) Handshake TLS AQUÍ (no en el accept): un cliente lento no bloquea al resto
        raw_sock.settimeout(8.0)
        try:
            client = ctx.wrap_socket(raw_sock, server_side=True)
        except Exception as e:
            log(1, f"TLS handshake falló con {peer}: {e}")
            try: raw_sock.close()
            except Exception: pass
            return

        # 2) Ventana corta para ver si el cliente habla primero.
        #    - Payload WebSocket: manda "GET / HTTP/1.1..." -> respondemos 101
        #    - SSL puro: manda "SSH-2.0-..."            -> passthrough
        #    - SSL puro mudo: no manda nada             -> passthrough tras 0.2s
        client.settimeout(0.2)
        data = b""
        try:
            data = client.recv(BUFFER_SIZE)
        except socket.timeout:
            data = b""
        except Exception:
            data = b""

        is_ws = False
        resto = b""
        if data[:4] in (b"GET ", b"POST", b"CONN", b"HEAD", b"PUT ", b"OPTI", b"PATC"):
            # Buscamos el final de las cabeceras HTTP
            idx = data.find(b"\r\n\r\n")
            if idx == -1:
                # Cabeceras partidas en varios paquetes: esperamos un poco más
                client.settimeout(1.0)
                try:
                    while idx == -1 and len(data) < 16384:
                        extra = client.recv(BUFFER_SIZE)
                        if not extra:
                            break
                        data += extra
                        idx = data.find(b"\r\n\r\n")
                except Exception:
                    pass
            is_ws = True
            # FIX: lo que venga DESPUÉS de las cabeceras son datos SSH reales.
            # El original los tiraba -> la sesión se quedaba colgada.
            if idx != -1:
                resto = data[idx + 4:]
            try:
                client.sendall(WS_RESPONSE)
            except Exception:
                return
            log(2, f"WS payload desde {peer} ({len(data)}B cabeceras, {len(resto)}B de datos)")
        client.settimeout(None)

        # 3) Conectar al destino real (Dropbear / SSH)
        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.settimeout(5.0)
        try:
            remote.connect((target_addr, int(target_port)))
            remote.settimeout(None)
            remote.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except Exception as e:
            log(1, f"DESTINO {target_addr}:{target_port} no responde ({e}). "
                   f"¿Está Dropbear/SSH arriba en ese puerto?")
            client.close()
            return
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        # 4) Reenviar lo pendiente al destino
        pendiente = resto if is_ws else data
        if pendiente:
            remote.sendall(pendiente)

        threading.Thread(target=transfer, args=(client, remote), daemon=True).start()
        transfer(remote, client)
    except Exception as e:
        log(1, f"Error con {peer}: {e}")
    finally:
        try: client and client.close()
        except Exception: pass
        with _lock:
            _conns -= 1

def serve(port, ctx, target_addr, target_port, workers):
    """Un proceso trabajador: escucha en su propio socket con SO_REUSEPORT."""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # SO_REUSEPORT: varios procesos comparten el 443. El kernel reparte las
    # conexiones entre ellos -> rompe el cuello de botella del GIL de Python.
    if workers > 1:
        try:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except Exception:
            pass
    try:
        server.bind(("0.0.0.0", int(port)))
        server.listen(2048)
        server.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception as e:
        log(0, f"ERROR: no puedo escuchar en 0.0.0.0:{port} -> {e}")
        os._exit(1)

    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    log(0, f"[pid {os.getpid()}] escuchando 0.0.0.0:{port} -> {target_addr}:{target_port}")

    global _conns
    while True:
        try:
            raw, addr = server.accept()
        except Exception:
            continue
        with _lock:
            if _conns >= MAX_CONNS:
                try: raw.close()
                except Exception: pass
                continue
            _conns += 1
        threading.Thread(target=handler,
                         args=(raw, ctx, target_addr, target_port, addr),
                         daemon=True).start()


def main(port, cert, key, target_addr, target_port):
    # Reducir el intervalo del switch de hilos = menos jitter con muchas conexiones
    try:
        sys.setswitchinterval(0.001)
    except Exception:
        pass

    ctx = build_context(cert, key)

    workers = int(os.environ.get("KRAKER_WORKERS", "0"))
    if workers <= 0:
        workers = min(4, os.cpu_count() or 1)

    if workers == 1:
        serve(port, ctx, target_addr, target_port, 1)
        return

    log(0, f"Modo multiproceso: {workers} workers con SO_REUSEPORT")
    children = []
    for _ in range(workers):
        pid = os.fork()
        if pid == 0:
            # --- hijo ---
            serve(port, ctx, target_addr, target_port, workers)
            os._exit(0)
        children.append(pid)

    def _bajar(*_):
        for p in children:
            try: os.kill(p, signal.SIGTERM)
            except Exception: pass
        os._exit(0)

    signal.signal(signal.SIGTERM, _bajar)
    signal.signal(signal.SIGINT, _bajar)

    # Padre: vigila y revive workers caídos
    while True:
        try:
            pid, _st = os.wait()
        except ChildProcessError:
            break
        except Exception:
            time.sleep(1); continue
        if pid in children:
            children.remove(pid)
            log(1, f"Worker {pid} murió; relanzando...")
            npid = os.fork()
            if npid == 0:
                serve(port, ctx, target_addr, target_port, workers)
                os._exit(0)
            children.append(npid)

if __name__ == "__main__":
    if len(sys.argv) < 6:
        print("Uso: KRAKER_SSL_Gateway.py <puerto> <cert> <key> <destino> <puerto_destino>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
