"""Small PawPrint-specific metrics exporter; Python standard library only."""
import hashlib
import json
import os
import re
import ssl
import time
import urllib.request
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

TOKEN = Path('/var/run/secrets/kubernetes.io/serviceaccount/token').read_text()
CA = '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
API = 'https://kubernetes.default.svc'
NAMESPACE = os.getenv('NAMESPACE', 'pawprint')
BACKUPS = Path('/backup')


def api(path):
    request = urllib.request.Request(API + path, headers={'Authorization': 'Bearer ' + TOKEN})
    with urllib.request.urlopen(request, context=ssl.create_default_context(cafile=CA), timeout=5) as response:
        return json.load(response)


def report():
    with urllib.request.urlopen('http://reporting:8080/api/reports/status', timeout=5) as response:
        return json.load(response)


def timestamp(value):
    if not value:
        return 0
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def latest_backup():
    candidates = sorted(BACKUPS.glob('petclinic-*.backup'), key=lambda path: path.stat().st_mtime, reverse=True)
    if not candidates:
        return 0, '', 0, 0, 0, 0
    directory = candidates[0]
    match = re.match(r'petclinic-(\d{8}T\d{6}Z)-', directory.name)
    created = datetime.strptime(match.group(1), '%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc).timestamp() if match else directory.stat().st_mtime
    checksums = directory / 'SHA256SUMS'
    valid = int(checksums.is_file())
    files = 0
    if valid:
        for line in checksums.read_text().splitlines():
            digest, name = line.split(maxsplit=1)
            target = directory / name.lstrip('*')
            files += 1
            if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                valid = 0
                break
    stat = os.statvfs(BACKUPS)
    used = (stat.f_blocks - stat.f_bfree) * stat.f_frsize
    available = stat.f_bavail * stat.f_frsize
    return created, directory.name, valid, files, used, available


def job_metrics():
    jobs = api(f'/apis/batch/v1/namespaces/{NAMESPACE}/jobs')['items']
    backup_failed = sum(1 for item in jobs if item['metadata']['name'].startswith('petclinic-backup') and item.get('status', {}).get('failed', 0))
    backup_active = sum(item.get('status', {}).get('active') or 0 for item in jobs if item['metadata']['name'].startswith('petclinic-backup'))
    restore = [item for item in jobs if item['metadata']['name'].startswith('petclinic-restore-test')]
    restore.sort(key=lambda item: item['metadata'].get('creationTimestamp', ''), reverse=True)
    latest = restore[0] if restore else None
    restore_success = int(bool(latest) and latest.get('status', {}).get('succeeded', 0) == 1)
    restore_name = latest['metadata']['name'] if latest else ''
    restore_completed = timestamp(latest.get('status', {}).get('completionTime')) if latest else 0
    completed_backups = [item for item in jobs if item['metadata']['name'].startswith('petclinic-backup') and item.get('status', {}).get('succeeded', 0) == 1]
    completed_backups.sort(key=lambda item: item.get('status', {}).get('completionTime', ''), reverse=True)
    backup_job_completed = timestamp(completed_backups[0].get('status', {}).get('completionTime')) if completed_backups else 0
    return backup_failed, backup_active, restore_success, restore_name, restore_completed, backup_job_completed


def collect():
    lines = []
    def gauge(name, help_text, value):
        lines.extend((f'# HELP {name} {help_text}', f'# TYPE {name} gauge', f'{name} {value}'))
    def info(name, help_text, labels):
        escaped = {key: str(value).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') for key, value in labels.items()}
        label_text = ','.join(f'{key}="{value}"' for key, value in escaped.items())
        lines.extend((f'# HELP {name} {help_text}', f'# TYPE {name} gauge', f'{name}{{{label_text}}} 1'))
    try:
        status = report()
        gauge('pawprint_reporting_stale', 'One when Reporting marks its data stale', int(status['stale']))
        gauge('pawprint_reporting_degraded', 'One when Reporting marks itself degraded', int(status['degraded']))
        gauge('pawprint_reporting_replay_pending_bytes', 'Replica WAL bytes received but not replayed', status.get('replayPendingBytes') or 0)
        gauge('pawprint_reporting_generated_timestamp_seconds', 'Last successful Reporting refresh', timestamp(status.get('generatedAt')))
        gauge('pawprint_reporting_data_freshness_timestamp_seconds', 'Last replayed transaction timestamp; may remain unchanged while idle', timestamp(status.get('dataFreshnessAt')))
        gauge('pawprint_reporting_last_wal_message_timestamp_seconds', 'Last WAL receiver message timestamp', timestamp(status.get('lastWalMessageAt')))
        gauge('pawprint_reporting_collector_up', 'Reporting JSON collection succeeded', 1)
    except Exception:
        traceback.print_exc()
        gauge('pawprint_reporting_collector_up', 'Reporting JSON collection succeeded', 0)
    try:
        created, backup_id, integrity, files, used, available = latest_backup()
        failed, active, restore_success, restore_name, restore_completed, backup_job_completed = job_metrics()
        gauge('pawprint_backup_latest_timestamp_seconds', 'Timestamp parsed from latest backup archive name', created)
        info('pawprint_backup_latest_info', 'Identity of latest backup archive', {'backup_id': backup_id})
        gauge('pawprint_backup_job_last_success_timestamp_seconds', 'Completion time of latest successful backup Job', backup_job_completed)
        gauge('pawprint_backup_archive_integrity', 'One when all SHA256SUMS entries in latest archive verify', integrity)
        gauge('pawprint_backup_verified_files', 'Files verified in latest backup archive', files)
        gauge('pawprint_backup_storage_used_bytes', 'Bytes used on the mounted backup filesystem', used)
        gauge('pawprint_backup_storage_available_bytes', 'Bytes available on the mounted backup filesystem', available)
        gauge('pawprint_backup_failed_jobs', 'Retained failed PawPrint backup Jobs', failed)
        gauge('pawprint_backup_active_jobs', 'Currently active PawPrint backup Jobs', active)
        gauge('pawprint_restore_verification_success', 'One when latest retained restore-test Job succeeded', restore_success)
        gauge('pawprint_restore_verification_timestamp_seconds', 'Completion time of latest retained restore-test Job', restore_completed)
        info('pawprint_restore_verification_info', 'Identity and result of latest retained restore-test Job', {'job_name': restore_name, 'result': 'succeeded' if restore_success else 'failed-or-missing'})
        gauge('pawprint_backup_collector_up', 'Backup filesystem and Kubernetes API collection succeeded', 1)
    except Exception:
        traceback.print_exc()
        gauge('pawprint_backup_collector_up', 'Backup filesystem and Kubernetes API collection succeeded', 0)
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


HTTPServer(('0.0.0.0', 9108), Handler).serve_forever()
