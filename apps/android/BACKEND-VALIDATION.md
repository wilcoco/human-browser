# Railway 백엔드 검증 — 2026-10-22

- 중앙 API: Node 24 + SQLite, 단일 Railway 서비스 /data 영구 볼륨
- 공개 주소: https://human-browser-production.up.railway.app
- GitHub: https://github.com/wilcoco/human-browser
- API 독립 시험 11개 통과: 서명·내용 변조, 정규 직렬화, 실제 AndroidKeyStore 서명, 게시·중복·대상·철회 소유권, 페이지 분리, DB 재개방, HTTP 통합
- Android 12 에뮬레이터 브라우저 회귀 26개 통과
- Android 공개 승인·취소·전송 대기 보존 검사 13개 통과
- 0.2.0 APK 릴리스 서명 검증 통과; 0.1.0과 같은 배포 인증서
- 실제 휴대폰 호환성과 Railway를 통한 기기 간 온라인 흐름은 미검증

## 배포 상태

Railway 프로젝트 authentic-radiance의 human-browser 서비스에 GitHub main, /data 볼륨, HTTPS 도메인을 연결했습니다. CLI 배포는 코드 스냅샷 단계에서 `Failed to snapshot repository`로 실패했으며 앱 빌드는 시작되지 않았습니다. 후속 GitHub 배포는 대기 상태입니다. Railway 공식 상태 페이지에 플랫폼 장애가 공지되어 있습니다.

온라인 정상 운영으로 확인되지 않았으므로 GitHub의 기존 0.1.0 APK 릴리스는 유지했습니다. 새 APK는 로컬 outputs/human-browser-android-0.2.0-alpha.apk 입니다. 실제 온라인 검증 후 배포해야 합니다.

복구 후 점검: `node scripts/smoke-api.mjs https://human-browser-production.up.railway.app`는 고유 합성 출처에만 시험 기록을 게시하고 끝에 철회합니다. 실제 사용자 자료는 사용하지 않습니다. 이어 Android의 공개 조회·게시·철회 흐름을 확인하고 0.2.0 릴리스를 게시합니다.
