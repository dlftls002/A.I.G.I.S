# 패치 — LED 검출 구역 90° 회전 + 위치/크기 조정

대상 프로젝트: `basys3project_inseok`
작성일: 2026-08-07

## 무엇이 바뀌었나

브레드보드를 세로로 세우고 카메라를 비스듬히 달았더니 화면에서 보드가 누워
보였다. 축 정렬 사각형으로는 LED를 담을 수 없어 **검출 구역을 시계방향 90°로
회전**시켰다. 함께 격자를 조금 키우고 오른쪽으로 옮겼다.

**인터페이스는 바뀌지 않았다.** 모듈 포트, SPI 패킷 형식, 상태 코드가 모두
그대로다. 따라서 아래 3개 파일만 덮어쓰면 끝난다.

## 적용 방법

패치의 `rtl/` 폴더를 프로젝트 루트에 그대로 덮어쓴다. 폴더 구조가 동일하다.

```
rtl/legacy/vision/RTL/LED_Set/led_zone_pkg.sv       (덮어쓰기)
rtl/legacy/vision/RTL/LED_Set/led_zone_monitor.sv   (덮어쓰기)
rtl/legacy/vision/RTL/Frame_Set/Frame_Set.sv        (덮어쓰기)
```

그리고 재합성한다. **다른 작업은 필요 없다.**

## 손대지 않아도 되는 것

| 항목 | 이유 |
|---|---|
| `scripts/create_project.tcl` | 파일이 추가·삭제되지 않았다 |
| `rtl/secure/basys3_secure_rack_control.sv` | 모듈 포트가 그대로다 |
| `constraints/basys3_secure.xdc` | 핀 변경 없음 |
| `rtl/legacy/vision/RTL/CAM_Set/*` | 변경 없음 |
| `LED_Set/unit_status.sv`, `status_packer.sv`, `LED_Set.sv` | 변경 없음 |
| `UI_Set/Drone_detector/Drone_Classification_Color.sv` | 내용 동일 (경로 유지) |
| SPI 패킷 형식 (16바이트, v2) | 변경 없음 |

## 파일별 변경 내용

### `LED_Set/led_zone_pkg.sv`

회전 상수와 변환 함수를 추가하고 구역 좌표표를 회전 후 좌표계 기준으로
교체했다.

```systemverilog
// Q8 고정소수점 (256 = 1.0)
localparam int ROT_COS = 0;      // 90도
localparam int ROT_SIN = 256;

function automatic int rot_x (input int sx, input int sy);   // 화면 -> 회전 후
function automatic int rot_y (input int sx, input int sy);
function automatic int unrot_x (input int rx, input int ry); // 역변환 (검증용)
function automatic int unrot_y (input int rx, input int ry);
```

구역 좌표는 **회전 후 좌표계** 기준이다. 회전 후에는 보드가 똑바로 서 있어
평범한 2열 × 3행 격자가 된다.

### `LED_Set/led_zone_monitor.sv`

픽셀 좌표를 한 번 역회전시킨 뒤 축 정렬 비교를 한다. 구역 6개를 각각
회전시키지 않으므로 곱셈이 6배로 늘지 않는다.

```systemverilog
logic signed [11:0] rot_px, rot_py;
assign rot_px = 12'(rot_x(int'(cur_px), int'(cur_py)));
assign rot_py = 12'(rot_y(int'(cur_px), int'(cur_py)));
```

### `Frame_Set/Frame_Set.sv`

화면 오버레이에 **동일한 변환**을 적용한다. 변환 함수를 패키지에 하나만 두어
화면에 보이는 칸과 실제 판정 영역이 어긋날 수 없게 했다.

## 예상 화면 배치 (카메라 320×240)

```
    0                                                            319
    ┌──────────────────────────────────────────────────────────────┐ 0
 58 │        ┌──────────┐   ┌──────────┐   ┌──────────┐            │
    │        │  zone 4  │   │  zone 2  │   │  zone 0  │            │
    │        │  u2 · A  │   │  u1 · A  │   │  u0 · A  │            │
117 │        └──────────┘   └──────────┘   └──────────┘            │
129 │        ┌──────────┐   ┌──────────┐   ┌──────────┐            │
    │        │  zone 5  │   │  zone 3  │   │  zone 1  │            │
    │        │  u2 · B  │   │  u1 · B  │   │  u0 · B  │            │
188 │        └──────────┘   └──────────┘   └──────────┘            │
    └──────────────────────────────────────────────────────────────┘ 239
            61       124   135      198   209      272
             └ 보드 아래                        보드 위 ┘
```

각 칸 63×59 픽셀. 화면 점유 x 61~272, y 58~188.

- **보드 위(unit 0)** → 화면 **오른쪽**
- **보드 아래(unit 2)** → 화면 **왼쪽**
- 유닛 안의 LED A/B → 화면 **위/아래**

## 추후 조정 방법

각도를 바꾸려면 `led_zone_pkg.sv`의 상수 **두 개만** 고친다. 검출과 화면이
함께 따라간다.

| 각도 | `ROT_COS` | `ROT_SIN` |
|---|---|---|
| 0° | 256 | 0 |
| 45° | 181 | 181 |
| **90°** | **0** | **256** |
| 반시계 90° | 0 | -256 |

구역 위치는 좌표표를 고친다. 90°에서는 방향이 이렇게 대응된다.

```
zone_y 감소  ->  화면 오른쪽으로     (화면x = 280 - ry)
zone_x 증가  ->  화면 아래로         (화면y = rx - 40)
```

오른쪽 여백이 47픽셀 남아 있어 더 밀 여지는 크지 않다.

## 검증 결과

패치 적용 상태에서 확인했다.

| 항목 | 결과 |
|---|---|
| `basys3_secure_rack_control` elaborate | **성공** (팀원 프로젝트 파일 목록 그대로 + 이 3개 치환) |
| 구역 지오메트리 (꼭짓점 24개 + 겹침 15쌍) | 54/54 |
| 구역 검출 + 히스테리시스 | 7/7 |
| 픽셀 색 판정 | 15/15 |
| SPI 패킷 | 19/19 |

지오메트리 검사는 **네 꼭짓점을 화면 좌표로 되돌려** 프레임 안에 들어오는지
전수 확인한다. 회전 때문에 구역이 화면 밖으로 잘리면 그 LED는 영원히 잡히지
않는데 증상이 조용해서 자동 검사가 필요하다.

## 남은 작업

구역 좌표는 아직 **추정치**다. 보드에 올려 `sw[0]`으로 격자를 띄우고 LED가
칸 안에 들어오도록 카메라를 맞춘 뒤, 어긋나면 `led_zone_pkg.sv`의 좌표
12개를 조정해야 한다.
