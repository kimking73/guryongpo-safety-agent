import { C } from '../tokens.js';
import { STEPS, STEP_LB, MAP_SHELTERS } from '../data.js';
import { rankHouseholds, crewName, hhmm } from '../logic.js';
import { Icon, Circle } from '../components/ui.jsx';
import { SideNav, NetBadge } from '../components/Chrome.jsx';

const ST = {
  help: { label: '도움 필요', bg: C.red },
  noresp: { label: '응답 없음', bg: C.redDeep },
  notyet: { label: '응답 없음', bg: C.redDeep },
  visit: { label: '방문 중', bg: C.navy },
  moving: { label: '대피 중', bg: C.orange },
  done: { label: '대피 완료', bg: C.green }
};

// 방재단 배정 상태
const AS = {
  unassigned: { label: '미배정', bg: C.red, order: 0 },
  enroute: { label: '가는 중', bg: C.orange, order: 1 },
  visiting: { label: '방문 중', bg: C.navy, order: 2 },
  evacuating: { label: '대피 중', bg: '#5B6585', order: 3 },
  done: { label: '대피 완료', bg: C.green, order: 4 }
};

function crewBadge(h) {
  const cn = crewName(h.crew);
  if (!h.crew) return { text: '배정 안 됨', icon: 'person_off', bg: C.redTint, fg: C.redDark };
  if (h.step === 'enroute') return { text: `${cn} 가는 중`, icon: 'directions_run', bg: C.orangeTint, fg: C.orangeInk };
  if (h.step === 'visiting') return { text: `${cn} 도착 · 확인 중`, icon: 'door_front', bg: C.tint, fg: C.navy };
  if (h.step === 'evacuating') return { text: `${cn} 대피 동행 중`, icon: 'directions_walk', bg: C.tint, fg: C.navy };
  return { text: `${cn} 대피 완료`, icon: 'check_circle', bg: '#E3F5EA', fg: '#147A44' };
}

function StepBar({ step }) {
  const sIdx = step ? STEPS.indexOf(step) : -1;
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,minmax(0,1fr))', gap: 6 }}>
      {STEP_LB.map((lb, k) => {
        const on = k <= sIdx;
        return (
          <div key={lb} style={{ display: 'flex', flexDirection: 'column', gap: 4, alignItems: 'center' }}>
            <span style={{ width: '100%', height: 8, borderRadius: 999, background: on ? (sIdx === 3 ? C.green : C.navy) : C.line, transition: 'background .4s' }} />
            <span style={{ fontSize: 13, fontWeight: 700, color: on ? C.ink : C.grey, whiteSpace: 'nowrap' }}>{lb}</span>
          </div>
        );
      })}
    </div>
  );
}

function CrewMap({ top }) {
  return (
    <div style={{ background: '#FFFFFF', borderRadius: 32, padding: 16, display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '6px 8px 0', flexWrap: 'wrap' }}>
        <h2 style={{ margin: 0, fontSize: 26, fontWeight: 800 }}>지도</h2>
        <span style={{ fontSize: 15, color: C.muted, whiteSpace: 'nowrap' }}>우선 확인 가구 · 대피소</span>
      </div>
      <div style={{ position: 'relative', height: 620, borderRadius: 24, overflow: 'hidden', background: 'repeating-linear-gradient(135deg,#E9EDF7 0 14px,#F3F5FA 14px 28px)' }}>
        <div style={{ position: 'absolute', left: '2%', top: '12%', width: '52%', height: '76%', borderRadius: '50%', background: 'rgba(215,49,43,0.12)', border: `2px dashed ${C.red}`, boxSizing: 'border-box' }} />
        <span style={{ position: 'absolute', left: '4%', top: '5%', fontSize: 15, fontWeight: 800, color: C.redDark, background: '#FFFFFF', borderRadius: 999, padding: '6px 12px', whiteSpace: 'nowrap' }}>위험지역 · 해안 저지대</span>
        <span style={{ position: 'absolute', right: 14, bottom: 14, fontFamily: 'ui-monospace,Menlo,monospace', fontSize: 13, color: C.muted, background: '#FFFFFF', borderRadius: 999, padding: '6px 12px' }}>예시 위치 · 실제 지도 연결 전</span>
        {MAP_SHELTERS.map(([n, x, y]) => (
          <span key={n} style={{ position: 'absolute', left: x + '%', top: y + '%', transform: 'translate(-50%,-50%)', display: 'flex', alignItems: 'center', gap: 6, background: '#FFFFFF', border: `3px solid ${C.navy}`, color: C.navy, borderRadius: 999, padding: '4px 12px 4px 6px', fontSize: 14, fontWeight: 800, whiteSpace: 'nowrap' }}>
            <Icon n="home_health" size={22} />{n}
          </span>
        ))}
        {top.map((h, i) => (
          <span key={h.id} title={(h.id === 'me' ? '내 가구' : h.name) + ' · ' + ST[h.pill].label} style={{ position: 'absolute', left: h.x + '%', top: h.y + '%', transform: 'translate(-50%,-50%)', width: 42, height: 42, borderRadius: '50%', background: ST[h.pill].bg, border: `3px solid ${h.id === 'me' ? '#FFD84D' : '#FFFFFF'}`, boxSizing: 'border-box', color: '#FFFFFF', fontSize: 18, fontWeight: 800, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: '0 2px 8px rgba(0,0,0,0.25)', zIndex: 2 }}>
            {i + 1}
          </span>
        ))}
      </div>
    </div>
  );
}

