{{flutter_js}}
{{flutter_build_config}}

// 서비스 워커를 쓰지 않는다 (2026-10-08): 예전 앱 파일을 저장해 두고 먼저 보여 줘서, 배포해도 새로고침으로 새 버전이
// 뜨지 않았다 (AI 기억 → 프로필 직업 칩 수정이 사용자 브라우저에 닿지 않음). 예전에 등록된 서비스 워커·캐시는 지운다.
// 시연·재난 정보 앱이라 오프라인 캐시보다 항상 최신 화면이 중요하다. deploy/push_web.sh 가 서비스 워커 파일도 자기 삭제판으로 바꾼다
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then((rs) => rs.forEach((r) => r.unregister()));
}
if (window.caches) {
  caches.keys().then((ks) => ks.forEach((k) => caches.delete(k)));
}
_flutter.loader.load();
