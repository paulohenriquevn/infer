"""Tests for the SGLang x vLLM comparison summary (no GPU or server needed)."""
import json

import pytest

import summarize


def turn(agent, turn_index, ttft, seconds, prompt, cached, completion=300, send=None):
    # by default turn 0 is sent at 0 s and the others well after it: steady state
    send = (0.0 if turn_index == 0 else 1_000.0 + turn_index) if send is None else send
    return {"agent": agent, "turn": turn_index, "ttft_s": ttft, "seconds": seconds, "send_s": send,
            "prompt_tokens": prompt, "cached_tokens": cached, "completion_tokens": completion}


T0 = {"agent": 0, "turn": 0, "ttft_s": 5.0, "seconds": 10.0, "send_s": 0.0,
      "prompt_tokens": 80_000, "cached_tokens": 0, "completion_tokens": 300}


def scenario(turns, errors=0):
    # every real log has turn 0 of each agent; without it the steady state never starts
    agents = {t["agent"] for t in turns}
    with_t0 = {t["agent"] for t in turns if t["turn"] == 0}
    zeros = [dict(T0, agent=a) for a in sorted(agents - with_t0)]
    return {"scenario": "agents", "status": "pass",
            "metrics": {"turn_errors": errors, "turn_log": zeros + turns}}


SLO = summarize.Slo(ttft_p95_s=5.0, tps_p50=30.0)


def test_first_turn_of_each_agent_is_left_out_of_cached_ttft():
    # Arrange: turn 0 is cold (40 s TTFT); the next ones hit the cache
    turns = [turn(0, 0, 40.0, 50.0, 80_000, 0)] + [turn(0, i, 1.0, 11.0, 80_000 + i, 79_000) for i in range(1, 5)]
    # Act
    r = summarize.evaluate_agents(scenario(turns), SLO)
    # Assert
    assert r["ttft_p95_s"] == pytest.approx(1.0)


def test_recomputed_tokens_per_turn_are_prompt_minus_cache():
    turns = [turn(0, 1, 1.0, 11.0, 10_000, 9_000), turn(0, 2, 1.0, 11.0, 12_000, 8_000)]
    r = summarize.evaluate_agents(scenario(turns), SLO)
    assert r["recomputed_p50"] == pytest.approx(2_500)
    assert r["cache_pct"] == pytest.approx(100 * 17_000 / 22_000)


def test_stream_speed_discounts_ttft():
    # 300 tokens in 10 s after the first token = 30 tok/s
    turns = [turn(0, 1, 2.0, 12.0, 1_000, 900)]
    r = summarize.evaluate_agents(scenario(turns), SLO)
    assert r["tps_p50"] == pytest.approx(30.0)


def test_level_fails_when_a_turn_errored():
    turns = [turn(0, 1, 1.0, 5.0, 1_000, 900)]
    r = summarize.evaluate_agents(scenario(turns, errors=1), SLO)
    assert not r["passes"]


def test_level_fails_when_ttft_p95_exceeds_slo():
    turns = [turn(0, i, 6.0, 10.0, 1_000, 900) for i in range(1, 4)]
    r = summarize.evaluate_agents(scenario(turns), SLO)
    assert not r["passes"]


def test_fails_loudly_when_server_does_not_report_cached_tokens():
    turns = [turn(0, 1, 1.0, 5.0, 1_000, None)]
    with pytest.raises(summarize.MissingCacheReport):
        summarize.evaluate_agents(scenario(turns), SLO)


def test_sessions_in_slo_stop_at_first_failing_level():
    # 48 passes by chance after 32 failed: it does not count
    levels = {8: True, 16: True, 32: False, 48: True}
    assert summarize.sessions_in_slo(levels) == 16


def test_sessions_in_slo_zero_when_smallest_level_fails():
    assert summarize.sessions_in_slo({8: False, 16: True}) == 0


REF = summarize.NeedleReference(errors=3, total=500)


