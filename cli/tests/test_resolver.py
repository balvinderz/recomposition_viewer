from android_compose_inspector.resolver import compose_artifact_id


def test_legacy_compose_uses_ui_artifact() -> None:
    assert compose_artifact_id("1.4.3") == "ui"


def test_kmp_compose_uses_android_artifact() -> None:
    assert compose_artifact_id("1.5.0") == "ui-android"
    assert compose_artifact_id("1.11.2") == "ui-android"
