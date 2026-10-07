import { C, LV, MIN } from '../tokens.js';
import { WARN_DETAIL, SERIES, HOURS, EVAC, SHELTERS } from '../data.js';
import { personalWarnTips, timeScale } from '../logic.js';
import { routeInfo } from '../screens/Dashboard.jsx';
import { Icon, Circle, Modal, CloseButton, inputPill } from '../components/ui.jsx';

export function WarningModal({ s, set }) {
  const w = WARN_DETAIL[s.warnOpen];
  const close = () => set({ warnOpen: null });
  const bg = w.lv === '경보' ? C.red : C.orange;
  return (
    <Modal label="경보 상세" onClose={close} maxWidth={760}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        <Circle size={72} bg={bg} fg="#FFFFFF"><Icon n={w.icon} size={42} /></Circle>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
          <h2 style={{ margin: 0, fontSize: 34, fontWeight: 800, whiteSpace: 'nowrap' }}>{s.warnOpen}</h2>
          <span style={{ fontSize: 17, color: C.muted }}>{w.area} · {w.issued} 발표 · {w.until}</span>
        </div>
        <CloseButton onClick={close} />
      </div>
      <p style={{ margin: 0, fontSize: 22, lineHeight: 1.55, fontWeight: 600 }}>{w.meaning}</p>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(min(100%,180px),1fr))', gap: 12 }}>
        {w.facts.map(([icon, l, v]) => (
          <div key={l} style={{ background: C.bg, borderRadius: 24, padding: '16px 18px', display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 16, fontWeight: 700, color: C.muted }}><Icon n={icon} size={22} style={{ color: C.navy }} />{l}</span>
            <span style={{ fontSize: 26, fontWeight: 800, color: C.navy, whiteSpace: 'nowrap' }}>{v}</span>
          </div>
        ))}
      </div>
      <div style={{ background: C.navy, color: '#FFFFFF', borderRadius: 28, padding: '22px 24px', display: 'flex', flexDirection: 'column', gap: 14 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, fontSize: 22, fontWeight: 800 }}><Icon n="person" size={28} />나에게 맞춘 안내</div>
        {personalWarnTips(s, s.warnOpen).map(m => (
          <div key={m.t} style={{ display: 'flex', alignItems: 'flex-start', gap: 14 }}>
            <Circle size={40} bg="#FFFFFF" fg={C.navy}><Icon n={m.icon} size={24} /></Circle>
            <span style={{ fontSize: 20, lineHeight: 1.5, paddingTop: 6 }}>{m.t}</span>
          </div>
        ))}
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div style={{ fontSize: 20, fontWeight: 800 }}>모두 지켜야 할 것</div>
        {w.base.map(t => (
          <div key={t} style={{ display: 'flex', alignItems: 'center', gap: 12, background: C.bg, borderRadius: 999, padding: '12px 20px 12px 12px' }}>
            <Circle size={32} bg={bg} fg="#FFFFFF"><Icon n="priority_high" size={20} /></Circle>
            <span style={{ fontSize: 19, fontWeight: 600 }}>{t}</span>
          </div>
        ))}
      </div>
    </Modal>
  );
}

const lvOf = (v, th) => th.filter(t => v >= t).length;

