import unittest
from types import SimpleNamespace as S
from scene_fields import scene_fields


def frame(**kwargs): return scene_fields(car=S(vEgo=12,leftBlindspot=True,rightBlindspot=False), **kwargs)


def radar(x=14, y=3, tid=77, present=True):
    return S(dRel=x,yRel=y,vRel=-2,present=present,radarTrackId=tid)


def model():
    line=S(x=[0,5,10], y=[-1,-2,-3], z=[1,2,3]); prediction=S(x=[14],y=[-3],v=[10],prob=.55)
    return S(position=line,laneLines=[line]*4,laneLineProbs=[.2,1,.4,.8],roadEdges=[line,line],roadEdgeStds=[.1,3],velocity=S(x=[12]),leadsV3=[prediction,prediction])


class Contract(unittest.TestCase):
    def test_geometry(self):
        r=frame(model=model(),model_age_s=0); self.assertEqual(len(r["laneLines"]),4); self.assertEqual(r["plannedPath"][1],dict(x=5,y=2,z=0)); self.assertEqual(r["roadEdgeStds"],[.1]); self.assertEqual(r["rightLane"],[])
    def test_offset_explicit_not_radar(self):
        r=frame(model=model(),model_age_s=0,radar=S(leadOne=radar()),radar_age_s=0,model_origin_forward_m=1.52); self.assertEqual(r["plannedPath"][0]["x"],-1.52); self.assertEqual(r["objects"][0]["distanceMeters"],14)
    def test_fresh_tracks(self):
        r=frame(radar=S(leadOne=radar(),leadsLeft=[radar(x=15,y=10,tid=12)]),radar_age_s=.3,tracks=S(points=[S(trackId=77,dRel=15,yRel=3,vRel=-2),S(trackId=13,dRel=20,yRel=-4,vRel=-5)]),tracks_age_s=.2)
        self.assertEqual([o["id"] for o in r["objects"]],[77,12,13]); self.assertEqual(r["objects"][2]["distanceMeters"],19); self.assertTrue(r["objects"][0]["isLead"])
    def test_stale_fallback(self):
        r=frame(model=model(),model_age_s=.4,radar=S(leadOne=radar()),radar_age_s=1.01,tracks=S(points=[radar()]),tracks_age_s=.31); self.assertEqual(len(r["objects"]),1); self.assertEqual(r["objects"][0]["source"],"vision"); self.assertEqual(r["objects"][0]["leftMeters"],3)
    def test_fresh_empty_not_replaced(self):
        self.assertEqual(frame(model=model(),model_age_s=0,radar=S(leadOne=radar(present=False)),radar_age_s=0)["objects"],[])
    def test_no_fake_side_track(self):
        r=frame(); self.assertTrue(r["leftBlindspot"]); self.assertFalse(r["rightBlindspot"]); self.assertEqual(r["objects"],[])
    def test_error_and_nan(self):
        r=frame(tracks=S(errors=S(radarFault=True),points=[radar()]),tracks_age_s=.05,radar=S(leadOne=radar(x=float("nan"))),radar_age_s=.05); self.assertEqual(r["objects"],[])
    def test_reject_reordered_and_nonfinite(self):
        m=model(); m.position=S(x=[3,float("inf"),2,4],y=[2,1,0,5]); r=frame(model=m,model_age_s=0); self.assertEqual([p["x"] for p in r["plannedPath"]],[3,4]); self.assertEqual(frame(model=m,model_age_s=-.01)["plannedPath"],[])
    def test_distinct_ids_stay_distinct(self):
        r=frame(radar=S(leadOne=radar(tid=1),leadTwo=radar(tid=2)),radar_age_s=0); self.assertEqual(len(r["objects"]),2)

if __name__ == "__main__": unittest.main()
