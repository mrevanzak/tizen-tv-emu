#!/usr/bin/env python3
"""TV screen and Samsung remote side by side: http://127.0.0.1:8765

The screen is QEMU's VNC output (websocket on :5700) drawn by noVNC. The remote is
Samsung's own controller skin from Tizen Studio (Smart 2016 where available); each button sends the
Linux keycode from its layout.xml to the guest through QEMU's monitor (`sendkey`).
shortcut: buttons whose keycode has no PS/2 equivalent (Extra, Play/Pause, long-press
Exit) are left inactive; port Samsung's virtio-maru-keyboard device if they are needed.
"""
import csv
import http.server
import json
import os
import socket
import xml.etree.ElementTree as ET

PORT = 8765
# Set by run.sh: QEMU's monitor socket, Samsung's remote skin in Tizen Studio, QEMU's keycode table.
MONITOR = os.environ["TIZEN_TV_EMU_MONITOR"]
SKIN = os.environ["TIZEN_TV_EMU_SKIN"]
KEYMAPS = os.environ["TIZEN_TV_EMU_KEYMAPS"]
LAYOUT_NS = {"u": "http://www.tizen.org/emulator/ui/layout"}


def load_skin():
    """Samsung's layout.xml: the remote's two images, and each button with its QEMU qcode."""
    with open(KEYMAPS) as f:
        qcode_by_linux = {int(row["Linux Keycode"], 0): row["QEMU QKeyCode"]
                          for row in csv.DictReader(f) if row["Linux Keycode"]}
    root = ET.parse(os.path.join(SKIN, "layout.xml")).getroot()
    normal = root.findtext(".//u:normalImage", namespaces=LAYOUT_NS)
    pressed = root.findtext(".//u:pressedImage", namespaces=LAYOUT_NS)
    buttons = []
    for key in root.iter("{%s}key" % LAYOUT_NS["u"]):
        region = {k: int(v) for k, v in key.find("u:region", LAYOUT_NS).attrib.items()}
        keycode = int(key.findtext("u:keycode", namespaces=LAYOUT_NS))
        buttons.append({
            "tip": key.findtext("u:tooltip", namespaces=LAYOUT_NS),
            "qcode": qcode_by_linux.get(keycode) or None,
            **region,
        })
    return normal, pressed, buttons


def png_size(path):
    with open(path, "rb") as f:
        header = f.read(24)  # width and height are big-endian ints at bytes 16-23 of a PNG
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


NORMAL_IMAGE, PRESSED_IMAGE, BUTTONS = load_skin()
WIDTH, HEIGHT = png_size(os.path.join(SKIN, NORMAL_IMAGE))
QCODES = {b["qcode"] for b in BUTTONS if b["qcode"]}
SKIN_FILES = {"/skin/normal.png": NORMAL_IMAGE, "/skin/pressed.png": PRESSED_IMAGE}

PAGE = """<!doctype html><meta charset=utf-8><title>Tizen TV</title>
<style>
html,body{margin:0;height:100%;background:#111;overflow:hidden}
body{display:flex;gap:16px;padding:16px;box-sizing:border-box}
#tv{flex:1;min-width:0;background:#000;border-radius:6px}
#remote{position:relative;width:WIDTHpx;height:HEIGHTpx;transform-origin:top left;
  background:url(/skin/normal.png)}
#holder{flex:none}
.k{position:absolute;cursor:pointer;border-radius:50%}
.k:active{background-image:url(/skin/pressed.png)}
.k.off{cursor:not-allowed}
</style>
<div id=tv></div>
<div id=holder><div id=remote></div></div>
<script type=module>
import RFB from 'https://cdn.jsdelivr.net/gh/novnc/noVNC@v1.5.0/core/rfb.js';
const buttons = BUTTONS_JSON;
const remote = document.getElementById('remote');
for (const b of buttons) {
  const el = document.createElement('div');
  el.className = b.qcode ? 'k' : 'k off';
  el.title = b.qcode ? b.tip : b.tip + ' (not supported)';
  Object.assign(el.style, {left: b.left + 'px', top: b.top + 'px', width: b.width + 'px',
    height: b.height + 'px', backgroundPosition: -b.left + 'px ' + -b.top + 'px'});
  if (b.qcode) {
    el.addEventListener('click', function sendKey() {
      fetch('/key/' + b.qcode, {method: 'POST'});
      rfb.focus();
    });
  }
  remote.append(el);
}
function fitRemoteToWindow() {
  const scale = (innerHeight - 32) / HEIGHT;
  remote.style.transform = 'scale(' + scale + ')';
  remote.parentElement.style.width = WIDTH * scale + 'px';
}
addEventListener('resize', fitRemoteToWindow);
fitRemoteToWindow();
const rfb = new RFB(document.getElementById('tv'), 'ws://127.0.0.1:5700');
rfb.scaleViewport = true;
rfb.addEventListener('disconnect', function reconnectSoon() { setTimeout(function () { location.reload(); }, 2000); });
</script>""".replace("BUTTONS_JSON", json.dumps(BUTTONS)).replace("WIDTH", str(WIDTH)).replace("HEIGHT", str(HEIGHT))


def send_key(qcode):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(2)
        s.connect(MONITOR)
        s.sendall(("sendkey %s\n" % qcode).encode())
        s.recv(4096)  # monitor banner/echo; keeps the command from being cut off on close


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in SKIN_FILES:
            with open(os.path.join(SKIN, SKIN_FILES[self.path]), "rb") as f:
                self._reply(200, f.read(), "image/png")
            return
        self._reply(200, PAGE.encode(), "text/html; charset=utf-8")

    def do_POST(self):
        qcode = self.path.rpartition("/")[2]
        if not self.path.startswith("/key/") or qcode not in QCODES:
            self._reply(404, b"unknown key", "text/plain")
            return
        try:
            send_key(qcode)
        except OSError as err:
            self._reply(503, ("emulator not running: %s" % err).encode(), "text/plain")
            return
        self._reply(204, b"", "text/plain")

    def _reply(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    assert {"esc", "f5", "ret", "up"} <= QCODES, "remote layout or keymap failed to load"
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
