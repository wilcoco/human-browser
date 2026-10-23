# Android 0.2.1 탐색 검증

검증일: 2026-10-23. Android 12 전용 에뮬레이터, System WebView 91.0.4472.114. 실제 사용자 기기는 사용하지 않았습니다.

## 수정

0.2.0은 새 창 요청을 거절하고 주소를 복사하라는 안내를 표시했습니다. 0.2.1은 사용자가 누른 링크의 새 WebView를 실제로 연결하므로 URL뿐 아니라 새 창의 실행 문맥과 폼 제출을 유지합니다. 뒤로가기로 원래 창에 복귀하고, 현재 창만 주소창·판단 패널을 갱신합니다. 자동 팝업은 차단하고 최대 8개 창을 유지합니다.

주소 입력의 Unicode 경계 공백, 대문자 HTTPS, 생략한 프로토콜, 호스트·포트, 경로의 공백, 한글 도메인을 처리합니다. 기존 기록의 출처 URL을 다시 쓰지 않습니다. HTTP 주소는 HTTPS로 연결하며 인증서 오류는 우회하지 않습니다. 주소창을 선택하면 기존 주소가 전체 선택됩니다.

## 통과한 검사

- 최종 서명 APK에서 탐색 검사 38개 통과: 주소 입력·잘못된 주소 거절, 실제 터치에 의한 target=_blank·window.open·빈 창 후 지연 이동·새 창 폼 제출, 뒤로가기·window.close, 자동 팝업 차단, 초안 출처 고정, SPA 주소 동기화, 방문만으로 판단이 생성되지 않음.
- 실제 `www.naver.com` 입력 → `https://m.naver.com/`의 NAVER 본문 표시 → 확장 영역 메뉴 표시 → 카페 링크 탭 후 `https://m.cafe.naver.com/`로 주소 이동 확인.
- 기존 브라우저 통합 검사 26개 통과: 인용·초안·명시적 저장·특정 기록 평가·철회·앱 재시작 보관.
- 0.2.0 위에 0.2.1 설치 성공. 기존 배포와 같은 인증서, versionCode 3, APK v2/v3 서명 검증 완료.

## 관찰된 한계

`www.naver.com` 자체는 이전 0.2.0 에뮬레이터에서도 열렸습니다. 사용자가 보고한 HTTPS 주소 거절 현상 전체를 동일 조건으로 재현했다고 주장하지 않습니다. 주소 정규화와 입력 편의 보완을 적용했습니다.

네이버 카페는 주소 이동 후 본문 표시 검사에서 실패했습니다. 메뉴 경유와 직접 접속 모두 빈 root를 반환했고, WebView 콘솔에 `Uncaught TypeError: e.split(...).at is not a function`이 기록됐습니다. 테스트 기기의 구형 WebView 91 호환성 문제로 판단하며, 카페 본문 표시가 검증됐다고 주장하지 않습니다. 실제 기기의 최신 Android System WebView에서 추가 확인이 필요합니다. 사이트 코드에 임의의 호환성 스크립트를 주입하지 않았습니다.

외부 앱 전용 연결·로그인·결제·모든 사이트와 모든 기종의 호환성은 보증하지 않습니다. 파일 업로드·다운로드 및 탭 목록 UI는 아직 없습니다. 백엔드와 공유 프로토콜은 이 버전에서 변경하지 않았습니다.

## 재현

`bash scripts/build-android.sh`, `bash scripts/test-android-browser.sh`로 빌드합니다. 개인 데이터 없는 전용 에뮬레이터에 두 APK를 설치한 후 다음을 실행합니다.

```sh
adb shell am instrument -w org.humanbrowser.android.browsertests/.NavigationChecks
adb shell am instrument -w -e stage cafe-probe org.humanbrowser.android.browsertests/.NavigationChecks
```

BrowserChecks는 새 테스트 저장소에서 별도로 실행합니다. 테스트 APK는 공개 배포 APK에 포함되지 않습니다.

새 창 처리 참조: [Android WebChromeClient](https://developer.android.com/reference/android/webkit/WebChromeClient), [Chromium WebView 새 창 처리](https://chromium.googlesource.com/chromium/src/+/refs/tags/139.0.7258.135/android_webview/docs/how-does-on-create-window-work.md).
