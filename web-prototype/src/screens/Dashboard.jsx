import { C, LV } from '../tokens.js';
import { LATEST_MSG, WARNINGS, METRICS, SHELTERS, BASE_DIST, MOVE_OPTS, CUR_PLACE } from '../data.js';
import { Icon, Circle } from '../components/ui.jsx';

const card = { background: '#FFFFFF', borderRadius: 32, padding: '28px 32px', display: 'flex', flexDirection: 'column' };
const popover = { position: 'absolute', left: 0, top: 'calc(100% + 10px)', background: '#FFFFFF', borderRadius: 28, boxShadow: '0 12px 36px rgba(20,36,92,0.18)', padding: 14, display: 'flex', flexDirection: 'column', gap: 8, zIndex: 5 };
const pillBtn = { display: 'flex', alignItems: 'center', gap: 4, whiteSpace: 'nowrap', fontSize: 17, fontWeight: 700, color: C.ink, background: C.bg, border: 'none', borderRadius: 999, padding: '6px 10px 6px 12px', cursor: 'pointer' };

export function routeInfo(s) {
  const placeNames = { home: '집', cur: '현위치', mine: '내 장소' };
  const xp = s.from[0] === 'x' ? s.extraPlaces[+s.from.slice(1)] : null;
  const fromName = s.from === 'custom' ? s.customPlace : xp ? xp.name : (placeNames[s.from] || '현위치');
  const baseDist = BASE_DIST[s.from] ?? 1.0; // 직접 입력 · 추가 장소는 1.0km로 고정
  const totalDist = baseDist + SHELTERS[s.shelter].off;
  return { fromName, baseDist, totalDist };
}

function OptionRow({ on, icon, label, sub, right, onClick }) {
  return (
    <button onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 12, borderRadius: 20, border: 'none', background: on ? C.navy : '#FFFFFF', color: on ? '#FFFFFF' : C.ink, cursor: 'pointer', textAlign: 'left' }}>
      <Circle size={40} bg={on ? 'rgba(255,255,255,0.16)' : C.tint}><Icon n={icon} size={22} /></Circle>
      <span style={{ flex: right ? 1 : undefined, display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
        <span style={{ fontSize: 19, fontWeight: 800 }}>{label}</span>
        <span style={{ fontSize: 14, opacity: 0.8 }}>{sub}</span>
      </span>
      {right && <span style={{ fontSize: 16, fontWeight: 700, whiteSpace: 'nowrap' }}>{right}</span>}
    </button>
  );
}

