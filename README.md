# 사람 브라우저 · Human Browser

읽고 끝나는 대신, 출처에 연결된 사람의 질문과 판단을 남기는 브라우저입니다.

## Android

**[설치 APK 다운로드](https://github.com/wilcoco/human-browser/releases/download/v0.2.1-alpha/human-browser-android-0.2.1-alpha.apk)** · [릴리스 안내](https://github.com/wilcoco/human-browser/releases/tag/v0.2.1-alpha)

Android 8.0 이상. 기존 0.1.0 위에 새 APK를 덮어 설치하면 됩니다. 앱을 삭제하지 마세요. Android가 요청하면 다운로드에 사용한 앱의 외부 앱 설치를 허용한 뒤 설치하세요.

- 웹페이지는 휴대폰에서 직접 열립니다. 서버에서 브라우저를 실행하지 않습니다.
- 현재 주소에 연결된 댓글·질문·평가·판단 기록이 함께 표시됩니다.
- 작성 중인 출처는 고정되며 **내용 확인 → 확인하고 저장** 이후에만 승인한 기록이 됩니다.
- 이유를 아직 모르는 보류와 서로 다른 판단을 남길 수 있습니다.

0.2.1은 새 창 링크·주소 입력을 개선했으며 Railway 서버에 연결됩니다. 개인 기록 카드에서 **이 기록 공개하기 → 확인하고 공개**를 선택하면 같은 URL을 보는 사람들과 판단을 공유할 수 있습니다. **공개/개인 → 공개 보기**로 다른 사람의 기록을 확인합니다. 기존 개인 기록과 초안은 자동 공개하지 않습니다. AI 관계 제안과 분산망은 후순위입니다.

[설치·사용·개인정보·빌드 안내](apps/android/README.md)

이 저장소에는 Android·macOS 앱 소스와 빌드·검증 스크립트가 있습니다. 개인 기록, 서명 개인키, 대화 및 특허 원본은 포함하지 않습니다.


## Railway 중앙 백엔드

0.2.0부터 개인 기록별 공개 게시와 페이지별 공개 댓글 조회를 지원합니다. 기존 개인 기록은 자동 업로드하지 않습니다. 분산망은 후순위입니다. [백엔드 구성·API·운영 안내](services/api/README.md)를 참고하세요.

## macOS

**[Mac 공용 ZIP 다운로드](https://github.com/wilcoco/human-browser/releases/download/macos-v0.1.0-alpha/human-browser-macos-0.1.0-alpha-universal.zip)** · [설치 안내](apps/macos/README.md)

macOS 14 이상, Apple Silicon·Intel 공용. ZIP을 풀고 `Human Browser.app`을 응용 프로그램으로 옮깁니다. Apple 공증 전 알파이므로 첫 실행 때 개발자 확인 경고가 나올 수 있습니다.

맥판은 현재 **로컬 개인 기록 버전**이며 Railway 공유·Android와 동기화는 아직 연결되지 않았습니다.
