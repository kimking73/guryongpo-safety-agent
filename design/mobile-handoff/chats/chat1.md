# Mobile app design

_Started 2026-10-06 12:38 UTC_

---

## User

Design a mobile app for

## Assistant



## Assistant

_[tool: ask_user]_

I've put up a short form. Once you answer it, I'll start designing. It asks which screens to include, the navigation type, whether you want variations, the target device, who the main users are, and for a mascot image if you have one.

## User

Answered — Asked for follow-up questions; screens: 온보딩(동의·정보 입력), 대시보드, 날씨 상세 카드, AI 대화창, 태풍, 사용자/설정, 대피 상태 확인 모달, 경로 안내, 알림 목록, 119 긴급전화; fidelity: 클릭 가능한 인터랙티브 프로토타입 (폰 프레임 1개); nav: 하단 탭바 4개 + 119 플로팅 버튼; variations: 태블릿 스타일 그대로 충실히 옮기기; platform: 중립; audience: 고령자 중심 — 큰 글씨·큰 버튼; notes: 첨부된 구룡포 안전 웹디자인 참고 사진을 기준으로 모바일 앱 화면을 디자인하라. 원본의 시각 요소는 그대로 유지하고 배치와 정보 구조만 앱에 맞게 재구성한다. 원본의 모든 정보와 기능을 빠짐없이 포함하되 첫 화면에서 핵심 안전 정보와 주요 행동을 바로 파악하도록 우선순위를 분명히 한다. 긴 내용은 제목·요약·접힘 영역으로 정리하고, 카드와 간결한 탐색 구…; design_system: Design system left to Claude

## Assistant



## Assistant

_[tool: ask_user]_

_[tool: ask_user]_

I added three more questions to the form: what goes in the four tabs, when the evacuation status check should pop up, and how to lay out the weather cards. I'll start the design once you answer.

## User

Answered — Asked for follow-up questions; tabs: 대시보드 · AI 대화창 · 태풍 · 사용자 (원본 그대로); evac_trigger: 시연 모드 ‘과거 힌남노 태풍 시연’ 켜면 자동 표시; weather_layout: 2열 그리드 (수치 중심)

## Assistant



## Assistant

_[tool: ask_user]_

I added three last questions to the form: what happens after the SOS button, how much the AI chat should respond to, and the to-do list items that were cut off in the screenshot.

## User

Answered — Asked for follow-up questions; sos_flow: 도움 필요 → 방재단 연락 중 화면 + 119 바로가기; ai_interaction: 직접 입력도 응답; checklist_rest: 알아서

## Assistant



## Assistant

_[tool: ask_user]_

_[tool: ask_user]_

One last question: should the prototype start from onboarding or from the dashboard? After that I'll start building.

## User

Answered — Asked for follow-up questions; start_screen: 온보딩부터 시작

## Assistant



## Assistant

_[tool: ask_user]_

That's the last question: how many onboarding steps there should be. Once you answer, I'll start building the prototype.

## User

Answered — Asked for follow-up questions; onboard_next: ‘다음’ → 집·내 장소·직업 입력 2단계 → 대시보드

## Assistant



## Assistant

_[tool: ask_user]_

I added one more question: should the job field use preset options or free text? I'm out of questions after this. Submit without pressing "Ask me follow-up questions" and I'll start building.

## User

Answered — job_options: 직접 입력

## Assistant

_[tool: run_script]_

_[tool: view_image]_

_[tool: dc_write]_

_[tool: ready_for_verification]_

I've built the mobile prototype as one clickable phone screen: 구룡포 안전 비서 모바일.dc.html. It starts at onboarding (2 steps), then goes to the 4 tabs with a 119 button that stays on screen. A check is still running in the background.

To see the evacuation status check, turn on 사용자 → 시연 모드 → 과거 힌남노 태풍 시연. The 10-minute countdown runs. 대피 중 opens 경로 안내, and 도움 필요 opens the 방재단 연락 중 screen with a 119 shortcut.

Things to review:
- **Added copy:** a few things weren't in your screenshots, so I wrote them myself:
  - the 4th–6th items on 태풍 → 지금 할 일
  - the AI chat answers
  - car travel times
  - the onboarding step 2 heading
  - the SOS and toast messages
- **Weather cards:** to keep the grid compact, each card's description only shows when you tap it, in a pull-up panel.
- **Placeholders:** maps are striped placeholders. The AI mascot is cropped from your AI chat screenshot. Send me the original image for a sharper version.

