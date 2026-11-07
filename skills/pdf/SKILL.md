---
name: pdf
description: 'PDF를 옵시디언 노트 저장소(또는 마크다운 폴더)에 노트로 넣는다. 원본 PDF도 복사하고 쪽마다 원본 그 쪽이 열리는 링크를 단다.'
when_to_use: '"이 PDF를 옵시디언에 넣어줘", "PDF를 노트로 만들어서 저장소에 정리해줘". PDF 합치기·나누기·양식 채우기·새로 만들기, PDF 내용을 한 번 읽어 달라는 요청에는 쓰지 않는다.'
---

# pdf — PDF를 노트로 넣기

도구는 이 스킬 폴더의 `pdf-to-note.sh`(아래 `$S` = `${CLAUDE_SKILL_DIR}/pdf-to-note.sh`)입니다.

1. 노트 저장소를 정한다. 요청에 경로가 있으면 그것, 없으면 현재·상위 폴더에서 `.obsidian/`이 있는 곳.
   못 찾으면 경로를 묻는다(옵시디언이 없어도 마크다운 폴더면 된다). 저장소에 CLAUDE.md·AGENTS.md가 있으면
   새 자료를 어디에 넣는지 규칙을 먼저 읽고 따른다. 기본은 노트 `PDF/`, 원본 `PDF/원본/`이고, 다른 폴더를 말하면
   `--notes-dir`·`--originals-dir`로 넘긴다.
2. PDF가 10개 이상이면 "중요한 일"이니 `plan`과 judge 승인을 먼저 권한다.
3. `bash "$S" [옵션] <pdf> <저장소>`를 PDF마다 실행한다. 같은 이름이 있으면 번호가 붙고, 있던 파일은 덮어쓰지 않는다.
   종료 코드 0이면 6번, 3이면 4번(도구 또는 Java 없음), 그 밖의 오류는 메시지를 그대로 알린다.
4. 변환 도구(opendataloader-pdf)가 없으면 그 자리에서 설치를 권한다(설치는 사용자가 한다).
   macOS: `brew install openjdk uv`, `uv tool install opendataloader-pdf` / Windows: `winget install EclipseAdoptium.Temurin.21.JDK`,
   `winget install astral-sh.uv`, `uv tool install opendataloader-pdf`(파이썬 3.11 이상은 uv가 받아 온다). Homebrew가 없으면
   https://adoptium.net 과 https://docs.astral.sh/uv/ 링크를 준다. 원하지 않으면 5번으로 간다.
5. Claude가 직접 읽기: PDF 내용이 대화로 Claude에 전달된다고 알린다. 쪽수는 `bash "$S" --info <pdf>`로 본다.
   30쪽을 넘으면 사용량이 크다고 먼저 알리고 계속할지 묻는다. 동의하면 `bash "$S" --prepare <pdf> <저장소>`로
   머리 정보 노트와 원본 복사본을 만들고, Read 도구로 PDF를 20쪽 이하씩 읽어 **요약하지 않고** 옮겨 노트 끝에 덧붙인다.
   각 쪽은 `<!-- p.N --> [[<link 값>#page=N|p.N]]` 줄로 시작한다(`link=` 줄의 값 사용).
6. 보고한다: 노트 경로, 쪽수, 쓴 도구, 그림 수, 경고. `warn=empty-pages:…`는 글자 층이 없는 쪽(스캔)이라 내용이 비었다고
   알리고, 원하면 그 쪽만 Claude가 읽어 해당 쪽 표시 아래에 채운다(그 쪽만큼 사용량이 든다).
7. 끝나면 "노트에서 물어보려면 ask로 질문하세요"라고 안내한다.