def test_needle_passes_with_same_error_rate_as_reference():
    # Arrange: 3 errors in 500, same as the reference vLLM
    needle = {"selected_summary": {"attempted": 500, "correct": 497}}
    # Act / Assert
    assert summarize.passes_needle(needle, REF)


def test_needle_fails_when_errors_are_significantly_above_reference():
    # Arrange: 22 errors in 500 (SGLang NVFP4 with Marlin), p of about 1e-4
    needle = {"selected_summary": {"attempted": 500, "correct": 478}}
    # Act / Assert
    assert not summarize.passes_needle(needle, REF)


def test_needle_passes_when_errors_are_below_reference():
    # Arrange: one-sided test; fewer errors never fail
    needle = {"selected_summary": {"attempted": 500, "correct": 500}}
    # Act / Assert
    assert summarize.passes_needle(needle, REF)


def test_needle_without_runs_fails():
    assert not summarize.passes_needle({"selected_summary": {"attempted": 0, "correct": 0}}, REF)


def test_fisher_one_sided_matches_value_computed_by_hand():
    # 3/120 against 3/500: P(X >= 3) in the hypergeometric N=620, K=6, n=120
    from math import comb
    expected = sum(comb(120, x) * comb(500, 6 - x) for x in range(3, 7)) / comb(620, 6)
    assert summarize.fisher_one_sided(3, 120, 3, 500) == pytest.approx(expected)


def test_needle_reference_reads_errors_slash_total():
    assert summarize.NeedleReference.from_text("3/500") == REF
    with pytest.raises(ValueError):
        summarize.NeedleReference.from_text("3 of 500")


def test_engine_fails_when_needle_at_16_concurrent_fails(tmp_path):
    # Arrange: needle at 8 passes, at 16 fails (EAGLE NaN, #49881)
    (tmp_path / "engine.txt").write_text("sglang")
    ok = {"selected_summary": {"attempted": 120, "correct": 120}}
    (tmp_path / "needle.json").write_text(json.dumps(ok))
    (tmp_path / "needle-c16.json").write_text(json.dumps({"selected_summary": {"attempted": 120, "correct": 7}}))
    (tmp_path / "gsm8k.json").write_text(json.dumps(ok))
    turns = [turn(0, 1, 1.0, 11.0, 1_000, 900)]
    (tmp_path / "agents-8.json").write_text(json.dumps({"scheduler": {"scenarios": [scenario(turns)]}}))
    # Act
    r = summarize.summarize_engine(tmp_path, SLO, 7.20, REF)
    # Assert
    assert not r["needle_ok"]


def test_turn_interrupted_by_end_of_scenario_is_left_out_of_statistics():
    # Arrange: the end of the level cuts a turn; it carries no usage nor cached_tokens
    cut = dict(turn(0, 2, 30.0, 40.0, 5_000, None), stopped=True)
    turns = [turn(0, 1, 1.0, 11.0, 1_000, 900), cut]
    # Act
    r = summarize.evaluate_agents(scenario(turns), SLO)
    # Assert
    assert r["steady_turns"] == 1
    assert r["ttft_p95_s"] == pytest.approx(1.0)
    assert r["interrupted"] == 1


def test_turn_sent_before_last_first_turn_finished_is_left_out_of_steady_state():
    # Arrange: agent 1 only finishes turn 0 at 120 s; agent 0's turn 1 was sent at 30 s, stuck in the cold queue
    turns = [turn(0, 0, 5.0, 10.0, 80_000, 0, send=0.0),
             turn(1, 0, 100.0, 120.0, 80_000, 0, send=0.0),
             turn(0, 1, 90.0, 100.0, 84_000, 80_000, send=30.0),
             turn(0, 2, 1.0, 11.0, 88_000, 84_000, send=200.0)]
    # Act
    r = summarize.evaluate_agents(scenario(turns), SLO)
    # Assert
    assert r["steady_turns"] == 1
    assert r["ttft_p95_s"] == pytest.approx(1.0)
    assert r["steady_start_s"] == pytest.approx(120.0)