## User

네트워크가 끊기면 오프라인이라고 표시하게 해줘. 이때 오프라인 상황임을 사용자가 명확히 알 수 있도록 색깔을 눈에 띄게 어울리게 잘 해줘

## Assistant

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_set_props]_

_[tool: ready_for_verification]_

The top-left chip now switches to "오프라인" when the network drops and back to "온라인" when it returns. Offline, it's dark orange with white text, a disconnected-plug icon and a light orange outline. I avoided red because the alert cards already use it.

To see it without disconnecting, turn on "forceOffline" in the Tweaks panel.

## User

사이즈 절반으로 줄여줘

## Assistant

_[tool: dc_html_str_replace]_

_[tool: ready_for_verification]_

I cut the 최근 재난문자 card to about half its height.
- I reduced the padding, icon and headline sizes.
- The two action chips now sit in one row and scroll sideways if they don't fit.
- The "원문 보기" bar is gone. The original text now opens from the arrow button at the top right of the card.

## User

지도에 전체화면 누르기 버튼을 추가해서 그 버튼을 누를 시에 지도 경로 표시 영역이 전체 화면에 뜰 수 있도록 해줘

## Assistant

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

I added a "전체화면" button to the top-right of the dashboard map. Tapping it fills the whole phone screen with the map.

- **Top:** a bar shows the start point and destination, with a button that closes full screen.
- **Bottom:** the walk/car switch and the travel time and distance stay visible.

## User

집, 직장, 현위치, 경로 안내 화면 보기와 같은 버튼들 크기가 너무 커서 다 절반 이하로 줄여줘

## User

강풍 강우량도 너무 사이즈가 커 6개 항목 전부 절반 이하로 줄여줘

## User

강풍 강우량도 너무 사이즈가 커 6개 항목 전부 절반 이하로 줄여줘

## Assistant

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: ready_for_verification]_

I cut all 6 weather cards to about a third of their old height (190px → 64px). Each card now has the icon on the left, with the name, value and level badge stacked to its right.

To save space, I took the note (북동풍, 밤사이 증가, etc.) and the arrow icon off the cards. The note still shows in the detail panel that opens when you tap a card. I haven't checked the narrowest cards (미세 / 초미세먼지), so long names may be cut off with "…".

## User

채팅 보내는게 좀 큰 것 같아. 2/3으로 줄여줘

## Assistant

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: ready_for_verification]_

I shrank the chat messages to 2/3 size. Both the AI and user bubbles now have smaller text (17px → 12px), padding and corner rounding, and the AI character image went from 46px to 31px.

12px may be hard for older users to read. If so, I can move it up to 14px.

## User

삭제

## Assistant

_[tool: dc_html_str_replace]_

I removed the voice guide button (the wave icon) from the chat input bar.

## User

이 버튼을 누르면 음성 입력이 된다는 것을 보여주기 위해서   목소리 파형이 나타나는 것처럼 해줘. 녹음이 된다는 네모 버튼도.

## Assistant

_[tool: read_file]_

_[tool: grep]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

Tapping the mic button now switches the input bar to a recording state.

- **While recording:** the bar gets a red outline, a blinking red dot, an elapsed-time counter and a moving voice waveform.
- **Stop:** a red round button with a white square on the right. Tapping it fills the input with the voice text ("대피할 때 뭘 해야 해?").
- **Auto-stop:** recording ends by itself after 30 seconds.

The waveform is simulated motion; it doesn't react to real sound. I haven't watched it run in the preview yet.

## User

태풍 섹션 자체를 다 없애버려. ai 대화창에 체크리스트를 추천 프롬프트로 넣어서 답변이 체크할 수 있게끔 리스트를 제공해줘. 추천 프롬프트의 태풍 정보도 알려달라고 해주는 것도 넣어

## Assistant

_[tool: run_script]_

_[tool: grep]_

_[tool: read_file]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

Now add `setEs` and handle the countdown timeout.

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

I removed the 태풍 tab, added two suggested prompts to the AI chat, and added a status bar for what was sent to 방재단. A background check is still running.

