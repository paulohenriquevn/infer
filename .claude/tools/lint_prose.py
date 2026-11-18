#!/usr/bin/env python3
"""Flag mechanical AI-writing tells in prose (English and Brazilian Portuguese).

Usage: lint_prose.py FILE [FILE ...]   (use "-" for stdin)

Code blocks, inline code and URLs are ignored. Exit code 1 when a blocking
pattern is found (dashes §8, chatbot residue §22), 0 otherwise. Structural
tells (§1 contrasts, §2 closers, §6 triads...) need a human read; the regexes
here only catch their most common surface forms.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass

BLOCKING = {"§8", "§22"}


@dataclass(frozen=True)
class Rule:
    section: str
    message: str
    pattern: re.Pattern[str]


def _words(section: str, message: str, words: list[str]) -> Rule:
    alternation = "|".join(re.escape(w) for w in sorted(words, key=len, reverse=True))
    return Rule(section, message, re.compile(rf"(?<![\w-])(?:{alternation})(?![\w-])", re.IGNORECASE))


RULES: list[Rule] = [
    Rule("§8", "dash used as connector (em/en dash or ' -- ')", re.compile(r"[—–]|\s--\s")),
    Rule("§21", "curly quotes", re.compile(r"[“”‘’]")),
    _words("§22", "chatbot residue", [
        "great question", "certainly!", "of course!", "i hope this helps", "hope this helps",
        "let me know if", "feel free to", "would you like me to", "want me to",
        "ótima pergunta", "excelente pergunta", "claro!", "com certeza!", "espero ter ajudado",
        "espero que ajude", "fico à disposição", "qualquer dúvida", "é só chamar", "quer que eu",
    ]),
    _words("§4", "staged run-up before the point", [
        "let's dive in", "let's dive into", "let's explore", "let's break this down",
        "here's what you need to know", "here's the thing", "without further ado", "real talk",
        "vamos lá", "bora", "vamos mergulhar", "sem mais delongas", "olha só", "vou ser sincero",
        "spoiler:",
    ]),
    _words("§3", "saying that sounds deep", [
        "the real question is", "at its core", "what really matters", "at the end of the day",
        "a verdadeira questão é", "no fundo", "o que realmente importa", "no fim do dia",
        "no final das contas",
    ]),
    _words("§5", "arguing with no one", [
        "to be clear", "i'm not saying", "don't get me wrong", "a tempting approach would be",
        "one might be tempted", "para deixar claro", "não estou dizendo que",
        "uma abordagem tentadora seria", "não me entenda mal",
    ]),
    _words("§12", "stock AI word", [
        "delve", "delves", "delving", "crucial", "pivotal", "seamless", "seamlessly", "leverage",
        "leveraging", "tapestry", "testament", "showcase", "showcasing", "underscore",
        "underscores", "intricate", "intricacies", "meticulous", "meticulously", "vibrant",
        "foster", "fostering", "streamline", "empower", "unlock", "elevate", "game-changer",
        "cutting-edge", "additionally", "moreover", "furthermore", "notably",
        "alavancar", "potencializar", "impulsionar", "desbloquear", "mergulhar", "panorama",
        "jornada", "vale ressaltar", "vale destacar", "é importante notar", "cabe destacar",
        "ademais", "outrossim", "nesse sentido", "em suma", "sem sombra de dúvida",
        "divisor de águas", "de ponta", "sinergia", "holístico", "holística",
    ]),
    _words("§13", "inflated significance", [
        "plays a key role", "plays a crucial role", "marks a pivotal", "sets the stage",
        "the future looks bright", "evolving landscape", "stands as a testament",
        "desempenha um papel fundamental", "desempenha um papel crucial", "marca um momento",
        "abre caminho para", "o futuro é promissor",
    ]),
    _words("§16", "sales language", [
        "groundbreaking", "stunning", "breathtaking", "nestled", "renowned", "world-class",
        "revolucionário", "revolucionária", "de excelência", "referência no mercado", "incrível",
    ]),
    _words("§18", "avoiding is/has", [
        "serves as", "stands as", "boasts", "atua como", "se configura como", "conta com",
        "dispõe de",
    ]),
    Rule("§1", "'not X but Y' contrast", re.compile(
        r"\b(?:not (?:just|only|merely)\b[^.]{0,80}\bbut\b|it'?s not\b[^.]{0,60}\bit'?s\b"
        r"|não (?:é apenas|é só|apenas|só)\b[^.]{0,80}\b(?:mas|é)\b"
        r"|não é\b[^.,]{0,60},\s*é\b)", re.IGNORECASE)),
    Rule("§19", "bold label in list item", re.compile(r"^\s*(?:[-*+]|\d+\.)\s+\*\*[^*]+:\*\*|^\s*(?:[-*+]|\d+\.)\s+\*\*[^*]+\*\*:")),
    Rule("§20", "emoji or arrow decoration in heading or list", re.compile(
        r"^\s*(?:#{1,6}|[-*+])\s.*(?:[\U0001F300-\U0001FAFF☀-➿]|→)")),
]

_FENCE = re.compile(r"^\s*(```|~~~)")
_INLINE_CODE = re.compile(r"`[^`]*`")
_URL = re.compile(r"https?://\S+|<[^>]+>")
_TITLE_CASE_HEADING = re.compile(r"^#{1,6}\s+(.+)$")
_SMALL_WORDS = {"a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "vs", "via"}


def _mask(line: str) -> str:
    """Replace inline code and URLs with spaces so columns stay aligned."""
    for rx in (_INLINE_CODE, _URL):
        line = rx.sub(lambda m: " " * len(m.group(0)), line)
    return line


def _title_case(heading: str) -> bool:
    words = [w for w in re.findall(r"[A-Za-z][A-Za-z'-]*", heading)]
    if len(words) < 3:
        return False
    content = [w for w in words[1:] if w.lower() not in _SMALL_WORDS]
    return bool(content) and all(w[0].isupper() for w in content)


def lint(text: str) -> list[tuple[int, int, str, str, str]]:
    findings: list[tuple[int, int, str, str, str]] = []
    in_fence = False
    for lineno, raw in enumerate(text.splitlines(), start=1):
        if _FENCE.match(raw):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        line = _mask(raw)
        for rule in RULES:
            for match in rule.pattern.finditer(line):
                findings.append((lineno, match.start() + 1, rule.section, rule.message, match.group(0).strip()))
        heading = _TITLE_CASE_HEADING.match(line)
        if heading and _title_case(heading.group(1)):
            findings.append((lineno, 1, "§20", "Title Case heading", heading.group(1).strip()))
    return findings


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    blocking = 0
    for path in argv:
        text = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
        for lineno, col, section, message, snippet in lint(text):
            flag = "BLOCK" if section in BLOCKING else "warn "
            blocking += section in BLOCKING
            print(f"{path}:{lineno}:{col}: {flag} {section} {message}: {snippet!r}")
    print(f"{blocking} blocking finding(s)", file=sys.stderr)
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