function RouteBar({ s, set }) {
  const { fromName, baseDist, totalDist } = routeInfo(s);
  const shelterName = SHELTERS[s.shelter].name;
  const setCustom = () => { const v = s.customDraft.trim(); if (v) set({ from: 'custom', customPlace: v, customDraft: '', pickerOpen: false }); };
  // 출발·도착을 바꿨으면 왼쪽 칸이 대피소 목록을 연다
  const openPlaces = st => ({ pickerOpen: !st.pickerOpen, shelterOpen: false });
  const openShelters = st => ({ shelterOpen: !st.shelterOpen, pickerOpen: false });
  const caret = open => open ? 'expand_less' : 'expand_more';
  const placeOpts = [
    ['cur', 'my_location', '현위치', '기본 설정 · GPS'],
    ['home', 'home', '집', s.home || '등록 안 됨'],
    ['mine', 'bookmark', '내 장소', s.mine || '등록 안 됨'],
    ...s.extraPlaces.map((p, i) => ['x' + i, 'bookmark', p.name, p.addr])
  ];

  return (
    <div style={{ position: 'absolute', left: 16, top: 16, maxWidth: 'calc(100% - 32px)', background: '#FFFFFF', borderRadius: 999, padding: '6px 6px 6px 18px', boxShadow: '0 6px 20px rgba(20,36,92,0.14)', display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 17, fontWeight: 700, minWidth: 0 }}>
        <button onClick={() => set(st => st.swapped ? openShelters(st) : openPlaces(st))} style={pillBtn}>
          {s.swapped ? shelterName : fromName}<Icon n={caret(s.swapped ? s.shelterOpen : s.pickerOpen)} size={20} style={{ color: C.muted }} />
        </button>
        <Icon n="arrow_forward" size={20} style={{ color: C.muted }} />
        <button onClick={() => set(st => st.swapped ? openPlaces(st) : openShelters(st))} style={pillBtn}>
          {s.swapped ? fromName : shelterName}<Icon n={caret(s.swapped ? s.pickerOpen : s.shelterOpen)} size={20} style={{ color: C.muted }} />
        </button>
      </div>
      <button onClick={() => set(st => ({ swapped: !st.swapped }))} title="출발·도착 바꾸기" style={{ width: 36, height: 36, borderRadius: '50%', border: 'none', background: C.tint, color: C.navy, cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
        <Icon n="swap_horiz" size={20} />
      </button>
      <div style={{ display: 'flex', gap: 4, background: C.tint, borderRadius: 999, padding: 3 }}>
        {MOVE_OPTS.map(([k, icon, label]) => (
          <button key={k} onClick={() => set({ mode: k })} title={label} style={{ width: 36, height: 36, borderRadius: '50%', border: 'none', background: s.mode === k ? C.navy : 'transparent', color: s.mode === k ? '#FFFFFF' : C.navy, cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <Icon n={icon} size={22} />
          </button>
        ))}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, background: C.navy, color: '#FFFFFF', borderRadius: 999, padding: '8px 16px', fontSize: 18, fontWeight: 800, whiteSpace: 'nowrap' }}>
        {(s.mode === 'walk' ? Math.round(totalDist * 15) : Math.max(2, Math.round(totalDist * 5))) + '분'}
        <span style={{ fontSize: 14, fontWeight: 600, opacity: 0.85 }}>{totalDist.toFixed(1)}km</span>
      </div>

      {s.pickerOpen && (
        <div style={{ ...popover, width: 'min(360px,calc(100vw - 200px))' }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: C.muted, padding: '4px 8px' }}>출발지 선택</div>
          {placeOpts.map(([k, icon, label, sub]) => (
            <OptionRow key={k} on={s.from === k} icon={icon} label={label} sub={sub} onClick={() => set({ from: k, pickerOpen: false })} />
          ))}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, background: C.bg, borderRadius: 999, padding: '5px 5px 5px 18px', marginTop: 4 }}>
            <Icon n="search" size={22} style={{ color: C.muted }} />
            <input value={s.customDraft} onChange={e => set({ customDraft: e.target.value })} onKeyDown={e => { if (e.key === 'Enter') setCustom(); }} placeholder="직접 입력"
              style={{ flex: 1, minWidth: 0, border: 'none', outline: 'none', background: 'transparent', fontSize: 18, color: C.ink, padding: '8px 0' }} />
            <button onClick={setCustom} style={{ fontSize: 17, fontWeight: 700, padding: '10px 18px', borderRadius: 999, border: 'none', background: C.navy, color: '#FFFFFF', cursor: 'pointer' }}>설정</button>
          </div>
        </div>
      )}
      {s.shelterOpen && (
        <div style={{ ...popover, width: 'min(380px,calc(100vw - 200px))' }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: C.muted, padding: '4px 8px' }}>대피소 선택 · 가까운 순</div>
          {SHELTERS.map((sh, i) => (
            <OptionRow key={sh.name} on={s.shelter === i} icon="home_health" label={sh.name} sub={sh.sub} right={(baseDist + sh.off).toFixed(1) + 'km'} onClick={() => set({ shelter: i, shelterOpen: false })} />
          ))}
        </div>
      )}
    </div>
  );
}

