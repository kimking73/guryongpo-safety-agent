import { C } from '../tokens.js';
import { DIS_OPTS, MOVE_OPTS } from '../data.js';
import { toggleDis, cleanAge, blockNonDigit } from '../logic.js';
import { Icon, Circle, ChoiceChip, inputPill } from '../components/ui.jsx';

const h1 = { margin: '8px 0 0', fontSize: 44, lineHeight: 1.2, fontWeight: 800, letterSpacing: '-0.02em' };
const lead = { margin: 0, fontSize: 22, color: C.muted, lineHeight: 1.5 };
const fieldTitle = { fontSize: 20, fontWeight: 700 };
const optional = { fontWeight: 500, color: C.muted };

export default function Onboarding({ s, set }) {
  const step = s.obStep;
  const canNext = s.consentLoc && s.consentSens;
  const consents = [
    { key: 'loc', icon: 'my_location', label: '위치 정보 수집 동의', on: s.consentLoc },
    { key: 'sens', icon: 'accessible', label: '장애 정보(시각·청각·지체) 민감정보 수집 동의', on: s.consentSens }
  ];
  const fields = [['home', 'home', '집 주소', '예: 구룡포읍 호미로 12'], ['mine', 'bookmark', '내 장소', '예: 구룡포 시장, 경로당'], ['job', 'work', '직업', '예: 어업, 상점 운영']];

  const start = () => set(st => {
    const d = st.obDraft;
    return {
      onboarded: true, obStep: 1,
      mode: st.move.includes('walk') || !st.move.length ? 'walk' : 'car',
      home: d.home.trim() || st.home, mine: d.mine.trim() || st.mine, job: d.job.trim() || st.job
    };
  });

  return (
    <div data-screen-label="초기 화면" style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '40px 20px', boxSizing: 'border-box', background: C.navy }}>
      <div style={{ width: '100%', maxWidth: 760, background: '#FFFFFF', borderRadius: 36, padding: '56px 56px 48px', boxSizing: 'border-box', display: 'flex', flexDirection: 'column', gap: 40 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10 }}>
          {[1, 2].map(k => <span key={k} style={{ width: step === k ? 36 : 12, height: 12, borderRadius: 999, background: step >= k ? C.navy : C.line, transition: 'width .3s' }} />)}
        </div>

        {step === 1 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 40 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              <Circle size={64} bg={C.navy} fg="#FFFFFF"><Icon n="shield" size={34} /></Circle>
              <h1 style={h1}>구룡포 안전 비서</h1>
              <p style={lead}>나에게 맞는 대피 안내를 위해 몇 가지만 알려주세요.</p>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              {consents.map(c => (
                <button key={c.key}
                  onClick={() => set(st => c.key === 'loc' ? { consentLoc: !st.consentLoc } : { consentSens: !st.consentSens, dis: st.consentSens ? [] : st.dis })}
                  style={{ display: 'flex', alignItems: 'center', gap: 18, padding: '22px 24px', borderRadius: 24, border: `2px solid ${c.on ? C.navy : C.line}`, background: c.on ? C.tint : '#FFFFFF', cursor: 'pointer', textAlign: 'left' }}>
                  <Icon n={c.icon} size={36} style={{ color: C.navy }} />
                  <span style={{ flex: 1, fontSize: 21, fontWeight: 600, color: C.ink }}>{(c.on ? '✓ ' : '') + c.label}</span>
                  <span style={{ fontSize: 17, fontWeight: 700, color: C.navy, background: C.tint, borderRadius: 999, padding: '6px 14px' }}>필수</span>
                </button>
              ))}
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 28 }}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                <div style={fieldTitle}>나이 <span style={optional}>(선택)</span></div>
                <input type="number" min="1" max="120" inputMode="numeric" placeholder="예: 72" value={s.age}
                  onChange={e => set({ age: cleanAge(e.target.value) })} onKeyDown={blockNonDigit}
                  style={{ ...inputPill, background: undefined, border: `2px solid ${C.line}`, maxWidth: 240 }} />
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                <div style={fieldTitle}>장애 유형 <span style={optional}>(선택 · 중복 가능)</span></div>
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>
                  {DIS_OPTS.map(([k, icon, label]) => (
                    <ChoiceChip key={k} on={s.dis.includes(k)} icon={icon} label={label}
                      onClick={() => set(st => ({ ...(!st.consentSens && k !== 'none' ? { consentSens: true } : {}), ...toggleDis(st, k) }))} />
                  ))}
                </div>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                <div style={fieldTitle}>이동 수단 <span style={optional}>(선택 · 중복 가능)</span></div>
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>
                  {MOVE_OPTS.map(([k, icon, label]) => (
                    <ChoiceChip key={k} on={s.move.includes(k)} icon={icon} label={label}
                      onClick={() => set(st => ({ move: st.move.includes(k) ? st.move.filter(x => x !== k) : [...st.move, k] }))} />
                  ))}
                </div>
              </div>
            </div>
            <button onClick={() => canNext && set({ obStep: 2 })} style={{ alignSelf: 'center', fontSize: 24, fontWeight: 700, padding: '20px 72px', borderRadius: 999, border: 'none', background: canNext ? C.navy : C.grey, color: '#FFFFFF', cursor: 'pointer' }}>다음</button>
          </div>
        )}

        {step === 2 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 36 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              <Circle size={64} bg={C.navy} fg="#FFFFFF"><Icon n="home_pin" size={34} /></Circle>
              <h1 style={h1}>자주 있는 곳을 알려주세요</h1>
              <p style={lead}>입력하면 그곳에서 가장 가까운 대피소를 바로 안내해 드려요. 모두 선택 사항이에요.</p>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
              {fields.map(([k, icon, label, placeholder]) => (
                <label key={k} style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  <span style={{ display: 'flex', alignItems: 'center', gap: 10, fontSize: 20, fontWeight: 700 }}>
                    <Circle size={40} bg={C.tint} fg={C.navy}><Icon n={icon} size={24} /></Circle>{label} <span style={optional}>(선택)</span>
                  </span>
                  <input value={s.obDraft[k]} placeholder={placeholder}
                    onChange={e => { const v = e.target.value; set(st => ({ obDraft: { ...st.obDraft, [k]: v } })); }}
                    style={inputPill} />
                </label>
              ))}
            </div>
            <div style={{ display: 'flex', justifyContent: 'center', gap: 12, flexWrap: 'wrap' }}>
              <button onClick={() => set({ obStep: 1 })} style={{ fontSize: 22, fontWeight: 700, padding: '20px 36px', borderRadius: 999, border: `2px solid ${C.navy}`, background: '#FFFFFF', color: C.navy, cursor: 'pointer' }}>이전</button>
              <button onClick={start} style={{ fontSize: 24, fontWeight: 700, padding: '20px 56px', borderRadius: 999, border: 'none', background: C.navy, color: '#FFFFFF', cursor: 'pointer' }}>시작하기</button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
