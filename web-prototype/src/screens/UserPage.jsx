import { C } from '../tokens.js';
import { DIS_OPTS, DIS_LABEL, MOVE_OPTS, HOUSEHOLDS, DANGER_HERE } from '../data.js';
import { toggleDis, cleanAge, blockNonDigit, buzz } from '../logic.js';
import { Icon, Circle, ChoiceChip, Switch } from '../components/ui.jsx';

const card = { background: '#FFFFFF', borderRadius: 32, padding: 32, display: 'flex', flexDirection: 'column' };
const rowLine = { display: 'flex', alignItems: 'center', gap: 16, padding: '14px 0', borderBottom: `1px solid ${C.tint}` };
const fieldInput = { fontSize: 21, padding: '16px 22px', borderRadius: 999, border: `2px solid ${C.line}`, outline: 'none', color: C.ink, background: C.bg };
const outlineBtn = { fontSize: 19, fontWeight: 700, padding: '14px 26px', borderRadius: 999, border: `2px solid ${C.navy}`, cursor: 'pointer', whiteSpace: 'nowrap' };
const CODE_MIN = 6;

function ToggleRow({ icon, label, desc, on, onClick }) {
  return (
    <button onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '16px 0', border: 'none', borderBottom: `1px solid ${C.tint}`, background: 'transparent', cursor: 'pointer', textAlign: 'left' }}>
      <Circle size={48} bg={C.tint} fg={C.navy}><Icon n={icon} size={26} /></Circle>
      <span style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <span style={{ fontSize: 21, fontWeight: 700, color: C.ink }}>{label}</span>
        <span style={{ fontSize: 16, color: C.muted }}>{desc}</span>
      </span>
      <Switch on={on} />
    </button>
  );
}

