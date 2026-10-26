[English](README.md) | [한국어](README-ko.md) | [简体中文](README-zh.md) | [日本語](README-ja.md)

# Element X × Conduit × Tailscale — 완전 로컬 채팅 레시피

**matrix.org도, 공개 포트도, 클라우드 계정도 쓰지 않습니다.** 스마트폰과 자체
서버 사이에서만 완결되는 Matrix 채팅 위에, 로컬 LLM으로 동작하는 AI 봇을 얹는
절차입니다. 아래 내용 전체는 Mac mini + iPhone + Element X로 매일 사용하는
구성에서 검증된 것입니다.

```
iPhone (Element X) ──HTTPS──▶ tailscale serve (443)
                                 ├── /_matrix     ─▶ 127.0.0.1:8008   Conduit/Tuwunel (Docker)
                                 └── /.well-known ─▶ 127.0.0.1:9111   정적 JSON
서버 내부:
  홈서버 ── RocksDB (./db/)
  봇 (Hermes Agent gateway) ── 127.0.0.1:8008 ── OpenAI 호환 엔드포인트(로컬 LLM)
```

얻을 수 있는 것:

- iPhone과 홈서버 사이의 프라이빗 채팅(Element X를 그대로 사용)
- AI 봇(OpenAI 호환이면 무엇이든; 로컬 LLM 권장)
- 스마트폰 푸시 알림(동작 방식과 주의점은 "알림과 프라이버시" 참고)
- 외부 의존은 Tailscale(무료 티어)과 Element X 앱 두 가지뿐. 메시지 본문과
  미디어는 모두 자신의 디스크에 남습니다

필요한 것:

- macOS 기기(Mac mini 권장, Apple Silicon에서 검증) 또는 Linux 박스
- Docker(Mac에서는 colima 권장)
- Tailscale(MagicDNS 활성화) + iPhone에 Tailscale 앱과 Element X
- 소요 시간: 30~60분(봇 없이는 약 20분)

**"완전 로컬"의 범위는?** 메시지 본문·미디어·계정, 그리고 (두뇌를 로컬 LLM으로
하면) 봇의 추론까지 네트워크 밖으로 나가지 않습니다. 다만 외부에 닿는 경로가
3개 있습니다: ① Tailscale의 제어 평면(연결 메타데이터. 제거하려면 자체 호스트
Headscale) ② iOS 푸시 알림(Element의 Sygnal → Apple APNs. 평문 방에서는 푸시
페이로드에 본문이 실림 — §8 참고. Android의 UnifiedPush로 이 경로를 없앨 수
있음) ③ Element X 앱 자체(App Store 배포·앱 내 텔레메트리 설정).

---

## 0. 먼저 정할 것(나중에 바꿀 수 없음)

**`server_name`은 영원합니다.** 모든 사용자 ID(`@you:server_name`)에 포함되며,
나중에 바꾸면 계정·방·기록 전부가 무효가 됩니다. Tailscale을 쓴다면 서버의
tailnet 호스트명(예: `matrix.example.ts.net`)을 처음부터 server_name으로 쓰는
것이 가장 간단합니다.

> 실전 메모: 우리 환경에서는 역사적 사정으로 server_name이 접속 호스트명과
> 다릅니다(federation이 꺼져 있으면 이름은 단순한 라벨로 동작합니다). 그래도
> 새로 구축한다면 **처음부터 같은 이름으로 맞추는 것**이 정답입니다.

federation은 끕니다(`allow_federation = false`). 외부 Matrix 서버와는
연결되지 않는 대신 공격 표면이 거의 0이 됩니다.

---

## 1. 홈서버: Docker로 Tuwunel

