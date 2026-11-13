
from app import app


def test_home():
    client = app.test_client()
    response = client.get("/")
    assert response.status_code == 200
    assert b"DevOps Server Monitoring App" in response.data


def test_health():
    client = app.test_client()
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json["status"] == "UP"


def test_info():
    client = app.test_client()
    response = client.get("/info")

    assert response.status_code == 200
    assert "hostname" in response.json
    assert "python_version" in response.json
