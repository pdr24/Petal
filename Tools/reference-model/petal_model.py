"""
Executable reference model of Petal's timing / state-machine / stats / persistence logic.
Mirrors App.swift function-by-function (names match). Feature flags let the SAME
tests run against the pre-fix logic (to demonstrate bugs) and the fixed logic.
Calendar math uses real IANA zones via zoneinfo (DST-correct), like Foundation.Calendar.
"""
import uuid, math
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

class Cal:
    current = None
    def __init__(self, tz="America/Chicago"): self.tz = ZoneInfo(tz); Cal.current = self
    @staticmethod
    def add_days_static(day_start): return Cal.current.add_days(day_start, 1)
    def start_of_day(self, t):
        d = datetime.fromtimestamp(t, self.tz)
        return datetime(d.year, d.month, d.day, tzinfo=self.tz).timestamp()
    def add_days(self, day_start, n):
        d = datetime.fromtimestamp(day_start, self.tz)
        nd = (datetime(d.year, d.month, d.day) + timedelta(days=n))
        return datetime(nd.year, nd.month, nd.day, tzinfo=self.tz).timestamp()
    def day_interval(self, t):
        s = self.start_of_day(t); return (s, self.add_days(s, 1))
    def week_interval(self, t):
        s = self.start_of_day(t)
        wd = datetime.fromtimestamp(s, self.tz).weekday()     # Monday = 0
        ws = self.add_days(s, -wd); return (ws, self.add_days(ws, 7))
    def local(self, *a): return datetime(*a, tzinfo=self.tz).timestamp()

def split(start, end, cal):                                    # DayMath.split
    out, cur, it = [], start, 0
    while cur < end and it < 10000:
        it += 1
        ds = cal.start_of_day(cur); nx = cal.add_days(ds, 1)
        if not nx > cur: out.append((ds, end - cur)); break
        se = min(nx, end); out.append((ds, se - cur)); cur = se
    return out

def overlap(s, e, a, b): return max(0.0, min(e, b) - max(s, a))

# ---------------------------------------------------------------- persistence
class DB:                                   # the SwiftData store
    def __init__(self): self.stopwatches, self.sessions, self.laps = {}, {}, {}

class Queue:                                # PersistenceQueue + PersistenceActor
    def __init__(self, db, flags): self.db, self.ops, self.flags = db, [], flags
    def enqueue(self, op): self.ops.append(op)
    def drain(self, n=None):
        k = len(self.ops) if n is None else min(n, len(self.ops))
        for _ in range(k): self.apply(self.ops.pop(0))
    def apply(self, op):
        kind, a = op[0], op[1:]; db = self.db
        if kind == "upsert": db.stopwatches[a[0]["id"]] = dict(a[0], deletedAt=db.stopwatches.get(a[0]["id"], {}).get("deletedAt"))
        elif kind == "softDelete": db.stopwatches[a[0]]["deletedAt"] = a[1]
        elif kind == "start": db.sessions[a[0]] = dict(id=a[0], sw=a[1], start=a[2], end=None, interrupted=False, note=None)
        elif kind == "end":
            s = db.sessions.get(a[0]);
            if s: s["end"] = max(a[1], s["start"])
        elif kind == "lap": db.laps[a[0]["id"]] = dict(a[0])
        elif kind == "fetchSessions": a[0]([dict(s) for s in db.sessions.values()])
        elif kind == "barrier": a[0]()

