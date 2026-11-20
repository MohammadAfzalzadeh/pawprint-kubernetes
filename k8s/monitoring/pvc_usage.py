"""Read-only local-path PVC directory usage exporter for PawPrint Kind workers."""
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path('/local-path')
NODE = os.environ['NODE_NAME']


def directory_bytes(path):
    total = 0
    for root, directories, files in os.walk(path, followlinks=False):
        for name in directories + files:
            try:
                total += (Path(root) / name).lstat().st_blocks * 512
            except (FileNotFoundError, PermissionError):
                continue
    return total


def collect():
    lines = [
        '# HELP pawprint_pvc_directory_used_bytes Actual allocated bytes below a local-path PVC directory',
        '# TYPE pawprint_pvc_directory_used_bytes gauge',
        '# HELP pawprint_pvc_backing_filesystem_available_bytes Available bytes on the backing node filesystem; not a PVC quota',
        '# TYPE pawprint_pvc_backing_filesystem_available_bytes gauge',
        '# HELP pawprint_pvc_backing_filesystem_size_bytes Size of the backing node filesystem; not a PVC quota',
        '# TYPE pawprint_pvc_backing_filesystem_size_bytes gauge',
    ]
    for path in sorted(ROOT.glob('pvc-*_pawprint_*')):
        claim = path.name.split('_pawprint_', 1)[1]
        stat = os.statvfs(path)
        labels = f'namespace="pawprint",persistentvolumeclaim="{claim}",node="{NODE}"'
        lines.append(f'pawprint_pvc_directory_used_bytes{{{labels}}} {directory_bytes(path)}')
        lines.append(f'pawprint_pvc_backing_filesystem_available_bytes{{{labels}}} {stat.f_bavail * stat.f_frsize}')
        lines.append(f'pawprint_pvc_backing_filesystem_size_bytes{{{labels}}} {stat.f_blocks * stat.f_frsize}')
    return ('\n'.join(lines) + '\n').encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ('/', '/metrics'):
            self.send_response(404); self.end_headers(); return
        body = collect()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; version=0.0.4')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass


HTTPServer(('0.0.0.0', 9109), Handler).serve_forever()
