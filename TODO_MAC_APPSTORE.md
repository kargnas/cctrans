# TODO — Mac App Store 제출

코드 측 준비는 `mas-prep` 브랜치에서 끝났다 (상세: [docs/mac-app-store.md](docs/mac-app-store.md)).
아래는 전부 **Apple Developer 계정 보유자만 할 수 있는 작업**과 그 이후의 제출 절차다.
위에서 아래 순서대로 진행하면 된다.

2026-06-12 진행 현황:

- [x] 인증서 2종 발급 + CI 시크릿 등록 (`CCTRANS_MAS_APP_CERTIFICATE_BASE64`,
      `CCTRANS_MAS_INSTALLER_CERTIFICATE_BASE64`, `CCTRANS_MAS_P12_PASSWORD`)
- [x] 개인정보 정책 페이지 — kargnas/test-af PR #66 (`https://kargn.as/cctrans/privacy`,
      지원 URL `https://kargn.as/cctrans`). 머지+Vapor 배포 후 활성화.
- [x] CI 업로드 파이프라인 `.github/workflows/release-mas.yml` (§5–6 자동화;
      프로파일 시크릿 2개와 업로드 자격증명만 채우면 동작)
- [x] 스토어 메타데이터 7개 로케일 + 리뷰 노트, 스크린샷 5장 (2880×1800)
      — 2026-06-13 별도 private 레포로 이전 (미공개 정보가 공개 레포에
      남지 않도록)
- [x] 샌드박스 차단 버그 수정 — helper argv 소실/컨테이너 분리 → App Group 채널
      (docs/mac-app-store.md §3.6). §7의 토스트·설정 UI 항목은 로컬 샌드박스
      빌드에서 사전 검증 완료, TestFlight에서 재확인만 하면 됨.
- [x] §2 App ID·§3 프로파일 — 발급 완료, 프로파일은 base64 시크릿으로 등록
- [x] §4 ASC 앱 레코드 — "CCTrans" (Apple ID 6779669255, SKU cctrans-mas).
      가격 무료 + 전 지역 175개 + 프라이버시 라벨 "Data Not Collected" 게시 완료
- [x] ASC API 키 "CCTrans CI" (TGTYRP4Z36) — 시크릿 `ASC_API_KEY_ID`/`ASC_API_ISSUER_ID`/`ASC_API_KEY_P8`
- [x] 메타데이터/스크린샷 ASC 반영 — fastlane deliver (0.3.0, 7로케일).
      리뷰 연락처는 별도 private 레포의 review_information/ 파일로 관리
- [x] §5–6 첫 빌드 업로드 — release-mas.yml 디스패치로 0.3.0 .pkg 업로드 성공
      (run 27424016336). 남은 것: TestFlight 처리 확인 → §7 QA → §8 제출 버튼

## 1. 인증서 발급 (developer.apple.com 또는 Xcode)

기존 Developer ID 인증서는 MAS에 재사용 불가. 두 개 새로 필요하다.

- [ ] `Apple Distribution` 인증서 — .app 서명용
- [ ] `Mac Installer Distribution` 인증서 — .pkg 서명용
  - Xcode → Settings → Accounts → Manage Certificates → `+` 가 가장 빠름
  - 발급 후 `security find-identity -v -p codesigning | grep -E "Apple Distribution|Installer"` 로 키체인 확인

## 2. App ID 등록 (developer.apple.com → Identifiers)

- [ ] `as.kargn.cctrans` (explicit) — App Sandbox capability 체크
- [ ] `as.kargn.cctrans.helper` (explicit) — App Sandbox capability 체크
  - 번들에 내장된 Tauri helper는 NSWorkspace로 별도 실행되는 독립 앱이라 자체 App ID가 필요하다

## 3. 프로비저닝 프로파일 (developer.apple.com → Profiles)

- [ ] 타입 **Mac App Store**, App ID `as.kargn.cctrans`, 인증서 = 위의 Apple Distribution → 다운로드
- [ ] 같은 방식으로 `as.kargn.cctrans.helper`용도 생성 → 다운로드
  - 메인 프로파일은 `CCTRANS_MAS_PROFILE`, helper 프로파일은
    `CCTRANS_MAS_HELPER_PROFILE`로 넘기면 `build-mas.zsh`가 각각
    `Contents/embedded.provisionprofile`로 임베드한다.

## 4. App Store Connect 앱 레코드

