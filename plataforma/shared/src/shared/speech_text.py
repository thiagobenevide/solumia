"""Text vs. speech for language study, shared by the backend and the worker:

- the words of a text with the position of each one;
- the time of each word in a synthesized speech (guided reading);
- the comparison between what the person read aloud and the text (correct, swapped and skipped
  words).

The output dict keys ("inicio", "fim", "estado", "certa", ...) are part of the contract with
the app.
"""

import difflib
import re
import unicodedata
from typing import Any

_WORD_PATTERN = re.compile(r"[\w’']+(?:[-‐][\w’']+)*", re.UNICODE)

LONG_PAUSE_SECONDS = 0.7
"""Seconds of silence between two words that count as a hesitation."""


def split_words(text: str) -> list[tuple[str, int, int]]:
    """(word, start, end) of each word of [text]; end is exclusive."""
    words = []
    for found in _WORD_PATTERN.finditer(text):
        words.append((found.group(), found.start(), found.end()))
    return words


def normalize_word(word: str) -> str:
    """Form used for comparison: lowercase, without accents or apostrophes (Whisper varies on
    this)."""
    decomposed = unicodedata.normalize("NFKD", word.lower())
    kept_characters = []
    for character in decomposed:
        if character.isalnum():
            kept_characters.append(character)
    return "".join(kept_characters)


def _normalize_reference(reference: list[tuple[str, int, int]]) -> list[str]:
    normalized = []
    for word, _start, _end in reference:
        normalized.append(normalize_word(word))
    return normalized


def _normalize_spoken(spoken_words: list[dict[str, Any]]) -> list[str]:
    normalized = []
    for spoken in spoken_words:
        normalized.append(normalize_word(str(spoken.get("palavra", ""))))
    return normalized


def _spoken_text(spoken: dict[str, Any]) -> str:
    return str(spoken.get("palavra", "")).strip()


def _diff_operations(
    reference: list[str], spoken: list[str]
) -> list[tuple[str, int, int, int, int]]:
    """Operations (equal/replace/insert/delete) that turn [reference] into [spoken]."""
    matcher = difflib.SequenceMatcher(None, reference, spoken, autojunk=False)
    return matcher.get_opcodes()


def _split_duration_by_length(
    reference: list[tuple[str, int, int]], duration: float
) -> list[dict[str, Any]]:
    """Without any recognized word, each word gets a share of [duration] proportional to its
    length."""
    total_length = 0
    for word, _start, _end in reference:
        total_length += len(word)
    if total_length == 0:
        total_length = 1

    timed_words = []
    current_time = 0.0
    for word, start, end in reference:
        word_end_time = current_time + duration * len(word) / total_length
        timed_words.append({
            "inicio": start,
            "fim": end,
            "t0": round(current_time, 3),
            "t1": round(word_end_time, 3),
        })
        current_time = word_end_time
    return timed_words


def _fill_time_gaps(times: list[tuple[float, float] | None], duration: float) -> None:
    """Each run of words without time splits evenly the interval between the known word before
    it and the known word after it. Changes [times] in place."""
    word_count = len(times)
    index = 0
    while index < word_count:
        if times[index] is not None:
            index += 1
            continue

        gap_end = index
        while gap_end < word_count and times[gap_end] is None:
            gap_end += 1

        gap_start_time = 0.0
        if index > 0 and times[index - 1] is not None:
            gap_start_time = times[index - 1][1]

        gap_end_time = duration
        if gap_end < word_count and times[gap_end] is not None:
            gap_end_time = times[gap_end][0]
        if gap_end_time < gap_start_time:
            gap_end_time = gap_start_time

        step = (gap_end_time - gap_start_time) / (gap_end - index)
        for position in range(index, gap_end):
            offset = position - index
            times[position] = (gap_start_time + step * offset, gap_start_time + step * (offset + 1))
        index = gap_end


