"""대화 기억(단기) — 2026-10-02.

단기 기억 = LangGraph Checkpointer — InMemorySaver (사용자 결정 2026-10-02). 대화(thread_id = conversation_id) 안의
           그래프 상태 전체를 서버 메모리에만 둔다. 마지막 문답 후 CONVERSATION_TTL_MIN이 지나거나 서버가 재시작되면 사라진다
           (대화 만료·정리는 service.ChatService). 위치·건강 정보가 대화 기록째로 DB에 영구 저장되지 않는다.
사용자 정보(대화를 넘어 남는 것)는 서버 프로필(user_profiles·user_places) 하나만 쓴다 (2026-10-08 사용자 결정) —
           읽기 tools.get_user_profile, 쓰기 profile_sync.py. 예전 장기 기억(ai_memory 스키마의 LangGraph store)은
           더 이상 읽지도 쓰지도 않는다. 데이터와 계정(db/init/08_ai_memory.sh)은 그대로 남겨 둔다.
재난 데이터(위험 판정·관측값)는 기억하지 않는다 — 답변의 재난 정보는 항상 DB 최신값 (tools.py, 읽기 전용 계정).
"""

# 마지막 문답 후 이 시간이 지난 대화는 끝난 것으로 본다: 단기 기억을 지우고, 같은 대화 id로 와도 새 대화로 시작한다
# (몇 시간 전의 "거기"로 지금 질문을 해석하지 않게 + 서버 메모리 정리). 사용자 프로필은 그대로 이어진다.
CONVERSATION_TTL_MIN = 60
