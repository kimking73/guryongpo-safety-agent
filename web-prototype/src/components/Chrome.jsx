import { C } from '../tokens.js';
import { NOTIFICATIONS, EVAC, CUR_PLACE } from '../data.js';
import { hhmm } from '../logic.js';
import { Icon, Circle } from './ui.jsx';

export function navItems(s) {
  return [
    ['dash', 'grid_view', '대시보드'],
    ['chat', 'chat_bubble', 'AI 대화창'],
    ...(s.crewLogged ? [['crew', 'shield_person', '방재단 현황']] : []),
    ['user', 'person', '사용자']
  ];
}

export function SideNav({ s, set, top, bottom }) {
  return (
    <nav style={{ width: 116, flexShrink: 0, background: C.navy, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10, padding: '24px 0', position: 'sticky', top: 0, height: '100vh', boxSizing: 'border-box', overflowY: 'auto' }}>
      {top}
      {navItems(s).map(([k, icon, label]) => {
        const on = s.screen === k;
        return (
          <button key={k} onClick={() => set({ screen: k })} style={{ width: 92, flexShrink: 0, padding: '14px 0 12px', borderRadius: 24, border: 'none', background: on ? '#FFFFFF' : 'transparent', color: on ? C.navy : '#FFFFFF', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, cursor: 'pointer' }}>
            <Icon n={icon} size={34} />
            <span style={{ fontSize: 16, fontWeight: 700 }}>{label}</span>
          </button>
        );
      })}
      {bottom}
    </nav>
  );
}

export function EmergencyCall() {
  return (
    <a href="tel:119" title="119 긴급전화" style={{ marginTop: 'auto', width: 92, flexShrink: 0, padding: '16px 0 14px', borderRadius: 24, background: C.red, color: '#FFFFFF', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, textDecoration: 'none', boxSizing: 'border-box' }}>
      <Circle size={48} bg="#FFFFFF" fg={C.red}><Icon n="call" size={30} /></Circle>
      <span style={{ fontSize: 22, fontWeight: 800, lineHeight: 1 }}>119</span>
      <span style={{ fontSize: 14, fontWeight: 700 }}>긴급전화</span>
    </a>
  );
}

// 온라인 / 오프라인 표시
export function NetBadge({ on }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 18, fontWeight: 700, color: on ? C.navy : '#FFFFFF', background: on ? '#FFFFFF' : C.orange, borderRadius: 999, padding: '10px 18px', whiteSpace: 'nowrap', transition: 'background .3s,color .3s' }}>
      <Icon n={on ? 'cloud_done' : 'cloud_off'} size={24} />{on ? '온라인' : '오프라인'}
    </div>
  );
}

function Bell({ s, set }) {
  const crewNoti = s.crewCalledAt ? [{ icon: 'support_agent', kind: '방재단 연락', time: hhmm(s.crewCalledAt), text: '10분 동안 응답이 없어 방재단에 내 위치와 상태를 보냈어요.', hi: true }] : [];
  const list = [...crewNoti, ...NOTIFICATIONS];
  return (
    <div style={{ position: 'relative' }}>
      <button onClick={() => set(st => ({ bellOpen: !st.bellOpen, bellRead: true }))} title="받은 알림" style={{ position: 'relative', width: 56, height: 56, borderRadius: '50%', border: 'none', background: s.bellOpen ? C.navy : '#FFFFFF', color: s.bellOpen ? '#FFFFFF' : C.navy, cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Icon n="notifications" size={30} />
        {!s.bellRead && (
          <span style={{ position: 'absolute', top: 2, right: 0, minWidth: 24, height: 24, padding: '0 6px', boxSizing: 'border-box', borderRadius: 999, background: C.navy, color: '#FFFFFF', border: '2px solid #FFFFFF', fontSize: 14, fontWeight: 800, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{s.crewCalledAt ? 3 : 2}</span>
        )}
      </button>
      {s.bellOpen && (
        <div style={{ position: 'absolute', right: 0, top: 68, zIndex: 20, width: 'min(440px,calc(100vw - 160px))', background: '#FFFFFF', borderRadius: 28, boxShadow: '0 12px 40px rgba(20,36,92,0.18)', padding: 20, display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '4px 8px 8px' }}>
            <span style={{ fontSize: 24, fontWeight: 800 }}>받은 알림</span>
            <span style={{ fontSize: 17, fontWeight: 600, color: C.muted }}>{list.length}건</span>
          </div>
          {list.map((n, i) => (
            <div key={i} style={{ display: 'flex', gap: 14, alignItems: 'flex-start', padding: 14, borderRadius: 20, background: C.bg }}>
              <Circle size={44} bg={n.hi ? C.navy : C.tint} fg={n.hi ? '#FFFFFF' : C.navy}><Icon n={n.icon} size={24} /></Circle>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
                <div style={{ display: 'flex', gap: 10, alignItems: 'baseline' }}>
                  <span style={{ fontSize: 18, fontWeight: 800, color: C.navy }}>{n.kind}</span>
                  <span style={{ fontSize: 15, color: C.muted }}>{n.time}</span>
                </div>
                <span style={{ fontSize: 18, lineHeight: 1.45, color: C.ink }}>{n.text}</span>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export function ResidentHeader({ s, set, online, showEvacChip }) {
  const ev = s.evacStatus ? EVAC[s.evacStatus] : null;
  const chipBg = ev ? ev.bg : C.red;
  const chipLabel = ev ? (s.evacStatus === 'noresp' ? '응답 없음 · 방재단 연락됨' : ev.label) : '대피 필요';
  return (
    <header style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '20px 40px', flexWrap: 'wrap' }}>
      <NetBadge on={online} />
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 18, fontWeight: 600, color: C.muted, background: '#FFFFFF', borderRadius: 999, padding: '10px 18px 10px 12px', whiteSpace: 'nowrap' }}>
        <Icon n="my_location" size={24} style={{ color: C.navy }} />
        <span style={{ fontWeight: 800, color: C.navy }}>현재 위치</span>
        <span>{CUR_PLACE}</span>
      </div>
      <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 14, flexShrink: 0 }}>
        {showEvacChip && (
          <button onClick={() => set({ evacOpen: true })} style={{ display: 'flex', alignItems: 'center', gap: 14, fontSize: 'clamp(22px,2.6vw,32px)', fontWeight: 800, padding: '10px 56px 10px 10px', minWidth: 260, borderRadius: 999, border: '4px solid #FFFFFF', background: chipBg, color: '#FFFFFF', cursor: 'pointer', whiteSpace: 'nowrap', boxShadow: '0 8px 24px rgba(14,24,56,0.3)' }}>
            <Circle size={64} bg="#FFFFFF" fg={chipBg}><Icon n={ev ? ev.icon : 'directions_run'} size={44} /></Circle>
            {chipLabel}
          </button>
        )}
        <Bell s={s} set={set} />
      </div>
    </header>
  );
}
