import { useEffect, useRef } from 'react';
import { C } from '../tokens.js';
import { RAIN_BARS } from '../data.js';
import { replyTo } from '../logic.js';
import { Icon } from '../components/ui.jsx';

const DEMO_TRANSCRIPT = '대피소까지 가는 길 알려줘';

function Wave() {
  return (
    <span style={{ display: 'flex', alignItems: 'center', gap: 4, height: 36, flexShrink: 0 }}>
      {[0, 1, 2, 3, 4, 5].map(i => (
        <span key={i} style={{ width: 5, height: 36, borderRadius: 999, background: C.red, transformOrigin: 'center', animation: `gkWave 0.9s ease-in-out ${i * 0.12}s infinite` }} />
      ))}
    </span>
  );
}

// 브라우저 음성 인식(ko-KR). 쓸 수 없으면 시연 문장을 한 글자씩 받아쓴다.
function useSpeech(s, set) {
  const rec = useRef(null);
  const fake = useRef(null);
  const finalText = useRef('');
  const listening = useRef(false);
  listening.current = s.listening;

  const stop = () => {
    clearInterval(fake.current);
    const r = rec.current; rec.current = null;
    if (r) { r.onend = null; try { r.stop(); } catch (e) { /* 이미 멈춤 */ } }
    set(st => {
      const t = st.interim.trim();
      return { listening: false, interim: '', draft: t ? (st.draft ? st.draft.trim() + ' ' : '') + t : st.draft };
    });
  };

  const runDemo = () => {
    let i = 0;
    clearInterval(fake.current);
    fake.current = setInterval(() => {
      if (!listening.current) { clearInterval(fake.current); return; }
      i += 1; set({ interim: DEMO_TRANSCRIPT.slice(0, i) });
      if (i >= DEMO_TRANSCRIPT.length) clearInterval(fake.current);
    }, 110);
  };

  const start = () => {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    set({ listening: true, interim: '' });
    listening.current = true;
    if (!SR) { runDemo(); return; }
    const r = new SR();
    r.lang = 'ko-KR'; r.interimResults = true; r.continuous = true;
    finalText.current = '';
    r.onresult = e => {
      let interim = '';
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const res = e.results[i];
        if (res.isFinal) finalText.current += res[0].transcript; else interim += res[0].transcript;
      }
      set({ interim: (finalText.current + interim).trim() });
    };
    r.onerror = ev => {
      if (ev && /not-allowed|service-not-allowed|audio-capture|network/.test(ev.error) && !finalText.current) { r.onend = null; rec.current = null; runDemo(); }
      else stop();
    };
    r.onend = () => { if (listening.current) stop(); };
    rec.current = r;
    try { r.start(); } catch (e) { stop(); }
  };

  useEffect(() => () => {
    clearInterval(fake.current);
    if (rec.current) try { rec.current.abort(); } catch (e) { /* 무시 */ }
    set({ listening: false, interim: '' });
  }, []);

  return { start, stop };
}

function scrollToBottom(smooth) {
  const go = () => window.scrollTo({ top: document.documentElement.scrollHeight, behavior: smooth ? 'smooth' : 'auto' });
  // 긴 답변이 다 그려지기 전에 멈추지 않도록 몇 번 더 내린다
  [60, 300, 700].forEach(t => setTimeout(go, t));
}

