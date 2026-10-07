import { C } from '../tokens.js';

export function Icon({ n, size = 24, style }) {
  return <span className="ms" style={{ fontSize: size, ...style }}>{n}</span>;
}

// 둥근 아이콘 원
export function Circle({ size, bg, fg, children, style }) {
  return (
    <span style={{ width: size, height: size, borderRadius: '50%', background: bg, color: fg, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, ...style }}>
      {children}
    </span>
  );
}

export function Switch({ on }) {
  return (
    <span style={{ width: 68, height: 40, borderRadius: 999, background: on ? C.navy : '#C9D0E2', position: 'relative', flexShrink: 0, transition: 'background .2s' }}>
      <span style={{ position: 'absolute', top: 4, left: on ? 32 : 4, width: 32, height: 32, borderRadius: '50%', background: '#FFFFFF', boxShadow: '0 1px 4px rgba(0,0,0,0.2)', transition: 'left .2s' }} />
    </span>
  );
}

// 체크 가능한 둥근 칩 (장애 유형 · 이동 수단)
export function ChoiceChip({ on, icon, label, onClick, size = 'lg' }) {
  const lg = size === 'lg';
  return (
    <button onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: lg ? 20 : 19, fontWeight: 600, padding: lg ? '16px 26px' : '14px 22px', borderRadius: 999, border: `2px solid ${C.navy}`, background: on ? C.navy : '#FFFFFF', color: on ? '#FFFFFF' : C.navy, cursor: 'pointer' }}>
      <Icon n={icon} size={lg ? 24 : 22} />{label}
    </button>
  );
}

export function Modal({ onClose, maxWidth, z = 45, label, children }) {
  return (
    <div data-screen-label={label} onClick={onClose} style={{ position: 'fixed', inset: 0, zIndex: z, background: 'rgba(14,24,56,0.6)', display: 'flex', alignItems: 'flex-start', justifyContent: 'center', padding: 24, boxSizing: 'border-box', overflowY: 'auto' }}>
      <div onClick={e => e.stopPropagation()} style={{ width: '100%', maxWidth, margin: 'auto', background: '#FFFFFF', borderRadius: 36, padding: 32, boxSizing: 'border-box', display: 'flex', flexDirection: 'column', gap: 24 }}>
        {children}
      </div>
    </div>
  );
}

export function CloseButton({ onClick, size = 56 }) {
  return (
    <button onClick={onClick} title="닫기" style={{ width: size, height: size, borderRadius: '50%', border: 'none', background: C.tint, color: C.navy, cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
      <Icon n="close" size={size === 56 ? 30 : 28} />
    </button>
  );
}

export const inputPill = { fontSize: 22, padding: '18px 24px', borderRadius: 999, border: `2px solid ${C.line}`, outline: 'none', color: C.ink, background: C.bg, fontFamily: 'inherit' };