[Tuwunel](https://github.com/matrix-construct/tuwunel)은 Conduit 계열에서
활발히 유지보수되는 구현입니다(가벼운 Matrix 홈서버·Rust·단일 바이너리·모든
데이터는 RocksDB 디렉터리 하나). 이 레시피는 이것을 기본으로 사용합니다:
Element X가 읽음 상태에 쓰는 sliding sync 수신 확장을 구현하고 있어, 본가
Conduit이 가진 읽지 않음 배지 버그(gotcha #15)는 처음부터 존재하지 않습니다.
이 레시피의 참조 서버는 Tuwunel v1.9.4로 운영 중입니다.

```bash
git clone https://github.com/<you>/elementx-local-recipe.git
cd elementx-local-recipe/scripts
cp tuwunel.toml.example tuwunel.toml
# tuwunel.toml 편집:
#   server_name         ← 영원히 쓸 이름(위의 주의를 읽을 것)
#   registration_token  ← 긴 랜덤 문자열(예: openssl rand -hex 16)
#   주의: 토큰은 DB를 처음 만들 때 읽힙니다. 나중에 config을 바꿔도 기존 DB에는
#         반영되지 않습니다.
./run-matrix.sh
curl -s http://127.0.0.1:8008/_matrix/client/versions   # JSON이 돌아오면 OK
```

Mac이라면 Docker는 colima를 권장합니다. **컨테이너가 외부로 나가는 DNS를
설정**하세요(알림용 push gateway 접속에 필요합니다. 기본값이 깨져 있으면
"알림만 조용히 안 옵니다"):

```bash
brew install colima docker
colima start --vm-type vz --cpu 2 --memory 2 --disk 20 --mount-type virtiofs \
  --dns 1.1.1.1 --dns 8.8.8.8
```

홈서버는 `127.0.0.1:8008`에서만 listen합니다. TLS는 앞단의 tailscale serve가
처리하므로 서버 자체에 인증서가 필요 없습니다.

> 본가 Conduit을 쓰고 싶어도 동작합니다(`conduit.toml.example`) — 단,
> **0.10.14 이상**을 사용하세요(CVE-2025-68667 / CVE-2026-24471은 0.10.11에서
> 수정, 인증 우회 계열은 0.10.13/0.10.14에서 수정. 릴리스가 느리므로 CVE 정보는
> 직접 추적). 그리고 **gotcha #15** 주의: 본가의 simplified sliding sync는 수신
> 확장을 항상 비워서 돌려주므로 Element X의 읽지 않음 배지가 붙습니다. 영구
> 해결은 Tuwunel로의 이전입니다 —
> [`docs/migrate-conduit-to-tuwunel.md`](docs/migrate-conduit-to-tuwunel.md).

---

## 2. Discovery: `/.well-known/matrix/client`

Element X는 **로그인 화면에 입력한 호스트명**에서
`GET /.well-known/matrix/client`을 가져와 그 안의 `base_url`을 사용합니다.
이 파일을 제공하는 것이 discovery의 본류입니다.

```bash
# 정적 파일(serve-wellknown.py가 자동 생성도 합니다)
mkdir -p wellknown-root/matrix
echo '{"m.homeserver":{"base_url":"https://matrix.example.ts.net"}}' \
  > wellknown-root/matrix/client

# 127.0.0.1:9111로 제공(--homeserver-url은 자신의 호스트명)
python3 scripts/serve-wellknown.py --root wellknown-root --port 9111 \
  --homeserver-url https://matrix.example.ts.net
```

상시 구동은 launchd(Mac)나 systemd(Linux)에 등록합니다. 내용은 정적 JSON이므로
`python3 -m http.server 9111 --directory wellknown-root --bind 127.0.0.1`도
같습니다.

> 실측+소스 확인 메모: Conduit 본가(v0.10.15)의 well-known 설정은
> `[global.well_known]` **서브테이블**로 쓰는 것이 정답입니다. conduwuit /
> continuwuity 계열 설정에서 보이는 플랫한 `well_known_client` 키는 **포크
> 전용 키 이름**이라 본가에서는 조용히 무시됩니다(정의되지 않은 키는 catchall로
> 버려지며 경고도 없습니다). 무시된 경우 Conduit 자신의 `8008/.well-known`은
> `server_name` 유래의 기본 URL을 돌려줍니다. 로그인 응답에도 `well_known`이
> 없으므로 **discovery의 본류는 "입력한 호스트명의 `/.well-known`" 한 곳뿐**입니다.
> 여기만 올바르게 제공하면 Conduit 자신의 well-known이 어긋나도 영향이 없습니다.
> well-known 제공은 다른 웹 서버가 해도 되며(spec 명시) CORS 헤더 부여가
> SHOULD입니다(`python3 -m http.server`는 CORS 헤더를 보내지 않으므로 엄격하게
> 하려면 `serve-wellknown.py`를 사용하세요).

---

## 3. tailscale serve로 외부에 내보내기(포트 포워딩 없음)

TLS 종단과 공개는 tailscale serve가 담당합니다. 라우터 포트 개방이 필요 없고
서버는 tailnet 안에서만 보입니다.

```bash
tailscale serve --bg --https=443 --set-path=/_matrix http://127.0.0.1:8008/_matrix
sleep 2
tailscale serve --bg --https=443 --set-path=/.well-known http://127.0.0.1:9111/.well-known
sleep 2
tailscale serve status   # 두 줄이 모두 있는지 반드시 확인
```

또는 `scripts/serve-paths.sh`를 실행하세요(확인 포함).

**ACL 주의**: tailnet 정책에서 스마트폰에서 이 서버로의 `tcp:443`을 허용해야
합니다(Tailscale 기본값은 거부). 허용 전에는 스마트폰만 타임아웃됩니다.
서버가 자기 자신은 볼 수 있어 알아차리기 어렵습니다. 서버 자신의 curl도
오탐이 나올 수 있으므로 확인은 다른 tailnet 기기에서 하는 것이 확실합니다.

---

## 4. 계정 생성

**Element X는 로그인만 가능하고 등록은 못 합니다**(앱 내 계정 생성 흐름은
관리형 인증 서버 대상입니다). 등록 토큰으로 API에서 만듭니다:

```bash
export REGISTRATION_TOKEN='conduit.toml에 넣은 토큰'
./scripts/create-account.sh https://matrix.example.ts.net you
# 비밀번호를 물으면 입력 → Element X에서 같은 조합으로 로그인
```

하는 일은 요청 하나뿐입니다:

```
POST /_matrix/client/v3/register
{"username": "you", "password": "...", "inhibit_login": true,
 "auth": {"type": "m.login.registration_token", "token": "..."}}
```

---

## 5. Element X로 로그인(iPhone)

1. iPhone에 Tailscale 앱(연결 ON)과 Element X를 설치
2. Element X 로그인 화면에서 "Sign in manually → Change account provider →
   Other"를 골라 `https://matrix.example.ts.net` 입력
   (QR 코드 로그인은 Matrix Authentication Service 전제라 Conduit에서는
   불가능합니다. 사용자명+비밀번호로 로그인합니다. Element X는 먼저 OIDC 인증
   메타데이터를 확인하고 없으면 비밀번호 로그인으로 폴백하므로 MAS 없이도
   순조롭게 통과합니다)
3. 4단계에서 만든 계정으로 로그인
4. 방 만들기 → 봇 초대(6단계 이후에)
5. 로그인 직후 복구 키·기기 확인 안내가 나오지만 암호화 방을 안 쓴다면 모두
   건너뛰어도 됩니다

**단말 쪽 주의(iPhone)**: Tailscale의 MagicDNS를 켜세요. iCloud 프라이빗
릴레이 / Wi-Fi의 "IP 주소 추적 제한"은 `*.ts.net` 접속을 간헐적으로 깨는
알려진 문제라 이 Wi-Fi에서는 끄세요. 상주 VPN이나 프라이버시 계열 브라우저
확장도 `*.ts.net`을 막을 수 있으니 끄거나 제외하세요.

**이 방들을 암호화하지 마세요**(이 레시피의 봇은 E2EE 미대응 — 이유는
"함정" 참고). Element X는 평문 방도 평소처럼 잘 씁니다.

---

## 6. AI 봇 더하기(Hermes Agent)

채팅방에 사는 봇은 [Hermes Agent](https://hermes-agent.nousresearch.com)
(Nous Research)의 gateway 기능으로 구현했습니다. 봇의 두뇌는 OpenAI 호환
엔드포인트면 무엇이든 되고, LiteLLM 경유 등으로 로컬 LLM 서버를 가리켜 완전
오프라인 운용도 가능합니다.

```bash
# 1) 봇용 계정 생성
REGISTRATION_TOKEN=... ./scripts/create-account.sh https://matrix.example.ts.net bot

# 2) 봇용 HOME과 환경 변수 준비
mkdir -p ~/matrix-bot-home
cp scripts/matrix.env.example ~/matrix-bot-home/.env
chmod 600 ~/matrix-bot-home/.env
#   MATRIX_HOMESERVER=http://127.0.0.1:8008
#   MATRIX_USER_ID=@bot:matrix.example.ts.net
#   MATRIX_PASSWORD=...
#   MATRIX_DEVICE_ID=botdev01          ← 고정 권장(유령 기기 방지)
#   MATRIX_ALLOWED_USERS=@you:matrix.example.ts.net
#   MATRIX_HOME_ROOM=!…:…              ← 봇의 홈 방
#   MATRIX_E2EE_MODE=optional
#   OPENAI_BASE_URL / OPENAI_API_KEY   ← 두뇌(OpenAI 호환이면 무엇이든)

# 3) launchd에 등록(plist 템플릿을 자신의 경로에 맞게 편집)
cp scripts/com.example.matrix-bot.plist.example \
   ~/Library/LaunchAgents/com.example.matrix-bot.plist
#   (hermes CLI 경로·WorkingDirectory·HERMES_HOME을 실제 경로로)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.matrix-bot.plist
```

인증 정보는 `$HERMES_HOME/.env`에서 읽습니다(plist에 비밀을 쓰지 마세요).
동작 확인은 Element X에서 봇에게 DM을 보내는 것뿐입니다. 두뇌 속도에 따라
15초 전후로 답이 옵니다.

---

## 7. 운용

### 감시(watchdog)

`scripts/matrix-watchdog.sh`를 5분마다 돌리면 끊어진 단계만 자동 수복합니다:

```
tailscaled → colima/Docker → 컨테이너 → 127.0.0.1:8008 → tailscale serve → 봇 프로세스
```

- 같은 단계의 수복은 10분에 1회까지. 3연패하면 수복을 멈추고 경보만 냅니다
  (`ALERT_HOOK`에 알림 스크립트를 넘기세요).
- 정지: `touch .watchdog-stop` / 드라이런: `WD_DRY=1 ./matrix-watchdog.sh`

### 백업

`scripts/standby-backup.sh` — 하루 1회 다른 기기로 DB를 동기화합니다.

- **핫 방식(macOS)**: APFS 로컬 스냅샷에서 rsync = 서버를 멈추지 않습니다.
  RocksDB는 스냅샷 시점의 정합 복사본이 나옵니다.
- **콜드 방식(폴백)**: `docker stop → rsync → docker start`(약 30초 정지·
  trap으로 복구 보장). Linux에서는 콜드 방식이나 rocksdb checkpoint를 쓰세요.

### 자주 있는 고장

| 증상 | 볼 곳 |
|---|---|
| 스마트폰만 연결 안 됨 | tailnet ACL의 `tcp:443` 허용 |
| 봇이 침묵(프로세스는 생존) | gateway.log의 `stopping sync` / `No adapter` 마커 → 재시작 |
| 알림만 안 옴 | 컨테이너 외향 DNS(`colima --dns`)와 push gateway 도달성 |
| `/_matrix`가 502 | serve status에서 사라진 경로 확인 → `serve-paths.sh` 재실행 |

---

## 8. 알림과 프라이버시(실측)

- **iOS의 Element X 알림**은 Element가 운영하는 push gateway(Sygnal,
  `matrix.org` 상) → Apple APNs 경로로 옵니다. 자체 Sygnal은 자체 빌드 앱과
  APNs 키가 필요해 **App Store판 Element X에서는 불가능**합니다. 따라서 iOS
  알림을 원하면 알림 메타데이터가 Apple/Element 경로를 지난다는 점을 받아들여야
  합니다(본문이 암호화되어 있어도 "무언가 도착했다"는 사실은 통과합니다).
- **평문 방의 페이로드에는 본문이 실립니다.** E2EE 방이라면 push 페이로드는
  room_id와 event_id뿐(복호화 전까지 본문 없음)이지만 평문 방에서는 방 이름·
  발신자·본문이 그대로 APNs로 흐릅니다. **민감한 방은 E2EE화하거나 알림을
  끄세요.** 이 레시피의 봇 구성은 평문 전제이므로 알림에 흐르는 내용에
  주의하세요.
- Android의 Element X는 UnifiedPush(자체 호스트 ntfy 등)를 선택할 수 있어
  Android 중심이라면 알림까지 완전 자체 호스트화할 수 있습니다(iOS는 위 제약).
- **알림이 오는지 실측하는 방법**: Element X → 설정 → 알림 → Troubleshooting의
  **Test Push Gateway** / **Test Push Loop Back** 실행 후 **Push History**
  확인. 안 오면 이 순서로: ① 컨테이너 외향 DNS/HTTPS(`colima --dns 1.1.1.1`)
  ② 알림 설정의 "Enable notifications on this device"를 한 번 끔→켬(로그아웃→
  재로그인 시 pusher가 재등록되지 않는 알려진 버그 회피) ③ 단말 MagicDNS
  ④ 프라이빗 릴레이/VPN.
- **알림은 2단계**입니다(push gateway가 울림 → Element X가 홈서버에서 본문
  취득). 후단은 Tailscale 길이므로 Tailscale이 죽으면 소리만 나고 본문이 안
  오거나 지연됩니다.

---

## 9. 함정(실전 검증)

1. **server_name은 영원**. 바꾸면 모든 ID·방·기록이 무효.
2. **E2EE는 봇을 죽입니다** — macOS 허브의 경우. Linux 호스트에서는 봇 쪽
   암호화 라이브러리(mautrix의 Olm/Megolm)가 네이티브로 동작하므로 암호화 방에
   대응하는 봇도 만들 수 있습니다(커뮤니티 사례 있음·Credits 참고). 방에
   `m.room.encryption`을 세우면 macOS의 봇은 전부 못 읽게 됩니다. 평문 운용으로
   통하세요.
3. **같은 server_name의 서버를 2대에서 동시 기동 금지**(split brain = 같은
   계정이 두 DB에 기록되어 기록이 영원히 불일치). 대기기를 만들 때는 반드시
   한쪽을 끄고 다른 쪽을 올리세요.
4. **Conduit v0.10.15는 `well_known_client`를 무시합니다.** discovery는
   "입력 호스트명의 `/.well-known`"(2단계)가 본류. Conduit 자신의
   `8008/.well-known`은 오래된 이름을 돌려줘도 아무도 보지 않습니다.
5. **로그인 응답에 `well_known`이 없습니다.** 클라이언트는 입력 URL을 계속
   쓰므로 URL 오타는 로그인 실패로 즉시 알 수 있습니다.
6. **tailnet ACL.** 새로 serve한 포트는 정책에 스마트폰 쪽 `tcp:443` 허용을
   추가하기 전까지 타임아웃됩니다. 서버 자신의 curl은 오탐이 있으므로 확인은
   다른 기기에서.
7. **tailscale serve 항목은 경합으로 사라질 수 있습니다.** 쓸 때마다
   `serve status`로 확인하고 사라졌으면 다시 추가(watchdog이 이걸 합니다).
8. **컨테이너 DNS.** colima 기본값에서는 외향 이름 해석이 죽을 수 있고 알림
   (push gateway 접속)만 조용히 실패합니다. `--dns 1.1.1.1` 권장.
9. **Element X에서는 계정을 만들 수 없습니다.** API+등록 토큰으로 만드세요
   (4단계).
10. **M_UNRECOGNIZED**는 클라이언트 API 버전(`v3`)과 서버 구현 차이일 때가
    많습니다. Conduit v0.10.15는 v3 엔드포인트 대응.
11. **QR 코드 로그인·통화는 안 됩니다.** QR 로그인(MSC4108)은 MAS 필수,
    통화(Element Call)는 LiveKit SFU 별도 구축이 필요합니다. coturn(TURN)을
    더해도 Element X 통화는 고쳐지지 않습니다.
12. **즐겨찾기(태그)와 전문 검색은 Conduit에서 조용히 버려지거나 미대응.**
    새 방 초대가 목록에 안 보이는 보고(sliding sync 계열)나 EX 동기화가 몇 분
    늦게 따라오는 보고도 있습니다. 실용상은 방을 한 번 열면 나옵니다.
13. **미디어 purge가 불가능**(S3도 미대응) = DB와 미디어는 단조 증가. 디스크
    감시를 넣으세요. `max_request_size`(기본 20MB)를 올리면 클라이언트 재시작으로
    반영됩니다.
14. **등록 토큰은 정적 1본**(config에 쓰기만). 기한 있는 복수 토큰이 필요하면
    포크(Continuwuity의 admin room 토큰 등)를 검토하세요.
15. **"읽었는데 읽지 않음 배지가 안 사라짐"은 본가 Conduit의 알려진 미수정
    버그입니다.** Element X의 읽음·입력 중 표시는 sliding sync의 수신 확장
    (MSC3960)으로 오지만 Conduit v0.10.15는 이 응답을 항상 비워서 돌려줍니다
    (소스 확인: `sync.rs`에서 `receipts.rooms` / `typing.rooms`가 하드코딩으로
    비어 있음). 읽음 요청 자체는 서버에 정상 저장되므로 데이터는 잃지 않습니다.
    응급 처치는 Element X 캐시 클리어(설정 → 버전 번호 7회 탭 → 개발자 메뉴 →
    Clear cache). **단 캐시 클리어는 임시방편** — 검증 환경에서는 몇 시간 만에
    재발해 새 메시지 1건에 99+ 배지가 나오고 클리어 후에도 30건이 남았습니다.
    **영구 해결은 서버를 Tuwunel로 이전**하는 것(수신 확장 구현됨·Conduit DB의
    in-place 이전으로 계정·방·기록·로그인 유지·정지 약 2분). 검증된 절차는
    [`docs/migrate-conduit-to-tuwunel.md`](docs/migrate-conduit-to-tuwunel.md).

---

## 10. 대기기(옵션)

DB를 매일 다른 기기로 동기화해 두면 서버가 죽어도 몇 분 만에 채팅을 부활할 수
있습니다(절차와 복귀 절차: `docs/failover.md`). 대기기는 평소 전원을 끄고,
장애 시 DB를 맞바꾸어 기동만 하면 됩니다.

## 11. 장기 관점: Conduit의 개발 정체와 포크

Conduit 개발은 사실상 1인 프로젝트로 느려졌습니다(미디어 purge 없음·S3 없음·
기능 추가가 느림). 커뮤니티는 포크 이전을 진행 중입니다:

- **Tuwunel** — Conduit에서의 이전을 공식 지원(실제 이전 사례에서 계정과
  내용 전부 무사히 유지)
- **Continuwuity** — conduwuit 계열의 커뮤니티 포크(Conduit에 없는 기능,
  예: admin room에서 발급하는 기한 있는 등록 토큰)

지금 구성이 불편하지 않다면 Conduit에 머물러도 됩니다. 이전할 때는
**server_name과 DB 백업이 그대로 이어집니다**(문서화된 이전 사례는 전부
보존됨). 이 레시피의 tailscale serve·well-known·봇 쪽은 바꿀 필요가 없을
것입니다.

> 실전 메모: Tuwunel(ghcr.io/matrix-construct/tuwunel)을 같은 호스트의 다른
> 포트에 띄워 수신 확장을 실측한 결과, sliding sync의 `extensions.receipts`에
> 읽음 데이터가 올바르게 돌아오는 것을 확인했습니다(Conduit v0.10.15는 항상
> 빈 맵). 그 확인 후 실제로 Conduit에서 Tuwunel로 이전을 완료했습니다 — 읽지
> 않음 배지 문제가 사라지고 캐시 클리어 응급처치도 필요 없어졌습니다. 전체
> 절차는 [`docs/migrate-conduit-to-tuwunel.md`](docs/migrate-conduit-to-tuwunel.md).

---

## Credits

- [Conduit](https://conduit.rs) — Matrix 홈서버(Apache-2.0). 설정 사양은
  [공식 docs](https://docs.conduit.rs/)와
  [v0.10.15 소스](https://gitlab.com/famedly/conduit)로 확인
- [Element X](https://element.io) — 클라이언트 앱.
  [요구 사항(element-meta#1915)](https://github.com/element-hq/element-meta/issues/1915)과
  [네이티브 sliding sync 전환 발표](https://matrix.org/blog/2024/11/14/moving-to-native-sliding-sync/) 참조
- [Tailscale](https://tailscale.com) — 네트워크(serve / ACL)
- [Hermes Agent](https://hermes-agent.nousresearch.com) — 봇 gateway(Nous Research)
- 커뮤니티 지식: r/selfhosted·Hacker News의 셀프호스팅 사례,
  [Tailscale × iCloud Private Relay 알려진 문제](https://github.com/tailscale/tailscale/issues/21677),
  [Element X iOS의 pusher 재등록 버그](https://github.com/element-hq/element-x-ios/issues/2602),
  그리고 [Hermes 봇을 Signal에서 Matrix로 옮긴 유사 사례(Linux에서 E2EE)](https://www.reddit.com/r/hermesagent/comments/1towdi5/i_moved_my_hermes_agent_from_signal_to_matrix/)

### Contributors

- **tenhkspark** — 설계·운용·실기 검증
- **로컬 LLM군** — 문서 검토와 번역 검토:
  GLM-5.3-Flash, Qwen3.8-Flash-Next, Nemotron 3.5 Lightning(모두 자가 서버에서
  가동)

## License

MIT — 자세한 내용은 [LICENSE](LICENSE)
