from infra_bot.state import BotState, StateStore


def test_state_round_trip(tmp_path) -> None:
    store = StateStore(tmp_path / "state.json")
    expected = BotState(
        last_run_status="success",
        reboot_required=True,
        last_slack_error="boom",
        last_run_package_details=["curl: 1 → 2"],
    )
    store.save(expected)
    actual = store.load()
    assert actual.last_run_status == "success"
    assert actual.reboot_required is True
    assert actual.last_slack_error == "boom"
    assert actual.last_run_package_details == ["curl: 1 → 2"]


def test_load_treats_empty_state_file_as_defaults(tmp_path) -> None:
    path = tmp_path / "state.json"
    path.write_text("", encoding="utf-8")
    store = StateStore(path)
    state = store.load()
    assert state.last_run_status is None
    assert state.last_run_package_details == []


def test_load_treats_invalid_json_as_defaults(tmp_path) -> None:
    path = tmp_path / "state.json"
    path.write_text("{not-json", encoding="utf-8")
    store = StateStore(path)
    state = store.load()
    assert state.last_run_status is None


def test_save_is_atomic_and_readable(tmp_path) -> None:
    path = tmp_path / "state.json"
    path.write_text("", encoding="utf-8")
    store = StateStore(path)
    store.save(BotState(last_run_status="success"))
    assert path.read_text(encoding="utf-8").strip().startswith("{")
    assert store.load().last_run_status == "success"
