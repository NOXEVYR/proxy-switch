"""Real packaged core / controller / HTTP traffic, isolated ports and settings. No system writes."""
import argparse, contextlib, http.server, json, pathlib, socket, subprocess, tempfile, threading, time, urllib.request

class Fixture(http.server.BaseHTTPRequestHandler):
    marker = b""
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(self.marker))); self.end_headers(); self.wfile.write(self.marker)
    def do_CONNECT(self):
        self.send_response(200); self.end_headers(); self.wfile.flush()
        self.connection.settimeout(5)
        # The isolated destination is plaintext HTTP. mihomo's HTTP upstream dials it through CONNECT.
        for _ in range(100):
            line = self.rfile.readline(8192)
            if line in (b"\r\n", b"\n", b""): break
        self.wfile.write(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: " + str(len(self.marker)).encode() + b"\r\n\r\n" + self.marker)
    def log_message(self, *args): pass

@contextlib.contextmanager
def server(marker):
    handler = type("Reply", (Fixture,), {"marker":marker})
    s = http.server.ThreadingHTTPServer(("127.0.0.1",0),handler)
    thread = threading.Thread(target=s.serve_forever,daemon=True); thread.start()
    try: yield s
    finally: s.shutdown(); s.server_close(); thread.join()

def port():
    with socket.socket() as s: s.bind(("127.0.0.1",0)); return s.getsockname()[1]

def main():
    p = argparse.ArgumentParser(); p.add_argument("--app", required=True); args = p.parse_args()
    app = pathlib.Path(args.app); executable = app / "Contents/MacOS/FlowSwitch"; core = app / "Contents/Resources/mihomo"
    with tempfile.TemporaryDirectory(prefix="FlowSwitch-integration-") as tmp, server(b"A") as a, server(b"B") as b, server(b"DIRECT") as direct:
        root = pathlib.Path(tmp); entry, control = port(), port(); secret = "isolated-test"
        settings = {"routes":[{"id":"a","name":"A","host":"127.0.0.1","port":a.server_port,"kind":"http"},{"id":"b","name":"B","host":"127.0.0.1","port":b.server_port,"kind":"http"}],"rules":[{"kind":"DOMAIN","value":"special.test","route":"b"}],"selected":"a","allowDirect":False,"port":entry}
        source = root / "input.json"; config = root / "core.json"; source.write_text(json.dumps(settings))
        subprocess.run([str(executable),"--export-config",str(source),str(config),str(control),secret],check=True,timeout=10)
        subprocess.run([str(core),"-t","-d",str(root),"-f",str(config)],check=True,timeout=30)
        proc = subprocess.Popen([str(core),"-d",str(root),"-f",str(config)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        def api(path, method="GET", body=None, token=secret):
            request = urllib.request.Request(f"http://127.0.0.1:{control}"+path,data=json.dumps(body).encode() if body else None,headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"},method=method)
            with opener.open(request,timeout=5) as response:
                data = response.read(); return json.loads(data) if data else {}
        def request(url):
            return subprocess.check_output(["/usr/bin/curl","--silent","--show-error","--max-time","5","--noproxy","","--proxy",f"http://127.0.0.1:{entry}",url])
        try:
            for _ in range(60):
                try: api("/version"); break
                except Exception: time.sleep(.1)
            else: raise AssertionError("core did not start")
            try: api("/version",token="incorrect"); raise AssertionError("controller accepted wrong secret")
            except urllib.error.HTTPError as e: assert e.code == 401
            assert request("http://ordinary.test/") == b"A"
            assert request("http://special.test/") == b"B"
            api("/proxies/FS-Default","PUT",{"name":"FS-b"}); assert request("http://ordinary.test/") == b"B"
            api("/proxies/FS-Default","PUT",{"name":"DIRECT"}); assert request(f"http://127.0.0.1:{direct.server_port}/") == b"DIRECT"
            api("/proxies/FS-Default","PUT",{"name":"FS-b"}); assert request("http://ordinary.test/") == b"B"
            # Current preferred A goes away; failover's verified selector action must keep entry stable.
            a.shutdown(); a.server_close()
            api("/proxies/FS-a","PUT",{"name":"UP-b"}); api("/proxies/FS-Default","PUT",{"name":"FS-a"})
            assert request("http://ordinary.test/") == b"B"
            api("/proxies/FS-a","PUT",{"name":"REJECT"})
            rejected = subprocess.run(["/usr/bin/curl","--silent","--fail","--max-time","3","--noproxy","","--proxy",f"http://127.0.0.1:{entry}","http://ordinary.test/"],stdout=subprocess.DEVNULL)
            assert rejected.returncode != 0
            assert request("http://special.test/") == b"B", "domain rule was lost by default selection"
            print("PASS: real A -> B -> DIRECT -> B; domain exception; closed A -> B; fail-closed; controller authentication")
        finally:
            proc.terminate(); proc.wait(timeout=10)

if __name__ == "__main__": main()
