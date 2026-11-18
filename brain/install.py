#!/usr/bin/env python3
"""GoblinMind post-extract installer (Windows).

Run from the installed addon dir — Interface/AddOns/GoblinMind/brain/
— or via install.bat. Sets up the pieces that can't ship pre-made:

  * feeds.json        — `backend` block (crowdsourced feed): the
                        goblin_server URL, this install's name, and
                        your realm+faction scope(s)
  * Startup entries   — the brain watcher always; goblin_server only
                        with --host (one machine per community hosts)
  * Firewall rule     --host only; one UAC prompt if not elevated

Everything is idempotent — re-running updates in place. Paths derive
from __file__ the same way `watch self` does, so no path questions
when the layout is right.
"""
import argparse
import base64
import ctypes
import json
import os
import re
import socket
import subprocess
import time
import sys
import urllib.request
import webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
STARTUP = os.path.expandvars(
    r'%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup')
FEEDS = os.path.join(HERE, 'feeds.json')
WATCH_BAT = os.path.join(STARTUP, 'goblinmind-brain-watch.bat')
SERVER_BAT = os.path.join(STARTUP, 'goblinmind-server.bat')
PORT = 8765


def addon_root():
    """Interface/AddOns when this script sits at
    .../Interface/AddOns/GoblinMind/brain/, else None."""
    parts = os.path.normpath(HERE).split(os.sep)
    if len(parts) >= 3 and parts[-3].lower() == 'addons':
        return os.sep.join(parts[:-2])
    return None


def default_scope():
    """First scope in the shipped GoblinMind_Data — the realm the
    packager built on, usually the right default for early users."""
    data = os.path.join(HERE, '..', '..', 'GoblinMind_Data', 'Data.lua')
    try:
        with open(data, encoding='utf-8', errors='replace') as fh:
            head = fh.read(262144)
    except OSError:
        return None
    m = re.search(r'realms\s*=\s*\{\s*\["([^"]+)"', head)
    return m.group(1) if m else None


def ask(prompt, default=None):
    suffix = f' [{default}]' if default else ''
    try:
        ans = input(f'{prompt}{suffix}: ').strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return default
    return ans or default


def write_feeds(url, name, scopes, key=None, api=None):
    cfg = {}
    if os.path.isfile(FEEDS):
        try:
            cfg = json.load(open(FEEDS, encoding='utf-8'))
        except ValueError:
            pass
    cfg['backend'] = {'url': url.rstrip('/'), 'name': name,
                      'scopes': scopes, 'poll_minutes': 15,
                      'upload': True}
    if key:
        cfg['backend']['key'] = key
    if api:
        cfg['api'] = api
    with open(FEEDS, 'w', encoding='utf-8') as fh:
        json.dump(cfg, fh, indent=1)
        fh.write('\n')
    print(f'  wrote {FEEDS} (backend: {url}, scopes: {scopes})')


def probe_backend(url):
    """Connectivity check + the scopes already shared — catches a bad
    IP or closed firewall at install time, not at first pull."""
    try:
        h = json.load(urllib.request.urlopen(
            url.rstrip('/') + '/v1/health', timeout=8))
    except Exception as e:
        return None, str(e)
    try:
        s = json.load(urllib.request.urlopen(
            url.rstrip('/') + '/v1/scopes', timeout=8))
        h['remote_scopes'] = s.get('scopes') or []
    except Exception:
        h['remote_scopes'] = []
    return h, None


def pick_scopes(remote, default):
    if remote:
        print('  scopes already shared on this backend:')
        for i, s in enumerate(remote, 1):
            print(f'    {i}) {s}')
        ans = ask('Scope — number, name, or comma list', default)
    else:
        ans = ask('Realm-faction scope (shown by /goblin status '
                  'in game)', default)
    out = []
    for part in (ans or '').split(','):
        part = part.strip()
        if part.isdigit() and 1 <= int(part) <= len(remote):
            out.append(remote[int(part) - 1])
        elif part:
            out.append(part)
    return out


