def test_create_and_get_aircraft(client, make_aircraft):
    created = make_aircraft(tail_number="88-0412", airframe="F-16C")
    assert created["status"] == "FMC"
    assert created["total_flight_hours"] == 0

    fetched = client.get(f"/api/v1/aircraft/{created['id']}").json()
    assert fetched["tail_number"] == "88-0412"


def test_duplicate_tail_number_is_conflict(client, make_aircraft):
    make_aircraft(tail_number="88-0412")
    response = client.post(
        "/api/v1/aircraft",
        json={"tail_number": "88-0412", "airframe": "F-16C", "unit": "13th Fighter Squadron"},
    )
    assert response.status_code == 409
    assert response.json()["rule"] == "unique_constraint"


def test_unknown_aircraft_is_404(client):
    response = client.get("/api/v1/aircraft/999")
    assert response.status_code == 404
    assert response.json()["request_id"]


def test_invalid_payload_is_422(client):
    response = client.post(
        "/api/v1/aircraft", json={"tail_number": "x", "airframe": "F-16C", "unit": "U"}
    )
    assert response.status_code == 422


def test_list_filters_by_status_and_unit(client, make_aircraft):
    make_aircraft(status="FMC", unit="13th Fighter Squadron")
    make_aircraft(status="NMC", unit="13th Fighter Squadron")
    make_aircraft(status="NMC", unit="4th Airlift Squadron", airframe="C-17A")

    nmc = client.get("/api/v1/aircraft", params={"status": "NMC"}).json()
    assert len(nmc) == 2

    airlift_nmc = client.get(
        "/api/v1/aircraft", params={"status": "NMC", "unit": "4th Airlift Squadron"}
    ).json()
    assert [a["airframe"] for a in airlift_nmc] == ["C-17A"]


def test_patch_updates_only_supplied_fields(client, make_aircraft):
    aircraft = make_aircraft(unit="13th Fighter Squadron")
    response = client.patch(f"/api/v1/aircraft/{aircraft['id']}", json={"status": "PMC"})
    assert response.status_code == 200
    assert response.json()["status"] == "PMC"
    assert response.json()["unit"] == "13th Fighter Squadron"


def test_readiness_report_computes_mission_capable_rate(client, make_aircraft):
    for status in ("FMC", "FMC", "PMC", "NMC"):
        make_aircraft(status=status)

    report = client.get("/api/v1/readiness").json()
    assert report["total_aircraft"] == 4
    assert report["aircraft_by_status"] == {"FMC": 2, "PMC": 1, "NMC": 1}
    assert report["mission_capable_rate"] == 0.75


def test_readiness_report_empty_fleet(client):
    report = client.get("/api/v1/readiness").json()
    assert report["total_aircraft"] == 0
    assert report["mission_capable_rate"] == 0.0