export function MetricModal({ s, set }) {
  const md = SERIES[s.metricOpen];
  const close = () => set({ metricOpen: null });
  const H = 190;
  const scale = Math.max(...md.vals, md.th[2]) * 1.1;
  const peak = md.vals.indexOf(Math.max(...md.vals));
  const fmt = v => v + md.unit;
  const nowLv = LV[lvOf(md.vals[0], md.th)];
  const peakLv = LV[lvOf(md.vals[peak], md.th)];
  // 주의 · 경보 기준선
  const lines = [[1, '주의'], [2, '경보']].filter(([k]) => md.th[k] <= scale)
    .map(([k, label]) => ({ bottom: Math.round(md.th[k] / scale * H), color: LV[k + 1].bg, label: label + ' ' + fmt(md.th[k]) }));
  const chartPad = '0 104px 0 4px';

  return (
    <Modal label="날씨 상세" onClose={close} maxWidth={820}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        <Circle size={72} bg={nowLv.bg} fg={nowLv.fg}><Icon n={md.pic} size={42} /></Circle>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
          <h2 style={{ margin: 0, fontSize: 32, fontWeight: 800 }}>{s.metricOpen}</h2>
          <span style={{ fontSize: 19, color: C.muted }}>지금 <b style={{ color: C.ink }}>{fmt(md.vals[0])}</b> · {nowLv.name}</span>
        </div>
        <CloseButton onClick={close} />
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, background: peakLv.bg, color: peakLv.fg, borderRadius: 28, padding: '20px 24px' }}>
        <Icon n="schedule" size={40} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          <span style={{ fontSize: 18, fontWeight: 700, opacity: 0.9 }}>가장 심할 때</span>
          <span style={{ fontSize: 28, fontWeight: 800 }}>{HOURS[peak]} · {fmt(md.vals[peak])} ({peakLv.name})</span>
        </div>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ fontSize: 20, fontWeight: 800 }}>앞으로 8시간</div>
        <div style={{ position: 'relative', height: 240, display: 'flex', alignItems: 'flex-end', gap: 10, padding: chartPad, borderBottom: `2px solid ${C.line}` }}>
          {lines.map(l => (
            <div key={l.label} style={{ position: 'absolute', left: 0, right: 0, bottom: l.bottom, borderTop: `2px dashed ${l.color}`, pointerEvents: 'none', zIndex: 2 }}>
              <span style={{ position: 'absolute', right: 0, top: -12, width: 96, textAlign: 'right', fontSize: 14, fontWeight: 800, lineHeight: '22px', color: l.color, background: '#FFFFFF', whiteSpace: 'nowrap' }}>{l.label}</span>
            </div>
          ))}
          {md.vals.map((v, i) => (
            <div key={i} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'flex-end', gap: 6, height: '100%', position: 'relative', zIndex: 1 }}>
              <span style={{ fontSize: 16, fontWeight: 800, color: C.ink, whiteSpace: 'nowrap' }}>{v}</span>
              <div style={{ width: '100%', maxWidth: 56, height: Math.max(10, Math.round(v / scale * H)), borderRadius: '999px 999px 12px 12px', background: LV[lvOf(v, md.th)].bg }} />
            </div>
          ))}
        </div>
        <div style={{ display: 'flex', gap: 10, padding: chartPad }}>
          {HOURS.map((t, i) => (
            <span key={t} style={{ flex: 1, textAlign: 'center', fontSize: 16, fontWeight: i === 0 ? 800 : 600, color: i === 0 ? C.navy : C.muted, whiteSpace: 'nowrap' }}>{t}</span>
          ))}
        </div>
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
        {LV.map((c, i) => (
          <div key={c.name} style={{ display: 'flex', alignItems: 'center', gap: 8, background: C.bg, borderRadius: 999, padding: '8px 16px 8px 10px', fontSize: 16, fontWeight: 700, whiteSpace: 'nowrap' }}>
            <span style={{ width: 20, height: 20, borderRadius: '50%', background: c.bg }} />
            {c.name} {i === 0 ? fmt(md.th[0]) + ' 미만' : fmt(md.th[i - 1]) + ' 이상'}
          </div>
        ))}
      </div>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14, background: C.tint, borderRadius: 28, padding: '20px 24px' }}>
        <Icon n="lightbulb" size={32} style={{ color: C.navy }} />
        <span style={{ fontSize: 21, lineHeight: 1.5, fontWeight: 600 }}>{md.tip}</span>
      </div>
    </Modal>
  );
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function MailModal({ s, set }) {
  const close = () => set({ mailOpen: false });
  // 시연용: 비밀번호는 확인하지 않고 이메일 형식만 본다
  const submit = () => set(st => EMAIL_RE.test(st.mailEmail.trim()) ? { mailUser: st.mailEmail.trim(), mailOpen: false, mailPw: '' } : { mailErr: true });
  const onKey = e => { if (e.key === 'Enter') submit(); };
  return (
    <Modal label="이메일 로그인" onClose={close} maxWidth={520} z={40}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 22 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <Circle size={56} bg={C.navy} fg="#FFFFFF"><Icon n="mail" size={30} /></Circle>
          <h2 style={{ margin: 0, flex: 1, fontSize: 30, fontWeight: 800 }}>이메일로 로그인</h2>
          <CloseButton onClick={close} size={52} />
        </div>
        <label style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 19, fontWeight: 700 }}>이메일</span>
          <input type="email" value={s.mailEmail} onChange={e => set({ mailEmail: e.target.value, mailErr: false })} onKeyDown={onKey} placeholder="example@email.com"
            style={{ ...inputPill, borderColor: s.mailErr ? C.red : C.line }} />
        </label>
        <label style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 19, fontWeight: 700 }}>비밀번호</span>
          <input type="password" value={s.mailPw} onChange={e => set({ mailPw: e.target.value })} onKeyDown={onKey} placeholder="비밀번호 입력" style={inputPill} />
        </label>
        {s.mailErr && <span style={{ fontSize: 17, fontWeight: 600, color: C.red, paddingLeft: 12 }}>이메일 주소를 다시 확인해 주세요.</span>}
        <button onClick={submit} style={{ fontSize: 24, fontWeight: 800, padding: 20, borderRadius: 999, border: 'none', background: C.navy, color: '#FFFFFF', cursor: 'pointer' }}>로그인</button>
      </div>
    </Modal>
  );
}

