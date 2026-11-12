"""Behavior tests for lint_prose: run with `python3 -m pytest` from this directory."""

from lint_prose import lint


def sections(text: str) -> list[str]:
    return [f[2] for f in lint(text)]


def test_em_dash_in_prose_is_blocking():
    assert "§8" in sections("The policy — announced late — applies now.")


def test_dash_inside_code_and_urls_is_ignored():
    text = "Run `a -- b` and see https://x.dev/a—b\n```\nfoo — bar\n```\n"
    assert "§8" not in sections(text)


def test_chatbot_residue_in_both_languages():
    assert "§22" in sections("I hope this helps!")
    assert "§22" in sections("Qualquer dúvida, é só chamar.")


def test_stock_words_match_whole_words_only():
    assert "§12" in sections("We leverage the cache.")
    assert "§12" not in sections("The leverages field is a column name.")


def test_not_x_but_y_in_portuguese():
    assert "§1" in sections("Não é um bug, é uma escolha de design.")


def test_bold_label_list_item():
    assert "§19" in sections("- **Performance:** Performance improved.")


def test_title_case_heading_flagged_sentence_case_not():
    assert "§20" in sections("## Strategic Negotiations And Global Partnerships")
    assert "§20" not in sections("## Strategic negotiations and global partnerships")


def test_clean_text_has_no_findings():
    assert lint("The scheduler routes each request to the pod with the longest cached prefix.") == []
