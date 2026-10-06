import random, math, sys, traceback, csv, io
from petal_model import *

EPS = 1e-6
def fresh(flags, tz="America/Chicago", start=None, db=None, defaults=None):
    cal = Cal(tz); clock = Clock(start or cal.local(2026, 6, 10, 10))
    db = db or DB(); q = Queue(db, flags); d = defaults if defaults is not None else {}
    st = Store(clock, cal, q, flags, d); st.load(); q.drain()
    return st, clock, cal, q, db, d

# ---------- independent oracles (computed from raw session records only) ----------
def all_records(st):
    recs = [dict(s) for s in st.q.db.sessions.values() if s["end"] is not None]
    known = {r["id"] for r in recs}
    for s in st.sw:                                       # live sessions not yet persisted/closed
        if s["runMono"] is not None:
            recs = [r for r in recs if r["id"] != s["sid"]]
            recs.append(dict(id=s["sid"], sw=s["id"], start=s["runWall"], end=s["runWall"] + st.session_elapsed(s)))
    # completed in memory but end-op not yet drained
    for r in st.completedToday + (st.statsBuffer or []):
        if r["id"] not in {x["id"] for x in recs}: recs.append(dict(r))
    return recs
def oracle_between(st, i, a, b): return sum(overlap(r["start"], r["end"], a, b) for r in all_records(st) if r["sw"] == i)

def check_invariants(st, reset_at, ctx, offsets=None):
    t0, t1 = st.today(); w0, w1 = st.cal.week_interval(st.c.wall)
    for s in st.sw:
        i = s["id"]; e = st.elapsed(s)
        assert e >= -EPS, f"{ctx}: negative elapsed {e}"
        if st.statsLoaded:
            assert abs(st.today_seconds(i) - oracle_between(st, i, t0, t1)) < 1e-3, f"{ctx}: Today mismatch {st.today_seconds(i)} vs {oracle_between(st,i,t0,t1)}"
            assert abs(st.week_seconds(i) - oracle_between(st, i, w0, w1)) < 1e-3, f"{ctx}: Week mismatch"
            assert abs(st.all_time(i) - oracle_between(st, i, -math.inf, math.inf)) < 1e-3, f"{ctx}: All-time mismatch {st.all_time(i)} vs {oracle_between(st,i,-math.inf,math.inf)}"
        # PRD §5.1: stopwatch value = today's time since the last reset
        lo = max(t0, reset_at.get(i, -math.inf))
        exp = oracle_between(st, i, lo, math.inf) + ((offsets or {}).get(i, (0, None))[0] if (offsets or {}).get(i, (0, None))[1] == t0 else 0)
        assert abs(e - exp) < 1e-3, f"{ctx}: displayed {e:.3f} != today-since-reset {exp:.3f}"
    # persistence consistency after drain
    st.q.drain()
    for s in st.sw:
        opens = [x for x in st.q.db.sessions.values() if x["sw"] == s["id"] and x["end"] is None]
        assert len(opens) == (1 if s["runMono"] is not None else 0), f"{ctx}: open sessions {len(opens)}"
        if s["runMono"] is not None: assert opens[0]["id"] == s["sid"], f"{ctx}: wrong open session"
        else:
            p = st.q.db.stopwatches[s["id"]]
            assert abs(p["acc"] - s["acc"]) < EPS, f"{ctx}: persisted acc {p['acc']} != memory {s['acc']}"
    for lp in st.q.db.laps.values():
        assert lp["session"] in st.q.db.sessions, f"{ctx}: orphan lap"

# ---------- deterministic tests ----------
TESTS = []
def test(f): TESTS.append(f); return f

@test
def state_machine_basic(flags):
    st, c, *_ = fresh(flags); a = st.create()
    st.reset(a); assert st.elapsed(st.model(a)) == 0                 # IDLE -> reset -> IDLE
    st.start(a); c.advance(1); assert st.elapsed(st.model(a)) == 1     # exactly 1 s
    st.pause(a); c.advance(50); assert st.elapsed(st.model(a)) == 1   # paused time excluded
    st.start(a); c.advance(59); assert st.elapsed(st.model(a)) == 60  # 59 -> 60
    st.pause(a); st.reset(a); assert st.elapsed(st.model(a)) == 0
    st.q.drain(); assert len(st.q.db.sessions) == 2                   # reset keeps history

