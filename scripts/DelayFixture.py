from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import time, sys
class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/stream.mp4'):
            data = open('sample.mp4','rb').read()
            self.send_response(200); self.send_header('Content-Type','video/mp4')
            self.send_header('Content-Length',str(len(data))); self.end_headers()
            try:
                for offset in range(0,len(data),10000):
                    self.wfile.write(data[offset:offset+10000]); self.wfile.flush(); time.sleep(.5)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if self.path.startswith('/delay.mp4'):

            time.sleep(15)
            self.path='/sample.mp4'
        try: super().do_GET()
        except (BrokenPipeError, ConnectionResetError): pass
    def log_message(self, *args): pass
if __name__=='__main__':
    import os
    os.chdir(sys.argv[1])
    ThreadingHTTPServer(('127.0.0.1',18766),Handler).serve_forever()
