-- =====================================================================
--  구룡가디언 — 스키마 추가분 v0.4 (2026-10-04, A13 취약 가구·민감정보 동의)
--  다시 실행해도 안전 — 빈 DB 는 docker 초기화가 01m_v0_3 다음에, 기존 DB 는 loader 가 매번 먼저 적용
--
--  1. 동의서 버전: care.households.consent_version — 동의 문구가 바뀌면 버전을 올리고, 이전 버전 가구는 재동의 대상
--  2. 건강 정보(혈액형·병력 메모)를 public.user_profiles → care.user_health 로 이동 (2026-10-04 결정)
--     AI 읽기 전용 계정(07_ai_readonly.sh)은 public 만 읽으므로 care 로 옮기면 볼 수 없다. 앱 API(/user) 응답 형식은 같음
-- =====================================================================

ALTER TABLE care.households ADD COLUMN IF NOT EXISTS consent_version text NOT NULL DEFAULT 'v1';

CREATE TABLE IF NOT EXISTS care.user_health (
  user_id       uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  blood_type    text CHECK (blood_type IN ('A+','A-','B+','B-','O+','O-','AB+','AB-')),
  medical_note  text,                               -- 119 전달용 (지병/복용약 등, 사용자 자유기재)
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- 기존 값 옮기고 public 컬럼 삭제 (컬럼이 남아 있을 때만 — 두 번째 실행부터는 아무것도 안 함)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'user_profiles' AND column_name = 'medical_note') THEN
    INSERT INTO care.user_health (user_id, blood_type, medical_note)
    SELECT user_id, blood_type, medical_note FROM public.user_profiles
    WHERE blood_type IS NOT NULL OR medical_note IS NOT NULL
    ON CONFLICT (user_id) DO NOTHING;
    ALTER TABLE public.user_profiles DROP COLUMN IF EXISTS blood_type;
    ALTER TABLE public.user_profiles DROP COLUMN IF EXISTS medical_note;
  END IF;
END $$;