@test
def double_start_and_idle_pause(flags):
    st, c, *_ = fresh(flags); a = st.create()
    st.pause(a); st.start(a); sid = st.model(a)["sid"]; c.advance(3); st.start(a)
    assert st.model(a)["sid"] == sid; c.advance(2); assert st.elapsed(st.model(a)) == 5
    st.q.drain(); assert len(st.q.db.sessions) == 1

@test
def independence_ten_running(flags):
    st, c, *_ = fresh(flags); ids = [st.create() for _ in range(10)]
    for k, i in enumerate(ids): st.start(i); c.advance(1)
    st.pause(ids[3]); st.reset(ids[5]); c.advance(10)
    for k, i in enumerate(ids):
        e = st.elapsed(st.model(i))
        if k == 3: assert e == 10 - 3
        elif k == 5: assert e == 0
        else: assert e == (10 - k) + 10, (k, e)
    assert sum(s["runMono"] is not None for s in st.sw) == 8

@test
def midnight_split_and_rollover(flags):
    cal = Cal(); st, c, *_ = fresh(flags, start=cal.local(2026, 6, 10, 23, 59))
    a = st.create(); st.start(a); c.advance(120); st.tick()
    assert abs(st.today_seconds(a) - 60) < EPS, st.today_seconds(a)
    assert abs(st.elapsed(st.model(a)) - 60) < EPS, f"display after midnight = {st.elapsed(st.model(a))} (PRD: today's time = 60)"
    st.pause(a)
    assert st.dayTotals[a][cal.local(2026, 6, 10)] == 60 and st.dayTotals[a][cal.local(2026, 6, 11)] == 60

@test
def pause_after_midnight_before_any_tick(flags):
    cal = Cal(); st, c, *_ = fresh(flags, start=cal.local(2026, 6, 10, 23, 0))
    a = st.create(); st.start(a); c.advance(7200)          # 23:00 -> 01:00, no tick (asleep)
    assert abs(st.elapsed(st.model(a)) - 3600) < EPS, f"display before tick {st.elapsed(st.model(a))}"
    st.pause(a)                                           # hotkey pressed on wake
    assert abs(st.model(a)["acc"] - 3600) < EPS, f"yesterday folded into today: {st.model(a)['acc']}"
    st.tick(); assert abs(st.elapsed(st.model(a)) - 3600) < EPS

@test
def paused_value_display_without_tick(flags):
    cal = Cal(); st, c, *_ = fresh(flags, start=cal.local(2026, 6, 10, 22))
    a = st.create(); st.start(a); c.advance(600); st.pause(a); c.advance(4 * 3600)
    assert st.elapsed(st.model(a)) == 0, f"stale value shown before day-change notification: {st.elapsed(st.model(a))}"

@test
def paused_value_resets_next_day(flags):
    cal = Cal(); st, c, *_ = fresh(flags, start=cal.local(2026, 6, 10, 22))
    a = st.create(); st.start(a); c.advance(3600); st.pause(a)
    c.advance(3 * 3600); st.handle_day_change()
    assert st.elapsed(st.model(a)) == 0, f"yesterday's value still shown: {st.elapsed(st.model(a))}"

@test
def dst_spring_forward_split(flags):
    cal = Cal("America/New_York")
    parts = split(cal.local(2026, 3, 7, 23), cal.local(2026, 3, 9, 1), cal)
    assert [p[1] for p in parts] == [3600, 23 * 3600, 3600], parts
    parts = split(cal.local(2026, 11, 1, 0, 30), cal.local(2026, 11, 2, 0, 30), cal)   # fall back: 25 h day
    assert [p[1] for p in parts] == [23.5 * 3600 + 3600, 1800], parts

