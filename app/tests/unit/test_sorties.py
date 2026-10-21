import pytest


def _transition(client, sortie_id, status, **extra):
    return client.post(f"/api/v1/sorties/{sortie_id}/transition", json={"status": status} | extra)


def test_full_sortie_lifecycle(client, make_aircraft, make_sortie):
    aircraft = make_aircraft()
    sortie = make_sortie(aircraft["id"], mission_type="COMBAT_AIR_PATROL").json()
    assert sortie["status"] == "SCHEDULED"

    airborne = _transition(client, sortie["id"], "AIRBORNE").json()
    assert airborne["actual_takeoff"] is not None

    landed = _transition(client, sortie["id"], "LANDED", notes="Uneventful").json()
    assert landed["status"] == "LANDED"
    assert landed["actual_landing"] is not None
    assert landed["notes"] == "Uneventful"

    after = client.get(f"/api/v1/aircraft/{aircraft['id']}").json()
    assert after["status"] == "FMC"
    assert after["total_flight_hours"] >= 0


def test_cannot_schedule_nmc_aircraft(client, make_aircraft, make_sortie):
    aircraft = make_aircraft(status="NMC")
    response = make_sortie(aircraft["id"])
    assert response.status_code == 409
    assert response.json()["rule"] == "aircraft_not_mission_capable"


def test_cannot_launch_aircraft_grounded_after_scheduling(client, make_aircraft, make_sortie):
    aircraft = make_aircraft()
    sortie = make_sortie(aircraft["id"]).json()
    client.patch(f"/api/v1/aircraft/{aircraft['id']}", json={"status": "NMC"})

    response = _transition(client, sortie["id"], "AIRBORNE")
    assert response.status_code == 409
    assert response.json()["rule"] == "aircraft_not_mission_capable"


def test_aircraft_cannot_fly_two_sorties_at_once(client, make_aircraft, make_sortie):
    aircraft = make_aircraft()
    first = make_sortie(aircraft["id"]).json()
    second = make_sortie(aircraft["id"]).json()
    _transition(client, first["id"], "AIRBORNE")

    response = _transition(client, second["id"], "AIRBORNE")
    assert response.status_code == 409
    assert response.json()["rule"] == "aircraft_already_airborne"


@pytest.mark.parametrize(
    ("path", "target"),
    [
        ([], "LANDED"),  # must take off first
        (["CANCELLED"], "AIRBORNE"),  # terminal state
        (["AIRBORNE", "LANDED"], "AIRBORNE"),  # terminal state
        (["AIRBORNE"], "CANCELLED"),  # airborne sorties abort, not cancel
    ],
)
def test_invalid_transitions_rejected(client, make_aircraft, make_sortie, path, target):
    sortie = make_sortie(make_aircraft()["id"]).json()
    for step in path:
        assert _transition(client, sortie["id"], step).status_code == 200

    response = _transition(client, sortie["id"], target)
    assert response.status_code == 409
    assert response.json()["rule"] == "invalid_status_transition"


def test_maintenance_writeup_grounds_aircraft(client, make_aircraft, make_sortie):
    aircraft = make_aircraft()
    sortie = make_sortie(aircraft["id"]).json()
    _transition(client, sortie["id"], "AIRBORNE")
    _transition(client, sortie["id"], "ABORTED", maintenance_required=True, notes="Hydraulic leak")

    grounded = client.get(f"/api/v1/aircraft/{aircraft['id']}").json()
    assert grounded["status"] == "NMC"


def test_list_sorties_filters(client, make_aircraft, make_sortie):
    a1, a2 = make_aircraft(), make_aircraft()
    make_sortie(a1["id"], mission_type="ISR")
    make_sortie(a1["id"], mission_type="TRAINING")
    make_sortie(a2["id"], mission_type="ISR")

    assert len(client.get("/api/v1/sorties", params={"aircraft_id": a1["id"]}).json()) == 2
    assert len(client.get("/api/v1/sorties", params={"mission_type": "ISR"}).json()) == 2
    assert len(client.get("/api/v1/sorties", params={"status": "AIRBORNE"}).json()) == 0


def test_rule_violations_are_counted_in_metrics(client, make_aircraft, make_sortie):
    make_sortie(make_aircraft(status="NMC")["id"])
    body = client.get("/metrics").text
    assert (
        'sortie_tracker_business_rule_violations_total{rule="aircraft_not_mission_capable"}' in body
    )