def lan_ip():
    """Primary LAN address — the URL friends install against."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))  # no traffic is sent
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def ensure_server_secret():
    """Create goblin_server.json with a fresh install_secret when the
    host lacks one — friends install with this key. Delete the file
    for open registration."""
    import secrets as _secrets
    cfgp = os.path.join(HERE, 'goblin_server.json')
    try:
        cfg = json.load(open(cfgp, encoding='utf-8'))
    except (OSError, ValueError):
        cfg = {}
    if not cfg.get('install_secret'):
        cfg['install_secret'] = _secrets.token_urlsafe(24)
        with open(cfgp, 'w', encoding='utf-8') as fh:
            json.dump(cfg, fh, indent=1)
    return cfg['install_secret']


def validate_api_key(cid, csec):
    """client_credentials round-trip — a typo'd key fails here at
    install time instead of silently dead-ending the api feed."""
    cred = base64.b64encode(f'{cid}:{csec}'.encode()).decode()
    req = urllib.request.Request(
        'https://oauth.battle.net/token?grant_type=client_credentials',
        data=b'', method='POST',
        headers={'Authorization': 'Basic ' + cred})
    try:
        json.load(urllib.request.urlopen(req, timeout=15))
        return True
    except Exception:
        return False


def api_block(scopes, region):
    """Prompt for the player's OWN Blizzard client credentials — a
    packager's key must never ship (abuse lands on their account).
    realms resolve lazily via the realm index ({scope: 0})."""
    print()
    print('Blizzard API feed — you need your OWN client credentials:')
    print('  1. Sign in on the page that just opened (Battle.net account)')
    print('  2. Create Client — any name, any redirect URI')
    print('  3. Paste the Client ID and Client Secret below')
    print('  (no browser? https://develop.battle.net/access/clients)')
    try:
        webbrowser.open('https://develop.battle.net/access/clients')
    except Exception:
        pass
    cid = ask("Client ID ('skip' to disable the Blizzard feed)")
    if not cid or cid.lower() == 'skip':
        return None
    csec = ask('Client Secret')
    if not csec:
        return None
    if not validate_api_key(cid, csec):
        print('  warning: token round-trip failed for those credentials')
        if ask('Save them anyway? (y/N)') not in ('y', 'yes'):
            return None
    return {'namespace': 'dynamic-' + region, 'region': region,
            'client_id': cid, 'client_secret': csec,
            'realms': {s: 0 for s in scopes}, 'poll_minutes': 30}


def write_bat(path, title, cmd):
    body = (f'@echo off\r\ncd /d "{HERE}"\r\n'
            f'start "{title}" /min cmd /k {cmd}\r\n')
    with open(path, 'w') as fh:
        fh.write(body)
    print(f'  wrote {path}')


def start_server():
    """Launch goblin_server.py now — the Startup bat only fires at
    login, and the installer's own probe + first upload need it up."""
    if sys.platform == 'win32':
        subprocess.Popen(
            f'start "GoblinMind Server" /min cmd /k '
            f'python goblin_server.py {PORT}', shell=True, cwd=HERE)
    else:
        subprocess.Popen([sys.executable, 'goblin_server.py',
                          str(PORT)], cwd=HERE)
    print(f'  server started on :{PORT}')