- **태풍 tab:** gone; the bottom bar now has three tabs (대시보드 · AI 대화창 · 사용자).
- **"태풍 대비 체크리스트 알려줘":** the answer includes a 6-item to-do list. Tapping an item checks it off with a strikethrough, and the "n / 6 완료" count updates.
- **"지금 태풍 정보 알려줘":** the answer shows a compact 힌남노 card with the closest-approach time, central pressure, top wind speed, direction and the path map.
- **방재단 status bar:** once you pick 대피 중, 대피 완료 or 도움 필요 in the evacuation check, a bar appears under the top status chips. It shows the status in its color (orange, green or red), "방재단에 전송됨" and the time sent. Tapping 변경 reopens the evacuation check. If the 10-minute countdown runs out with no answer, it sets 도움 필요.

## User

옆으로 스크롤 할 수 있게

## Assistant

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

The two action chips in the 재난문자 card now scroll sideways, by touch swipe or by mouse drag. The row now runs to the card's edges, and the right edge fades out so it's clear there's more to see.

## User

compact하게. 깔끔하게. 경로 안내 화면 보기 삭제.

## Assistant

_[tool: grep]_

_[tool: read_file]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

I tightened the route section under the dashboard map from five rows to two (about 300px → 90px) and removed the 경로 안내 화면 보기 button.

- **Row 1:** a 집 | 현위치 | 내 장소 selector, with the walk/car switch next to it.
- **Row 2:** the start point and address in small text, with the shelter name below in bold. The swap button and the travel time and distance sit on the right.

The 경로 안내 screen can still be reached from the AI chat map card and from 대피 중 in the evacuation check.

## User

이걸 삭제하고 대피 현황 대피 중/ 대피 완료 / 도움 필요 상태를 표시하도록

## Assistant

_[tool: read_file]_

_[tool: grep]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: read_file]_

_[tool: grep]_

_[tool: read_file]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: ready_for_verification]_

I made both changes.

- **현재 위치 → 대피 현황:** the top bar's 현재 위치 chip is now a 대피 현황 chip. It reads "응답 전" on white until you answer the evacuation check. After that it shows 대피 중 (orange), 대피 완료 (green) or 도움 필요 (red). Tapping it reopens the evacuation check so you can change the status. I also removed the separate status bar I added earlier, since this chip replaces it.
- **119 floating button:** removed. 119 can still be called from the 도움 필요 (SOS) screen.

## User

글자수는 키워

## User

옆으로 스크롤 하게 해줘

## User

옆으로 스크롤 하게 해줘

## Assistant

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

The suggested prompts in the AI chat now scroll sideways, by touch swipe or by mouse drag. The right edge fades out so it's clear there's more. Releasing a drag won't accidentally send a prompt. I haven't tried a drag in the preview yet.

## User

이걸 누르면 대시보드로 넘어가서 지도 경로 화면의 전체 화면이 뜰 수 있게 해줘

## User

이걸 누르면 대시보드로 넘어가서 지도 경로 화면의 전체 화면이 뜰 수 있게 해줘

## User

음성을 글자로 바꿨어요라는 안내는 뜨지 않아도 돼

## Assistant

_[tool: dc_js_str_replace]_

The "음성을 글자로 바꿨어요" message no longer pops up when you stop recording. The recognized text still goes into the input box.

## User

추천 프롬프트를 눌렀을 시에 답변에 따라서 자연스럽게 밑으로 내려갈 수 있게 해줘

## Assistant

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

The chat now scrolls down smoothly when you tap a suggested prompt.

- **Your question and the "답변을 준비하고 있어요…" bubble:** the view slides to the bottom.
- **The answer:** the view stops with the top of the answer near the top of the screen. That way a long answer, like the checklist or typhoon card, reads from its first line instead of jumping to the end.

A background check is still running.

## User

Found issues — fixing…

## Assistant

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

I fixed the chat auto-scroll: the code couldn't find the chat's scroll area, so it never moved. It now does, and the scroll uses my own smooth motion instead of the browser's, which was lagging badly in the preview. Opening the chat tab now also jumps to the newest message. A second background check is running to confirm.

## User

Found issues — fixing…

## Assistant

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

The last fix still didn't make the chat scroll. The scroll now runs straight from sending a message and from switching tabs.

- **Sending a question:** the view slides to the bottom, then to the top of the answer once it arrives.
- **Opening the chat tab:** jumps to the newest message.
- **Other tabs:** open scrolled to the top.

A background check is running to confirm it now works.

## User

장소 이름, 주소를 2가지를 입력할 수 있게

## Assistant

_[tool: grep]_

_[tool: read_file]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

"내 장소 추가하기" now opens a form with two fields, 장소 이름 and 주소, plus 취소 and 추가 buttons.

