# 최신 버전 검증

0.2.0의 실제 Railway 공유·업데이트 시험은 [BACKEND-VALIDATION.md](BACKEND-VALIDATION.md)를 참고하세요. 아래는 0.1.0 당시의 로컬 기능 검증 기록입니다.

# Android 0.1.0 Alpha 검증

2026-10-22 · Android 12 / API 31 ARM64 전용 에뮬레이터 · 합성 자료만 사용

## 실행 결과

- 배포용 APK 설치 성공. 최소 Android 8.0(API 26), target/compile API 35.
- 배포 인증서의 APK v2/v3 서명 검증 성공. 디버그 APK가 아님.
- 저장소 독립 검사: 34개 통과.
- 실제 WebView 및 네이티브 Activity 흐름 검사: 26개 통과.

저장소 검사는 초안·반환 JSON의 변경 불가, 출처 필터, 필수 필드, 잘못된 URL·유니코드·크기 거절, 공개키로 독립 서명 검증, 철회 이력과 중복 철회, 재시작 후 지속성, append-only 기록, 키 소실 시 새 키로 자동 교체하지 않는 동작을 확인했다.

브라우저 검사는 예제 및 외부 HTTPS 페이지 열기, 페이지 방문·입력·확인 화면만으로 승인 기록이 생기지 않음, A 페이지 초안이 B 페이지 이동 후에도 A에 저장됨, 정확한 대상 댓글의 평가, 초안 재시작 복구, 비웹 주소 차단, 철회, 선택 문장 캡처, 네이티브 JS 브리지 미노출을 확인했다. 화면 시험의 입력은 자동화된 합성 입력이며 실제 사람의 의견이나 인간 인증 데이터가 아니다.

## 범위

단일 Android 12 에뮬레이터에서의 기능 검증이다. 실제 휴대폰, 제조사별 환경, 최신 Android 15/16의 화면·키보드·시스템 설정, 모든 웹사이트의 로그인·미디어 호환성을 보증하지 않는다. 내보내기 중 회전·프로세스 복구에 대한 수정은 코드 검토했으며 실제 파일 선택기 종단 시험은 아직 수행하지 않았다.

공유 서버, 고유 인간 증명, AI 관계 제안, 분산망, 전역 신뢰 점수는 구현하지 않았으며 시험 통과 대상으로 주장하지 않는다.

## 재현

빌드 스크립트로 앱 및 두 테스트 APK를 생성하고, 개인 데이터가 없는 전용 Android 에뮬레이터에 설치한다.

```
adb -s EMULATOR_SERIAL shell am instrument -w org.humanbrowser.android.recordtests/.RecordStoreChecks
adb -s EMULATOR_SERIAL shell am instrument -w org.humanbrowser.android.browsertests/.BrowserChecks
```

브라우저 테스트는 기록 없는 전용 시험 설치에서 시작해야 한다. 실사용자의 앱 데이터로 실행하지 않는다.
