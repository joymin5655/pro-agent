# 어떻게 동작하나요

이 문서는 pro-agent가 모델을 어떻게 나누고, 규칙을 어떻게 넣고, 어디서 동작하는지 설명합니다.
Claude Code에 관한 내용은 모두 공식 문서에서 가져왔고, 확인한 날짜는 2026-11-06입니다.

## 모델 배분과 근거

**기본 모델.** 공식 문서는 이렇게 적습니다.

> Pro, Max, Ultra, Team, Enterprise, and Anthropic API: defaults to Opus 5.5

출처: [Default model setting](https://code.claude.com/docs/en/model-config#default-model-setting)

**충돌하는 안내.** 오류 문서에는 이런 항목이 있습니다.

> Claude Opus is not available with the Claude Pro plan.

해결 방법으로는 `/model`을 열어 요금제에 포함된 모델을 고르라고 합니다.
출처: [Errors](https://code.claude.com/docs/en/errors#claude-opus-is-not-available-with-the-claude-pro-plan)

두 안내가 맞지 않고, 만든 사람은 Pro 계정으로 시험해 보지 못했습니다. 그래서 키트는 메인 모델을 Sonnet으로 두고, 결재 담당(judge)이 Opus를 못 쓰면 Sonnet으로 대신합니다.

**자문 기능(advisor).** 메인 Sonnet이 일하다가 막히면 Opus에게 묻는 기능입니다. 문서의 조합표에는 이런 줄이 있습니다.

> Sonnet main + Opus advisor | Sonnet handles routine work and escalates planning, ambiguous failures, and completion checks to Opus

알아 둘 점은 다음과 같습니다.

- 문서는 "The advisor tool is experimental"이라고 밝힙니다.
- 구독 요금제에서는 "advisor usage counts toward your plan's usage limits"입니다.
- "pairing a faster main model with a stronger advisor typically costs less than running the stronger model throughout"입니다.
- 메인 모델 Sonnet 5.5는 자문으로 "Fable, Opus 5 or later, Sonnet 5.5"를 받습니다.
- "Subagents inherit the configured advisor"입니다. 보조 AI도 같은 자문을 물려받습니다.
- "If the API refuses the pairing of an advisor that Claude Code attached, Claude Code resends that request without the advisor"입니다. 조합이 거부되면 자문 없이 조용히 이어 갑니다.
- 명령은 `/advisor opus`, `/advisor sonnet`, `/advisor off`입니다. `/advisor`만 치면 현재 자문을 보여 줍니다. 선택은 `advisorModel`로 저장됩니다.
- Fable을 자문으로 쓰면 사용 크레딧이 청구될 수 있습니다.

출처: [Advisor](https://code.claude.com/docs/en/advisor)

**opusplan.** 계획 모드에서는 Opus, 실행에서는 Sonnet을 쓰는 설정입니다. 문서 표현은 "uses `opus` during plan mode, then switches to `sonnet` for execution"입니다. 키트의 기본값은 아니며 Opus 접근이 필요합니다.
출처: [opusplan](https://code.claude.com/docs/en/model-config#opusplan-model-setting)

**Fable.** 문서에 따르면 "Fable usage can bill to usage credits"입니다(요금제에 따라 다릅니다). 키트는 사용자가 분명히 허락하기 전에는 Fable로 바꾸지 않습니다.
출처: [Fable and usage credits](https://code.claude.com/docs/en/model-config#fable-and-usage-credits)

`/model sonnet`을 치면 선택이 새 대화의 기본값으로 저장됩니다(사용자 설정의 `model`).
출처: [Model config](https://code.claude.com/docs/en/model-config)

## 보조 AI의 모델이 정해지는 순서

보조 AI(subagent)가 쓸 모델은 아래 순서로 정해집니다.

1. 부를 때 넘기는 `model` 값
2. 에이전트 파일에 적힌 `model`
3. 환경 변수 `CLAUDE_CODE_SUBAGENT_MODEL`
4. 메인 대화의 모델

모델이 정해져 있지 않은 기본 제공 에이전트는 메인 모델을 물려받습니다.
출처: [Subagents](https://code.claude.com/docs/en/sub-agents)

그래서 키트의 에이전트 세 개는 파일에 모델을 적어 두었습니다.

| 에이전트 | 파일의 model |
|---|---|
| scout | haiku |
| reviewer | sonnet |
| judge | opus |

judge가 Opus 오류로 실패하면 운영 규칙에 따라 같은 요청을 다시 보냅니다. 이때는 1번 자리, 곧 호출마다 넘기는 `model: sonnet`을 씁니다. 에이전트 파일의 `opus`보다 호출 값이 우선하기 때문입니다.
기본 에이전트(Explore, general-purpose)를 부를 때도 `model`을 직접 적도록 규칙에 들어 있습니다.

## 플러그인이 못 하는 것

- 플러그인은 모델이나 자문을 설정할 수 없습니다. 플러그인 설정 중 "Only `agent` and `subagentStatusLine` take effect"입니다. 그래서 사용자가 `/model sonnet`과 `/advisor opus` 두 줄을 칩니다.
- "A `CLAUDE.md` at the plugin root isn't loaded as context"입니다. 그래서 규칙을 `CLAUDE.md`에 두지 않고 세션 시작 자동 점검 장치(hook)로 넣습니다.

출처: [Plugins reference](https://code.claude.com/docs/en/plugins-reference)

## 운영 규칙이 들어가는 방식

`hooks/hooks.json`은 두 가지를 등록합니다.

- SessionStart: `hooks/session-start.sh` 실행
- PreToolUse(Bash): `hooks/guard-bash.sh` 실행 (위험 명령 점검, 자세한 내용은 [safety.md](safety.md))

SessionStart 자동 점검 장치의 출력은 대화 맥락에 들어갑니다. 문서에 "Claude Code adds plain-text stdout as context"라고 되어 있습니다([Hooks](https://code.claude.com/docs/en/hooks)).

`session-start.sh`가 하는 일은 두 가지입니다.

1. `rules/operating-rules.md`를 그대로 출력합니다.
2. 프로젝트에 `agent-notes/PROGRESS.md`가 있으면 "이어서 할 일이 있습니다" 안내와 함께 그 파일의 앞 40줄을 출력합니다. 첫 답변에서 1~2줄로 알리고 이어 할지 묻도록 안내합니다.

스크립트는 어떤 경우에도 오류 없이 끝나도록(exit 0) 만들었습니다.

## 어디서 무엇이 동작하나

| 기능 | Claude Code | Cowork | 채팅 | 클라우드 세션 |
|---|---|---|---|---|
| 스킬·명령 | 동작 | 동작 | 동작 | 불러오지 않음 |
| pdf·ask (파일을 읽고 씀) | 동작 | 동작(직접 시험 못 함) | 쓸 수 없음(파일 저장 불가) | 불러오지 않음 |
| 보조 AI(scout, reviewer, judge) | 동작 | 동작 | 없음 | 불러오지 않음 |
| 세션 시작 규칙·명령 차단(hook) | 동작 | 동작 | 없음 | 불러오지 않음 |

근거는 두 문서입니다.

- 채팅·Cowork: 에이전트는 Cowork와 Claude Code에서만 동작하고, 자동 점검 장치는 플러그인이 내 컴퓨터에서 도는 곳(Cowork, Claude Code)에서만 동작합니다. 채팅은 스킬과 명령만 받습니다. ([Plugins overview](https://claude.com/docs/plugins/overview))
- 클라우드 세션: claude.ai/code를 포함한 클라우드 세션은 내 컴퓨터에 설치한 플러그인을 불러오지 않습니다. ([Install plugins](https://code.claude.com/docs/en/plugins/install))

Cowork 열은 공식 안내서만 근거로 했고 직접 시험하지는 않았습니다.

## PDF 노트 기능(pdf, ask)

- `pdf`의 결정적인 부분(변환 도구와 Java 찾기, 파일 복사, 이름 겹침 피하기, 머리 정보, 쪽 표시)은 `skills/pdf/pdf-to-note.sh` 셸 스크립트가 맡습니다. Claude가 같은 일을 매번 다르게 하지 않게 하려는 것입니다. 종료 코드는 0 성공, 2 입력 오류 또는 저장 실패, 3 도구 또는 Java 없음, 4 변환 실패이고, 3이면 스킬이 설치 권유 → Claude 직접 읽기 순서로 넘어갑니다.
- 변환 도구가 있으면 내 컴퓨터에서 opendataloader-pdf가 PDF를 마크다운으로 바꿉니다. 이때 PDF는 키트가 밖으로 보내지 않습니다. 도구가 없고 사용자가 설치를 원하지 않으면 Claude가 PDF를 20쪽 이하씩 직접 읽어 같은 형식으로 옮기며, 이때 PDF 내용이 대화로 Claude에 전달됩니다.
- 노트의 쪽 표시 `<!-- p.N --> [[원본.pdf#page=N|p.N]]` 한 줄이 두 일을 합니다. `ask`는 `<!-- p.N -->`로 쪽 번호를 찾고, 같은 줄의 링크를 출처로 씁니다.
- `ask`는 낱말 검색입니다. 질문을 낱말 묶음으로 나눠 scout(Haiku)가 Grep으로 동시에 찾고, 메인 Sonnet이 찾은 쪽만 읽고 답합니다. 뜻 검색이나 검색 목록 파일은 만들지 않습니다.

## "중요한 일" 기준

운영 규칙(`rules/operating-rules.md`)의 다섯 가지입니다. 하나라도 해당하면 judge를 부릅니다.

1. 되돌리기 어렵습니다 (삭제, 덮어쓰기, 배포, 기록 되감기)
2. 바깥으로 나갑니다 (메일·메시지 전송, 게시, 공개)
3. 돈이 듭니다
4. 큽니다 (파일 10개 이상 또는 1시간 이상)
5. 사용자가 중요하다고 말했습니다

그 밖의 일에는 judge를 부르지 않습니다. Opus 사용을 꼭 필요한 판단으로 좁히려는 것입니다.

## 진행 메모 파일

- `agent-notes/PLAN.md`: `plan` 스킬이 만듭니다. 틀은 `skills/plan/PLAN-template.md`에 있습니다. 이미 있으면 덮어쓰기 전에 묻고, 옛 파일은 `agent-notes/archive/`로 옮깁니다.
- `agent-notes/PROGRESS.md`: `save`, `do`, `check`가 갱신합니다. 틀은 `skills/save/PROGRESS-template.md`에 있습니다. 끝난 단계 줄은 지우지 않습니다.

두 파일은 지금 작업하는 프로젝트 폴더 안에 생깁니다. 그 프로젝트를 git으로 관리하는데 메모는 저장소에 올리고 싶지 않다면, 그 프로젝트의 `.gitignore`에 `agent-notes/` 한 줄을 넣으세요.
