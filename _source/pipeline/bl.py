"""Client for Blender 5.2's official MCP extension socket (127.0.0.1:9876).

Protocol, read off mcp_to_blender_server.py:
  request : {"type": "execute", "code": "<python>", "strict_json": false} + b"\\x00"
  reply   : {"status": "ok", "result": {...}, "stdout"?, "stderr"?} + b"\\x00"
            {"status": "error", "message": "<traceback>"}

The executed code runs with a pre-seeded namespace containing `result = {}`.
Whatever dict you assign to `result` comes back. It must be a dict.
strict_json=false makes non-serializable values fall back to repr() instead of
erroring, which is what we want while probing.

Usage:
    python bl.py <script.py>          run a file
    python bl.py -c "<code>"         run a snippet
"""
import json, socket, sys

HOST, PORT, TIMEOUT = "127.0.0.1", 9876, 600.0


def execute(code, strict_json=False):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    s.connect((HOST, PORT))
    try:
        req = {"type": "execute", "code": code, "strict_json": strict_json}
        s.sendall(json.dumps(req).encode("utf-8") + b"\x00")

        buf = b""
        while b"\x00" not in buf:
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        frame = buf.split(b"\x00", 1)[0]
        if not frame:
            raise RuntimeError("no reply frame; raw=%r" % buf[:400])
        return json.loads(frame.decode("utf-8"))
    finally:
        s.close()


def report(reply, limit=14000):
    if reply.get("stdout"):
        print("--- stdout ---")
        print(reply["stdout"][:limit])
    if reply.get("stderr"):
        print("--- stderr ---")
        print(reply["stderr"][:limit])
    if reply.get("status") == "ok":
        print("--- result ---")
        print(json.dumps(reply.get("result"), indent=2)[:limit])
    else:
        print("--- ERROR ---")
        print(str(reply.get("message"))[:limit])
    return reply.get("status") == "ok"


if __name__ == "__main__":
    if sys.argv[1] == "-c":
        code = sys.argv[2]
    else:
        code = open(sys.argv[1], encoding="utf-8").read()
    sys.exit(0 if report(execute(code)) else 1)
