# 사람 브라우저 · Human Browser

읽고 끝나는 대신, 출처에 연결된 사람의 질문과 판단을 남기는 브라우저입니다.

## Android

**[설치 APK 다운로드](https://github.com/wilcoco/human-browser/releases/download/v0.1.0-alpha/human-browser-android-0.1.0-alpha.apk)** · [릴리스 안내](https://github.com/wilcoco/human-browser/releases/tag/v0.1.0-alpha)

Android 8.0 이상. Android가 요청하면 다운로드에 사용한 앱의 외부 앱 설치를 허용한 뒤 설치하세요.

- 웹페이지는 휴대폰에서 직접 열립니다. 서버에서 브라우저를 실행하지 않습니다.
- 현재 주소에 연결된 댓글·질문·평가·판단 기록이 함께 표시됩니다.
- 작성 중인 출처는 고정되며 **내용 확인 → 확인하고 저장** 이후에만 승인한 기록이 됩니다.
- 이유를 아직 모르는 보류와 서로 다른 판단을 남길 수 있습니다.

현재 공개 APK 0.1.0은 개인 로컬 MVP입니다. `main`의 0.2.0 소스에는 Railway 공개 댓글 연결이 추가되었습니다. 서버의 온라인 검증과 새 APK 공개 배포는 진행 중입니다. AI 관계 제안과 분산망은 후순위입니다.

[설치·사용·개인정보·빌드 안내](apps/android/README.md)

이 저장소에는 Android 앱 소스와 빌드·검증 스크립트가 있습니다. 개인 기록, 서명 개인키, 대화 및 특허 원본은 포함하지 않습니다.


## Railway 중앙 백엔드

0.2.0부터 개인 기록별 공개 게시와 페이지별 공개 댓글 조회를 지원합니다. 기존 개인 기록은 자동 업로드하지 않습니다. 분산망은 후순위입니다. [백엔드 구성·API·운영 안내](services/api/README.md)를 참고하세요.