export default function Chat({ s, set }) {
  const speech = useSpeech(s, set);
  const msgCount = useRef(s.msgs.length);

  useEffect(() => { scrollToBottom(false); }, []);
  useEffect(() => {
    if (s.msgs.length !== msgCount.current) scrollToBottom(true);
    msgCount.current = s.msgs.length;
  }, [s.msgs.length]);

  const send = text => {
    if (!text.trim()) return;
    set(st => ({ draft: '', msgs: [...st.msgs, { me: true, text }, replyTo(st, text)] }));
  };
  const toggleItem = (mi, ii) => set(st => ({ msgs: st.msgs.map((x, j) => j !== mi ? x : { ...x, list: x.list.map((y, k) => k === ii ? { ...y, done: !y.done } : y) }) }));

  const suggestions = [
    s.dis.includes('body') ? '휠체어로 갈 수 있는 대피소 알려줘' : '내 위치에서 가장 가까운 대피소 알려줘',
    '재난 후 내가 받을 수 있는 보험이 있는지 알려줘',
    '대피할 때 뭘 해야 해?'
  ];
  const roundBtn = { width: 56, height: 56, borderRadius: '50%', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' };
  const rowStat = { display: 'flex', gap: 12, justifyContent: 'space-between', whiteSpace: 'nowrap' };

  return (
    <div data-screen-label="AI 대화창" style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: '8px 40px 32px', gap: 20, maxWidth: 1100, width: '100%', boxSizing: 'border-box' }}>
      <h1 style={{ margin: 0, fontSize: 48, fontWeight: 800, letterSpacing: '-0.02em' }}>AI 대화창</h1>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 16 }}>
        <div style={{ display: 'flex', gap: 14, alignItems: 'flex-start' }}>
          <span style={{ width: 64, height: 64, borderRadius: '50%', background: '#FFFFFF', border: `3px solid ${C.navy}`, boxSizing: 'border-box', overflow: 'hidden', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
            <img src="mori-face.png" alt="모리" style={{ width: '100%', height: '100%', borderRadius: '50%', objectFit: 'cover', display: 'block' }} />
          </span>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 14, maxWidth: 560, width: '100%' }}>
            <div style={{ background: '#FFFFFF', borderRadius: '8px 28px 28px 28px', padding: '22px 26px', fontSize: 22, lineHeight: 1.55 }}>
              태풍이 구룡포에 가까워지고 있어요. 지금 계신 곳에서 가장 가까운 대피소는 <b>구룡포초등학교</b>예요. {s.mode === 'walk' ? '걸어서 약 12분 걸려요.' : '차로 약 4분 걸려요.'}
            </div>
            <div style={{ background: '#FFFFFF', borderRadius: 28, padding: 12, display: 'flex', flexDirection: 'column', gap: 12 }}>
              <div style={{ height: 200, borderRadius: 20, background: 'repeating-linear-gradient(135deg,#E9EDF7 0 12px,#F3F5FA 12px 24px)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: 'ui-monospace,Menlo,monospace', fontSize: 15, color: C.muted }}>지도 · 현위치 → 대피소</div>
              <button onClick={() => set({ screen: 'dash' })} style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10, padding: 16, borderRadius: 999, border: 'none', background: C.navy, color: '#FFFFFF', fontSize: 20, fontWeight: 700, cursor: 'pointer' }}>
                <Icon n="directions" size={26} />경로 안내 화면 보기
              </button>
            </div>
            <div style={{ background: '#FFFFFF', borderRadius: 28, padding: '22px 26px', display: 'grid', gridTemplateColumns: 'minmax(0,1fr) auto', gap: 20, alignItems: 'end' }}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                <div style={{ fontSize: 19, fontWeight: 700 }}>시간별 강수량</div>
                <div style={{ display: 'flex', alignItems: 'flex-end', gap: 10, height: 96 }}>
                  {RAIN_BARS.map(([h, t], i) => (
                    <div key={t} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, flex: 1 }}>
                      <div style={{ width: '100%', maxWidth: 30, height: h, borderRadius: 999, background: i >= 3 ? C.navy : '#B8C2DE' }} />
                      <span style={{ fontSize: 14, color: C.muted }}>{t}</span>
                    </div>
                  ))}
                </div>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10, fontSize: 19 }}>
                <div style={rowStat}><span style={{ color: C.muted }}>기온</span><b>18.5℃</b></div>
                <div style={rowStat}><span style={{ color: C.muted }}>미세먼지</span><b>좋음</b></div>
                <div style={{ ...rowStat, whiteSpace: undefined }}><span style={{ color: C.muted }}>바람</span><b>22m/s</b></div>
              </div>
            </div>
          </div>
        </div>

        {s.msgs.map((m, mi) => (
          <div key={mi} style={{ display: 'flex', justifyContent: m.me ? 'flex-end' : 'flex-start' }}>
            <div style={{ maxWidth: 560, background: m.me ? C.navy : '#FFFFFF', color: m.me ? '#FFFFFF' : C.ink, borderRadius: m.me ? '28px 8px 28px 28px' : '8px 28px 28px 28px', padding: '20px 26px', fontSize: 22, lineHeight: 1.55, display: 'flex', flexDirection: 'column', gap: 14 }}>
              <span>{m.text}</span>
              {m.list && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 18, fontWeight: 800, color: C.navy }}>
                    <Icon n="checklist" size={24} />대피 체크리스트
                    <span style={{ marginLeft: 'auto', fontSize: 16, color: C.muted, whiteSpace: 'nowrap' }}>{m.list.filter(x => x.done).length} / {m.list.length} 완료</span>
                  </div>
                  {m.list.map((it, ii) => (
                    <button key={ii} onClick={() => toggleItem(mi, ii)} style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '12px 16px 12px 12px', borderRadius: 20, border: 'none', background: C.bg, cursor: 'pointer', textAlign: 'left' }}>
                      <span style={{ width: 36, height: 36, borderRadius: '50%', background: it.done ? C.green : '#FFFFFF', border: `2px solid ${it.done ? C.green : C.navy}`, boxSizing: 'border-box', color: '#FFFFFF', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                        <Icon n="check" size={24} />
                      </span>
                      <span style={{ fontSize: 20, fontWeight: 600, lineHeight: 1.4, color: it.done ? C.muted : C.ink, textDecoration: it.done ? 'line-through' : 'none' }}>{it.t}</span>
                    </button>
                  ))}
                </div>
              )}
            </div>
          </div>
        ))}
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 17, fontWeight: 700, color: C.muted }}>
          <Icon n="auto_awesome" size={22} style={{ color: C.navy }} />내 정보에 맞춘 추천 질문
        </div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
          {suggestions.map(t => (
            <button key={t} onClick={() => send(t)} style={{ fontSize: 19, fontWeight: 600, padding: '14px 22px', borderRadius: 999, border: `2px solid ${C.navy}`, background: '#FFFFFF', color: C.navy, cursor: 'pointer' }}>{t}</button>
          ))}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: '#FFFFFF', borderRadius: 999, padding: '10px 10px 10px 28px', boxShadow: '0 4px 20px rgba(20,36,92,0.08)' }}>
          {!s.listening ? (
            <>
              <input value={s.draft} onChange={e => set({ draft: e.target.value })} onKeyDown={e => { if (e.key === 'Enter') send(s.draft); }} placeholder="무엇이든 물어보세요"
                style={{ flex: 1, minWidth: 0, border: 'none', outline: 'none', fontSize: 22, background: 'transparent', color: C.ink, padding: '10px 0' }} />
              <button onClick={speech.start} title="음성 입력" style={{ ...roundBtn, background: C.tint, color: C.navy }}><Icon n="mic" size={30} /></button>
            </>
          ) : (
            <>
              <div style={{ flex: 1, minWidth: 0, display: 'flex', alignItems: 'center', gap: 14, padding: '6px 0' }}>
                <Wave />
                <span style={{ flex: 1, minWidth: 0, fontSize: 22, color: s.interim ? C.ink : C.muted, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{s.interim || '듣고 있어요… 말씀해 주세요'}</span>
              </div>
              <button onClick={speech.stop} title="음성 인식 중지" style={{ display: 'flex', alignItems: 'center', gap: 8, height: 56, padding: '0 22px 0 16px', borderRadius: 999, border: 'none', background: C.red, color: '#FFFFFF', cursor: 'pointer', fontSize: 20, fontWeight: 800, whiteSpace: 'nowrap' }}>
                <Icon n="stop_circle" size={30} />중지
              </button>
            </>
          )}
          <button onClick={() => send(s.draft)} title="보내기" style={{ ...roundBtn, background: C.navy, color: '#FFFFFF' }}><Icon n="arrow_upward" size={30} /></button>
        </div>
      </div>
    </div>
  );
}