function PriorityList({ top }) {
  const order = ['도움 필요+장애', '도움 필요', '응답 없음+장애', '응답 없음'];
  return (
    <div style={{ background: '#FFFFFF', borderRadius: 32, padding: 24, display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}><h2 style={{ margin: 0, flex: 1, fontSize: 26, fontWeight: 800 }}>우선 확인 가구</h2></div>
      <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 6, fontSize: 15, fontWeight: 700, color: C.muted, marginTop: -4 }}>
        <span style={{ color: C.redDark, fontWeight: 800, whiteSpace: 'nowrap' }}>위험지역 안</span>
        <span style={{ whiteSpace: 'nowrap' }}>·</span>
        {order.map((t, i) => (
          <span key={t} style={{ display: 'contents' }}>
            {i > 0 && <span style={{ whiteSpace: 'nowrap' }}>›</span>}
            <span style={{ whiteSpace: 'nowrap' }}>{t}</span>
          </span>
        ))}
      </div>
      {top.length === 0 && (
        <div style={{ background: C.bg, borderRadius: 24, padding: 20, textAlign: 'center', fontSize: 19, fontWeight: 700, color: C.muted }}>위험지역 안에 급한 가구가 없어요</div>
      )}
      {top.map((h, i) => {
        const b = crewBadge(h);
        const st = ST[h.pill];
        const tags = [...(h.danger ? [{ t: '위험지역', bg: C.redTint, fg: C.redDark }] : []), ...h.tags.map(t => ({ t, bg: C.tint, fg: C.navy }))];
        return (
          <div key={h.id} style={{ display: 'flex', alignItems: 'center', gap: 14, background: C.bg, borderRadius: 24, padding: '14px 16px', textAlign: 'left' }}>
            <span style={{ width: 46, height: 46, borderRadius: '50%', background: h.tier >= 3 ? C.red : C.redDeep, color: '#FFFFFF', fontSize: 21, fontWeight: 800, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>{i + 1}</span>
            <span style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 6, minWidth: 0 }}>
              <span style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap' }}>
                <span style={{ fontSize: 21, fontWeight: 800, color: C.ink, whiteSpace: 'nowrap' }}>{h.name}</span>
                <span style={{ fontSize: 16, color: C.muted, whiteSpace: 'nowrap' }}>{h.age ? h.age + '세' : ''}</span>
                <span style={{ fontSize: 15, color: C.muted, whiteSpace: 'nowrap' }}>{h.addr}</span>
              </span>
              <span style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                {tags.map(t => <span key={t.t} style={{ fontSize: 14, fontWeight: 800, background: t.bg, color: t.fg, borderRadius: 999, padding: '4px 10px', whiteSpace: 'nowrap' }}>{t.t}</span>)}
              </span>
            </span>
            <span style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 6, flexShrink: 0 }}>
              <span style={{ fontSize: 15, fontWeight: 800, color: '#FFFFFF', background: st.bg, borderRadius: 999, padding: '7px 14px', whiteSpace: 'nowrap' }}>{st.label}</span>
              <span style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 14, fontWeight: 800, color: b.fg, background: b.bg, borderRadius: 999, padding: '5px 10px 5px 8px', whiteSpace: 'nowrap' }}>
                <Icon n={b.icon} size={16} />{b.text}
              </span>
            </span>
          </div>
        );
      })}
    </div>
  );
}

