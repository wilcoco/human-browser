# 사람 브라우저 macOS 0.1.0 Alpha

**[Mac 공용 ZIP 다운로드](https://github.com/wilcoco/human-browser/releases/download/macos-v0.1.0-alpha/human-browser-macos-0.1.0-alpha-universal.zip)**

macOS 14 이상, Apple Silicon과 Intel 공용입니다. 현재 맥판은 개인 기록을 로컬에 저장하는 알파입니다. Android의 Railway 공개 댓글·판단 공유와 기기 간 동기화는 아직 연결되지 않았습니다.

## 설치

1. ZIP을 내려받아 압축을 풉니다.
2. `Human Browser.app`을 응용 프로그램 폴더로 옮겨 실행합니다.
3. 주소창에 `www.naver.com` 같은 주소 또는 검색어를 입력합니다. 왼쪽에서 탐색하고 오른쪽에서 질문·댓글·평가·보류를 작성합니다.
4. **내용 확인 → 확인하고 로컬 저장**을 눌러야 기록이 저장됩니다. 초안은 자동 보관됩니다.

이 배포는 ad-hoc 서명이며 Apple Developer ID 서명·공증은 받지 않았습니다. 개발자 확인 경고가 뜰 수 있습니다. 앱의 출처를 확인한 후 사용자가 직접 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**를 선택할 수 있습니다. [Apple 공식 안내](https://support.apple.com/ko-kr/102445). 시스템 전체의 보안 기능을 끄는 명령은 필요하지 않습니다.

## 기능과 데이터

- macOS WebKit으로 기기에서 직접 브라우징, 탭·뒤로·앞으로·새로고침.
- 현재 URL에 연결된 개인 기록 목록, 선택 문장 인용, 출처가 고정된 초안.
- 질문·댓글·답변·평가·기록 연결·판단 보류, 확인 후 저장과 철회.
- 같은 맥판의 서명된 JSON 기록 내보내기·검증 후 가져오기.
- 웹 쿠키와 세션은 앱 종료 시 초기화됩니다. 판단 기록은 유지됩니다.
- 저장 경로: `~/Library/Application Support/org.humanbrowser.alpha/`. 기록 서명키는 macOS 키체인에 저장합니다.
- 배포 파일에는 사용자 기록, 키체인 키, 개발 PC의 저장 경로가 포함되지 않습니다.
- 기존 개발판의 `work/runtime` 저장소는 그대로 두며 자동으로 옮기지 않습니다. 필요한 기록은 기존 개발판에서 내보내 새 앱에서 가져올 수 있습니다.

Android와 맥판의 기록 형식은 현재 다릅니다. 외부 앱 전용 링크, 일부 팝업·로그인·결제, 웹 파일 다운로드·업로드 및 카메라·마이크 권한은 지원하지 않습니다. AI·분산망은 아직 없습니다.

## 소스에서 빌드

Xcode Command Line Tools, macOS SDK, Python 3가 필요합니다.

```sh
bash scripts/build-macos.sh
```

arm64와 x86_64를 각각 컴파일한 뒤 Universal 실행 파일로 합칩니다. 결과 앱과 ZIP, SHA-256 파일은 `outputs/`에 생성됩니다. 로컬 ad-hoc 서명으로 빌드하며 Developer ID 인증서를 자동으로 사용하지 않습니다.
