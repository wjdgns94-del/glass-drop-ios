# Glass Drop (iOS)

노트북의 Glass Drop 앱이 보내는 화면을 아이패드·아이폰에서 받아 보여 주는 짝 앱이에요. 노트북 쪽 소스는 `C:\dev\dumoni2`(폴더 이름만 옛 이름)에 있고, 통신 규격은 그곳의 `PROTOCOL.md`, 식별자는 `IDENTIFIERS.md`가 정본이에요.

## 먼저 알아둘 것 (중요)
- **컴파일은 클라우드에서 처음 확인됨.** 이 PC는 윈도우라 Swift를 한 번도 컴파일하지 못했어요. 코드는 눈으로만 검토했고, GitHub Actions의 첫 빌드에서 오류가 나올 수 있어요. 오류가 나면 로그(`build-log` 아티팩트)를 보고 고치면 돼요.
- 실기기에서 돌려 본 적이 없어요. 블루투스 페어링과 영상은 실기기(아이패드/아이폰 + 노트북)에서만 시험할 수 있어요(시뮬레이터는 블루투스 안 됨).
- 번들 ID `app.glassdrop.client` 는 **임시 값**이에요. 사장님이 정해야 해요.

## 폴더 구조
```
project.yml                 XcodeGen 설정 (.xcodeproj 은 여기서 생성, 손으로 쓰지 않음)
.github/workflows/build.yml macOS 러너에서 xcodegen → xcodebuild(시뮬레이터, 서명 없음)
GlassDrop/
  GlassDropApp.swift        앱 시작, 앞/뒤로 갈 때 처리
  ContentView.swift         연결 화면, 전체 화면 영상, 컨트롤 카드
  SessionModel.swift        전체 흐름: 찾기 → 페어링(hello) → 화면 주소 → 영상, 공유·클립보드
  BLEClient.swift           CoreBluetooth(노트북 찾기, 특성 읽기/쓰기/알림)
  NWStream.swift            TCP 연결(Network.framework) async 래퍼
  VideoClient.swift         영상 TCP: 열쇠 전송 → H.264 수신
  AnnexBParser.swift        Annex-B 바이트를 NAL로 자르기, AUD(00 00 00 01 09 F0)를 프레임 끝으로 사용
  H264Decoder.swift         VTDecompressionSession으로 디코딩 (SPS/PPS는 스트림에서 읽음)
  VideoSurface.swift        AVSampleBufferDisplayLayer로 전체 화면 표시
  ClipClient.swift          클립보드 TCP 채널(G/X/T/P)
  Identifiers.swift         새 UUID·포트 (옛 듀모니 값은 쓰지 않음)
  Models.swift              hello JSON, 주소 파싱, 오류 번호 → 쉬운 한국어
```
Info.plist 는 `project.yml` 이 만들어 줘요(블루투스·로컬 네트워크 사용 문구 포함).

## 만든 기능
1. 같은 와이파이 노트북 찾기: BLE로 노트북 서비스 UUID 스캔 → 목록에서 [연결]. 또는 `IP`와 열쇠(32글자) 직접 입력(`IP:포트:열쇠` 통째로 붙여 넣기도 됨).
2. 페어링: 노트북에 hello(JSON, `pair:true`)를 쓰고, 노트북 쪽 오류 128(페어링 중)이면 1.5초마다 최대 40번 다시 시도해요. iOS가 띄우는 숫자 확인 창은 시스템이 처리해요.
3. 화면: BLE로 `IP:51968:열쇠`를 읽어 TCP 연결 → 열쇠 32글자 전송 → H.264 수신 → VideoToolbox 디코딩 → 전체 화면. 끊기면 최대 3번 자동 재연결, 앱이 백그라운드로 갔다 오면 다시 연결.
4. 공유 스위치(Sharing 특성): 마우스·키보드, 클립보드 양방향, 포인터 속도. 포인터가 어느 쪽에 있는지 표시(PointerSide).
5. 클립보드: 짧은 글(512바이트 이하)은 BLE, 긴 글·그림은 TCP 채널. 노트북이 알림(t/L/i)을 보내면 자동으로 가져오고, 버튼으로 수동 가져오기·보내기.
6. 안부(Awake) 신호를 4초마다 보내요(앱이 보일 때 1, 아닐 때 0).
7. 연결 상태와 오류는 쉬운 한국어로 화면에 표시해요(노트북 오류 128~134, 0x11 등).

