#!/usr/bin/env python3
"""
MJPEG HTTP server that bridges the rm_aim_sim shared-memory camera to any
OpenCV (or browser) consumer.

Usage:
    # Terminal 1 — run the sim with remote control enabled
    ./run.sh -- --remote

    # Terminal 2 — start this server
    python3 tools/mjpeg_server.py [--port 8080] [--channel default] [--quality 85]

    # In your other repo / OpenCV code
    cap = cv2.VideoCapture("http://localhost:8080/video")

The server holds the IPC client lock, so no other tool (camera_demo.py, etc.)
can run at the same time — same rule as any other client.

Metadata (sim_time, gimbal yaw/pitch, session_id) is also available:
    GET http://localhost:8080/state  ->  latest state.json as JSON
    GET http://localhost:8080/frame  ->  latest frame.json metadata as JSON
"""

import argparse
import io
import json
import math
import socket
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Add tools/ to path so local_ipc can be imported when invoked from repo root
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from local_ipc import LocalClient


# ---------------------------------------------------------------------------
# Shared frame buffer — writer (IPC thread) and readers (HTTP threads)
# ---------------------------------------------------------------------------

class FrameBuffer:
    def __init__(self):
        self._lock = threading.Lock()
        self._jpeg = b""
        self._meta = {}
        self._state = {}
        self._event = threading.Event()

    def put(self, jpeg: bytes, frame_meta: dict, state: dict):
        with self._lock:
            self._jpeg = jpeg
            self._meta = frame_meta
            self._state = state
        self._event.set()
        self._event.clear()

    def wait_jpeg(self, timeout=2.0):
        self._event.wait(timeout)
        with self._lock:
            return self._jpeg

    def get_meta(self):
        with self._lock:
            return dict(self._meta)

    def get_state(self):
        with self._lock:
            return dict(self._state)


_buf = FrameBuffer()


# ---------------------------------------------------------------------------
# IPC reader thread
# ---------------------------------------------------------------------------

def ipc_reader(channel: str, quality: int, timeout: float):
    import numpy as np
    import cv2
    client = None
    encode_params = [cv2.IMWRITE_JPEG_QUALITY, quality]
    try:
        print(f"[mjpeg] Connecting to sim channel '{channel}'...", flush=True)
        client = LocalClient(channel, timeout=timeout)
        print("[mjpeg] Connected.", flush=True)
        while True:
            state = client.read_state(timeout=timeout)
            identity = client.request_frame()
            frame, pixels = client.receive_frame(identity, timeout=timeout)
            if frame["session_id"] != state["session_id"]:
                continue
            camera = frame["camera"]
            width = int(camera["width"])
            height = int(camera["height"])
            channels = {"rgb8": 3, "rgba8": 4}[frame["encoding"]]
            rgb = np.frombuffer(pixels, dtype=np.uint8).reshape(height, width, channels)
            bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR if channels == 3 else cv2.COLOR_RGBA2BGR)
            ok, buf = cv2.imencode(".jpg", bgr, encode_params)
            if ok:
                _buf.put(buf.tobytes(), frame, state)
    except KeyboardInterrupt:
        pass
    except Exception as e:
        print(f"[mjpeg] IPC error: {e}", file=sys.stderr, flush=True)
        sys.exit(1)
    finally:
        if client is not None:
            try:
                client.close()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

BOUNDARY = b"--frame"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request noise; errors still go to stderr

    def do_GET(self):
        if self.path in ("/video", "/video/"):
            self._stream()
        elif self.path in ("/state", "/state/"):
            self._json(_buf.get_state())
        elif self.path in ("/frame", "/frame/"):
            self._json(_buf.get_meta())
        elif self.path in ("/", "/index.html"):
            self._html()
        else:
            self.send_error(404)

    def _stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            while True:
                jpeg = _buf.wait_jpeg(timeout=2.0)
                if not jpeg:
                    continue
                header = (
                    b"\r\n" + BOUNDARY + b"\r\n"
                    b"Content-Type: image/jpeg\r\n"
                    b"Content-Length: " + str(len(jpeg)).encode() + b"\r\n\r\n"
                )
                self.wfile.write(header + jpeg)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, data: dict):
        body = json.dumps(data, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _html(self):
        host = self.headers.get("Host", "localhost:8080")
        body = f"""<!doctype html>
<html><head><title>rm_aim_sim MJPEG</title></head>
<body style="background:#0c1b2a;color:#d5e2e9;font-family:monospace;padding:1em">
<h2>rm_aim_sim MJPEG stream</h2>
<img src="/video" style="max-width:100%;border:1px solid #284353"><br><br>
<a href="/state">/state</a> &nbsp; <a href="/frame">/frame</a><br><br>
<code>cap = cv2.VideoCapture("http://{host}/video")</code>
</body></html>""".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8080, help="HTTP port (default 8080)")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default 127.0.0.1; use 0.0.0.0 for LAN)")
    parser.add_argument("--channel", default="default", help="IPC channel (default 'default')")
    parser.add_argument("--quality", type=int, default=85, help="JPEG quality 1-100 (default 85)")
    parser.add_argument("--timeout", type=float, default=8.0, help="IPC connect/frame timeout in seconds")
    args = parser.parse_args()

    if not (1 <= args.quality <= 100):
        parser.error("quality must be 1-100")
    if not (math.isfinite(args.timeout) and args.timeout > 0):
        parser.error("timeout must be positive")

    t = threading.Thread(target=ipc_reader, args=(args.channel, args.quality, args.timeout), daemon=True)
    t.start()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{'localhost' if args.host == '127.0.0.1' else args.host}:{args.port}"
    print(f"[mjpeg] Serving at {url}/video", flush=True)
    print(f"[mjpeg] OpenCV:  cap = cv2.VideoCapture(\"{url}/video\")", flush=True)
    print(f"[mjpeg] Metadata: {url}/state  |  {url}/frame", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[mjpeg] Shutting down.", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
