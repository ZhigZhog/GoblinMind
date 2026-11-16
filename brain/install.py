#!/usr/bin/env python3
"""GoblinMind post-extract installer (Windows).

Run from the installed addon dir — Interface/AddOns/GoblinMind/brain/
— or via install.bat. Sets up the pieces that can't ship pre-made:

  * feeds.json        — `backend` block (crowdsourced feed): the
                        goblin_server URL, this install's name, and
                        your realm+faction scope(s)
  * Startup entries   — the brain watcher always; goblin_server only
                        with --host (one machine per community hosts)
  * Firewall rule     --host only, and only when run elevated

Everything is idempotent — re-running updates in place. Paths derive
from __file__ the same way `watch self` does, so no path questions
when the layout is right.
"""
import argparse
import ctypes
import json
import os
import re
import socket
import subprocess
import sys

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


def write_feeds(url, name, scopes):
    cfg = {}
    if os.path.isfile(FEEDS):
        try:
            cfg = json.load(open(FEEDS, encoding='utf-8'))
        except ValueError:
            pass
    cfg['backend'] = {'url': url.rstrip('/'), 'name': name,
                      'scopes': scopes, 'poll_minutes': 15,
                      'upload': True}
    with open(FEEDS, 'w', encoding='utf-8') as fh:
        json.dump(cfg, fh, indent=1)
        fh.write('\n')
    print(f'  wrote {FEEDS} (backend: {url}, scopes: {scopes})')


def write_bat(path, title, cmd):
    body = (f'@echo off\r\ncd /d "{HERE}"\r\n'
            f'start "{title}" /min cmd /k {cmd}\r\n')
    with open(path, 'w') as fh:
        fh.write(body)
    print(f'  wrote {path}')


def firewall_rule():
    windll = getattr(ctypes, 'windll', None)
    if windll is None or not windll.shell32.IsUserAnAdmin():
        print('  firewall rule needs an admin shell — run once as admin:')
        print(f'    netsh advfirewall firewall add rule '
              f'name="GoblinMind Backend {PORT}" dir=in action=allow '
              f'protocol=TCP localport={PORT}')
        return
    # netsh has no upsert — delete first so re-runs stay idempotent
    subprocess.run(['netsh', 'advfirewall', 'firewall', 'delete',
                    'rule', f'name=GoblinMind Backend {PORT}'],
                   capture_output=True)
    r = subprocess.run(
        ['netsh', 'advfirewall', 'firewall', 'add', 'rule',
         f'name=GoblinMind Backend {PORT}', 'dir=in', 'action=allow',
         'protocol=TCP', f'localport={PORT}'],
        capture_output=True, text=True)
    print('  firewall rule added' if r.returncode == 0
          else f'  netsh failed: {r.stdout.strip() or r.stderr.strip()}')


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--backend-url',
                    help='goblin_server URL, e.g. http://192.168.1.10:8765')
    ap.add_argument('--name', help='this install\'s name in the backend')
    ap.add_argument('--scope', action='append',
                    help='realm-faction scope(s), e.g. MyRealm-Alliance')
    ap.add_argument('--host', action='store_true',
                    help='also run the backend server here + firewall rule')
    ap.add_argument('--dev', action='store_true',
                    help='proceed even outside Interface/AddOns')
    ap.add_argument('--remove', action='store_true',
                    help='remove the Startup entries and exit')
    a = ap.parse_args()

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

    url = (a.backend_url or
           ask('Backend server URL (host\'s LAN IP, e.g. '
               'http://192.168.1.10:8765)', 'http://127.0.0.1:8765'))
    if not url:
        sys.exit('backend URL is required')
    if '://' not in url:
        url = 'http://' + url
    name = a.name or ask('Install name', socket.gethostname())
    scopes = a.scope or [
        ask('Realm-faction scope (shown by /goblin status in game)',
            default_scope())]
    scopes = [s for s in scopes if s]
    if not scopes:
        sys.exit('at least one scope is required')

    print('GoblinMind install:')
    write_feeds(url, name, scopes)
    if addon_root():
        write_bat(WATCH_BAT, 'GoblinMind Brain',
                  'python goblin_brain.py watch self -v --feed book')
        if a.host:
            write_bat(SERVER_BAT, 'GoblinMind Server',
                      f'python goblin_server.py {PORT}')
            firewall_rule()
    else:
        # 'watch self' can't resolve paths outside Interface/AddOns —
        # a Startup bat pointing here would silently die at login
        print('  skipped Startup entries — not inside Interface/AddOns')
    print('done — the watcher starts at next login (or run '
          'goblin-watch.bat now). /reload in game to pick it up.')


if __name__ == '__main__':
    main()