- **추가 button:** stays greyed out until both fields are filled. Tapping it adds the place to the 내 정보 list with the address shown underneath.
- **If a field is empty:** a message asks you to fill in both.

The 내 장소 entered during onboarding still shows the name only, since that screen has no address field.

## User

방재단 전용 코드 입력할 수 있는 칸 생성

## Assistant

_[tool: grep]_

_[tool: read_file]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

The 방재단 로그인 card now has a field for the 방재단 code, with a 로그인 button next to it.

- **Typing the code:** up to 8 characters, letters, numbers and "-" only, and letters are turned into capitals automatically.
- **로그인 button:** stays greyed out until at least 4 characters are entered. With fewer, the field outline turns red and an error message appears.
- **After logging in:** the input is replaced by a green "로그인됨" badge and a 로그아웃 button.

The prototype accepts any code of 4 or more characters, since there's no real check behind it.

## User

compact하고 깔끔하게

## Assistant

_[tool: grep]_

_[tool: read_file]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: eval_js_user_view]_

_[tool: dc_js_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: eval_js_user_view]_

I made the user tab more compact and fixed the 방재단 code field so you can type in it.

- **방재단 code field:** typing worked, but the field only kept letters, numbers and "-". Anything else, like Korean typed while the keyboard was in Korean mode, was silently deleted, so the field looked locked. It now accepts any characters, up to 12. A test entry stayed in the field.
- **내 정보, 알림, 시연 모드:**
  - The cards have less padding and smaller headings.
  - Rows went from 64–78px to 44–56px tall.
  - Icons are small plain icons instead of circled ones.
  - Toggles are smaller, and the line under the last row is gone.
  - "내 장소 추가하기" is a thinner full-width button.
  - When 과거 힌남노 태풍 시연 is on, the row turns light orange with an orange outline.

## User

방재단 대시보드 코드를 입력했을 시에 이런 화면이 구현되도록 해줘

## Assistant

_[tool: read_file]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: ready_for_verification]_

After a 방재단 code login, a new "방재단 현황" tab appears in the bottom bar and opens to the 주민 대피 현황 screen. A background check is still running.

- **Top bar:** shows 방재단원(나), 온라인 and a red 실시간 pill, with "구룡포읍 자율방재단 · 방금 갱신 [time]" under the title.
- **Counts:** 도움 필요, 응답 없음, 대피 중 and 대피 완료 in a 2×2 grid.
- **지도:** a placeholder with the dashed red 위험지역 · 해안 저지대 zone, pins for the 4 shelters, pins for priority households, and the "예시 위치 · 실제 지도 연결 전" note.
- **우선 확인 가구:** lists 도움 필요 and 응답 없음 households first, or shows "위험지역 안에 급한 가구가 없어요" when there are none.
- **방재단 배정 현황:** the assigned/unassigned count, the five stage counts (scroll sideways), and a card per household with its assignee, status badge and 4-step 출발 → 방문 → 대피 동행 → 완료 bar. Unfinished households are listed first.

Things to know:
- **Linked to the resident side:** the status you pick in the resident evacuation check feeds into the counts and the priority list. With no answer yet, "내 가구 (시연)" counts as 응답 없음.
- **"내 가구 (시연)" card buttons:** this card has a button that walks it through 내가 맡기 → 방문 도착 → 대피 동행 시작 → 대피 완료 처리. The other households are fixed sample data.
- **Added sample data:** your screenshot showed six households. I added 정O례 (병포리 언덕길) and 윤O길 (석병리 해안, 대피 중) so the counts match the 1 / 1 / 6 in your screenshot. I also gave 한O수 the assignee 최구조, because the name was cut off. Please replace these with your real names.
- **Logging out:** 로그아웃 in the 사용자 tab removes the 방재단 현황 tab.

## User

클릭하면 전체화면

## Assistant

_[tool: dc_html_str_replace]_

_[tool: dc_html_str_replace]_

_[tool: dc_js_str_replace]_

_[tool: ready_for_verification]_

Tapping the map on the 방재단 현황 tab now opens it in full screen. A small expand icon in the map's top-right corner shows that it can be tapped.

- **Full-screen view:** the 위험지역 zone, shelter labels and priority-household pins are drawn larger across the whole phone screen.
- **Top bar:** shows "지도" and the 위험지역 · 해안 저지대 label, plus a button to close full screen.