function ProfileCard({ s, set }) {
  const disLabel = s.dis.length === 0 ? '선택 안 함' : s.dis.map(d => DIS_LABEL[d]).join(' · ');
  const moveLabel = s.move.length === 0 ? '선택 안 함' : s.move.map(m => m === 'walk' ? '도보' : '자동차').join(' · ');
  const profile = [
    ['cake', '나이', s.age ? s.age + '세' : '입력 안 함'],
    ['accessible', '장애', disLabel],
    ['directions_walk', '이동 수단', moveLabel],
    ['work', '직업', s.job || '입력 안 함'],
    ['home', '집', s.home || '입력 안 함'],
    ['bookmark', '내 장소', s.mine || '입력 안 함']
  ];
  const editFields = [
    ['age', 'cake', '나이', 'number', '예: 72'],
    ['job', 'work', '직업', 'text', '예: 어업'],
    ['home', 'home', '집 주소', 'text', '예: 구룡포읍 호미로'],
    ['mine', 'bookmark', '내 장소', 'text', '예: 구룡포 시장']
  ];
  const addPlace = () => set(st => {
    const addr = st.newPlaceAddr.trim();
    if (!addr) return { newPlaceErr: true };
    const name = st.newPlaceName.trim() || '내 장소 ' + (st.extraPlaces.length + 2);
    return { extraPlaces: [...st.extraPlaces, { name, addr }], addPlaceOpen: false, newPlaceName: '', newPlaceAddr: '' };
  });
  const toggleAddPlace = () => set(st => ({ addPlaceOpen: !st.addPlaceOpen, newPlaceName: '', newPlaceAddr: '', newPlaceErr: false }));
  const sectionLabel = (icon, text) => (
    <span style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 19, fontWeight: 700 }}><Icon n={icon} size={24} style={{ color: C.navy }} />{text}</span>
  );

  return (
    <div style={{ ...card, gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, margin: '0 0 12px' }}>
        <h2 style={{ margin: 0, flex: 1, fontSize: 28, fontWeight: 800 }}>내 정보</h2>
        <button onClick={() => set(st => ({ editing: !st.editing }))} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 19, fontWeight: 700, padding: '12px 22px', borderRadius: 999, border: 'none', background: s.editing ? C.navy : C.tint, color: s.editing ? '#FFFFFF' : C.navy, cursor: 'pointer' }}>
          <Icon n={s.editing ? 'check' : 'edit'} size={24} />{s.editing ? '저장' : '수정'}
        </button>
      </div>

      {s.editing ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 22 }}>
          {editFields.map(([k, icon, label, type, placeholder]) => (
            <label key={k} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {sectionLabel(icon, label)}
              <input type={type} min={k === 'age' ? '1' : undefined} value={s[k]} placeholder={placeholder}
                onChange={e => set({ [k]: k === 'age' ? cleanAge(e.target.value) : e.target.value })}
                onKeyDown={k === 'age' ? blockNonDigit : undefined} style={fieldInput} />
            </label>
          ))}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {sectionLabel('accessible', '장애 유형')}
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
              {DIS_OPTS.map(([k, icon, label]) => (
                <ChoiceChip key={k} size="md" on={s.dis.includes(k)} icon={icon} label={label}
                  onClick={() => set(st => ({ ...(!st.consentSens && k !== 'none' ? { consentSens: true } : {}), ...toggleDis(st, k) }))} />
              ))}
            </div>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {sectionLabel('directions_walk', '이동 수단')}
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
              {MOVE_OPTS.map(([k, icon, label]) => (
                <ChoiceChip key={k} size="md" on={s.move.includes(k)} icon={icon} label={label}
                  onClick={() => set(st => ({ move: st.move.includes(k) ? st.move.filter(x => x !== k) : [...st.move, k] }))} />
              ))}
            </div>
          </div>
        </div>
      ) : profile.map(([icon, label, value]) => (
        <div key={label} style={rowLine}>
          <Circle size={44} bg={C.tint} fg={C.navy}><Icon n={icon} size={24} /></Circle>
          <span style={{ fontSize: 19, color: C.muted, width: 84, flexShrink: 0 }}>{label}</span>
          <span style={{ fontSize: 21, fontWeight: 700 }}>{value}</span>
        </div>
      ))}

      {s.extraPlaces.map((p, i) => (
        <div key={i} style={rowLine}>
          <Circle size={44} bg={C.tint} fg={C.navy}><Icon n="bookmark" size={24} /></Circle>
          <span style={{ fontSize: 19, color: C.muted, width: 84, flexShrink: 0 }}>{p.name}</span>
          <span style={{ flex: 1, fontSize: 21, fontWeight: 700, minWidth: 0 }}>{p.addr}</span>
          <button onClick={() => set(st => ({ extraPlaces: st.extraPlaces.filter((_, j) => j !== i), from: st.from === 'x' + i ? 'cur' : st.from }))} title="삭제"
            style={{ width: 40, height: 40, borderRadius: '50%', border: 'none', background: C.bg, color: C.muted, cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
            <Icon n="close" size={22} />
          </button>
        </div>
      ))}

      {s.addPlaceOpen ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 12, background: C.bg, borderRadius: 28, padding: 20 }}>
          <div style={{ fontSize: 20, fontWeight: 800 }}>새 장소 등록</div>
          <input value={s.newPlaceName} onChange={e => set({ newPlaceName: e.target.value })} placeholder="이름 (예: 딸네 집, 경로당)"
            style={{ ...fieldInput, fontSize: 20, background: '#FFFFFF' }} />
          <input value={s.newPlaceAddr} onChange={e => set({ newPlaceAddr: e.target.value, newPlaceErr: false })} onKeyDown={e => { if (e.key === 'Enter') addPlace(); }} placeholder="주소 (예: 구룡포읍 구룡포길 12)"
            style={{ ...fieldInput, fontSize: 20, background: '#FFFFFF', borderColor: s.newPlaceErr ? C.red : C.line }} />
          <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
            <button onClick={addPlace} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 20, fontWeight: 800, padding: '14px 28px', borderRadius: 999, border: 'none', background: C.navy, color: '#FFFFFF', cursor: 'pointer' }}>
              <Icon n="check" size={24} />등록
            </button>
            <button onClick={toggleAddPlace} style={{ fontSize: 20, fontWeight: 700, padding: '14px 26px', borderRadius: 999, border: `2px solid ${C.navy}`, background: '#FFFFFF', color: C.navy, cursor: 'pointer' }}>취소</button>
          </div>
        </div>
      ) : (
        <button onClick={toggleAddPlace} style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 12, alignSelf: 'flex-start', fontSize: 19, fontWeight: 700, padding: '14px 22px', borderRadius: 999, border: `2px dashed ${C.navy}`, background: '#FFFFFF', color: C.navy, cursor: 'pointer' }}>
          <Icon n="add" size={24} />내 장소 추가하기
        </button>
      )}
    </div>
  );
}