function AssignmentBoard({ list }) {
  const keyOf = h => h.crew && h.step ? h.step : (h.eff === 'done' ? null : (h.danger ? 'unassigned' : null));
  const rows = list.map((h, i) => ({ h, i, k: keyOf(h) })).filter(x => x.k).sort((a, b) => AS[a.k].order - AS[b.k].order || a.i - b.i);
  const n = k => rows.filter(x => x.k === k).length;
  return (
    <div style={{ background: '#FFFFFF', borderRadius: 32, padding: 24, display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <h2 style={{ margin: 0, flex: 1, fontSize: 26, fontWeight: 800 }}>방재단 배정 현황</h2>
        <span style={{ fontSize: 15, fontWeight: 700, color: C.muted, whiteSpace: 'nowrap' }}>배정 {rows.length - n('unassigned')}가구 · 미배정 {n('unassigned')}가구</span>
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {Object.keys(AS).map(k => (
          <span key={k} style={{ display: 'flex', alignItems: 'center', gap: 6, background: C.bg, borderRadius: 999, padding: '6px 12px 6px 8px', fontSize: 15, fontWeight: 800, color: C.ink, whiteSpace: 'nowrap' }}>
            <span style={{ width: 12, height: 12, borderRadius: '50%', background: AS[k].bg }} />{AS[k].label} {n(k)}
          </span>
        ))}
      </div>
      {rows.map(({ h, k }) => (
        <div key={h.id} style={{ display: 'flex', flexDirection: 'column', gap: 10, background: C.bg, borderRadius: 24, padding: '14px 16px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ flex: 1, display: 'flex', alignItems: 'baseline', gap: 8, minWidth: 0, flexWrap: 'wrap' }}>
              <span style={{ fontSize: 19, fontWeight: 800, whiteSpace: 'nowrap' }}>{h.name}</span>
              <span style={{ fontSize: 15, color: C.muted, whiteSpace: 'nowrap' }}>{h.addr}</span>
            </span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 15, fontWeight: 800, color: C.navy, whiteSpace: 'nowrap' }}>
              <Icon n="badge" size={18} />{h.crew ? crewName(h.crew) : '담당자 없음'}
            </span>
            <span style={{ fontSize: 14, fontWeight: 800, color: '#FFFFFF', background: AS[k].bg, borderRadius: 999, padding: '6px 12px', whiteSpace: 'nowrap' }}>{AS[k].label}</span>
          </div>
          <StepBar step={h.step} />
        </div>
      ))}
    </div>
  );
}

export default function CrewDashboard({ s, set, online }) {
  const list = rankHouseholds(s);
  const top = list.filter(h => h.tier > 0).slice(0, 5);
  const cnt = k => list.filter(h => h.eff === k || (k === 'noresp' && h.eff === 'notyet')).length;
  const counts = [['help', 'sos'], ['noresp', 'support_agent'], ['moving', 'directions_walk'], ['done', 'check_circle']];

  return (
    <div data-screen-label="방재단" style={{ display: 'flex', minHeight: '100vh' }}>
      <SideNav s={s} set={set}
        top={<>
          <Circle size={56} bg={C.red} fg="#FFFFFF" style={{ marginBottom: 4 }}><Icon n="badge" size={30} /></Circle>
          <div style={{ fontSize: 14, fontWeight: 800, color: '#FFFFFF', marginBottom: 14 }}>방재단</div>
        </>}
        bottom={
          <button onClick={() => set({ crewLogged: false, crewCode: '', screen: 'user' })} style={{ marginTop: 'auto', width: 92, flexShrink: 0, padding: '14px 0 12px', borderRadius: 24, border: '2px solid rgba(255,255,255,0.4)', background: 'transparent', color: '#FFFFFF', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, cursor: 'pointer' }}>
            <Icon n="logout" size={30} />
            <span style={{ fontSize: 15, fontWeight: 700 }}>로그아웃</span>
          </button>
        } />

      <main style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column' }}>
        <header style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '20px 40px', flexWrap: 'wrap' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 18, fontWeight: 700, color: C.navy, background: '#FFFFFF', borderRadius: 999, padding: '10px 18px', whiteSpace: 'nowrap' }}>
            <Icon n="badge" size={24} />방재단원(나) · 구룡포읍 자율방재단
          </div>
          <NetBadge on={online} />
          <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{ fontSize: 17, color: C.muted, whiteSpace: 'nowrap' }}>방금 갱신 · {hhmm(s.now)}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 8, background: C.red, color: '#FFFFFF', borderRadius: 999, padding: '10px 18px', fontSize: 17, fontWeight: 800, whiteSpace: 'nowrap' }}>
              <span style={{ width: 10, height: 10, borderRadius: '50%', background: '#FFFFFF' }} />실시간
            </span>
          </div>
        </header>

        <div data-screen-label="방재단 현황" style={{ padding: '8px 40px 56px', display: 'flex', flexDirection: 'column', gap: 24 }}>
          <h1 style={{ margin: 0, fontSize: 48, fontWeight: 800, letterSpacing: '-0.02em' }}>주민 대피 현황</h1>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(min(100%,220px),1fr))', gap: 12 }}>
            {counts.map(([k, icon]) => (
              <div key={k} style={{ background: '#FFFFFF', borderRadius: 999, padding: '12px 24px 12px 12px', display: 'flex', alignItems: 'center', gap: 12 }}>
                <Circle size={48} bg={ST[k].bg} fg="#FFFFFF"><Icon n={icon} size={28} /></Circle>
                <span style={{ flex: 1, fontSize: 20, fontWeight: 800, color: C.ink, whiteSpace: 'nowrap' }}>{ST[k].label}</span>
                <span style={{ fontSize: 40, fontWeight: 800, lineHeight: 1, color: ST[k].bg }}>{cnt(k)}</span>
              </div>
            ))}
          </div>
          <CrewMap top={top} />
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(min(100%,480px),1fr))', gap: 20, alignItems: 'start' }}>
            <PriorityList top={top} />
            <AssignmentBoard list={list} />
          </div>
        </div>
      </main>
    </div>
  );
}