## 일부러 안 만든 것 / 규격상 없는 것
- **터치·애플펜슬을 노트북으로 보내는 기능은 없어요.** PROTOCOL.md 에 터치 메시지가 없고, 소스에서도 확인했어요. 마우스·키보드는 노트북이 표준 블루투스 HID(키보드/마우스)로 아이패드에 직접 입력을 보내는 구조라 앱이 할 일이 없어요. (`TouchpadFingers.cs`는 노트북 터치패드 읽기용이에요.) 터치 입력이 필요하면 노트북 쪽에 새 규격을 추가해야 해요.
- iBeacon 감시(CoreLocation)와 비콘 번호 특성은 구현하지 않았어요. 찾기는 서비스 UUID 스캔으로만 해요(앱이 켜져 있을 때만).
- QR/카메라로 열쇠 스캔은 없어요. 규격에 QR이 없어서 붙여 넣기만 지원해요.
- HTTP 단축어(규격 9번), 앱 업데이트 안내 화면(`minApp` 이 높으면 오류 문구만 표시)은 간단히만 처리했어요.
- 앱 아이콘 없음(자리표시 상태).

## 확인한 것 (노트북 소스를 직접 읽어서)
- 영상 TCP: 연결 후 5초 안에 열쇠 32글자(ASCII) 전송, 틀리면 끊김. 기다리는 동안 1초마다 AUD 6바이트가 와요(`StreamServer.cs`). 프레임마다 인코더 출력 뒤에 AUD가 붙어요(`CaptureAndEncode.cs`).
- hello JSON 필드와 camelCase(`PairingHello.cs`, `Program.cs`), VideoAddress 문자열 형식 `IP:51968:열쇠`, ClipboardImage 특성 JSON(`host, port, token, ui, agent, minApp`) 이 코드와 같아요.
- `ui` 값은 `LiveUi.Root` 가 항상 null 이라 현재는 항상 null 이에요(`LiveUi.cs`).
- 이름표 값은 PROTOCOL.md(2026-11-24 갱신)대로 `glassdrop`. 앱은 옛 임시 값 `dumoni2` 도 받아 줘요(이름 바꾸기 전 노트북 빌드와 시험용).

## 확인 못 한 것 (실기기에서 봐야 해요)
- 영상 스트림 첫 프레임에 SPS/PPS가 들어 있는지(Windows 하드웨어 H.264 인코더에 따라 다름). 없으면 앱은 "화면이 오지 않아요"에서 멈춰요. 이 경우 인코더 출력에서 SPS/PPS를 따로 꺼내 붙이는 작업이 필요해요.
- 프로필/레벨, 해상도가 아이폰·아이패드 하드웨어 디코더와 맞는지.
- 키프레임이 시작 때 한 번뿐이라, 중간에 디코딩이 깨지면 재연결뿐이에요(규격에 재요청 없음). 그래서 재연결을 3번까지 자동으로 해요.
- BLE 페어링 때 iOS가 숫자 확인 창을 실제로 띄우는지, 그리고 hello 재시도 흐름이 노트북의 128/129/130 응답과 맞게 돌아가는지.
- `IP:포트:열쇠`를 BLE 없이 직접 넣는 방법: 노트북 TCP는 열쇠만 보지만, 열쇠가 노트북 화면 어디에 보이는지는 확인 못 했어요(열쇠는 노트북이 켜질 때마다 바뀜). 그래서 주소 직접 입력은 열쇠를 얻을 방법이 따로 있어야 써요.
- 노트북이 hello 없이 영상만 받아도 해상도가 맞게 설정되는지(직접 입력 연결에서는 hello를 안 보내요).
- iOS 16 대상 API(UIScreen.main 등)의 경고, Xcode 버전 차이로 인한 컴파일 오류.

## 사장님이 할 일
1. **번들 ID 정하기**: 지금 `app.glassdrop.client` 는 임시. `project.yml` 의 `PRODUCT_BUNDLE_IDENTIFIER` 를 바꿔요.
2. **애플 개발자 팀 지정**: `project.yml` 의 `settings.base` 에 `DEVELOPMENT_TEAM` 을 넣어요(팀 ID는 비밀값은 아니지만 저장소에 올릴지 정해요).
3. GitHub에 올리면 Actions 첫 빌드 결과(컴파일 오류 여부) 확인 → 오류 있으면 알려 주세요.
4. **실기기 시험**: 노트북에 Glass Drop 켜고, 아이패드/아이폰에 설치해서 찾기 → 페어링 → 화면 → 클립보드 순으로 확인.
5. 앱 아이콘·화면 문구 다듬기(디자인).

## 다음 단계
- 실기기에서 영상이 나오면: SPS/PPS, 지연 시간, 끊김 보완.
- TestFlight 올리기: 애플 개발자 계정 + 번들 ID 등록 + 서명(`CODE_SIGNING_ALLOWED=NO` 는 시뮬레이터 빌드 확인용일 뿐) + 앱 아이콘 + 개인정보 문구.
- 필요하면 터치/펜슬 입력 규격을 노트북 앱에 추가.

## 로컬에서 만들기 (맥이 있을 때)
```
brew install xcodegen
xcodegen generate
open GlassDrop.xcodeproj
```