def load_and_recover(db, heartbeat, now, today_start, flags):   # PersistenceActor.loadAndRecover
    recovered = 0
    for s in db.sessions.values():
        if s["end"] is None:
            recovered += 1
            end = max(s["start"], min(heartbeat if heartbeat is not None else s["start"], now))
            s["end"] = end; s["interrupted"] = True
            o = db.stopwatches.get(s["sw"])
            if o is None: continue
            if flags.get("day_aware_recovery"):
                portion = overlap(s["start"], end, today_start, math.inf)
                te = Cal.add_days_static(today_start)
                if o.get("accDay") is not None and today_start <= o["accDay"] < te: o["acc"] += portion
                else: o["acc"], o["accDay"] = portion, today_start
            else:
                o["acc"] += end - s["start"]
    if flags.get("rollover"):
        for o in db.stopwatches.values():
            te = Cal.add_days_static(today_start)
            if o.get("deletedAt") is None and not (o.get("accDay") is not None and today_start <= o["accDay"] < te):
                o["acc"], o["accDay"] = 0.0, today_start
    return [dict(o) for o in sorted(db.stopwatches.values(), key=lambda x: x["sort"]) if o.get("deletedAt") is None], recovered

# ---------------------------------------------------------------- store
class Store:
    def __init__(self, clock, cal, queue, flags, defaults):
        self.c, self.cal, self.q, self.f, self.d = clock, cal, queue, flags, defaults
        self.sw, self.selected, self.route = [], None, None
        self.dayTotals, self.allTime, self.counts, self.completedToday = {}, {}, {}, []
        self.openLaps, self.statsBuffer, self.statsGen, self.statsLoaded = {}, None, 0, False
        self.currentDay = None; self.notified = []; self.loaded = False
    # -- helpers
    def model(self, i): return next((s for s in self.sw if s["id"] == i), None)
    def today(self): return self.cal.day_interval(self.c.wall)
    def snap(self, s): return dict(id=s["id"], name=s["name"], sort=s["sort"], acc=s["acc"], accDay=s.get("accDay"), goal=s.get("goal"))
    def session_elapsed(self, s): return max(0.0, self.c.mono - s["runMono"]) if s["runMono"] is not None else 0.0
    def elapsed(self, s):
        if self.f.get("robust_day"):
            td = self.cal.start_of_day(self.c.wall)
            if s.get("accDay") is not None and self.cal.start_of_day(s["accDay"]) != td:
                return self.live_overlap(s, td, math.inf)     # stale day: only today's live part
        if s["runMono"] is None: return s["acc"]
        base = s["countMono"] if self.f.get("rollover") else s["runMono"]
        return s["acc"] + max(0.0, self.c.mono - base)
    # -- load
    def load(self):
        hb = self.d.get("heartbeat"); ts = self.cal.start_of_day(self.c.wall)
        self.q.drain()                           # ensure prior ops landed (new process)
        items, rec = load_and_recover(self.q.db, hb, self.c.wall, ts, self.f)
        for o in items:
            self.sw.append(dict(id=o["id"], name=o["name"], sort=o["sort"], acc=max(0.0, o["acc"]), accDay=o.get("accDay"),
                                goal=o.get("goal"), runMono=None, countMono=None, runWall=None, sid=None))
        self.selected = self.d.get("selected") if self.model(self.d.get("selected")) else (self.sw[0]["id"] if self.sw else None)
        self.loaded, self.currentDay = True, ts
        self.load_stats(); return rec
    def load_stats(self):
        self.statsGen += 1; g = self.statsGen; self.statsBuffer = []
        self.q.enqueue(("fetchSessions", lambda recs, g=g: self.finish_stats(recs, g)))
    def finish_stats(self, recs, g):
        if g != self.statsGen: return
        self.dayTotals, self.allTime, self.counts, self.completedToday = {}, {}, {}, []
        live = {s["id"] for s in self.sw}
        for r in recs:
            if r["end"] is not None and r["sw"] in live: self.accumulate(r)
        buf, self.statsBuffer = self.statsBuffer or [], None
        for r in buf: self.accumulate(r)
        self.statsLoaded = True
    def accumulate(self, r):
        for day, secs in split(r["start"], r["end"], self.cal):
            self.dayTotals.setdefault(r["sw"], {}); self.dayTotals[r["sw"]][day] = self.dayTotals[r["sw"]].get(day, 0) + secs
        self.allTime[r["sw"]] = self.allTime.get(r["sw"], 0) + max(0.0, r["end"] - r["start"])
        self.counts[r["sw"]] = self.counts.get(r["sw"], 0) + 1
        t0, t1 = self.today()
        if r["start"] < t1 and r["end"] >= t0: self.completedToday.append(r)
    def record_completed(self, r):
        if self.statsBuffer is not None: self.statsBuffer.append(r)
        else: self.accumulate(r)
    # -- stats queries
    def live_overlap(self, s, a, b):
        if s["runWall"] is None: return 0.0
        return overlap(s["runWall"], s["runWall"] + self.session_elapsed(s), a, b)
    def seconds_on_day(self, i, day):
        done = self.dayTotals.get(i, {}).get(day[0], 0.0); s = self.model(i)
        return done + (self.live_overlap(s, *day) if s else 0.0)
    def today_seconds(self, i): return self.seconds_on_day(i, self.today())
    def week_seconds(self, i):
        ws, _ = self.cal.week_interval(self.c.wall); tot, d = 0.0, ws
        for _ in range(7):
            nx = self.cal.add_days(d, 1); tot += self.seconds_on_day(i, (d, nx)); d = nx
        return tot
    def all_time(self, i):
        s = self.model(i); return self.allTime.get(i, 0.0) + (self.session_elapsed(s) if s else 0.0)
    def streak(self, i):
        day = self.today(); n = 1 if self.seconds_on_day(i, day) >= 60 else 0
        for _ in range(3650):
            ps = self.cal.add_days(day[0], -1); day = (ps, day[0])
            if self.seconds_on_day(i, day) >= 60: n += 1
            else: break
        return n
    # -- state machine
    def start(self, i):
        if self.f.get("robust_day"): self.handle_day_change()
        s = self.model(i)
        if s is None or s["runMono"] is not None: return
        if self.f.get("rollover"):
            td = self.cal.start_of_day(self.c.wall)
            if s.get("accDay") is None or self.cal.start_of_day(s["accDay"]) != td: s["acc"], s["accDay"] = 0.0, td
        sid = str(uuid.uuid4()); s.update(runMono=self.c.mono, countMono=self.c.mono, runWall=self.c.wall, sid=sid)
        self.q.enqueue(("start", sid, i, self.c.wall)); self.selected = i
        self.d["selected"] = i; self.d["heartbeat"] = self.c.wall
    def pause(self, i):
        if self.f.get("robust_day"): self.handle_day_change()
        s = self.model(i)
        if s is None or s["runMono"] is None: return
        dur = max(0.0, self.c.mono - s["runMono"])
        counted = max(0.0, self.c.mono - (s["countMono"] if self.f.get("rollover") else s["runMono"]))
        s["acc"] += counted
        if self.f.get("rollover"): s["accDay"] = self.cal.start_of_day(self.c.wall)
        end = s["runWall"] + dur; sid = s["sid"]
        rec = dict(id=sid, sw=i, start=s["runWall"], end=end, interrupted=False, laps=self.openLaps.pop(sid, []))
        s.update(runMono=None, countMono=None, runWall=None, sid=None)
        self.q.enqueue(("end", sid, end)); self.q.enqueue(("upsert", self.snap(s)))
        self.record_completed(rec)
    def toggle(self, i):
        s = self.model(i)
        if s: (self.pause if s["runMono"] is not None else self.start)(i)
    def reset(self, i):
        if self.f.get("robust_day"): self.handle_day_change()
        s = self.model(i)
        if s is None: return
        if s["runMono"] is not None: self.pause(i)
        s["acc"] = 0.0
        if self.f.get("rollover"): s["accDay"] = self.cal.start_of_day(self.c.wall)
        self.q.enqueue(("upsert", self.snap(s)))
    def lap(self, i):
        if self.f.get("robust_day"): self.handle_day_change()
        s = self.model(i)
        if s is None or s["runMono"] is None: return
        lp = dict(id=str(uuid.uuid4()), session=s["sid"], elapsed=self.elapsed(s))
        self.openLaps.setdefault(s["sid"], []).append(lp); self.q.enqueue(("lap", lp))
    def create(self, name=None):
        n = len(self.sw) + 1
        s = dict(id=str(uuid.uuid4()), name=name or f"Timer {n}", sort=max([x["sort"] for x in self.sw], default=-1) + 1,
                 acc=0.0, accDay=self.cal.start_of_day(self.c.wall), goal=None, runMono=None, countMono=None, runWall=None, sid=None)
        self.sw.append(s); self.q.enqueue(("upsert", self.snap(s)))
        if self.selected is None: self.selected = s["id"]
        return s["id"]
    def delete(self, i):
        s = self.model(i)
        if s is None: return
        if s["runMono"] is not None: self.pause(i)
        self.sw = [x for x in self.sw if x["id"] != i]
        self.q.enqueue(("softDelete", i, self.c.wall))
        for dct in (self.dayTotals, self.allTime, self.counts): dct.pop(i, None)
        self.completedToday = [r for r in self.completedToday if r["sw"] != i]
        if self.selected == i: self.selected = self.sw[0]["id"] if self.sw else None
        if self.route == i: self.route = None
    def select_position(self, p):
        if 1 <= p <= len(self.sw): self.selected = self.sw[p - 1]["id"]
    # -- tick / day change / goals
    def menubar_stopwatch(self):
        sel = self.model(self.selected)
        if sel and sel["runMono"] is not None: return sel
        running = [s for s in self.sw if s["runMono"] is not None]
        return max(running, key=lambda s: s["runMono"]) if running else None
    def tick(self):
        if self.f.get("robust_day") and self.cal.start_of_day(self.c.wall) != self.currentDay: self.handle_day_change()
        if any(s["runMono"] is not None for s in self.sw):
            self.d["heartbeat"] = self.c.wall        # (every 30 ticks in Swift; per-tick here = upper bound)
            self.check_goals()
        if self.cal.start_of_day(self.c.wall) != self.currentDay: self.handle_day_change()
    def handle_day_change(self):
        day = self.cal.start_of_day(self.c.wall)
        if day == self.currentDay: return
        self.currentDay = day; t0, t1 = self.today(); self.flash = {}
        self.completedToday = [r for r in self.completedToday if r["start"] < t1 and r["end"] >= t0]
        if self.f.get("rollover"):
            for s in self.sw:
                if s.get("accDay") is None or self.cal.start_of_day(s["accDay"]) != day:
                    s["acc"], s["accDay"] = 0.0, day
                    if s["runMono"] is not None:
                        s["countMono"] = s["runMono"] + max(0.0, day - s["runWall"])
                    self.q.enqueue(("upsert", self.snap(s)))
    def check_goals(self):
        if not self.statsLoaded: return
        key = self.cal.start_of_day(self.c.wall)
        for s in self.sw:
            g = s.get("goal")
            if s["runMono"] is None or not g: continue
            if self.today_seconds(s["id"]) >= g and self.d.setdefault("goalNotified", {}).get(s["id"]) != key:
                self.d["goalNotified"][s["id"]] = key; self.notified.append((s["id"], key)); self.flash = getattr(self, "flash", {}); self.flash[s["id"]] = self.c.wall
    def prepare_for_termination(self):
        for s in list(self.sw):
            if s["runMono"] is not None: self.pause(s["id"])
        self.d["heartbeat"] = self.c.wall; self.q.drain()

class Clock:
    def __init__(self, wall): self.wall, self.mono = wall, 10_000.0
    def advance(self, dt): self.wall += dt; self.mono += dt

# ---------------------------------------------------------------- CSV (ExportManager.escape)
def csv_escape(raw):
    s = raw
    if s and s[0] in "=+-@\t\r": s = "'" + s
    if any(ch in s for ch in ',"\n\r'): s = '"' + s.replace('"', '""') + '"'
    return s
