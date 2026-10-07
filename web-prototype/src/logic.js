import { MIN } from './tokens.js';
import { CREW, STEPS, HOUSEHOLDS } from './data.js';

export function initialState(tw) {
  return {
    onboarded: !tw.showOnboarding,
    obStep: 1, obDraft: { home: '', mine: '', job: '' },
    screen: tw.startScreen,
    consentLoc: true, consentSens: false, age: '',
    dis: [], move: ['walk'], job: '', home: '', mine: '',
    from: 'cur', mode: 'walk', swapped: false, shelter: 0,
    pickerOpen: false, shelterOpen: false, customPlace: '', customDraft: '', mapFull: false,
    voice: false, vibrate: false, flash: false,
    demoReplay: false, demoCrew: false,
    draft: '', msgs: [], listening: false, interim: '',
    bellOpen: false, bellRead: false,
    warnOpen: null, metricOpen: null,
    evacOpen: tw.evacNeeded, evacStatus: null, evacAt: null,
    askStart: null, nextCheckAt: null, crewCalledAt: null, recheck: false,
    now: Date.now(), online: typeof navigator !== 'undefined' ? navigator.onLine : true,
    editing: false,
    addPlaceOpen: false, newPlaceName: '', newPlaceAddr: '', newPlaceErr: false, extraPlaces: [],
    mailOpen: false, mailEmail: '', mailPw: '', mailErr: false, mailUser: '',
    crewOpen: false, crewCode: '', crewLogged: false, crewErr: false,
    hh: HOUSEHOLDS, lastSim: 0
  };
}

export const timeScale = tw => (tw.fastDemo ? 60 : 1);

// 대피가 필요한 재난 상황인지 (Tweaks 또는 시연 모드)
export const disasterActive = (s, tw) => tw.evacNeeded || s.demoReplay;

// 1초마다: 대피 재확인 · 무응답 처리 · 방재단 진행 시뮬레이션
export function tick(s, tw, now) {
  const sc = timeScale(tw);
  const up = { now };
  if (typeof navigator !== 'undefined' && navigator.onLine !== s.online) up.online = navigator.onLine;
  if (s.onboarded && disasterActive(s, tw)) {
    if (s.evacStatus === 'moving' && !s.evacOpen && s.nextCheckAt && now >= s.nextCheckAt) {
      Object.assign(up, { evacOpen: true, askStart: now, nextCheckAt: null, recheck: true });
    } else if (s.evacOpen && !s.askStart) {
      up.askStart = now;
    } else if (s.evacOpen && s.askStart && (now - s.askStart) * sc >= 10 * MIN) {
      Object.assign(up, { evacOpen: false, askStart: null, evacStatus: 'noresp', crewCalledAt: now, bellRead: false, recheck: false });
    }
  }
  if (s.crewLogged && now - (s.lastSim || 0) >= (s.demoCrew ? 2500 : 7000)) {
    up.lastSim = now;
    const hh = simStep(s);
    if (hh) up.hh = hh;
  }
  return up;
}

const busy = (hh, id) => hh.some(h => h.crew === id && h.step && h.step !== 'done');

function simStep(s) {
  if (s.demoCrew) {
    const idle = CREW.filter(c => c.id !== 'me' && !busy(s.hh, c.id));
    const target = s.hh.find(h => !h.crew && h.danger && (h.id === 'me' ? s.evacStatus !== 'done' : h.base !== 'done'));
    if (idle.length && target) return s.hh.map(h => h.id === target.id ? { ...h, crew: idle[0].id, step: 'enroute' } : h);
  }
  // 다른 단원 한 명의 진행 단계를 한 칸 넘긴다
  const active = s.hh.filter(h => h.crew && h.crew !== 'me' && h.step && h.step !== 'done');
  if (!active.length) return null;
  const id = active[Math.floor(Math.random() * active.length)].id;
  return s.hh.map(h => h.id === id ? { ...h, step: STEPS[STEPS.indexOf(h.step) + 1] } : h);
}

export const crewName = id => (CREW.find(c => c.id === id) || {}).name || '';

const DIS_TAG = { sight: '시각장애', hear: '청각장애', body: '지체장애' };
const WEIGHT = { help: 50, noresp: 48, notyet: 48, moving: 12, done: 0 };

// 가구 목록을 위급한 순서로 정렬한다.
// 위험지역 안: 도움 필요+장애 > 도움 필요 > 응답 없음+장애 > 응답 없음 (tier 4 → 1)
export function rankHouseholds(s) {
  return s.hh.map(h0 => {
    let h = h0;
    if (h.id === 'me') {
      const tags = s.dis.filter(d => DIS_TAG[d]).map(d => DIS_TAG[d]);
      if (+s.age >= 65) tags.unshift('고령');
      h = { ...h, base: s.evacStatus || 'notyet', age: s.age ? +s.age : null, tags, vuln: tags.length > 0, addr: s.home || '주소 미등록' };
    }
    const eff = h.step === 'done' ? 'done' : h.step === 'evacuating' ? 'moving' : h.base;
    const pill = h.step === 'visiting' ? 'visit' : eff;
    const dis = h.tags.some(t => /장애|휠체어|거동불편/.test(t));
    const urgent = eff === 'help' || eff === 'noresp' || eff === 'notyet';
    const tier = !h.danger || !urgent ? 0 : eff === 'help' ? (dis ? 4 : 3) : (dis ? 2 : 1);
    const score = eff === 'done' ? -1000 : tier * 1000 + (h.danger ? 100 : 0) + WEIGHT[eff] + (h.vuln ? 10 : 0) + (h.age || 0) / 100;
    return { ...h, eff, pill, score, tier };
  }).sort((a, b) => b.score - a.score);
}

