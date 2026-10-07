// 화면에 쓰는 고정 데이터. 재난문자 · 수치 · 대피소 · 가구 정보는 모두 시연용 예시다.

export const SHELTERS = [
  { name: '구룡포초등학교 대피소', sub: '실내 · 수용 300명', off: 0 },
  { name: '구룡포읍 행정복지센터', sub: '실내 · 수용 120명', off: 0.2 },
  { name: '구룡포중학교 대피소', sub: '실내 · 수용 400명', off: 0.4 },
  { name: '구룡포종합사회복지관', sub: '실내 · 휠체어 접근 가능', off: 0.6 }
];

export const BASE_DIST = { cur: 0.8, home: 1.2, mine: 0.6, custom: 1.0 };

export const CUR_PLACE = '구룡포항 근처';
// 현위치(구룡포항 근처)는 해안 저지대라 항상 위험 지역으로 본다.
export const DANGER_HERE = true;

export const DIS_OPTS = [['sight', 'visibility', '시각'], ['hear', 'hearing', '청각'], ['body', 'accessible', '지체'], ['none', 'block', '해당 없음']];
export const DIS_LABEL = { sight: '시각', hear: '청각', body: '지체', none: '해당 없음' };
export const MOVE_OPTS = [['walk', 'directions_walk', '도보'], ['car', 'directions_car', '자동차']];

export const NOTIFICATIONS = [
  { icon: 'cyclone', kind: '태풍 경보', time: '14:30', text: '구룡포 일대 태풍 경보 발효. 최근접 예상 내일 오전 7시.', hi: true },
  { icon: 'sms', kind: '재난문자', time: '14:20', text: '[포항시] 해안가·방파제 접근 금지. 저지대 주민은 대피 준비 바랍니다.', hi: true },
  { icon: 'waves', kind: '풍랑 경보', time: '13:00', text: '동해남부 앞바다 풍랑 경보. 파고 5m 이상.', hi: false },
  { icon: 'sms', kind: '재난문자', time: '12:05', text: '[행정안전부] 오늘 밤부터 강풍·호우. 외출 자제, 창문 고정하세요.', hi: false },
  { icon: 'home_health', kind: '대피소 개방', time: '09:30', text: '구룡포초등학교 등 대피소 3곳 개방.', hi: false }
];

export const LATEST_MSG = {
  from: '포항시',
  time: '14:20',
  head: '태풍이 오고 있어요. 바닷가에 가지 마세요.',
  actions: [
    { icon: 'do_not_step', text: '바닷가·방파제 가지 않기' },
    { icon: 'home_health', text: '저지대 주민 대피 준비' }
  ],
  full: '[포항시] 태풍 북상, 해안가·방파제 접근 금지. 저지대 주민은 대피 준비 바랍니다.'
};

export const WARNINGS = [
  { icon: 'cyclone', label: '태풍 경보', strong: true },
  { icon: 'waves', label: '풍랑 경보', strong: true },
  { icon: 'air', label: '강풍 주의보', strong: false },
  { icon: 'rainy', label: '호우 주의보', strong: false }
];