def firewall_rule():
    """Inbound TCP rule for the backend. Admin shell adds it directly;
    otherwise one UAC prompt runs delete+add via an elevated helper."""
    rule = f'GoblinMind Backend {PORT}'
    cmds = (f'netsh advfirewall firewall delete rule name="{rule}"; '
            f'netsh advfirewall firewall add rule name="{rule}" '
            f'dir=in action=allow protocol=TCP localport={PORT}')
    windll = getattr(ctypes, 'windll', None)
    if windll and windll.shell32.IsUserAnAdmin():
        # netsh has no upsert — delete first so re-runs stay idempotent
        subprocess.run(['netsh', 'advfirewall', 'firewall', 'delete',
                        'rule', f'name={rule}'], capture_output=True)
        r = subprocess.run(
            ['netsh', 'advfirewall', 'firewall', 'add', 'rule',
             f'name={rule}', 'dir=in', 'action=allow',
             'protocol=TCP', f'localport={PORT}'],
            capture_output=True, text=True)
        print('  firewall rule added' if r.returncode == 0
              else f'  netsh failed: '
                   f'{r.stdout.strip() or r.stderr.strip()}')
        return
    if windll:
        r = windll.shell32.ShellExecuteW(
            None, 'runas', 'powershell.exe',
            '-NoProfile -WindowStyle Hidden -Command "' + cmds + '"',
            None, 0)
        if r and r > 32:
            print('  firewall rule — approve the UAC prompt to open '
                  f'TCP {PORT}')
            for _ in range(20):
                time.sleep(0.5)
                q = subprocess.run(
                    ['netsh', 'advfirewall', 'firewall', 'show',
                     'rule', f'name={rule}'],
                    capture_output=True, text=True)
                if rule in (q.stdout or ''):
                    print('  firewall rule added')
                    return
            print(f'  still pending — verify: netsh advfirewall '
                  f'firewall show rule name="{rule}"')
            return
        print('  UAC declined — firewall stays closed')
    print('  run once as admin to open the port:')
    print(f'    netsh advfirewall firewall add rule name="{rule}" '
          f'dir=in action=allow protocol=TCP localport={PORT}')


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--backend-url',
                    help='goblin_server URL, e.g. http://192.168.1.10:8765')
    ap.add_argument('--name', help='this install\'s name in the backend')
    ap.add_argument('--scope', action='append',
                    help='realm-faction scope(s), e.g. MyRealm-Alliance')
    ap.add_argument('--key',
                    help='shared install secret if the backend gates '
                         'registration (blank = open backend)')
    ap.add_argument('--api-id', help='Blizzard API client ID')
    ap.add_argument('--api-secret', help='Blizzard API client secret')
    ap.add_argument('--region', default='us',
                    help='API region: us/eu/kr/tw (default us)')
    ap.add_argument('--skip-api', action='store_true',
                    help='disable the Blizzard API feed entirely')
    ap.add_argument('--host', action='store_true',
                    help='also run the backend server here + firewall rule')
    ap.add_argument('--dev', action='store_true',
                    help='proceed even outside Interface/AddOns')
    ap.add_argument('--remove', action='store_true',
                    help='remove the Startup entries and exit')
    ap.add_argument('--register', action='store_true',
                    help='write only the watcher Startup entry and '
                         'exit — called by goblin-watch.bat on first '
                         'run so one double-click is ever needed')
    a = ap.parse_args()

    if a.register:
        if addon_root():
            write_bat(WATCH_BAT, 'GoblinMind Brain',
                      'python goblin_brain.py watch self -v --feed book')
        else:
            print('skipped — not inside Interface/AddOns')
        return

    if not addon_root() and not a.remove and not a.dev:
        print(f'warning: {HERE} is not inside Interface/AddOns — the '
              'watcher needs the addon layout (watch self derives '
              'paths from this location)')
        if ask('Continue anyway? (y/N)') not in ('y', 'yes'):
            sys.exit('aborted — run this from the installed addon\'s '
                     'brain dir, or pass --dev')
    if a.remove:
        for p in (WATCH_BAT, SERVER_BAT):
            try:
                os.remove(p)
                print(f'removed {p}')
            except OSError:
                pass
        return

    if not a.host:
        # end-user path: no prompts. Every configurable piece —
        # backend URL/key, Blizzard API credentials, scopes — stages
        # through the in-game onboarding wizard and the watcher folds
        # it into feeds.json itself. This step only registers the
        # watcher so the player's one manual act is "start the
        # program once" (or nothing at all, after next login).
        if addon_root():
            write_bat(WATCH_BAT, 'GoblinMind Brain',
                      'python goblin_brain.py watch self -v --feed book')
            print('watcher registered — starts at next login (or '
                  'double-click goblin-watch.bat to run it now)')
            print('all configuration happens in game — the onboarding '
                  'wizard or /goblin backend')
            print('to HOST a backend for others, rerun: install.bat '
                  '--host')
        else:
            print('skipped Startup entries — not inside Interface/AddOns')
        return

    # --host only past this point: this machine IS the backend — own
    # feed goes via loopback; the server must be up before the health
    # probe below
    url = a.backend_url or 'http://127.0.0.1:8765'
    start_server()
    firewall_rule()
    if not url:
        sys.exit('backend URL is required')
    if '://' not in url:
        url = 'http://' + url
    name = a.name or ask('Install name', socket.gethostname())
    h, err = probe_backend(url)
    if h is None:
        print(f'  warning: cannot reach {url} — {err}')
        print('  (check the IP and that the host\'s firewall '
              'allows TCP 8765)')
        if ask('Continue anyway? (y/N)') not in ('y', 'yes'):
            sys.exit('aborted')
        remote = []
    else:
        remote = h.get('remote_scopes') or []
        print(f'  backend alive — {len(h.get("installs") or [])} '
              f'install(s), {len(remote)} scope(s) shared')
    scopes = a.scope or pick_scopes(remote, default_scope())
    scopes = [s for s in scopes if s]
    if not scopes:
        sys.exit('at least one scope is required')
    key = a.key or ask('Shared install key (leave blank if the '
                       'backend has none)')
    api = None
    if a.api_id and a.api_secret:
        api = {'namespace': 'dynamic-' + a.region, 'region': a.region,
               'client_id': a.api_id, 'client_secret': a.api_secret,
               'realms': {s: 0 for s in scopes}, 'poll_minutes': 30}
        if not validate_api_key(a.api_id, a.api_secret):
            print('  warning: API credentials failed a token round-trip')
    elif not a.skip_api:
        api = api_block(scopes, a.region)
        if api is None:
            print('  Blizzard feed disabled — the backend feed still '
                  'works; rerun the installer to add a key later')

    print('GoblinMind install:')
    write_feeds(url, name, scopes, key, api)
    if addon_root():
        write_bat(WATCH_BAT, 'GoblinMind Brain',
                  'python goblin_brain.py watch self -v --feed book')
        if a.host:
            write_bat(SERVER_BAT, 'GoblinMind Server',
                      f'python goblin_server.py {PORT}')
            firewall_rule()
            secret = ensure_server_secret()
            ip = lan_ip()
            invite_url = f'http://{ip or "<this-PC-LAN-IP>"}:{PORT}'
            print('  share with friends — they enter these in the')
            print('  GoblinMind setup window in game (or /goblin backend):')
            print(f'    backend URL : {invite_url}')
            print(f'    install key : {secret}')
            # durable copy — console output scrolls away, this file
            # sits beside the bat and can be re-opened or shared
            # verbatim any time a friend joins later
            try:
                with open(os.path.join(HERE, 'backend-invite.txt'),
                          'w', encoding='utf-8') as fh:
                    fh.write('GoblinMind backend invite\n'
                             '===========================\n'
                             'Give friends these two values — they\n'
                             'type them into the GoblinMind setup\n'
                             'window in game (or /goblin backend):\n\n'
                             f'  server address : {invite_url}\n'
                             f'  key            : {secret}\n\n'
                             'Their install never needs the command\n'
                             'line — the in-game wizard writes the\n'
                             'config for them.\n')
                print('  (also saved to backend-invite.txt here)')
            except OSError:
                pass
            print('  (delete goblin_server.json beside the server for '
                  'open registration)')
    else:
        # 'watch self' can't resolve paths outside Interface/AddOns —
        # a Startup bat pointing here would silently die at login
        print('  skipped Startup entries — not inside Interface/AddOns')
    print('done — the watcher starts at next login (or run '
          'goblin-watch.bat now). /reload in game to pick it up.')


if __name__ == '__main__':
    main()
