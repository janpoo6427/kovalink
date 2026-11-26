"""Independent, display-only adapter. No device I/O or control imports."""
from itertools import islice
from math import isfinite


def field(msg, name, default=None):
    if isinstance(msg, dict):
        return msg.get(name, default)
    # Avoid asking pycapnp for unknown fields on a fork with a different schema.
    schema = getattr(type(msg), "schema", None)
    if schema is not None and name not in msg.schema.fields:
        return default
    return getattr(msg, name, default)


def seq(msg, key):
    value = field(msg, key)
    return () if value is None else value


def num(v):
    return isinstance(v, (float, int)) and not isinstance(v, bool) and isfinite(v)


def index(seq_, i):
    return seq_[i] if i < len(seq_) else None


def points(line, offset):
    result = []
    for x, y in islice(zip(seq(line, "x"), seq(line, "y")), 33):
        if num(x) and num(y) and (not result or x-offset > result[-1]["x"]):
            result.append({"x": x-offset, "y": -y, "z": 0.0})
    return result


def fresh(age, limit):
    return num(age) and 0 <= age <= limit


def scene_fields(*, car, model=None, model_age_s=None, radar=None, radar_age_s=None,
                 tracks=None, tracks_age_s=None, model_origin_forward_m=0.0):
    """Inputs are payloads (SubMaster[service]), ages in monotonic seconds.

    Caller must pass only valid services and a fresh carState. Override model
    offset only for a known, verified model-to-bumper origin; never shift radar.
    """
    if not num(model_origin_forward_m):
        raise ValueError("model_origin_forward_m must be finite")
    ego = field(car, "vEgo")
    if not num(ego):
        raise ValueError("fresh carState.vEgo is required")
    model = model if fresh(model_age_s, .5) else None
    offset = model_origin_forward_m
    lanes = []
    for i, line in enumerate(islice(seq(model, "laneLines"), 4)):
        p = index(seq(model, "laneLineProbs"), i)
        lanes.append({"points": points(line, offset), "probability": max(0, min(1, p)) if num(p) else 0})
    edges, stds = [], []
    for i, edge in enumerate(islice(seq(model, "roadEdges"), 2)):
        std = index(seq(model, "roadEdgeStds"), i)
        if num(std) and 0 <= std <= 2.5:
            edges.append(points(edge, offset)); stds.append(std)
    objects = []

    def add(x, y, v, tid, lead, source):
        if not all(num(n) for n in (x, y, v)) or not -30 <= x <= 200:
            return
        tid = tid if type(tid) is int and 0 <= tid <= (1 << 63)-1 else None
        for old in objects:
            if ((tid is not None and old.get("id") == tid) or
                ((tid is None or old.get("id") is None) and abs(old["distanceMeters"]-x) < 2.5
                 and abs(old["leftMeters"]-y) < 1 and abs(old["relativeSpeedMps"]-v) < 3)):
                if tid is not None: old.setdefault("id", tid)
                old["isLead"] |= lead
                return
        row = dict(kind="vehicle", distanceMeters=x, leftMeters=y, relativeSpeedMps=v, isLead=lead, source=source)
        if tid is not None: row["id"] = tid
        objects.append(row)

    if radar is not None and fresh(radar_age_s, 1):
        def lead_row(row, primary):
            if not field(row, "present", field(row, "status", False)): return
            add(field(row,"dRel"),field(row,"yRel"),field(row,"vRel"),field(row,"radarTrackId"),primary,"radarState")
        for key in ("leadOne", "leadTwo", "leadLeft", "leadRight"):
            lead_row(field(radar,key), key == "leadOne")
        for key in ("leadsLeft", "leadsCenter", "leadsRight", "leadsLeft2", "leadsRight2", "leadsCutIn"):
            for row in islice(seq(radar,key), 64): lead_row(row, False)
    else:
        model_speed = index(seq(field(model,"velocity"),"x"),0)
        for i, row in enumerate(islice(seq(model,"leadsV3"), 4)):
            p = field(row,"prob")
            x,y,v = (index(seq(row,k),0) for k in ("x","y","v"))
            if num(p) and .5 <= p <= 1 and all(num(n) for n in (x,y,v)):
                add(x-offset,-y,v-(model_speed if num(model_speed) else ego),None,i == 0,"vision")
    errors = field(tracks,"errors")
    bad = any(field(errors,k,False) for k in ("canError","radarFault","wrongConfig","radarUnavailableTemporary")) if errors is not None else False
    if fresh(tracks_age_s,.3) and not bad:
        for row in islice(seq(tracks,"points"),128):
            x, v = field(row,"dRel"),field(row,"vRel")
            if num(x) and num(v): add(x+v*tracks_age_s,field(row,"yRel"),v,field(row,"trackId"),False,"track")
    result = dict(laneLines=lanes,roadEdges=edges,roadEdgeStds=stds,objects=objects,
                  plannedPath=points(field(model,"position"),offset))
    for i, k in ((1,"leftLane"),(2,"rightLane")):
        result[k] = lanes[i]["points"] if i < len(lanes) and lanes[i]["probability"] >= .5 else []
    for k in ("leftBlindspot","rightBlindspot"):
        flag = field(car,k)
        if isinstance(flag,bool): result[k] = flag
    return result