@test
def week_boundaries(flags):
    cal = Cal()
    ws, we = cal.week_interval(cal.local(2026, 12, 31, 12))            # Thursday
    assert (ws, we) == (cal.local(2026, 12, 28), cal.local(2027, 1, 4))
    ws, we = cal.week_interval(cal.local(2026, 6, 14, 23, 59))         # Sunday is the LAST day
    assert ws == cal.local(2026, 6, 8)
    st, c, *_ = fresh(flags, start=cal.local(2026, 6, 14, 23, 30))    # session across Sun->Mon
    a = st.create(); st.start(a); c.advance(3600); st.pause(a)
    assert abs(st.week_seconds(a) - 1800) < EPS and abs(st.today_seconds(a) - 1800) < EPS

@test
def streak_boundaries(flags):
    st, c, cal, *_ = fresh(flags)
    a = st.create()
    for secs in (60, 60, 59):                  # day1 60s, day2 60s, day3 59s
        st.start(a); c.advance(secs); st.pause(a); c.advance(86400 - secs); st.tick()
    assert st.streak(a) == 0, st.streak(a)     # yesterday had 59 s -> broken
    st.start(a); c.advance(60); assert st.streak(a) == 1
    b = st.create()
    for _ in range(3): st.start(b); c.advance(120); st.pause(b); c.advance(86400 - 120); st.tick()
    assert st.streak(b) == 3
    c.advance(86400); st.tick(); assert st.streak(b) == 0             # skipped a day

@test
def streak_cross_midnight_counts_both_days(flags):
    cal = Cal(); st, c, *_ = fresh(flags, start=cal.local(2026, 6, 10, 23, 59))
    a = st.create(); st.start(a); c.advance(120); st.tick()
    assert st.streak(a) == 2, st.streak(a)     # 60 s on each day

@test
def goal_boundaries_and_once(flags):
    st, c, *_ = fresh(flags); a = st.create(); st.model(a)["goal"] = 1800
    st.start(a); c.advance(1799); st.tick(); assert not st.notified
    c.advance(1); st.tick(); assert len(st.notified) == 1
    for _ in range(100): c.advance(1); st.tick()
    assert len(st.notified) == 1, "notified more than once"
    c.advance(86400); st.tick()
    # still running next day: goal crossing re-evaluated from today's total only
    assert len(st.notified) == 2, st.notified

@test
def goal_flash_survives_midnight(flags):
    cal = Cal(); st, c, *_ = fresh(flags, start=cal.local(2026, 6, 10, 23, 0))
    a = st.create(); st.model(a)["goal"] = 1800
    st.start(a); c.advance(3600 + 1800); st.tick()              # goal crossed only counting today
    assert getattr(st, "flash", {}).get(a) is not None, "goal flash wiped by the day change in the same tick"

@test
def laps_belong_to_active_session(flags):
    st, c, *_ = fresh(flags); a = st.create()
    st.lap(a); st.start(a); c.advance(1); st.lap(a); st.lap(a); sid1 = st.model(a)["sid"]
    st.pause(a); st.lap(a); st.start(a); c.advance(1); st.lap(a); sid2 = st.model(a)["sid"]
    st.q.drain(); laps = list(st.q.db.laps.values())
    assert [l["session"] for l in laps] == [sid1, sid1, sid2]

@test
def crash_recovery_no_double_count(flags):
    st, c, cal, q, db, d = fresh(flags); a = st.create(); st.start(a); c.advance(100); st.pause(a)
    st.start(a); c.advance(40); st.tick(); c.advance(15)   # heartbeat at +40 of run 2; crash at +55
    q.drain()                                              # ops reached disk; process killed
    c.advance(3600)                                        # relaunch 1 h later
    st2 = Store(c, cal, Queue(db, flags), flags, d); rec = st2.load(); st2.q.drain()
    assert rec == 1
    s = next(x for x in db.sessions.values() if x["interrupted"])
    assert abs((s["end"] - s["start"]) - 40) < EPS, "closed at launch time instead of heartbeat"
    assert abs(st2.model(a)["acc"] - 140) < EPS, st2.model(a)["acc"]
    assert not any(x["end"] is None for x in db.sessions.values())
    st2.q.drain(); assert abs(st2.all_time(a) - 140) < EPS

