import os

from fastapi import FastAPI, HTTPException

from app.community_directions import (
    Point,
    PointList,
    get_communities,
    get_con,
    get_nearest,
)

app = FastAPI()

kube_pod_name = os.getenv("KUBE_POD_NAME", "test")
app_env = os.getenv("APP_ENV", "test")

_con = get_con()


@app.get("/")
async def root():
    return {"description": "Cardinal Direction Finder for Alaska Communities",
            "pod_name": kube_pod_name,
            "app_env": app_env}


# For kubernetes
@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/communities")
def communities():
    return get_communities(_con)


def parse_coords(coords: str) -> list[Point]:
    try:
        return [
            Point(lat=float(lat), lon=float(lon))
            for lat, lon in (pair.split(",") for pair in coords.split(";"))
        ]
    except ValueError:
        raise HTTPException(400, "Use format: lat,lon;lat,lon")


@app.get("/communities/{coords}")
def community_dist(coords: "str"):
    """
    Distance and direction from nearest Community.

    Format: lat,lon;lat,lon;...

    i.e. /communities/65,-149
    """

    pts = parse_coords(coords)
    ak_comms = []
    for pt in pts:
        ak_comms.append(get_nearest(_con, pt))
    return ak_comms


@app.post("/communities/dist_from")
def community_dist_post(coords: PointList):
    """
    Distance and direction from nearest Community.
    """
    ak_comms = []
    for pt in coords.points:
        ak_comms.append(get_nearest(_con, pt))
    return ak_comms