- [ ] appstoreconnect.apple.com → My Apps → `+` → New App (macOS)
- [ ] 이름 "CCTrans" 스토어 전역 유니크 확인 (선점됐으면 대안: "CCTrans Translator" 등)
- [ ] Bundle ID `as.kargn.cctrans` 연결, SKU 임의 지정
- [ ] **개인정보 정책 URL 필수** — kargn.as 아래에 페이지 하나 만들어야 함
- [ ] Privacy nutrition label 입력
  - OpenRouter 키는 로컬 보관, 번역 텍스트는 사용자가 선택한 경우에만 OpenRouter로 전송됨
  - Apple Translation은 온디바이스 — 개발자 수집 데이터 없음으로 신고 가능
- [ ] 카테고리 Productivity, 가격 무료(또는 결정), 수출 규정 = 표준 HTTPS만 사용 → exempt

## 5. 제출용 빌드 생성

```sh
CCTRANS_VERSION=<버전> \
CCTRANS_MAS_SIGN_IDENTITY="Apple Distribution: Sangrak Choi (<TEAM_ID>)" \
CCTRANS_TEAM_ID=<TEAM_ID> \
CCTRANS_MAS_PROFILE=<다운로드한 메인 프로파일 경로> \
CCTRANS_MAS_HELPER_PROFILE=<다운로드한 helper 프로파일 경로> \
CCTRANS_MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Sangrak Choi (<TEAM_ID>)" \
./scripts/build-mas.zsh
```

- [ ] `dist-mas/CCTrans-mas-<버전>.pkg` 생성 확인
- [ ] `codesign -dvv --entitlements - dist-mas/CCTrans.app` — sandbox=true + application-identifier 확인
- [ ] 버전은 직배포 릴리즈와 무관하게 ASC 기준 단조 증가만 지키면 됨

## 6. 업로드

- [ ] CI로 업로드: Actions → **Mac App Store Release** 워크플로우 디스패치
  (버전 입력 → 빌드·서명·검증·altool 업로드까지 자동).
  - 필요 시크릿: `CCTRANS_MAS_PROFILE_BASE64`, `CCTRANS_MAS_HELPER_PROFILE_BASE64`
    (§3에서 발급한 프로파일 base64) + `ASC_API_KEY_ID`/`ASC_API_ISSUER_ID`/`ASC_API_KEY_P8`
    (없으면 `APPLE_ID`/`APPLE_APP_PASSWORD` 폴백)
  - 메타데이터/스크린샷은 별도 private 레포에서 관리 — 거기서 fastlane/ 변경을
    push하면 자동으로 ASC에 반영됨
  - 수동 대안: Transporter.app으로 .pkg 업로드
- [ ] ASC → TestFlight 탭에서 빌드 처리 완료 대기 (자동 ingest 검사에서 entitlements 문제가 여기서 걸러짐)

## 7. TestFlight QA (제출 전 실기기 확인)

- [ ] 첫 실행: 로컬 모델 설정창이 **안** 뜨고 provider가 Apple Translation인지
- [ ] Cmd+C 더블 → Input Monitoring 권한 안내 → 허용 후 재실행 → 번역 토스트
- [ ] 권한 거부 상태에서도 같은 텍스트 2회 복사(pasteboard 폴백)로 번역되는지
- [ ] 미설치 언어쌍 → Apple 언어팩 다운로드 다이얼로그 플로우
- [ ] 스크린샷 번역 (Shift+Cmd+2) → Screen Recording 권한 플로우
- [ ] 토스트가 caret이 아니라 toastPosition 설정 위치에 뜨는지
- [ ] 설정 UI: provider 2개만 노출(Apple/OpenRouter), Permission Helper에 Accessibility 항목 없음
- [ ] 메뉴바에 "Check for Updates..." 없음 (Sparkle 미포함)
- [ ] GitHub star 프롬프트 안 뜸 (MAS 채널 자동 비활성)

## 8. 심사 제출

- [ ] 스크린샷: 1280×800 / 1440×900 / 2560×1600 / 2880×1800 중 한 규격으로 통일
- [ ] **Review note 필수 작성** (없으면 거절 확률 높음):
  - 메뉴바 전용(LSUIElement) 앱 — Dock에 안 보이며 메뉴바 아이콘에서 시작한다는 안내
  - 사용법: 아무 앱에서 같은 텍스트를 2번 복사하면 번역 토스트가 뜬다
  - Input Monitoring/Screen Recording 권한이 각각 왜 필요한지 한 줄씩
  - 리뷰어용 OpenRouter 데모 API 키 (Apple Translation은 키 없이 동작하므로 핵심 기능 시연은 키 없이도 가능하다고 명시)
- [ ] 제출 → 심사 중 거절 사유는 docs/mac-app-store.md §6 리스크 표 참조

## 9. 남은 결정 (제출 전 아무 때나)

- [ ] 무료 확정? (현재 계획은 무료 기준)
- [ ] `mas-prep` 브랜치 main 머지 시점 — 머지하면 직배포 자동 릴리즈에도 CGEventTap/Apple Translation이 포함됨