@test
def crash_recovery_across_midnight(flags):
    cal = Cal(); st, c, cal, q, db, d = fresh(flags, start=cal.local(2026, 6, 10, 23, 50))
    a = st.create(); st.start(a); c.advance(1200); st.tick(); q.drain()   # hb at 00:10 next day
    c.advance(600)
    st2 = Store(c, cal, Queue(db, flags), flags, d); st2.load(); st2.q.drain()
    assert abs(st2.model(a)["acc"] - 600) < EPS, f"recovered acc {st2.model(a)['acc']} (only today's 600 s should count)"

@test
def relaunch_next_day_zeroes_value(flags):
    cal = Cal(); st, c, cal, q, db, d = fresh(flags)
    a = st.create(); st.start(a); c.advance(500); st.prepare_for_termination()
    c.advance(86400)
    st2 = Store(c, cal, Queue(db, flags), flags, d); st2.load(); st2.q.drain()
    assert st2.elapsed(st2.model(a)) == 0, st2.elapsed(st2.model(a))
    assert abs(st2.all_time(a) - 500) < EPS

@test
def quit_while_running(flags):
    st, c, cal, q, db, d = fresh(flags); ids = [st.create() for _ in range(3)]
    for i in ids: st.start(i); c.advance(10)
    st.prepare_for_termination()
    assert not any(x["end"] is None for x in db.sessions.values())
    st2 = Store(c, cal, Queue(db, flags), flags, d); st2.load(); st2.q.drain()
    assert [round(st2.elapsed(s)) for s in st2.sw] == [30, 20, 10]

@test
def delete_selected_running(flags):
    st, c, *_ = fresh(flags); a, b, x = st.create(), st.create(), st.create()
    st.start(b); st.route = b; st.delete(b)
    assert st.selected == a and st.route is None and st.model(b) is None
    st.q.drain(); assert st.q.db.stopwatches[b]["deletedAt"] is not None
    assert len([s for s in st.q.db.sessions.values() if s["sw"] == b]) == 1   # history retained
    st.select_position(3); assert st.selected == a                  # out of range: unchanged
    st.select_position(2); assert st.selected == x

@test
def stats_race_pause_during_fetch(flags):
    st, c, *_ = fresh(flags); a = st.create(); st.start(a); c.advance(10)
    st.load_stats()                  # fetch queued behind nothing; don't drain yet
    st.pause(a); c.advance(5); st.start(a); c.advance(5); st.pause(a)
    st.q.drain()
    assert abs(st.all_time(a) - 15) < EPS, st.all_time(a)          # 10 s + 5 s of running time
    st.load_stats(); st.start(a); c.advance(1); st.load_stats(); st.pause(a); st.q.drain(n=1); st.q.drain()
    assert abs(st.all_time(a) - 16) < EPS, st.all_time(a)

@test
def menubar_rules(flags):
    st, c, *_ = fresh(flags); a, b = st.create(), st.create()
    assert st.menubar_stopwatch() is None
    st.start(a); c.advance(5); st.start(b); assert st.menubar_stopwatch()["id"] == b
    st.pause(b); assert st.menubar_stopwatch()["id"] == a
    st.delete(a); assert st.menubar_stopwatch() is None

@test
def csv_escaping(flags):
    cases = ["plain", "a,b", 'say "hi"', "l1\r\nl2", "=HYPERLINK(1)", "-5", "emoji 🌸,x", "", "tab\tin"]
    row = ",".join(csv_escape(x) for x in cases)
    parsed = next(csv.reader(io.StringIO(row)))
    expect = [("'" + x) if x and x[0] in "=+-@\t\r" else x for x in cases]
    assert parsed == expect, parsed

