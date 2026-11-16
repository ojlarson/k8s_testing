import geopandas as gpd
import pandas as pd

df = pd.read_csv("https://github.com/ua-snap/geospatial-vector-veracity/raw/main/vector_data/point/alaska_point_locations.csv")

gdf = gpd.GeoDataFrame(
    df, geometry=gpd.points_from_xy(df["longitude"], df["latitude"]), crs="EPSG:4326"
)
gdf = gdf.to_crs(3338)
gdf.to_parquet("./app/alaska_point_locations.geoparquet")

gdfp = gpd.read_parquet("./app/alaska_point_locations.geoparquet")