def align_word_times(
    text: str, spoken_words: list[dict[str, Any]], duration: float
) -> list[dict[str, Any]]:
    """Time (t0, t1 in seconds) of each word of [text] in a speech of it.

    [spoken_words] come from Whisper (`palavra`, `inicio`, `fim`). Words it did not recognize get
    their time by interpolation; when none was recognized, the time is split by word length."""
    reference = split_words(text)
    if not reference:
        return []

    times: list[tuple[float, float] | None] = [None] * len(reference)
    normalized_reference = _normalize_reference(reference)
    normalized_spoken = _normalize_spoken(spoken_words)

    operations = _diff_operations(normalized_reference, normalized_spoken)
    for operation, ref_start, ref_end, spoken_start, spoken_end in operations:
        if operation != "equal" and operation != "replace":
            continue
        paired_count = min(ref_end - ref_start, spoken_end - spoken_start)
        for offset in range(paired_count):
            spoken = spoken_words[spoken_start + offset]
            times[ref_start + offset] = (float(spoken["inicio"]), float(spoken["fim"]))

    any_time_found = False
    for word_time in times:
        if word_time is not None:
            any_time_found = True
            break
    if not any_time_found:
        return _split_duration_by_length(reference, duration)

    _fill_time_gaps(times, duration)

    timed_words = []
    for index in range(len(reference)):
        word_time = times[index]
        if word_time is None:
            continue
        _word, start, end = reference[index]
        timed_words.append({
            "inicio": start,
            "fim": end,
            "t0": round(word_time[0], 3),
            "t1": round(word_time[1], 3),
        })
    return timed_words


def _count_long_pauses(spoken_words: list[dict[str, Any]]) -> int:
    pauses = 0
    for index in range(1, len(spoken_words)):
        previous_end = float(spoken_words[index - 1]["fim"])
        current_start = float(spoken_words[index]["inicio"])
        if current_start - previous_end > LONG_PAUSE_SECONDS:
            pauses += 1
    return pauses


def compare_reading(reference_text: str, spoken_words: list[dict[str, Any]]) -> dict[str, Any]:
    """What was read aloud ([spoken_words] from Whisper, with time and `prob`) against the text.

    Each word of the text becomes `certa` (correct), `trocada` (swapped, with what was said) or
    `omitida` (skipped); plus the extra spoken words, the accuracy, the words per minute and the
    long pauses."""
    reference = split_words(reference_text)
    normalized_reference = _normalize_reference(reference)
    normalized_spoken = _normalize_spoken(spoken_words)

    result_words: list[dict[str, Any]] = []
    for word, start, end in reference:
        result_words.append({"texto": word, "inicio": start, "fim": end, "estado": "omitida"})

    extra_words: list[str] = []
    operations = _diff_operations(normalized_reference, normalized_spoken)
    for operation, ref_start, ref_end, spoken_start, spoken_end in operations:
        if operation == "insert":
            for spoken_index in range(spoken_start, spoken_end):
                extra_words.append(_spoken_text(spoken_words[spoken_index]))
            continue
        if operation == "delete":
            continue

        ref_count = ref_end - ref_start
        spoken_count = spoken_end - spoken_start
        paired_count = min(ref_count, spoken_count)
        for offset in range(paired_count):
            spoken = spoken_words[spoken_start + offset]
            if operation == "equal":
                state = "certa"
            else:
                state = "trocada"
            result_words[ref_start + offset].update(
                estado=state,
                dita=_spoken_text(spoken),
                t0=float(spoken["inicio"]),
                t1=float(spoken["fim"]),
                prob=round(float(spoken.get("prob", 1.0)), 3),
            )

        # In a replace, the spoken words beyond the reference ones are extras.
        if operation == "replace" and spoken_count > ref_count:
            for spoken_index in range(spoken_start + ref_count, spoken_end):
                extra_words.append(_spoken_text(spoken_words[spoken_index]))

    correct_count = 0
    for result_word in result_words:
        if result_word["estado"] == "certa":
            correct_count += 1

    duration = 0.0
    if spoken_words:
        duration = float(spoken_words[-1]["fim"]) - float(spoken_words[0]["inicio"])

    non_empty_extras = []
    for extra in extra_words:
        if extra:
            non_empty_extras.append(extra)

    accuracy = 0.0
    if reference:
        accuracy = round(100 * correct_count / len(reference), 1)

    words_per_minute = 0
    if duration > 0:
        words_per_minute = round(len(spoken_words) * 60 / duration)

    return {
        "palavras": result_words,
        "extras": non_empty_extras,
        "precisao": accuracy,
        "ppm": words_per_minute,
        "pausas": _count_long_pauses(spoken_words),
        "duracao": round(duration, 1),
    }