# ---------- adversarial fuzzer ----------
def fuzz(flags, seeds=400, steps=120, start_seed=0):
    fails = []
    for seed in range(start_seed, start_seed + seeds):
        rnd = random.Random(seed)
        tz = rnd.choice(["America/Chicago", "America/New_York", "Europe/London", "Australia/Sydney"])
        cal = Cal(tz)
        start = cal.local(2026, rnd.choice([3, 6, 10, 11, 12]), rnd.randint(1, 28), rnd.randint(0, 23), rnd.randint(0, 59))
        st, c, cal, q, db, d = fresh(flags, tz=tz, start=start)
        reset_at = {}; log = []; offsets = {}
        try:
            for step in range(steps):
                op = rnd.choices(["create", "start", "pause", "toggle", "reset", "lap", "delete", "adv", "bigadv",
                                  "tick", "drain", "partial", "stats", "select", "crash", "quit", "goal"],
                                 [4, 10, 8, 10, 4, 5, 2, 12, 3, 6, 5, 4, 2, 2, 1, 1, 2])[0]
                ids = [s["id"] for s in st.sw]; i = rnd.choice(ids) if ids else None
                log.append((op, i[:4] if i else None))
                if op == "create" and len(st.sw) < 25: st.create()
                elif op in ("start", "pause", "toggle", "lap") and i: getattr(st, op)(i)
                elif op == "reset" and i:
                    st.reset(i); reset_at[i] = c.wall; offsets.pop(i, None)
                elif op == "delete" and i: st.delete(i); reset_at.pop(i, None)
                elif op == "adv": c.advance(rnd.choice([0, 0.001, 0.5, 1, 59, 60, 61, 3599, 3600]))
                elif op == "bigadv": c.advance(rnd.choice([6 * 3600, 86399, 86400, 86401, 3 * 86400]))  # no tick: delayed callback
                elif op == "tick": st.tick()
                elif op == "drain": q.drain()
                elif op == "partial": q.drain(n=rnd.randint(0, 3))
                elif op == "stats": st.load_stats()
                elif op == "select": st.select_position(rnd.randint(0, 30))
                elif op == "goal" and i: st.model(i)["goal"] = rnd.choice([None, 60, 1800])
                elif op in ("crash", "quit"):
                    if op == "quit": st.prepare_for_termination()
                    else:
                        st.tick(); q.drain(n=rnd.randint(0, len(q.ops)))   # some ops lost with the process
                        q.ops.clear()
                    c.advance(rnd.choice([1, 120, 86400]))
                    st = Store(c, cal, Queue(db, flags), flags, d); st.load(); st.q.drain(); q = st.q
                    t0 = st.today()[0]
                    for s2 in st.sw:
                        lo = max(t0, reset_at.get(s2["id"], -math.inf))
                        off = st.elapsed(s2) - oracle_between(st, s2["id"], lo, math.inf)
                        if op == "quit":   # a clean quit must lose nothing
                            assert abs(off) < 1e-3, f"seed {seed}: clean quit changed value by {off}"
                        offsets[s2["id"]] = (off, t0)   # a crash may only lose not-yet-saved resets
                    continue
                if rnd.random() < 0.5: st.tick()          # ticks can be late or missing entirely
                check_invariants(st, reset_at, f"seed {seed} step {step} op {op}", offsets)
        except AssertionError as e:
            fails.append((seed, str(e), log[-6:]))
    return fails

def run(label, flags):
    print(f"\n=== {label}: flags={flags} ===")
    ok = bad = 0
    for t in TESTS:
        try: t(flags); ok += 1
        except AssertionError as e: bad += 1; print(f"  FAIL {t.__name__}: {e}")
        except Exception: bad += 1; print(f"  ERROR {t.__name__}:"); traceback.print_exc()
    print(f"  deterministic: {ok} passed, {bad} failed")
    f = fuzz(flags)
    print(f"  fuzz: {400 - len(set(x[0] for x in f))}/400 seeds clean")
    for x in f[:3]: print("   ", x[1], "| last ops:", x[2])
    return bad + len(f)

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    if which in ("before", "both"): run("BEFORE fixes (current App.swift logic)", {})
    if which in ("after", "both"): run("AFTER fixes", {"rollover": True, "day_aware_recovery": True, "robust_day": True})