function MailCard({ s, set }) {
  const on = !!s.mailUser;
  return (
    <div style={{ background: '#FFFFFF', borderRadius: 32, padding: '28px 32px', display: 'flex', alignItems: 'center', gap: 16, flexWrap: 'wrap' }}>
      <Circle size={52} bg={C.tint} fg={C.navy}><Icon n="mail" size={28} /></Circle>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2, minWidth: 200 }}>
        <span style={{ fontSize: 21, fontWeight: 700 }}>{on ? s.mailUser : '이메일로 로그인 · 가입'}</span>
        <span style={{ fontSize: 17, color: C.muted }}>{on ? '로그인됨 · 다른 기기에서도 내 정보 사용' : '선택 사항 · 다른 기기에서도 내 정보 사용'}</span>
      </div>
      <button onClick={() => set(st => st.mailUser ? { mailUser: '', mailEmail: '', mailPw: '' } : { mailOpen: true, mailErr: false })}
        style={{ ...outlineBtn, background: on ? '#FFFFFF' : C.navy, color: on ? C.navy : '#FFFFFF' }}>{on ? '로그아웃' : '로그인'}</button>
    </div>
  );
}

function CrewLoginCard({ s, set }) {
  const submit = () => set(st => st.crewCode.trim().length >= CODE_MIN
    ? { crewLogged: true, crewOpen: false, lastSim: Date.now(), screen: 'crew' }
    : { crewErr: true });
  const solid = !(s.crewLogged || s.crewOpen);
  return (
    <div style={{ background: '#FFFFFF', borderRadius: 32, padding: '28px 32px', display: 'flex', flexDirection: 'column', gap: 18 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, flexWrap: 'wrap' }}>
        <Circle size={52} bg={C.navy} fg="#FFFFFF"><Icon n="badge" size={28} /></Circle>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2, minWidth: 200 }}>
          <span style={{ fontSize: 21, fontWeight: 700 }}>{s.crewLogged ? '방재단으로 로그인됨' : '방재단 로그인'}</span>
          <span style={{ fontSize: 17, color: C.muted }}>{s.crewLogged ? '구룡포읍 자율방재단 · 현장 보고와 주민 안내 기능을 쓸 수 있어요' : '방재단원은 전용 코드로 로그인하세요'}</span>
        </div>
        <button onClick={() => set(st => st.crewLogged ? { crewLogged: false, crewCode: '' } : { crewOpen: !st.crewOpen, crewErr: false })}
          style={{ ...outlineBtn, background: solid ? C.navy : '#FFFFFF', color: solid ? '#FFFFFF' : C.navy }}>
          {s.crewLogged ? '로그아웃' : (s.crewOpen ? '닫기' : '코드로 로그인')}
        </button>
      </div>
      {s.crewOpen && !s.crewLogged && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: C.bg, borderRadius: 999, padding: '6px 6px 6px 24px', border: `2px solid ${s.crewErr ? C.navy : 'transparent'}` }}>
            <input value={s.crewCode} onChange={e => set({ crewCode: e.target.value.toUpperCase(), crewErr: false })} onKeyDown={e => { if (e.key === 'Enter') submit(); }} placeholder="방재단 전용 코드 입력"
              style={{ flex: 1, minWidth: 0, border: 'none', outline: 'none', background: 'transparent', fontSize: 21, letterSpacing: '0.08em', color: C.ink, padding: '10px 0' }} />
            <button onClick={submit} style={{ fontSize: 19, fontWeight: 700, padding: '12px 24px', borderRadius: 999, border: 'none', background: C.navy, color: '#FFFFFF', cursor: 'pointer' }}>확인</button>
          </div>
          <span style={{ fontSize: 16, color: C.muted, paddingLeft: 12 }}>
            {s.crewErr ? '코드를 다시 확인해 주세요. 6자리 이상 입력해야 해요.' : '읍사무소에서 받은 코드를 입력하세요. (시연: 아무 6자리)'}
          </span>
        </div>
      )}
    </div>
  );
}