// 대피 필요 알림: 대피 완료 / 대피 중 / 도움 필요. 고르면 바로 닫힌다.
export function EvacModal({ s, set, tw, pings }) {
  const sc = timeScale(tw);
  const simEl = s.askStart ? Math.max(0, (s.now - s.askStart) * sc) : 0;
  const remainMs = Math.max(0, 10 * MIN - simEl);
  const remainTxt = `${Math.floor(remainMs / MIN)}분 ${String(Math.floor(remainMs % MIN / 1000)).padStart(2, '0')}초`;
  const { totalDist } = routeInfo(s);
  const pick = k => {
    const now = Date.now();
    set({ evacStatus: k, evacAt: now, evacOpen: false, askStart: null, recheck: false, crewCalledAt: null,
      nextCheckAt: k === 'moving' ? now + 10 * MIN / sc : null });
  };
  const noWrap = { whiteSpace: 'nowrap' };

  return (
    <div data-screen-label="대피 알림" style={{ position: 'fixed', inset: 0, zIndex: 50, background: 'rgba(14,24,56,0.6)', display: 'flex', alignItems: 'flex-start', justifyContent: 'center', padding: 24, boxSizing: 'border-box', overflowY: 'auto' }}>
      <div style={{ width: '100%', maxWidth: 640, margin: 'auto', background: '#FFFFFF', borderRadius: 36, padding: '28px 28px 24px', boxSizing: 'border-box', display: 'flex', flexDirection: 'column', gap: 18 }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10, textAlign: 'center' }}>
          <Circle size={72} bg={C.red} fg="#FFFFFF"><Icon n="directions_run" size={46} /></Circle>
          <div style={{ fontSize: 17, fontWeight: 700, color: C.red, ...noWrap }}>대피 필요 · {s.demoReplay ? '힌남노 시연 · 해안 저지대' : '태풍 · 해안 저지대'}</div>
          <h2 style={{ margin: 0, fontSize: 'clamp(26px,3.6vw,36px)', fontWeight: 800, lineHeight: 1.25, letterSpacing: '-0.02em', display: 'flex', flexDirection: 'column' }}>
            <span style={noWrap}>지금 계신 곳은 위험해요.</span>
            <span style={noWrap}>대피소로 이동하세요.</span>
          </h2>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, fontSize: 19, fontWeight: 600, color: C.muted, ...noWrap }}>
            <Icon n="home_health" size={24} style={{ color: C.navy }} />
            <span>{SHELTERS[s.shelter].name} · {totalDist.toFixed(1)}km</span>
          </div>
        </div>
        {(s.recheck || pings > 1) && (
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10, background: C.orangeTint, color: C.orangeInk, borderRadius: 999, padding: '12px 20px', fontSize: 18, fontWeight: 800, ...noWrap }}>
            <Icon n="refresh" size={24} />{pings > 1 ? `다시 확인해요 · ${pings}번째 알림` : '10분이 지났어요 · 아직 대피 중이신가요?'}
          </div>
        )}
        <div style={{ fontSize: 20, fontWeight: 700, textAlign: 'center' }}>지금 상태를 알려주세요</div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, fontSize: 16, fontWeight: 600, color: C.muted, textAlign: 'center' }}>
          <Icon n="timer" size={20} style={{ color: C.red }} /><span>응답이 없으면 {remainTxt} 뒤 방재단에 연락해요</span>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {['done', 'moving', 'help'].map(k => {
            const e = EVAC[k], help = k === 'help';
            return (
              <button key={k} onClick={() => pick(k)} style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '12px 24px 12px 12px', borderRadius: 999, border: 'none', background: help ? C.red : C.bg, color: help ? '#FFFFFF' : C.ink, cursor: 'pointer', textAlign: 'left' }}>
                <Circle size={56} bg={help ? '#FFFFFF' : e.bg} fg={help ? C.red : '#FFFFFF'}><Icon n={e.icon} size={34} /></Circle>
                <span style={{ display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
                  <span style={{ fontSize: 26, fontWeight: 800, ...noWrap }}>{e.label}</span>
                  <span style={{ fontSize: 16, opacity: 0.85 }}>{e.desc}</span>
                </span>
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
