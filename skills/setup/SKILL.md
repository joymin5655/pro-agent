---
name: setup
description: 'pro-agent를 처음 쓸 때 모델 설정(Sonnet 기본, Opus 자문)을 점검하고 맞춘다. 결재 연결 시험도 할 수 있다.'
when_to_use: '사용자가 직접 /pro-agent:setup 으로 실행한다. "pro-agent 설정해줘", "처음 세팅 도와줘"'
disable-model-invocation: true
---

# setup — 처음 설정

1. 사용자 설정 파일을 읽는다. macOS/Linux는 `~/.claude/settings.json`, Windows는 `%USERPROFILE%\.claude\settings.json`.
   파일이 없으면 기본값으로 본다. `model`과 `advisorModel`을 확인한다.
2. `model`이 `sonnet`이 아니면: Pro 요금제에서 Claude Code 기본값은 Opus라 한도를 빨리 쓴다고 설명하고,
   `/model sonnet`을 입력해 달라고 안내한다. `advisorModel`이 없거나 `opus`가 아니면 `/advisor opus`를 권한다
   (그러면 Sonnet이 결정 지점에서만 Opus에게 묻는다).
   원하면 설정 파일을 대신 고쳐 준다: 바꿀 내용을 정확히 보여 주고 허락을 받은 뒤, 원본을
   `settings.json.bak-<YYYYMMDD>`로 복사하고 그 두 키만 바꾼다.
3. (선택) 결재 연결 시험: Opus를 조금 쓰므로 먼저 묻는다. 허락하면 `pro-agent:judge`에게
   "연결 시험입니다. '결재 연결 확인'이라고만 답하세요."를 보낸다.
   - 성공 → "결재 담당(Opus) 사용 가능"
   - Opus를 쓸 수 없다는 오류 → "이 요금제에서는 Opus를 쓸 수 없습니다. 결재는 자동으로 Sonnet이 대신합니다. 자문은 `/advisor sonnet` 또는 `/advisor off`로 바꿔 주세요."
4. (선택) PDF 변환 도구 점검: `bash "${CLAUDE_SKILL_DIR}/../pdf/pdf-to-note.sh" --check`를 실행해 결과를 알린다.
   `tool=ok`와 `java=ok`면 "PDF를 노트로 넣을 준비가 되어 있습니다". 없으면 설치 방법만 안내하고 설치는 하지 않는다.
   macOS: `brew install openjdk`, `pipx install opendataloader-pdf` / Windows: `winget install EclipseAdoptium.Temurin.21.JDK`,
   `pipx install opendataloader-pdf`. 선택 사항이라고 덧붙인다: 없어도 `pdf`는 Claude가 PDF를 직접 읽어 노트로 만든다.
5. 마지막에 세 줄로 안내한다.
   - 큰 일은 "○○ 계획 세워줘"로 시작하세요.
   - 남은 사용량은 `/usage`로 확인하세요.
   - 쉬기 전에는 "여기까지 기록해줘"라고 말하세요.
