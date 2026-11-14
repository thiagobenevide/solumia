import pytest
from capture.model import (
    Frame,
    Studio,
    follow_target,
    interpolate,
    source_rect,
    targets,
    template_items,
)


def test_default_has_screen_scene():
    studio = Studio.default()
    scene = studio.current()
    assert scene is not None
    assert [studio.source(i.source).kind for i in scene.items] == ["screen"]
    assert {s.kind for s in studio.sources} == {"screen", "microphone", "output"}


def test_json_round_trip():
    studio = Studio.default()
    studio.add_source("text", "Title", {"text": "Hi"})
    assert Studio.from_json(studio.to_json()).to_json() == studio.to_json()


def test_remove_source_leaves_scenes():
    studio = Studio.default()
    studio.remove_source(studio.sources[0].id)
    assert studio.current().items == []


def test_items_skip_audio_and_duplicates():
    studio = Studio.default()
    screen, mic = studio.sources[0].id, studio.sources[1].id
    studio.set_items(studio.current_scene, [{"source": screen, "alpha": 3, "zoom": 0.2},
                                            {"source": screen}, {"source": mic}])
    items = studio.current().items
    assert len(items) == 1 and items[0].alpha == 1.0 and items[0].zoom == 1.0


def test_config_validation():
    studio = Studio()
    studio.set_config({"width": 1081, "encoder": "nvh265"})
    assert studio.config.width == 1080
    with pytest.raises(ValueError):
        studio.set_config({"encoder": "h266"})


def test_cover_on_ultrawide_has_no_bars():
    # 2560x1080 screen inside a 16:9 item: full height, 75% of the width, following cx
    x, y, w, h = source_rect(2560 / 1080, 16 / 9, 1.0, 0.0, 0.5, "cover")
    assert (round(w, 3), h, x, y) == (0.75, 1.0, 0.0, 0.0)
    x, _, _, _ = source_rect(2560 / 1080, 16 / 9, 1.0, 1.0, 0.5, "cover")
    assert round(x, 3) == 0.25


def test_cover_square_camera_and_zoom():
    x, y, w, h = source_rect(16 / 9, 1.0, 2.0, 0.5, 0.5, "cover")
    assert round(w, 4) == round(9 / 16 / 2, 4) and h == 0.5
    assert round(x + w / 2, 4) == 0.5


def test_contain_shows_bars():
    _, y, w, h = source_rect(2560 / 1080, 16 / 9, 1.0, 0.5, 0.5, "contain")
    assert w == 1.0 and h > 1 and y < 0


def test_follow_target_dead_zone():
    assert follow_target(0.5, 0.55, 0.5) == 0.5  # inside the dead zone: stays
    assert follow_target(0.5, 0.9, 0.5) == pytest.approx(0.75)  # pushes up to the edge
    assert follow_target(0.5, 0.1, 1.2) == 0.5


def test_hidden_source_gets_zero_alpha():
    studio = Studio.default()
    studio.add_scene("Empty")
    assert targets(studio, studio.scenes[1])[studio.sources[0].id].alpha == 0


def test_transitions():
    a = {"x": Frame(0, 0, 100, 100, 1.0, 1, radius=0), "y": Frame(0, 0, 10, 10, 0.0, 0)}
    b = {"x": Frame(200, 0, 100, 100, 1.0, 1, radius=50), "y": Frame(0, 0, 10, 10, 1.0, 2)}
    assert interpolate(a, b, 0.5, "cut", 1920) == b
    mid = interpolate(a, b, 0.5, "move", 1920)
    assert mid["x"].x == 100 and mid["x"].radius == 25 and mid["x"].alpha == 1.0
    assert mid["y"].alpha == pytest.approx(0.5)
    assert interpolate(a, b, 0.5, "fade", 1920)["x"].x == 200
    assert interpolate(a, b, 0.0, "slide", 1920)["y"].x == 1920
    assert interpolate(a, b, 1.0, "zoom", 1920) == b


def test_templates_fit_canvas():
    items = template_items("screen_cam_circle", 1920, 1080, "s", "c")
    cam = items[1]
    assert cam["w"] == cam["h"] and cam["radius"] == cam["w"] / 2
    assert cam["x"] + cam["w"] < 1920 and cam["y"] + cam["h"] < 1080
    vertical = template_items("side_by_side", 1080, 1920, "s", "c")
    assert vertical[0]["w"] == 1080 and vertical[1]["y"] == vertical[0]["h"]
    assert template_items("cam_only", 1920, 1080, "s", None) == []
    with pytest.raises(ValueError):
        template_items("nope", 1920, 1080, "s", "c")