export default function UserPage({ s, set }) {
  const canVibrate = typeof navigator !== 'undefined' && !!navigator.vibrate;
  const notiToggles = [
    { k: 'voice', icon: 'volume_up', label: '음성 안내 자동 재생', desc: '시각 장애 선택 시 자동으로 켜져요' },
    { k: 'vibrate', icon: 'vibration', label: '진동 알림', desc: canVibrate ? '대피 알림이 오면 휴대폰이 진동해요 · 켜면 한 번 울려요' : '이 기기에서는 진동이 지원되지 않아요 (안드로이드 휴대폰에서 작동)' },
    { k: 'flash', icon: 'flash_on', label: '화면 점멸', desc: '청각 장애 선택 시 자동으로 켜져요' }
  ];
  const demoToggles = [
    { k: 'demoCrew', icon: 'shield_person', label: '방재단 시연',
      desc: s.demoCrew ? '시연 중 · 방재단원이 위험지역 가구를 찾아가 대피시키고 있어요' : '방재단원이 가구를 찾아가 대피시키는 과정을 보여줘요' },
    { k: 'demoReplay', icon: 'history', label: '과거 힌남노 태풍 시연',
      desc: s.demoReplay ? '시연 중 · 현위치(구룡포항 근처)는 위험 지역이에요' : '2022년 태풍 힌남노 기록을 바탕으로 재현해요' }
  ];
  const toggleDemo = k => set(st => {
    if (k === 'demoCrew') {
      return st.demoCrew ? { demoCrew: false }
        : { demoCrew: true, crewLogged: true, screen: 'crew', crewOpen: false, hh: HOUSEHOLDS, lastSim: Date.now() - 1500 };
    }
    // 힌남노 시연을 켜면 현위치가 위험 지역이므로 대피 알림을 바로 띄운다
    return !st.demoReplay && DANGER_HERE ? { demoReplay: true, evacOpen: true, evacStatus: null } : { demoReplay: !st.demoReplay };
  });

  return (
    <div data-screen-label="사용자 페이지" style={{ padding: '8px 40px 56px', display: 'flex', flexDirection: 'column', gap: 28 }}>
      <h1 style={{ margin: 0, fontSize: 48, fontWeight: 800, letterSpacing: '-0.02em' }}>사용자</h1>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(min(100%,440px),1fr))', gap: 20, alignItems: 'start' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
          <ProfileCard s={s} set={set} />
          <MailCard s={s} set={set} />
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
          <div style={{ ...card, gap: 6 }}>
            <h2 style={{ margin: '0 0 10px', fontSize: 28, fontWeight: 800 }}>알림</h2>
            {notiToggles.map(t => (
              <ToggleRow key={t.k} {...t} on={s[t.k]} onClick={() => { if (t.k === 'vibrate' && !s.vibrate) buzz([300]); set(st => ({ [t.k]: !st[t.k] })); }} />
            ))}
          </div>
          <div style={{ ...card, gap: 6 }}>
            <h2 style={{ margin: '0 0 10px', fontSize: 28, fontWeight: 800 }}>시연 모드</h2>
            {demoToggles.map(t => <ToggleRow key={t.k} {...t} on={s[t.k]} onClick={() => toggleDemo(t.k)} />)}
          </div>
          <CrewLoginCard s={s} set={set} />
        </div>
      </div>
    </div>
  );
}