export function toggleDis(s, k) {
  const dis = k === 'none' ? (s.dis.includes('none') ? [] : ['none'])
    : (s.dis.includes(k) ? s.dis.filter(x => x !== k) : [...s.dis.filter(x => x !== 'none'), k]);
  // 시각 장애 → 음성 안내, 청각 장애 → 진동 · 화면 점멸 자동 켜기
  return {
    dis,
    voice: dis.includes('sight') || (s.voice && !dis.includes('none')),
    vibrate: dis.includes('hear') || (s.vibrate && !dis.includes('none')),
    flash: dis.includes('hear') || (s.flash && !dis.includes('none'))
  };
}

// 나이 칸: 양수만, 최대 세 자리
export const cleanAge = v => String(v).replace(/[^0-9]/g, '').replace(/^0+/, '').slice(0, 3);
export const blockNonDigit = e => { if (['-', '+', 'e', 'E', '.'].includes(e.key)) e.preventDefault(); };

const FISHING = /어업|어민|선박|배/;

export function checklistFor(s) {
  const items = [
    '가스 밸브 잠그고 전기 차단기 내리기',
    '물 · 비상식량 · 상비약 · 평소 먹는 약 챙기기',
    '신분증 · 휴대폰 · 충전기 · 손전등 챙기기',
    '창문 닫고 문 잠그기',
    '가족이나 이웃에게 대피한다고 알리기',
    '해안도로 · 하천 옆 · 지하차도 피해서 이동하기'
  ];
  if (s.dis.includes('body')) items.splice(2, 0, '휠체어 · 보행기 충전 상태 확인하기');
  if (s.dis.includes('sight')) items.splice(2, 0, '흰지팡이 챙기고 음성 안내 켜 두기');
  if (s.dis.includes('hear')) items.splice(2, 0, '보청기 · 여분 배터리 챙기기');
  if (s.job && FISHING.test(s.job)) items.push('배를 단단히 묶고 항구에서 빨리 벗어나기');
  return items.map(t => ({ t, done: false }));
}

// 미리 정해 둔 예시 답변 (단어 포함 여부로만 판단)
export function replyTo(s, text) {
  if (/뭘 해야|무엇을 해야|뭐 해야|해야 할|할 일|체크리스트|준비|챙/.test(text)) {
    return { me: false, text: '대피 전에 아래 내용을 하나씩 확인해 보세요. 끝낸 항목을 누르면 체크돼요.', list: checklistFor(s) };
  }
  const reply = /대피소|가까/.test(text) ? '가장 가까운 대피소는 구룡포초등학교(0.8km)예요. 걸어서 약 12분 걸려요.'
    : /바다|해안|파도/.test(text) ? '지금 파고가 5.2m로 매우 높아요. 해안도로와 방파제에는 가지 마세요.'
    : /보험/.test(text) ? '풍수해보험에 가입되어 있다면 주택·온실·상가 피해를 보상받을 수 있어요. 어업인은 어선·양식 재해보험도 확인해 보세요. 가입하지 않았더라도 읍사무소에서 재난지원금을 신청할 수 있어요.'
    : /가방/.test(text) ? '물, 상비약, 휴대폰 충전기, 신분증, 손전등을 챙기세요.'
    : '확인했어요. 필요한 정보를 대시보드에도 표시해 둘게요.';
  return { me: false, text: reply };
}

// 경보 상세 창의 '나에게 맞춘 안내'
export function personalWarnTips(s, warnLabel) {
  const mine = [];
  const near = s.home ? `집(${s.home})` : '현위치(구룡포항 근처)';
  mine.push({ icon: 'home_health', t: `${near}에서 가장 가까운 대피소는 구룡포초등학교예요. ${s.mode === 'car' ? '차로 약 4분' : '걸어서 약 12분'} 걸려요.` });
  if (+s.age >= 65) mine.push({ icon: 'elderly', t: '어르신은 미리 대피하는 게 안전해요. 해가 지기 전에 이동하세요.' });
  if (s.dis.includes('body')) mine.push({ icon: 'accessible', t: '휠체어로 갈 수 있는 구룡포종합사회복지관을 추천해요. 혼자 이동이 어려우면 \'도움 필요\'를 눌러 방재단을 부르세요.' });
  if (s.dis.includes('sight')) mine.push({ icon: 'volume_up', t: '음성 안내를 켜 두었어요. 대피할 때는 가족이나 이웃과 함께 이동하세요.' });
  if (s.dis.includes('hear')) mine.push({ icon: 'vibration', t: '진동과 화면 깜빡임으로 알려드려요. 휴대폰을 몸에 지니고 계세요.' });
  if (s.job && FISHING.test(s.job)) mine.push({ icon: 'directions_boat', t: '배를 단단히 묶고, 바다 일은 경보가 풀릴 때까지 멈추세요.' });
  if (s.job && /상점|가게|장사|운영/.test(s.job)) mine.push({ icon: 'storefront', t: '가게 간판과 밖에 둔 물건을 안으로 들이세요.' });
  if (s.move.includes('car') && /호우|태풍/.test(warnLabel)) mine.push({ icon: 'directions_car', t: '차를 지하 주차장에 두지 말고 높은 곳으로 옮기세요.' });
  return mine;
}

export const buzz = pattern => {
  try { if (navigator.vibrate) navigator.vibrate(pattern || [400, 150, 400, 150, 600]); } catch (e) { /* 진동 미지원 */ }
};

export const hhmm = t => new Date(t).toTimeString().slice(0, 5);
