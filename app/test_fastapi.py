from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_read_main():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"message": "Hello World from test"}


def test_read_healthz():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_communities():
    response = client.get("/communities")
    assert response.status_code == 200


def test_community_dist_string():
    response = client.get("/communities/65,-149")
    assert response.status_code == 200
    assert len(response.json()) == 1
    assert response.json()[0].get("string") == "9 miles NNE Old Minto"


def test_community_dist_post():
    response = client.post(
        "/communities/dist_from", json={"points": [{"lat": 65, "lon": -149}]}
    )
    assert response.status_code == 200
    assert len(response.json()) == 1
    assert response.json()[0].get("string") == "9 miles NNE Old Minto"
