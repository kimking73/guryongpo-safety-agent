"""LangSmith 추적 설정 — 기본은 꺼짐, 켜도 시연 모드 대화만 (실제 사용자 데이터가 밖으로 나가지 않게)."""
from guardian_ai import tracing


def _env(monkeypatch, **kw):
    for k in ("LANGSMITH_TRACING", "LANGSMITH_API_KEY", "LANGSMITH_TRACE_SCOPE"):
        monkeypatch.delenv(k, raising=False)
    for k, v in kw.items():
        monkeypatch.setenv(k, v)


def test_off_by_default_and_without_key(monkeypatch):
    _env(monkeypatch)
    assert not tracing.configured() and not tracing.allowed(demo=True)
    client = object()
    assert tracing.wrap_client(client) is client                      # 꺼져 있으면 클라이언트를 건드리지 않는다
    _env(monkeypatch, LANGSMITH_TRACING="true")                        # 키 없이 켜기만 하면 보내지 않는다
    assert not tracing.configured()


def test_default_scope_sends_demo_chats_only(monkeypatch):
    _env(monkeypatch, LANGSMITH_TRACING="true", LANGSMITH_API_KEY="k")
    assert tracing.allowed(demo=True) and not tracing.allowed(demo=False)
    _env(monkeypatch, LANGSMITH_TRACING="true", LANGSMITH_API_KEY="k", LANGSMITH_TRACE_SCOPE="all")
    assert tracing.allowed(demo=False)


def test_scope_disables_tracing_for_real_chats_even_when_enabled(monkeypatch):
    from langsmith import utils
    _env(monkeypatch, LANGSMITH_TRACING="true", LANGSMITH_API_KEY="k")
    with tracing.scope(demo=False):
        assert not utils.tracing_is_enabled()
    with tracing.scope(demo=True):
        assert utils.tracing_is_enabled()