def test_level_without_enough_steady_state_does_not_pass():
    turns = [turn(0, 1, 1.0, 11.0, 1_000, 900)]
    r = summarize.evaluate_agents(scenario(turns), summarize.Slo(min_turns=20))
    assert not r["passes"]
    assert r["insufficient_sample"]


def test_steady_state_does_not_start_if_some_agent_did_not_finish_turn_0():
    # Arrange: 2 agents in the level, only agent 0 finished turn 0
    c = scenario([turn(0, 0, 5.0, 10.0, 80_000, 0, send=0.0), turn(0, 1, 1.0, 11.0, 84_000, 80_000, send=50.0)])
    c["metrics"]["agents"] = 2
    # Act
    r = summarize.evaluate_agents(c, SLO)
    # Assert
    assert r["steady_turns"] == 0
    assert r["steady_start_s"] is None


def test_turn_without_cached_tokens_counts_as_zero_when_server_reports_cache_on_others():
    # Arrange: SGLang omits the field when nothing came from the cache (evicted prefix)
    turns = [turn(0, 1, 1.0, 11.0, 10_000, 9_000), turn(0, 2, 60.0, 70.0, 12_000, None)]
    # Act
    r = summarize.evaluate_agents(scenario(turns), SLO)
    # Assert
    assert r["cache_pct"] == pytest.approx(100 * 9_000 / 22_000)
    assert r["recomputed_p90"] == pytest.approx(1_000 + 0.9 * (12_000 - 1_000))


def _agents_only_directory(tmp_path):
    (tmp_path / "engine.txt").write_text("vllm")
    turns = [turn(0, 1, 1.0, 11.0, 1_000, 900)]
    (tmp_path / "agents-8.json").write_text(json.dumps({"scheduler": {"scenarios": [scenario(turns)]}}))
    return tmp_path


def test_agents_only_directory_is_summarized_with_gate_marked_as_not_run(tmp_path):
    # Arrange: second run with AGENTS_ONLY=1 has no needle.json nor gsm8k.json
    directory = _agents_only_directory(tmp_path)
    # Act
    r = summarize.summarize_engine(directory, SLO, 5.61, REF)
    # Assert
    assert r["needle_ok"] is None


def test_engine_that_fails_needle_counts_zero_sessions_per_dollar(tmp_path):
    # Arrange: speed passes but the needle gate fails
    directory = _agents_only_directory(tmp_path)
    (directory / "needle.json").write_text(json.dumps({"selected_summary": {"attempted": 500, "correct": 478}}))
    (directory / "gsm8k.json").write_text(json.dumps({"selected_summary": {"attempted": 96, "correct": 96}}))
    # Act
    r = summarize.summarize_engine(directory, SLO, 5.61, REF)
    # Assert
    assert r["sessions_per_usd_h"] == 0


def test_directory_with_legacy_portuguese_file_names_is_summarized(tmp_path):
    # Arrange: result directories written before the translation use motor.txt and agentes-<N>.json
    (tmp_path / "motor.txt").write_text("vllm")
    passing = [turn(0, i, 1.0, 11.0, 1_000, 900) for i in range(1, 4)]
    for n in (8, 16):
        (tmp_path / f"agentes-{n}.json").write_text(json.dumps({"scheduler": {"scenarios": [scenario(passing)]}}))
    # Act
    r = summarize.summarize_engine(tmp_path, SLO, 5.61, REF)
    # Assert
    assert r["engine"] == "vllm"
    assert sorted(r["levels"]) == [8, 16]
    assert r["sessions_in_slo"] == 16


def test_same_level_under_legacy_and_current_names_fails_loudly(tmp_path):
    # Arrange: agents-8.json and agentes-8.json in one directory are two results for one level
    directory = _agents_only_directory(tmp_path)
    (directory / "agentes-8.json").write_text((directory / "agents-8.json").read_text())
    # Act / Assert
    with pytest.raises(ValueError, match="level 8 appears twice"):
        summarize.summarize_engine(directory, SLO, 5.61, REF)
