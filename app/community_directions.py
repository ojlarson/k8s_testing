import duckdb
import pandas as pd
from pydantic import BaseModel, Field

DIRECTIONS = [
    "N",
    "NNE",
    "NE",
    "ENE",
    "E",
    "ESE",
    "SE",
    "SSE",
    "S",
    "SSW",
    "SW",
    "WSW",
    "W",
    "WNW",
    "NW",
    "NNW",
]
CORNERS = [x * (360 / 16) for x in list(range(17))]

DIRECTION_RANGES = {}
for i in range(len(DIRECTIONS)):
    if CORNERS[i] + CORNERS[i - 1] == 360:
        t1 = (CORNERS[i - 1] + CORNERS[i - 2]) / 2
    else:
        t1 = (CORNERS[i - 1] + CORNERS[i]) / 2
    t2 = (CORNERS[i] + CORNERS[i + 1]) / 2
    if t1 > t2:
        t1 = t1 - 360
    bounds = (t1, t2)
    DIRECTION_RANGES[DIRECTIONS[i]] = bounds


class Point(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class PointList(BaseModel):
    points: list[Point] = None


_con = None


def get_con():
    global _con
    if _con is None:
        _con = duckdb.connect()
        _con.execute("LOAD spatial;")
        _con.execute("SET geometry_always_xy = true")
        _con.execute("""
            CREATE TABLE ak_communities AS
            SELECT * FROM read_parquet('./app/alaska_point_locations.geoparquet')
        """)
        _con.execute("CREATE INDEX idx ON ak_communities USING RTREE (geometry);")
    return _con


def get_direction(azimuth: float):
    if azimuth < 0 or azimuth > 360:
        raise ValueError("Value must be within 0 to 360")
    if azimuth > 348.75:
        azimuth = azimuth - 360
    in_dir_range = [
        azimuth >= v[0] and azimuth < v[1] for v in DIRECTION_RANGES.values()
    ]
    direction_list = [
        direction for direction, in_range in zip(DIRECTIONS, in_dir_range) if in_range
    ]
    if len(direction_list) != 1:
        raise ValueError("Value matches multiple azimuth groups")
    return direction_list[0]


def meters_to_miles(meters):
    return meters * 0.000621371


def get_x_nearest(con, lon, lat, num_places=5) -> pd.DataFrame:
    result = con.sql(
        """
    WITH origin AS (
        SELECT ST_Transform(ST_Point($lon, $lat), 'EPSG:4326', 'EPSG:3338') AS pt
    )
    SELECT 
        name, 
        longitude, 
        latitude,
        degrees(ST_Azimuth(geometry, origin.pt)) as azimuth,
        ST_Distance(origin.pt, geometry) AS dist_m
    FROM ak_pts, origin
    ORDER BY dist_m ASC
    LIMIT $num_places;
    """,
        params={"num_places": num_places, "lon": lon, "lat": lat},
    ).df()

    result["direction"] = result["azimuth"].apply(get_direction)
    result["dist_miles"] = result["dist_m"].apply(meters_to_miles)
    return result


def get_nearest(con, Point):
    result = con.sql(
        """
    WITH origin AS (
        SELECT ST_Transform(ST_Point($lon, $lat), 'EPSG:4326', 'EPSG:3338') AS pt
    )
    SELECT 
        name, 
        longitude, 
        latitude,
        degrees(ST_Azimuth(geometry, origin.pt)) as azimuth,
        ST_Distance(origin.pt, geometry) AS dist_m
    FROM ak_communities, origin
    ORDER BY dist_m ASC
    LIMIT 1;
    """,
        params={"lon": Point.lon, "lat": Point.lat},
    ).fetchall()
    result = result[0]
    direction = get_direction(result[3])
    dist_miles = meters_to_miles(result[4])
    name = result[0]
    return {
        "direction": direction,
        "dist_miles": dist_miles,
        "name": name,
        "string": f"{round(dist_miles)} miles {direction} {name}",
    }


def get_communities(con):
    result = con.sql("SELECT name, latitude, longitude FROM ak_communities")
    return result.to_dicts()
