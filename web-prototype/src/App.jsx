import { useCallback, useEffect, useRef, useState } from 'react';
import { MIN } from './tokens.js';
import { initialState, tick, disasterActive, timeScale, buzz } from './logic.js';
import { SideNav, EmergencyCall, ResidentHeader } from './components/Chrome.jsx';
import { Icon, Circle } from './components/ui.jsx';
import TweaksPanel, { readTweaks } from './components/TweaksPanel.jsx';
import Onboarding from './screens/Onboarding.jsx';
import Dashboard from './screens/Dashboard.jsx';
import Chat from './screens/Chat.jsx';
import UserPage from './screens/UserPage.jsx';
import CrewDashboard from './screens/CrewDashboard.jsx';
import { WarningModal, MetricModal, MailModal, EvacModal } from './modals/Modals.jsx';

// 클래스 컴포넌트의 setState처럼 부분 객체(또는 함수)를 합친다
function useMergeState(init) {
  const [s, setS] = useState(init);
  const set = useCallback(u => setS(prev => {
    const patch = typeof u === 'function' ? u(prev) : u;
    return patch ? { ...prev, ...patch } : prev;
  }), []);
  return [s, set];
}

export default function App() {
  const [tw, setTw] = useState(() => readTweaks(window.location.search));
  const [s, set] = useMergeState(() => initialState(tw));
  const twRef = useRef(tw);
  twRef.current = tw;

  const changeTweaks = patch => {
    setTw(t => ({ ...t, ...patch }));
    if ('showOnboarding' in patch) set({ onboarded: !patch.showOnboarding, obStep: 1 });
    if ('startScreen' in patch) set({ screen: patch.startScreen });
    if (patch.evacNeeded) set({ evacOpen: true });
  };

  useEffect(() => {
    const id = setInterval(() => set(st => tick(st, twRef.current, Date.now())), 1000);
    const onNet = () => set({ online: navigator.onLine });
    const onEsc = e => { if (e.key === 'Escape') set(st => st.mapFull ? { mapFull: false } : null); };
    window.addEventListener('online', onNet);
    window.addEventListener('offline', onNet);
    window.addEventListener('keydown', onEsc);
    return () => {
      clearInterval(id);
      window.removeEventListener('online', onNet);
      window.removeEventListener('offline', onNet);
      window.removeEventListener('keydown', onEsc);
    };
  }, [set]);

  const active = disasterActive(s, tw);
  const evacVisible = s.onboarded && s.evacOpen && active;
  const simEl = s.askStart ? Math.max(0, (s.now - s.askStart) * timeScale(tw)) : 0;
  const pings = 1 + Math.floor(simEl / (2 * MIN)); // 응답 없으면 2분마다 다시 묻는다
  const online = s.online && !tw.simOffline;

  // 진동 알림: 대피 알림이 뜨거나 다시 물을 때, 무응답으로 방재단에 연락될 때 (길게)
  const alertKey = useRef('');
  const key = evacVisible ? 'open:' + pings : (s.evacStatus === 'noresp' ? 'noresp' : '');
  useEffect(() => {
    if (key && key !== alertKey.current && s.vibrate) buzz(key === 'noresp' ? [800, 200, 800, 200, 800] : null);
    alertKey.current = key;
  }, [key, s.vibrate]);

  if (!s.onboarded) return <><Onboarding s={s} set={set} /><TweaksPanel tw={tw} onChange={changeTweaks} /></>;

  if (s.crewLogged && s.screen === 'crew') {
    return <><CrewDashboard s={s} set={set} online={online} /><TweaksPanel tw={tw} onChange={changeTweaks} /></>;
  }

  return (
    <div style={{ display: 'flex', minHeight: '100vh' }}>
      <SideNav s={s} set={set}
        top={<Circle size={56} bg="#FFFFFF" fg="#14245C" style={{ marginBottom: 20 }}><Icon n="shield" size={30} /></Circle>}
        bottom={<EmergencyCall />} />
      <main style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column' }}>
        <ResidentHeader s={s} set={set} online={online} showEvacChip={!s.evacOpen && active} />
        {s.screen === 'dash' && <Dashboard s={s} set={set} />}
        {s.screen === 'chat' && <Chat s={s} set={set} />}
        {s.screen === 'user' && <UserPage s={s} set={set} />}
      </main>
      {s.warnOpen && <WarningModal s={s} set={set} />}
      {s.metricOpen && <MetricModal s={s} set={set} />}
      {s.mailOpen && <MailModal s={s} set={set} />}
      {evacVisible && <EvacModal s={s} set={set} tw={tw} pings={pings} />}
      <TweaksPanel tw={tw} onChange={changeTweaks} />
    </div>
  );
}
