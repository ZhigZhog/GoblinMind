#!/usr/bin/env python
"""test_mesh_scale.py — mesh scale model.

Phase A measures REAL constants inside the harness (wire bytes,
in-client Lua dispatch cost, peers-table memory) using unmodified
Mesh.lua/Orders.lua. Phase B plugs those into a population model:
N clients on ONE chat channel — every channel addon message is
delivered to every client, dispatched on the render thread.

The question: how big can the swarm get before the protocol — not
the server — breaks? WoW chat channels are realm-wide and layer-
agnostic, so 'a million users on one realm' is the right N.

Usage: python brain/test_mesh_scale.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_mesh_sim import World


# ---------- Phase A: measured constants (real code, real wire) ---

def measure():
    """One client + one scripted peer-flood — extract the four
    constants the model needs from the REAL addon code."""
    w = World()
    c = w.client('Alpha')
    c.fire_login()
    w.pump()

    # --- T beacon wire size (1 board advertised) ----------------
    c.lua.execute('GM.Mesh.Advertise()')
    c.advance(1)
    tmsgs = [m['msg'] for m in c.flush_wire() if '|T|' in m['msg']]
    t_bytes = len(tmsgs[0]) if tmsgs else 0

    # --- dispatch cost: T beacons (RelayPeer table write) -------
    # pure-Lua loop around the real CHAT_MSG_ADDON handler — no
    # Python bridge in the measurement. 10k distinct senders.
    bench = c.lua.eval('''
        function(msg, n)
            fire_event("CHAT_MSG_ADDON", "GoblinMind", msg,
                       "CHANNEL", "w")
            collectgarbage("collect")
            local t0 = os.clock()
            for i = 1, n do
                fire_event("CHAT_MSG_ADDON", "GoblinMind", msg,
                           "CHANNEL", "peer" .. i)
            end
            return (os.clock() - t0) * 1e6 / n
        end''')
    t_msg = '1|T|Sim-Realm-A|main:aaaa,alt:bbbb'
    t_us = bench(t_msg, 10000)

    # --- dispatch cost: S record (Stage ring-buffer write) ------
    s_msg = '1|S|Sim-Realm-A|5518:5:120:s:2,5519:1:80:u:1'
    s_us = bench(s_msg, 10000)

    # --- dispatch cost: W stream row (full order ingest) --------
    # opportunistic ingest means EVERY listener parses every row,
    # not just the asker — pin a remote-board stream, then bench
    # real W records from the same sender
    n_us = c.lua.eval('''
        function(n)
            fire_event("CHAT_MSG_ADDON", "GoblinMind",
                       "1|N|Sim-Realm-A|gob;1;ffff", "CHANNEL",
                       "svr1")
            local msg = "1|W|Sim-Realm-A|" ..
                "gob;1;1:ord-1795300001-919;5518;10;0;7;500;" ..
                "86400;PostName;550e8400-e29b-41d4-a716-" ..
                "446655440000;1795386356;open;1;0,0,0,0,0,0"
            fire_event("CHAT_MSG_ADDON", "GoblinMind", msg,
                       "CHANNEL", "svr1")
            collectgarbage("collect")
            local t0 = os.clock()
            for i = 1, n do
                fire_event("CHAT_MSG_ADDON", "GoblinMind", msg,
                           "CHANNEL", "svr1")
            end
            return (os.clock() - t0) * 1e6 / n
        end''')(10000)

    # --- peers-table memory: real RelayPeer writes --------------
    mem = c.lua.eval('''
        function(n)
            collectgarbage("collect")
            local k0 = collectgarbage("count")
            local OR = GM.Orders
            for i = 1, n do
                OR.RelayPeer("main:aaaa", "peer" .. i)
            end
            collectgarbage("collect")
            return (collectgarbage("count") - k0) * 1024 / n
        end''')
    peer_bytes = mem(20000)

    # --- typical record sizes -----------------------------------
    w_row = len('12345:ord-1795300001-919:5518:10:0:3:500:86400:'
                'CharName:550e8400-e29b-41d4-a716-446655440000:1:'
                '1795300000:1795386356:open')  # ~120B realistic
    i_row = len('12345:ord-x:5518:10:0:500:86400:CharName:open')
    s_rec = len('5518:5:120:s:2')               # sale event

    w.srv.shutdown()
    return {
        't_msg_bytes':  t_bytes or len('1|T|Sim-Realm-A|main:aaaa'),
        'dispatch_us_T': t_us,
        'dispatch_us_S': s_us,
        'dispatch_us_N': n_us,
        'peer_bytes':   peer_bytes,
        'w_row_bytes':  w_row,
        'i_row_bytes':  i_row,
        's_rec_bytes':  s_rec,
    }


# ---------- Phase B: population model ----------------------------

# protocol cadences (from Orders.lua / Mesh.lua — keep in sync!)
T_INTERVAL    = 280     # beacon loop, seconds
D_ANSWER_MIN  = 10      # a D re-beacon allowed if _advT older
SERVE_MIN     = 10      # stream throttle per board
ITEM_SERVE_MIN = 10     # i-row throttle per server
MAX_MSG       = 240     # wire cap per addon message

# workload assumptions (documented, adjustable)
SCAN_EVERY     = 600    # one replicate scan per client per 10 min
S_MSGS_PER_SCAN = 3     # ~120 S recs x ~17B -> ~2-3 x 240B msgs
M_MSGS_PER_SCAN = 2     # mb-diff batch, same math
LOGIN_FRAC_MIN = 0.01   # 1% of the realm logs in per minute
SERVE_FRAC     = 0.30   # fraction of clients that can serve a board
Q_RATE_HOUR    = 1.0    # one REFRESH per client-hour
I_RATE_HOUR    = 0.5    # one item search per client-hour
ORDERS_IN_SNAP = 100    # W rows per streamed snapshot
FRAME_MS       = 16.6   # 60 fps budget — the hard wall for dispatch

# verdict thresholds (avg Lua work per frame on mesh traffic alone)
CPU_WARN_MS, CPU_DEAD_MS = 2.0, 12.0
PEER_WARN_MB, PEER_DEAD_MB = 30.0, 150.0
# channel-side: Blizzard anti-flood is fuzzy, but sustained
# multi-thousand msg/sec on a chat channel is dead on arrival;
# receiving has no cap — the delivery itself is the weapon.


def ambient_per_client_s(m):
    """Steady-state channel sends per client per second."""
    t  = 1.0 / T_INTERVAL                        # beacon loop
    sm = (S_MSGS_PER_SCAN + M_MSGS_PER_SCAN) / SCAN_EVERY
    qi = (Q_RATE_HOUR + I_RATE_HOUR) / 3600.0
    d  = 0.0                                      # D handled below
    return t + sm + qi + d


def model(K, n, m, mit=None):
    """One scenario column: returns the four load numbers.
    mit = dict of levers:
      beacon_scale : T interval *= max(1, peers/beacon_cap)
      peer_cap     : keep at most K peers per board
      suppress     : fraction of would-be responders silenced by
                     overhearing another answer (gossip dedup)
      shards       : split channel into S shards, N/S each"""
    mit = mit or {}
    shards   = mit.get('shards', 1)
    peer_cap = mit.get('peer_cap')
    suppress = mit.get('suppress', 0.0)
    beacon_cap = mit.get('beacon_cap')

    nc = max(1, n // shards)                     # clients per shard
    peers_seen = min(nc, peer_cap or nc)         # table entries

    # ambient sends/s per client (beacon adapts if scaled)
    tint = T_INTERVAL
    if beacon_cap and nc > beacon_cap:
        tint = T_INTERVAL * (nc / beacon_cap)
    per_client = (1.0 / tint
                  + (S_MSGS_PER_SCAN + M_MSGS_PER_SCAN) / SCAN_EVERY
                  + (Q_RATE_HOUR + I_RATE_HOUR) / 3600.0)

    # login-driven D storms: every client hears every D and
    # re-beacons if its own beacon is >10s old — the throttle caps
    # each client at 0.1/s but there are nc of them.
    logins_s = nc * LOGIN_FRAC_MIN / 60.0
    d_per_client = min(logins_s, 1.0 / D_ANSWER_MIN)

    # query fan-out: every tag-matched server streams per Q (10s
    # per-board cap each) — aggregate serve rate grows with nc.
    servers  = nc * SERVE_FRAC
    q_s      = nc * Q_RATE_HOUR / 3600.0
    i_s      = nc * I_RATE_HOUR / 3600.0
    w_msgs   = max(1, int(ORDERS_IN_SNAP * m['w_row_bytes']
                          // MAX_MSG))
    serve_s  = servers * min(q_s, 1.0 / SERVE_MIN)         * (1.0 - suppress)
    iserve_s = servers * min(i_s, 1.0 / ITEM_SERVE_MIN)         * (1.0 - suppress)

    inbound_s = (nc * (per_client + d_per_client)
                 + serve_s * w_msgs + iserve_s + q_s + i_s)

    # CPU: weighted dispatch cost — peers writes for T/D/S/M,
    # stream rows for N/W, i rows like S
    us = (0.10 * m['dispatch_us_T']
          + 0.10 * m['dispatch_us_S']
          + 0.80 * m['dispatch_us_N'])
    cpu_ms_frame = inbound_s * us / 1000.0 * (FRAME_MS / 1000.0)

    peer_mb = peers_seen * m['peer_bytes'] / 1e6
    chan_mbps = inbound_s * 200 * 8 / 1e6         # ~200B avg wire

    return {
        'nc': nc, 'inbound_s': inbound_s,
        'cpu_ms': cpu_ms_frame, 'peer_mb': peer_mb,
        'chan_mbps': chan_mbps,
        'responders': servers * (1.0 - suppress),
    }


def verdict(r):
    if r['cpu_ms'] >= CPU_DEAD_MS or r['peer_mb'] >= PEER_DEAD_MB:
        return 'FATAL'
    if r['cpu_ms'] >= CPU_WARN_MS or r['peer_mb'] >= PEER_WARN_MB:
        return 'degraded'
    return 'ok'


def main():
    print('== phase A: measured constants (real addon code) ==')
    m = measure()
    print('  T beacon wire           : %d B' % m['t_msg_bytes'])
    print('  dispatch, T (peer write): %.2f us/msg' % m['dispatch_us_T'])
    print('  dispatch, S (stage)     : %.2f us/msg' % m['dispatch_us_S'])
    print('  dispatch, W (order row) : %.2f us/msg' % m['dispatch_us_N'])
    print('  peers table entry       : %.0f B' % m['peer_bytes'])
    print()

    print('== phase B: population model — current protocol ==')
    print('%-10s %-10s %-12s %-10s %-12s %s'
          % ('clients', 'msgs/s in', 'ms/frame', 'peers MB',
             'chan Mbit/s', 'verdict'))
    ns = [100, 300, 1000, 3000, 10000, 30000,
          100000, 300000, 1000000]
    cross_cpu = cross_mem = None
    for n in ns:
        r = model(None, n, m)
        v = verdict(r)
        if v != 'ok' and cross_cpu is None:
            cross_cpu = n
        if r['peer_mb'] >= PEER_WARN_MB and cross_mem is None:
            cross_mem = n
        print('%-10d %-10.0f %-12.2f %-10.1f %-12.1f %s'
              % (n, r['inbound_s'], r['cpu_ms'], r['peer_mb'],
                 r['chan_mbps'], v))
    print()

    print('== mitigation levers — at 1M clients ==')
    rows = [
        ('current protocol', {}),
        ('peer cap 200/board', {'peer_cap': 200}),
        ('beacon scales w/ pop', {'beacon_cap': 2000}),
        ('90% overhear suppression', {'suppress': 0.90}),
        ('8 channel shards', {'shards': 8}),
        ('all four combined',
         {'peer_cap': 200, 'beacon_cap': 2000,
          'suppress': 0.90, 'shards': 8}),
    ]
    print('%-28s %-10s %-12s %-10s %s'
          % ('lever', 'msgs/s in', 'ms/frame', 'peers MB', 'verdict'))
    for name, mit in rows:
        r = model(None, 1000000, m, mit)
        print('%-28s %-10.0f %-12.2f %-10.1f %s'
              % (name, r['inbound_s'], r['cpu_ms'], r['peer_mb'],
                 verdict(r)))
    print()
    print('crossover (degraded begins): ~%d clients' %
          (cross_cpu or -1))
    print('crossover (peers table):   ~%d clients' %
          (cross_mem or -1))


if __name__ == '__main__':
    main()
