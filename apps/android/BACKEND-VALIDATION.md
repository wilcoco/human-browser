# Android 0.2.0 공유·업데이트 검증

2026-10-23 (한국 시간). Android 12 / API 31 ARM64 전용 에뮬레이터에서 합성 입력만 사용했습니다.

## 실제 온라인·업데이트 시험

기존 공개 APK 0.1.0을 설치해 합성 판단을 저장한 뒤, 삭제 없이 0.2.0 APK를 덮어 설치했습니다. 업데이트·온라인 검사 18개를 통과했습니다.

- 기존 기록 ID와 서명 보존, 이전 서명키로 새 평가 작성
- 업데이트만으로 기존 기록이 공개되지 않음
- 실제 네이티브 확인 버튼으로 공개 게시, 서버의 접수 응답
- 별도 HTTP 조회 클라이언트에서 같은 URL의 판단·인용 근거·보류 상태 조회
- 앱 공개 패널에 서버에서 받은 판단 표시
- 정확한 원기록을 대상으로 평가 작성·공개·조회
- 작성자의 철회가 서버 목록에 반영됨, 별도 평가는 유지됨

시험 종료 후 모든 합성 게시물을 철회했고 별도 HTTPS 조회에서 해당 시험 작성자의 활성 기록 0개를 확인했습니다. 서버의 불변 감사 이력에는 합성 원기록과 철회 이벤트가 남습니다.

## 앞서 완료한 검사

- API 독립 시험 12개: 서명 위조·내용 변조·정규 직렬화·실제 AndroidKeyStore 서명, 게시·중복·대상·철회 소유권, 페이지 분리, DB 재개방, URL별 다인 판단 공유, HTTP 흐름
- Android 브라우저 회귀 26개
- 공개 승인·취소·전송 대기 보존 13개
- 저장소 독립 검사 34개 (0.1.0)
- 실제 Railway HTTPS 서버의 두 키 간 게시·평가·조회·철회 시험

## 배포 파일

패키지 `org.humanbrowser.android`, versionCode 2, versionName `0.2.0-alpha`.
최소 Android 8.0(API 26), target API 35. 릴리스 APK v2/v3 서명 검증을 통과했습니다.

0.1.0과 같은 배포 인증서 SHA-256:
`171003bfc327e046450d7f1e889c397324092b4ca60605021739f18e2da80377`

## 범위와 한계

실제 휴대폰·다양한 Android 버전·제조사별 호환성 시험은 아직 없습니다. 네트워크 끊김 상태의 전송 대기 보존은 별도 검사했으며 모든 이동통신·절전 상황을 검증한 것은 아닙니다. Mac 앱 연동, AI, 분산망, 고유 인간 인증은 이번 배포 범위가 아닙니다. 서버의 예약 백업·복구 시험도 별도 운영 작업입니다.

## 재현

`bash scripts/test-android-browser.sh`로 시험 APK를 만듭니다. 아래 단계는 개인정보 없는 별도 에뮬레이터에서만 실행합니다. seed는 빈 0.1.0 설치에서 시작해야 하며, 이후 0.2.0 설치는 `adb install -r`로 진행합니다.

```sh
adb -s EMULATOR_SERIAL shell am instrument -w -e stage seed org.humanbrowser.android.browsertests/.OnlineChecks
# 0.2.0 APK를 기존 앱 위에 설치한 다음
adb -s EMULATOR_SERIAL shell am instrument -w -e stage online org.humanbrowser.android.browsertests/.OnlineChecks
```

API 시험: `node --test tests/api/*.test.mjs`
실제 서버 합성 시험: `node scripts/smoke-api.mjs https://human-browser-production.up.railway.app`