export const WARN_DETAIL = {
  '태풍 경보': { icon: 'cyclone', lv: '경보', issued: '오늘 11:00', until: '내일 낮까지', area: '포항시 · 동해남부 앞바다',
    meaning: '태풍으로 강한 바람과 많은 비가 예상될 때 내려요. 큰 피해가 날 수 있어요.',
    facts: [['air', '최대 바람', '43m/s'], ['rainy', '예상 비', '100~200mm'], ['schedule', '가장 가까울 때', '내일 오전 7시']],
    base: ['해안가 · 방파제 · 하천 옆에 가지 않기', '창문을 닫고 창문에서 멀리 떨어지기', '대피 안내가 오면 바로 대피소로 이동하기'] },
  '풍랑 경보': { icon: 'waves', lv: '경보', issued: '오늘 13:00', until: '모레 새벽까지', area: '동해남부 앞바다',
    meaning: '바다의 바람과 파도가 매우 높을 때 내려요. 배가 다니기 위험해요.',
    facts: [['waves', '파도 높이', '5~7m'], ['air', '바다 바람', '20m/s 이상'], ['directions_boat', '선박', '출항 금지']],
    base: ['항구 · 방파제 · 갯바위에 가지 않기', '해안도로로 다니지 않기', '파도 구경하러 바닷가에 가지 않기'] },
  '강풍 주의보': { icon: 'air', lv: '주의보', issued: '오늘 12:00', until: '내일 오후까지', area: '포항시',
    meaning: '바람이 강하게 불 때 내려요. 간판이나 물건이 날아갈 수 있어요.',
    facts: [['air', '바람 세기', '14~21m/s'], ['schedule', '가장 셀 때', '오늘 17시'], ['umbrella', '우산', '쓰기 어려움']],
    base: ['화분 · 간판 · 빨래 등 날아갈 물건 치우기', '공사장 · 큰 나무 · 전봇대 옆 피하기', '꼭 필요할 때만 밖에 나가기'] },
  '호우 주의보': { icon: 'rainy', lv: '주의보', issued: '오늘 10:00', until: '내일 아침까지', area: '포항시',
    meaning: '짧은 시간에 비가 많이 올 때 내려요. 길에 물이 찰 수 있어요.',
    facts: [['rainy', '시간당 비', '30~70mm'], ['water', '하천 수위', '오르는 중'], ['schedule', '가장 많을 때', '오늘 17시']],
    base: ['지하 공간 · 지하차도에 들어가지 않기', '물이 찬 길은 걸어서 건너지 않기', '하천 옆 길로 다니지 않기'] }
};

// lv: 지금 경보 단계 (0 좋음 ~ 3 경보)
export const METRICS = [
  { icon: 'cyclone', label: '강풍', value: '22', unit: 'm/s', note: '북동풍', pic: 'air', easy: '우산이 뒤집힐 만큼 센 바람이에요', lv: 3 },
  { icon: 'rainy', label: '강우량', value: '48', unit: 'mm/h', note: '밤사이 증가', pic: 'flood', easy: '길에 물이 찰 만큼 비가 많이 와요', lv: 2 },
  { icon: 'waves', label: '파고', value: '5.2', unit: 'm', note: '해안 접근 금지', pic: 'tsunami', easy: '파도가 집 2층 높이만큼 높아요', lv: 3 },
  { icon: 'water', label: '하천 수위', value: '2.1', unit: 'm', note: '경계 2.8m', pic: 'water_damage', easy: '아직 괜찮지만 물이 불어나고 있어요', lv: 1 },
  { icon: 'masks', label: '미세 / 초미세먼지', value: '18 / 9', unit: '㎍', note: '환기 가능', pic: 'sentiment_satisfied', easy: '공기가 깨끗해요. 마스크 없어도 돼요', lv: 0 },
  { icon: 'wb_sunny', label: '자외선 지수', value: '1', unit: '', note: '흐림', pic: 'cloud', easy: '햇볕이 약해요. 모자 없어도 돼요', lv: 0 }
];

// th: [관심, 주의, 경보] 기준값
export const SERIES = {
  '강풍': { pic: 'air', unit: 'm/s', vals: [22, 24, 26, 28, 27, 24, 20, 16], th: [9, 14, 21], tip: '17시에 바람이 가장 세요. 그 전에 화분·간판을 안으로 들이고, 창문에서 떨어져 계세요.' },
  '강우량': { pic: 'flood', unit: 'mm/h', vals: [48, 55, 62, 70, 58, 40, 25, 12], th: [10, 30, 50], tip: '17시 전후로 비가 가장 많이 와요. 지하 공간과 낮은 길은 피하세요.' },
  '파고': { pic: 'tsunami', unit: 'm', vals: [5.2, 5.8, 6.4, 6.9, 6.5, 5.6, 4.8, 4.0], th: [2, 3, 5], tip: '밤늦게까지 파도가 높아요. 오늘은 항구·방파제·해안도로에 가지 마세요.' },
  '하천 수위': { pic: 'water_damage', unit: 'm', vals: [2.1, 2.3, 2.5, 2.8, 3.0, 2.9, 2.7, 2.4], th: [2.0, 2.8, 3.3], tip: '18시쯤 물이 가장 높아져요. 하천 옆 길로 다니지 마세요.' },
  '미세 / 초미세먼지': { pic: 'sentiment_satisfied', unit: '㎍', vals: [18, 16, 14, 12, 12, 13, 15, 16], th: [31, 81, 151], tip: '하루 종일 공기가 깨끗해요. 마스크 없이 다녀도 괜찮아요.' },
  '자외선 지수': { pic: 'cloud', unit: '', vals: [1, 1, 0, 0, 0, 0, 0, 0], th: [3, 6, 8], tip: '흐려서 햇볕이 약해요. 따로 준비할 것은 없어요.' }
};
export const HOURS = ['지금', '15시', '16시', '17시', '18시', '19시', '20시', '21시'];

