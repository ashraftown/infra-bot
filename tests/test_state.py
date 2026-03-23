from infra_bot.state import BotState, StateStore


def test_state_round_trip(tmp_path) -> None:
    store = StateStore(tmp_path / "state.json")
    expected = BotState(last_run_status="success", reboot_required=True)
    store.save(expected)
    actual = store.load()
    assert actual.last_run_status == "success"
    assert actual.reboot_required is True