function MapCard({ s, set }) {
  const full = s.mapFull;
  const places = [['home', 'home', '집', '구룡포읍 호미로'], ['cur', 'my_location', '현위치', CUR_PLACE], ['mine', 'bookmark', '내 장소', '구룡포 시장']];
  return (
    <div style={{ background: '#FFFFFF', borderRadius: 32, padding: 16, display: 'grid', gridTemplateColumns: 'minmax(0,1fr) 260px', gap: 16, minHeight: 480 }}>
      <div style={{ position: full ? 'fixed' : 'relative', inset: full ? 0 : 'auto', zIndex: full ? 60 : 'auto', borderRadius: full ? 0 : 24, overflow: 'hidden', background: 'repeating-linear-gradient(135deg,#E9EDF7 0 14px,#F3F5FA 14px 28px)', minHeight: 448 }}>
        <button onClick={() => set(st => ({ mapFull: !st.mapFull }))} title={full ? '전체 화면 닫기' : '전체 화면'} style={{ position: 'absolute', right: 16, bottom: 16, zIndex: 4, display: 'flex', alignItems: 'center', gap: 8, height: 56, padding: '0 22px 0 16px', borderRadius: 999, border: 'none', background: C.navy, color: '#FFFFFF', cursor: 'pointer', fontSize: 18, fontWeight: 800, whiteSpace: 'nowrap', boxShadow: '0 6px 20px rgba(20,36,92,0.25)' }}>
          <Icon n={full ? 'close_fullscreen' : 'open_in_full'} size={28} />{full ? '전체 화면 닫기' : '전체 화면'}
        </button>
        <div style={{ position: 'absolute', left: '50%', top: '50%', transform: 'translate(-50%,-50%)', fontFamily: 'ui-monospace,Menlo,monospace', fontSize: 16, color: C.muted, background: '#FFFFFF', padding: '8px 14px', borderRadius: 999 }}>지도 · 경로 표시 영역</div>
        <RouteBar s={s} set={set} />
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div style={{ fontSize: 18, fontWeight: 700, color: C.muted, padding: '8px 8px 2px' }}>출발지 선택</div>
        {places.map(([k, icon, label, sub]) => {
          const on = s.from === k;
          return (
            <button key={k} onClick={() => set({ from: k })} style={{ display: 'flex', alignItems: 'center', gap: 14, padding: 18, borderRadius: 24, border: 'none', background: on ? C.navy : C.bg, color: on ? '#FFFFFF' : C.ink, cursor: 'pointer', textAlign: 'left' }}>
              <Circle size={48} bg={on ? 'rgba(255,255,255,0.16)' : '#FFFFFF'}><Icon n={icon} size={28} /></Circle>
              <span style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                <span style={{ fontSize: 21, fontWeight: 800 }}>{label}</span>
                <span style={{ fontSize: 15, opacity: 0.8 }}>{sub}</span>
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}

function MetricCard({ m, onOpen }) {
  const c = LV[m.lv];
  return (
    <div className="metric-card" onClick={onOpen} style={{ background: '#FFFFFF', borderRadius: 32, padding: 28, display: 'flex', flexDirection: 'column', gap: 18, minHeight: 200, boxSizing: 'border-box', cursor: 'pointer', position: 'relative' }}>
      <span style={{ position: 'absolute', top: 20, right: 20 }}><Circle size={40} bg={C.bg} fg={C.navy}><Icon n="chevron_right" size={24} /></Circle></span>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        <div style={{ position: 'relative', width: 96, height: 96, flexShrink: 0, borderRadius: '50%', background: c.bg, color: c.fg, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon n={m.pic} size={56} />
          <span style={{ position: 'absolute', right: -4, bottom: -4, width: 40, height: 40, borderRadius: '50%', background: '#FFFFFF', color: C.navy, border: `3px solid ${c.bg}`, boxSizing: 'border-box', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <Icon n={m.icon} size={22} />
          </span>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
          <span style={{ fontSize: 22, fontWeight: 700 }}>{m.label}</span>
          <span style={{ fontSize: 18, lineHeight: 1.4, color: C.ink, textWrap: 'pretty' }}>{m.easy}</span>
        </div>
      </div>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, marginTop: 'auto' }}>
        <span style={{ fontSize: 52, fontWeight: 800, letterSpacing: '-0.02em', color: C.navy }}>{m.value}</span>
        <span style={{ fontSize: 22, fontWeight: 700, color: C.muted }}>{m.unit}</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <span style={{ fontSize: 17, fontWeight: 700, padding: '6px 14px', borderRadius: 999, background: c.bg, color: c.fg }}>{c.name}</span>
        <span style={{ fontSize: 17, color: C.muted }}>{m.note}</span>
      </div>
    </div>
  );
}

export default function Dashboard({ s, set }) {
  return (
    <div data-screen-label="대시보드" style={{ padding: '8px 40px 56px', display: 'flex', flexDirection: 'column', gap: 28 }}>
      <h1 style={{ margin: 0, fontSize: 48, fontWeight: 800, letterSpacing: '-0.02em' }}>대시보드</h1>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(min(100%,420px),1fr))', gap: 20 }}>
        <div style={{ ...card, background: C.red, color: '#FFFFFF', gap: 20, boxShadow: '0 10px 30px rgba(215,49,43,0.3)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
            <Circle size={48} bg="#FFFFFF" fg={C.red}><Icon n="sms" size={28} /></Circle>
            <h2 style={{ margin: 0, fontSize: 24, fontWeight: 800, whiteSpace: 'nowrap' }}>최근 재난문자</h2>
            <span style={{ marginLeft: 'auto', fontSize: 18, fontWeight: 700, opacity: 0.9, whiteSpace: 'nowrap' }}>{LATEST_MSG.from} · {LATEST_MSG.time}</span>
          </div>
          <div style={{ fontSize: 34, fontWeight: 800, lineHeight: 1.3, letterSpacing: '-0.01em', textWrap: 'pretty' }}>{LATEST_MSG.head}</div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
            {LATEST_MSG.actions.map(a => (
              <div key={a.text} style={{ display: 'flex', alignItems: 'center', gap: 10, background: '#FFFFFF', color: C.redDark, borderRadius: 999, padding: '12px 20px 12px 12px', fontSize: 20, fontWeight: 800, whiteSpace: 'nowrap' }}>
                <Circle size={40} bg={C.redTint}><Icon n={a.icon} size={26} /></Circle>{a.text}
              </div>
            ))}
          </div>
          <div style={{ fontSize: 17, lineHeight: 1.5, opacity: 0.85 }}>원문: {LATEST_MSG.full}</div>
        </div>
        <div style={{ ...card, gap: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <Circle size={48} bg={C.tint} fg={C.navy}><Icon n="warning" size={28} /></Circle>
            <h2 style={{ margin: 0, fontSize: 26, fontWeight: 800 }}>경보 · 주의보</h2>
            <span style={{ marginLeft: 'auto', fontSize: 17, fontWeight: 600, color: C.muted }}>기상청</span>
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>
            {WARNINGS.map(w => (
              <button key={w.label} onClick={() => set({ warnOpen: w.label })} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '14px 16px 14px 22px', borderRadius: 999, border: 'none', background: w.strong ? C.navy : C.tint, color: w.strong ? '#FFFFFF' : C.navy, fontSize: 20, fontWeight: 700, cursor: 'pointer', whiteSpace: 'nowrap' }}>
                <Icon n={w.icon} size={26} />{w.label}<Icon n="chevron_right" size={24} style={{ opacity: 0.8 }} />
              </button>
            ))}
          </div>
          <p style={{ margin: 0, fontSize: 18, color: C.muted, lineHeight: 1.5 }}>해안가와 방파제 접근을 피하고 가까운 대피소 위치를 확인하세요.</p>
        </div>
      </div>

      <MapCard s={s} set={set} />

      <h2 style={{ margin: '12px 0 0', fontSize: 32, fontWeight: 800, letterSpacing: '-0.01em' }}>지금 구룡포 날씨 <span style={{ color: C.muted, fontWeight: 600 }}>· 10분 전 갱신</span></h2>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10, marginTop: -12 }}>
        {LV.map(l => (
          <div key={l.name} style={{ display: 'flex', alignItems: 'center', gap: 8, background: '#FFFFFF', borderRadius: 999, padding: '8px 16px 8px 10px', fontSize: 18, fontWeight: 700 }}>
            <span style={{ width: 22, height: 22, borderRadius: '50%', background: l.bg }} />{l.name}
          </div>
        ))}
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(min(100%,280px),1fr))', gap: 20 }}>
        {METRICS.map(m => <MetricCard key={m.label} m={m} onOpen={() => set({ metricOpen: m.label })} />)}
      </div>
    </div>
  );
}