export const RAIN_BARS = [[12, '15시'], [20, '16시'], [34, '17시'], [52, '18시'], [80, '19시'], [64, '20시']];

export const EVAC = {
  done: { icon: 'check_circle', label: '대피 완료', desc: '대피소에 도착했어요', bg: '#1E9E5A' },
  moving: { icon: 'directions_walk', label: '대피 중', desc: '지금 대피소로 가고 있어요', bg: '#EF7D1A' },
  help: { icon: 'sos', label: '도움 필요', desc: '혼자 이동하기 어려워요', bg: '#D7312B' },
  noresp: { icon: 'support_agent', label: '응답 없음', desc: '', bg: '#8A1C17' }
};

// ── 방재단 ──
export const CREW = [
  { id: 'c1', name: '김방재', area: '구룡포항 구역' },
  { id: 'c2', name: '이현장', area: '하천변 구역' },
  { id: 'c3', name: '박안전', area: '시장 구역' },
  { id: 'c4', name: '최구조', area: '삼정리 구역' },
  { id: 'me', name: '나', area: '호미로 구역' }
];
export const STEPS = ['enroute', 'visiting', 'evacuating', 'done'];
export const STEP_LB = ['출발', '방문', '대피 동행', '완료'];

// x, y: 지도 위 위치(%)
export const HOUSEHOLDS = [
  { id: 'h1', name: '김○순', age: 84, tags: ['독거노인', '거동불편'], danger: true, vuln: true, base: 'noresp', crew: null, step: null, addr: '호미로 해안가', shelter: '구룡포초등학교', x: 16, y: 30 },
  { id: 'h2', name: '박○호', age: 77, tags: ['지체장애', '휠체어'], danger: true, vuln: true, base: 'help', crew: 'c1', step: 'enroute', addr: '구룡포항 앞', shelter: '구룡포종합사회복지관', x: 30, y: 52 },
  { id: 'h3', name: '이○자', age: 81, tags: ['독거노인', '청각장애'], danger: true, vuln: true, base: 'notyet', crew: 'c2', step: 'visiting', addr: '하천변 주택', shelter: '구룡포중학교', x: 44, y: 66 },
  { id: 'h4', name: '최○식', age: 69, tags: ['시각장애'], danger: true, vuln: true, base: 'notyet', crew: 'c3', step: 'evacuating', addr: '구룡포시장 뒤', shelter: '구룡포읍 행정복지센터', x: 38, y: 34 },
  { id: 'me', name: '내 가구 (시연)', age: null, tags: [], danger: true, vuln: false, base: 'linked', crew: null, step: null, addr: '', shelter: '구룡포초등학교', x: 24, y: 42 },
  { id: 'h5', name: '정○희', age: 88, tags: ['독거노인'], danger: false, vuln: true, base: 'notyet', crew: null, step: null, addr: '병산리', shelter: '구룡포읍 행정복지센터', x: 80, y: 20 },
  { id: 'h6', name: '한○수', age: 74, tags: ['고령 부부'], danger: true, vuln: true, base: 'done', crew: 'c4', step: 'done', addr: '삼정리 해안', shelter: '구룡포중학교', x: 20, y: 76 },
  { id: 'h7', name: '윤○영', age: 35, tags: ['영유아'], danger: false, vuln: false, base: 'moving', crew: null, step: null, addr: '구평리', shelter: '구룡포중학교', x: 72, y: 74 }
];

export const MAP_SHELTERS = [['구룡포초등학교', 58, 42], ['구룡포읍 행정복지센터', 52, 26], ['구룡포중학교', 64, 60], ['구룡포종합사회복지관', 84, 46]];
