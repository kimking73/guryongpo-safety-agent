import { useState } from 'react';
import { C } from '../tokens.js';
import { Icon } from './ui.jsx';

// 시연용 설정. URL 쿼리로 처음 값을 정하고(?evac=1&fast=1 …), ?tweaks 가 있으면 이 패널이 보인다.
const PARAMS = {
  startScreen: ['start', 'dash'],
  showOnboarding: ['onboarding', true],
  evacNeeded: ['evac', false],
  fastDemo: ['fast', false],
  simOffline: ['offline', false]
};

export function readTweaks(search) {
  const q = new URLSearchParams(search);
  const tw = {};
  for (const [key, [param, def]] of Object.entries(PARAMS)) {
    const raw = q.get(param);
    if (raw === null) tw[key] = def;
    else if (typeof def === 'boolean') tw[key] = raw === '1' || raw === 'true';
    else tw[key] = ['dash', 'chat', 'user'].includes(raw) ? raw : def;
  }
  tw.panel = q.has('tweaks');
  return tw;
}

const LABELS = {
  showOnboarding: '초기 화면 표시 (showOnboarding)',
  evacNeeded: '대피 필요 (evacNeeded)',
  fastDemo: '빠른 시연 · 1초 = 1분 (fastDemo)',
  simOffline: '오프라인 시연 (simOffline)'
};

export default function TweaksPanel({ tw, onChange }) {
  const [open, setOpen] = useState(false);
  if (!tw.panel) return null;
  return (
    <div style={{ position: 'fixed', right: 16, bottom: 16, zIndex: 100, display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 8 }}>
      {open && (
        <div style={{ background: '#FFFFFF', borderRadius: 20, boxShadow: '0 12px 40px rgba(20,36,92,0.25)', padding: 16, display: 'flex', flexDirection: 'column', gap: 10, fontSize: 15, minWidth: 260 }}>
          <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontWeight: 700 }}>
            시작 화면 (startScreen)
            <select value={tw.startScreen} onChange={e => onChange({ startScreen: e.target.value })} style={{ marginLeft: 'auto', fontSize: 15 }}>
              <option value="dash">대시보드</option><option value="chat">AI 대화창</option><option value="user">사용자</option>
            </select>
          </label>
          {Object.keys(LABELS).map(k => (
            <label key={k} style={{ display: 'flex', alignItems: 'center', gap: 8, fontWeight: 700, cursor: 'pointer' }}>
              <input type="checkbox" checked={tw[k]} onChange={e => onChange({ [k]: e.target.checked })} />{LABELS[k]}
            </label>
          ))}
        </div>
      )}
      <button onClick={() => setOpen(o => !o)} title="Tweaks" style={{ width: 48, height: 48, borderRadius: '50%', border: 'none', background: C.ink, color: '#FFFFFF', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: '0 6px 20px rgba(14,24,56,0.3)' }}>
        <Icon n={open ? 'close' : 'tune'} size={26} />
      </button>
    </div>
  );
}
